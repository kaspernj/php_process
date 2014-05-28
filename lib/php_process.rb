require "wref" if !Kernel.const_defined?(:Wref)
require "tsafe" if !Kernel.const_defined?(:Tsafe)
require "php-serialize4ruby"
require "base64"
require "open3"
require "thread"
require "string-cases"

#This class starts a PHP-process and proxies various calls to it. It also spawns proxy-objects, which can you can call like they were normal Ruby-objects.
#===Examples
# php = PhpProcess.new
# print "PID of PHP-process: #{php.func("getmypid")}\n"
# print "Explode test: #{php.func("explode", ";", "1;2;3;4;5")}\n"
class PhpProcess
  #Autoloader for subclasses.
  def self.const_missing(name)
    path = "#{File.dirname(__FILE__)}/../include/#{::StringCases.camel_to_snake(name)}.rb"
    raise LoadError, "Does not exist: '#{path}'." unless File.exists?(path)
    require path
    raise LoadError, "Still not defined after autoload: '#{name}'." unless ::PhpProcess.const_defined?(name)
    return ::PhpProcess.const_get(name)
  end
  
  #Returns the path to the gem.
  def self.path
    return File.realpath(File.dirname(__FILE__))
  end
  
  #A hash that contains links between Ruby object IDs and the PHP object IDs. It can be read because the proxy-objects adds their data to it.
  attr_reader :object_ids
  
  #This object controls which IDs should be unset on the PHP-side by being a destructor on the Ruby-side.
  def objects_unsetter(id)
    obj_count_id = @object_ids[id]
    
    if @object_unset_ids.index(obj_count_id) == nil
      @object_unset_ids << obj_count_id
    end
    
    @object_ids.delete(id)
  end
  
  #Spawns various used variables, launches the process and more.
  #===Examples
  #If you want debugging printed to stderr:
  # php = PhpProcess.new(:debug => true)
  INITIALIZE_VALID_ARGS = [:debug, :debug_output, :debug_stderr, :cmd_php, :on_err]
  def initialize(args = {})
    parse_args_and_set_vars(args)
    start_php_process
    check_alive
    $stderr.puts "PHP-script ready." if @debug
    start_read_loop
    
    if block_given?
      begin
        yield(self)
      ensure
        self.destroy
      end
    end
  end
  
  def parse_args_and_set_vars(args)
    args.each do |key, val|
      raise "Invalid argument: '#{key}'." unless INITIALIZE_VALID_ARGS.include?(key)
    end
    
    @args = args
    @debug = @args[:debug]
    @debug_output = @args[:debug_output]
    @send_count = 0
    @send_mutex = Mutex.new
    @responses = Tsafe::MonHash.new
    @object_ids = Tsafe::MonHash.new
    @object_unset_ids = Tsafe::MonArray.new
    @objects = Wref_map.new
    @constant_val_cache = Tsafe::MonHash.new
    
    #Used for 'create_func'.
    @callbacks = {}
    @callbacks_count = 0
    @callbacks_mutex = Mutex.new
  end
  
  def start_php_process
    if RUBY_ENGINE == "jruby"
      pid, @stdin, @stdout, @stderr = IO.popen4(php_cmd_as_string)
    else
      @stdin, @stdout, @stderr = Open3.popen3(php_cmd_as_string)
    end
    
    @stdin.sync = true
    @stdin.set_encoding("iso-8859-1:utf-8")
    
    @stdout.sync = true
    @stdout.set_encoding("utf-8:iso-8859-1")
    
    @stderr_handler = ::PhpProcess::StderrHandler.new(:stderr => @stderr, :php_process => self)
    start_out_reader_thread
  end
  
  #Returns various info in a hash about the object-cache on the PHP-side.
  def object_cache_info
    return self.send(:type => :object_cache_info)
  end
  
  #Joins all the threads.
  def join
    @thread.join if @thread
    @err_thread.join if @err_thread
  end
  
  #Destroys the object closing and unsetting everything.
  def destroy
    @destroyed = true
    @stdout.close if @stdout && !@stdout.closed?
    @stdin.close if @stdin && !@stdin.closed?
    @stderr.close if @stderr && !@stderr.closed?
    
    # Respond to any waiting queues to avoid locking those threads.
    if @responses
      @responses.each do |id, queue|
        queue.push(::PhpProcess::DestroyedError.new)
      end
    end
  end
  
  #Returns the if the object has been destroyed.
  def destroyed?
    return true if @destroyed
    return false
  end
  
  #Proxies to 'send_real' but calls 'flush_unset_ids' first.
  def send(hash)
    raise ::PhpProcess::DestroyedError if destroyed?
    flush_unset_ids
    return send_real(hash)
  end
  
  #Evaluates a string containing PHP-code and returns the result.
  #===Examples
  # print php.eval("array(1 => 2);") #=> {1=>2}
  def eval(eval_str)
    return send(:type => :eval, :eval_str => eval_str)
  end
  
  #Spawns a new object from a given class with given arguments and returns it.
  #===Examples
  # pe = php.new("PHPExcel")
  # pe.getProperties.setCreator("kaspernj")
  def new(classname, *args)
    return send(:type => :new, :class => classname, :args => parse_data(args))
  end
  
  #Call a function in PHP.
  #===Examples
  # arr = php.func("explode", ";", "1;2;3;4;5")
  # pid_of_php_process = php.func("getmypid")
  # php.func("require_once", "PHPExcel.php")
  def func(func_name, *args)
    return send(:type => :func, :func_name => func_name, :args => parse_data(args))
  end
  
  #Sends a call to a static method on a class with given arguments.
  #===Examples
  # php.static("Gtk", "main_quit")
  def static(class_name, method_name, *args)
    return send(:type => :static_method_call, :class_name => class_name, :method_name => method_name, :args => parse_data(args))
  end
  
  #Creates a function on the PHP-side. When the function is called, it callbacks to the Ruby-side which then can execute stuff back to PHP.
  #===Examples
  # func = php.create_func do |d|
  #   d.php.static("Gtk", "main_quit")
  # end
  #
  # button.connect("clicked", func)
  def create_func(args = {}, &block)
    callback_id = nil
    func = nil
    @callbacks_mutex.synchronize do
      callback_id = @callbacks_count
      func = PhpProcess::CreatedFunction.new(:php => self, :id => callback_id)
      @callbacks[callback_id] = {:block => block, :func => func, :id => callback_id}
      @callbacks_count += 1
    end
    
    raise "No callback-ID?" if !callback_id
    self.send(:type => :create_func, :callback_id => callback_id)
    
    return func
  end
  
  #This flushes the unset IDs to the PHP-process and frees memory. This is automatically called if 500 IDs are waiting to be flushed. Normally you would not need or have to call this manually.
  #===Examples
  # php.flush_unset_ids(true)
  def flush_unset_ids(force = false)
    return nil if self.destroyed? or (!force and @object_unset_ids.length < 500)
    while @object_unset_ids.length > 0 and elements = @object_unset_ids.shift(500)
      $stderr.print "Sending unsets: #{elements}\n" if @debug
      send_real("type" => "unset_ids", "ids" => elements)
    end
    
    #Clean wref-map.
    @objects.clean
  end
  
  #Parses argument-data into special hashes that can be used on the PHP-side. It is public because the proxy-objects uses it. Normally you would never use it.
  def parse_data(data)
    if data.is_a?(PhpProcess::ProxyObject)
      return {:type => :proxyobj, :id => data.args[:id]}
    elsif data.is_a?(PhpProcess::CreatedFunction)
      return {:type => :php_process_created_function, :id => data.args[:id]}
    elsif data.is_a?(Hash)
      newhash = {}
      data.each do |key, val|
        newhash[key] = parse_data(val)
      end
      
      return newhash
    elsif data.is_a?(Array)
      newarr = []
      data.each do |val|
        newarr << parse_data(val)
      end
      
      return newarr
    else
      return data
    end
  end
  
  #Returns the value of a constant on the PHP-side.
  def constant_val(name)
    const_name = name.to_s
    
    unless @constant_val_cache.key?(const_name)
      @constant_val_cache[const_name] = self.send(:type => :constant_val, :name => name)
    end
    
    return @constant_val_cache[const_name]
  end
  
  #Returns various informations about boths sides memory in a hash.
  def memory_info
    return {
      :php_info => self.send(:type => :memory_info),
      :ruby_info => {
        :responses => @responses.length,
        :objects_ids => @object_ids.length,
        :object_unset_ids => @object_unset_ids.length,
        :objects => @objects.length
      }
    }
  end
  
private
  
  def start_out_reader_thread
    $stderr.print "Waiting for PHP-script to be ready.\n" if @debug
    started = false
    @stdout.each_line do |line|
      if match = line.match(/^php_script_ready:(\d+)\n/)
        started = true
        break
      end
      
      $stderr.print "Line gotten while waiting: #{line}" if @debug
    end
    
    if !started
      stderr_output = @stderr.read
      raise "PHP process wasnt started: #{stderr_output}"
    end
  end
  
  def php_cmd_as_string
    bin_path_tries = [
      "/usr/bin/php5",
      "/usr/bin/php"
    ]
    
    cmd_str = ""
    
    if @args[:cmd_php]
      cmd_str = "#{@args[:cmd_php]}"
    else
      bin_path_tries.each do |bin_path|
        next unless File.exists?(bin_path)
        cmd_str << bin_path
        break
      end
      
      if cmd_str.empty? && File.exists?("/usr/bin/env")
        cmd_str = "/usr/bin/env php5"
      end
    end
    
    cmd_str << " \"#{File.dirname(__FILE__)}/php_script.php\""
    
    return cmd_str
  end
  
  #Generates the command from the given object and sends it to the PHP-process. Then returns the parsed result.
  def send_real(hash)
    $stderr.print "Sending: #{hash[:args]}\n" if @debug and hash[:args]
    str = ::Base64.strict_encode64(::PHP.serialize(hash))
    
    #Find new ID for the send-request.
    id = nil
    @send_mutex.synchronize do
      id = @send_count
      @send_count += 1
    end
    
    @responses[id] = ::Queue.new
    
    begin
      @stdin.write("send:#{id}:#{str}\n")
    rescue Errno::EPIPE, IOError => e
      #Wait for fatal error and then throw it.
      Thread.pass
      check_alive
      
      #Or just throw the normal error.
      raise e
    end
    
    #Then return result.
    return read_result(id)
  end
  
  def wait_for_and_read_response(id)
    $stderr.print "php_process: Waiting for answer to ID: #{id}\n" if @debug
    check_alive
    
    begin
      resp = @responses[id].pop
    rescue Exception => e
      if e.class.name.to_s == "fatal"
        $stderr.puts "php_process: Deadlock error detected." if @debug
        
        #Wait for fatal error to be registered through thread and then throw it.
        sleep 0.2
        Thread.pass
        $stderr.puts "php_process: Checking for alive." if @debug
        check_alive
      end
      
      raise e
    ensure
      @responses.delete(id)
    end
  end
  
  def generate_php_error(resp)
    begin
      raise ::Kernel.const_get(resp["ruby_type"]), resp["msg"] if resp.key?("ruby_type")
      raise PhpError, resp["msg"]
    rescue => e
      # This adds the PHP-backtrace to the Ruby-backtrace, so it looks like it is part of the same application, which is kind of is.
      php_bt = []
      resp["bt"].split("\n").each do |resp_bt|
        php_bt << resp_bt.gsub(/\A#(\d+)\s+/, "")
      end
      
      # Rethrow exception with combined backtrace.
      e.set_backtrace(php_bt + e.backtrace)
      raise e
    end
  end
  
  #Searches for a result for a ID and returns it. Runs 'check_alive' to see if the process should be interrupted.
  def read_result(id)
    resp = wait_for_and_read_response(id)
    
    # Errors are pushed in case of fatals and destroys to avoid deadlock.
    raise resp if resp.is_a?(Exception)
    
    if resp.is_a?(Hash) && resp["type"] == "error" && resp.key?("msg") && resp.key?("bt")
      generate_php_error(resp)
    end
    
    $stderr.print "Found answer #{id} - returning it.\n" if @debug
    return read_parsed_data(resp)
  end
  
  #Checks if something is wrong. Maybe stdout got closed or a fatal error appeared on stderr?
  def check_alive
    if @fatal
      message = @fatal
      @fatal = nil
      error = ::PhpProcess::FatalError.new(message)
      
      @responses.each do |id, queue|
        queue.push(error)
      end
      
      $stderr.puts "php_process: Throwing fatal error for: #{caller}" if @debug
      destroy
    elsif destroyed?
      raise PhpProcess::DestroyedError
    end
    
    raise "stdout closed." if !@stdout || @stdout.closed?
  end
  
  #Parses special hashes to proxy-objects and leaves the rest. This is used automatically.
  def read_parsed_data(data)
    if data.is_a?(Array) && data.length == 2 && data[0] == "proxyobj"
      id = data[1].to_i
      
      if proxy_obj = @objects.get!(id)
        $stderr.print "Reuse proxy-obj!\n" if @debug
        return proxy_obj
      else
        $stderr.print "Spawn new proxy-obj!\n" if @debug
        proxy_obj = ::PhpProcess::ProxyObject.new(
          :php => self,
          :id => id
        )
        @objects[id] = proxy_obj
        return proxy_obj
      end
    elsif data.is_a?(Hash)
      newdata = {}
      data.each do |key, val|
        newdata[key] = read_parsed_data(val)
      end
      
      return newdata
    else
      return data
    end
  end
  
  def spawn_call_back_created_func(args)
    Thread.new do
      begin
        func_d = @callbacks[args["func_id"].to_i]
        func_d[:block].call(*args["args"])
      rescue => e
        $stderr.puts "Error while calling in thread."
        $stderr.puts e.inspect
        $stderr.puts e.backtrace
      end
    end
  end
  
  #Starts the thread which reads answers from the PHP-process. This is called automatically from the constructor.
  def start_read_loop
    @thread = Thread.new do
      begin
        read_loop
        $stderr.puts "php_process: Read-loop stopped." if @debug
      rescue => e
        unless destroyed?
          $stderr.puts "Error in read-loop-thread."
          $stderr.puts e.inspect
          $stderr.puts e.backtrace
        end
      end
    end
  end
  
  def read_loop
    @stdout.each_line do |line|
      parsed = parse_line(line.to_s.strip)
      next if parsed == :next
      id, type, args = parsed[:id], parsed[:type], parsed[:args]
      $stderr.print "Received: #{id}:#{type}:#{args}\n" if @debug
      
      if type == "answer"
        @responses[id].push(args)
      elsif type == "send"
        spawn_call_back_created_func(args) if args["type"] == "call_back_created_func"
      else
        raise "Unknown type: '#{type}'."
      end
    end
  end
  
  def parse_line(line)
    if line.empty? || @stdout.closed?
      $stderr.puts "Got empty line from process - skipping: #{line}" if @debug
      return :next
    end
    
    check_for_special(line)
    data = line.split(":")
    raise "Didn't contain any data: #{data}" if !data[2] || data[2].empty?
    args = ::PHP.unserialize(::Base64.strict_decode64(data[2].strip))
    
    return {:type => data[0], :id => data[1].to_i, :args => args}
  end
  
  # Checks the given string for special input like when a fatal error occurred or the sub-process is killed off.
  def check_for_special(str)
    if str.match(/^(PHP |)Fatal error: (.+)\s*/)
      $stderr.puts "Fatal error detected: #{str}" if @debug
      @fatal = str.strip
      check_alive
    elsif str.match(/^Killed\s*$/)
      $stderr.puts "Killed error detected: #{str}" if @debug
      @fatal = "Process was killed."
      check_alive
    end
  end
end
