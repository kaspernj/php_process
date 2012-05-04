require "knjrbfw"
require "base64"
require "php_serialize"

#This class starts a PHP-process and proxies various calls to it. It also spawns proxy-objects, which can you can call like they were normal Ruby-objects.
#===Examples
# php = Php_process.new
# print "PID of PHP-process: #{php.func("getmypid")}\n"
# print "Explode test: #{php.func("explode", ";", "1;2;3;4;5")}\n"
class Php_process
  #A hash that contains links between Ruby object IDs and the PHP object IDs. It can be read because the proxy-objects adds their data to it.
  attr_reader :object_ids
  
  #This object controls which IDs should be unset on the PHP-side by being a destructor on the Ruby-side.
  def objects_unsetter(id)
    @object_unset_ids << @object_ids[id]
    @object_ids.delete(id)
  end
  
  #Spawns various used variables, launches the process and more.
  #===Examples
  #If you want debugging printed to stderr:
  # php = Php_process.new(:debug => true)
  def initialize(args = {})
    @args = args
    @debug = @args[:debug]
    @send_count = 0
    @responses = Knj::Threadsafe::Synced_hash.new
    @object_ids = Knj::Threadsafe::Synced_hash.new
    @object_unset_ids = Knj::Threadsafe::Synced_array.new
    
    cmd_str = "/usr/bin/env php5 \"#{File.dirname(__FILE__)}/php_script.php\""
    
    if RUBY_ENGINE == "jruby"
      pid, @stdin, @stdout, @stderr = IO.popen4(cmd_str)
    else
      @stdin, @stdout, @stderr = Open3.popen3(cmd_str)
    end
    
    @stdout.sync = true
    @stdin.sync = true
    
    @stdout.autoclose = true
    @stdin.autoclose = true
    
    @err_thread = Knj::Thread.new do
      @stderr.each_line do |str|
        if str.match(/^PHP Fatal error: (.+)\s+/)
          @fatal = str.strip
        end
        
        @args[:on_err].call(str) if @args[:on_err]
        $stderr.print "Process error: #{str}" if @debug
      end
    end
    
    $stderr.print "Waiting for PHP-script to be ready.\n" if @debug
    started = false
    @stdout.lines do |line|
      if match = line.match(/^php_script_ready:(\d+)\n/)
        started = true
        break
      end
      
      $stderr.print "Line gotten while waiting: #{line}" if @debug
    end
    
    raise "PHP process wasnt started." if !started
    check_alive
    
    $stderr.print "PHP-script ready.\n" if @debug
    start_read_loop
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
    @thread.kill if @thread
    @err_thread.kill if @err_thread
    @stdout.close if @stdout
    @stdin.close if @stdin
    @stderr.close if @stderr
    @thread = nil
    @err_thread = nil
    @fatal = nil
    @responses = nil
    @object_ids = nil
    @object_unset_ids = nil
    @send_count = nil
    @args = nil
    @debug = nil
  end
  
  #Proxies to 'send_real' but calls 'flush_unset_ids' first.
  def send(hash)
    self.flush_unset_ids
    return send_real(hash)
  end
  
  #Evaluates a string containing PHP-code and returns the result.
  #===Examples
  # print php.eval("array(1 => 2);") #=> {1=>2}
  def eval(eval_str)
    return self.send(:type => :eval, :eval_str => eval_str)
  end
  
  #Spawns a new object from a given class with given arguments and returns it.
  #===Examples
  # pe = php.new("PHPExcel")
  # pe.getProperties.setCreator("kaspernj")
  def new(classname, *args)
    return self.send(:type => :new, :class => classname, :args => args)["object"]
  end
  
  #Call a function in PHP.
  #===Examples
  # arr = php.func("explode", ";", "1;2;3;4;5")
  # pid_of_php_process = php.func("getmypid")
  # php.func("require_once", "PHPExcel.php")
  def func(func_name, *args)
    return self.send(:type => :func, :func_name => func_name, :args => args)["result"]
  end
  
  #This flushes the unset IDs to the PHP-process and frees memory. This is automatically called if 500 IDs are waiting to be flushed. Normally you would not need or have to call this manually.
  #===Examples
  # php.flush_unset_ids(true)
  def flush_unset_ids(force = false)
    return nil if !force and @object_unset_ids.length < 500
    while @object_unset_ids.length > 0 and elements = @object_unset_ids.shift(500)
      $stderr.print "Sending unsets: #{elements}\n" if @debug
      send_real("type" => "unset_ids", "ids" => elements)
    end
  end
  
  private
  
  #Generates the command from the given object and sends it to the PHP-process. Then returns the parsed result.
  def send_real(hash)
    $stderr.print "Sending: #{hash}\n" if @debug
    str = Base64.strict_encode64(PHP.serialize(hash))
    @stdin.write("send:#{@send_count}:#{str}\n")
    id = @send_count
    @send_count += 1
    
    #Slep a tiny bit to wait for first answer.
    sleep 0.001
    
    #Then return result.
    return read_result(id)
  end
  
  #Searches for a result for a ID and returns it. Runs 'check_alive' to see if the process should be interrupted.
  def read_result(id)
    loop do
      if @responses.key?(id)
        resp = @responses[id]
        @responses.delete(id)
        
        if resp.is_a?(Hash) and resp["type"] == "error"
          raise "#{resp["msg"]}\n\n#{resp["bt"]}"
        end
        
        return read_parsed_data(resp)
      end
      
      check_alive
      sleep 0.05
      $stderr.print "Waiting for answer to ID: #{id}\n" if @debug
    end
  end
  
  #Checks if something is wrong. Maybe stdout got closed or a fatal error appeared on stderr?
  def check_alive
    raise "stdout closed." if @stdout and @stdout.closed?
    raise @fatal if @fatal
  end
  
  #Parses special hashes to proxy-objects and leaves the rest. This is used automatically.
  def read_parsed_data(data)
    if data.is_a?(Hash) and data["type"] == "php_process_proxy" and data.key?("id")
      return Proxy_obj.new(
        :php => self,
        :id => data["id"].to_i,
        :class => data["class"].to_sym
      )
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
  
  #Starts the thread which reads answers from the PHP-process. This is called automatically from the constructor.
  def start_read_loop
    @thread = Knj::Thread.new do
      @stdout.lines do |line|
        data = line.split(":")
        args = PHP.unserialize(Base64.strict_decode64(data[2].strip))
        type = data[0]
        id = data[1].to_i
        $stderr.print "Received: #{id}:#{type}:#{args}\n" if @debug
        
        if type == "answer"
          @responses[id] = args
        else
          raise "Unknown type: '#{type}'."
        end
      end
    end
  end
end

#This object proxies calls to the object it refers to on the PHP-side. It is automatically spawned from "php.new" and should not be spawned manually.
#===Examples
# php = Php_process.new
# pe = php.new("PHPExcel")
# pe.getProperties.setCreator("kaspernj")
class Php_process::Proxy_obj
  #Sets required instance-variables and defines the finalizer for unsetting on the PHP-side.
  def initialize(args)
    @args = args
    @args[:php].object_ids[self.__id__] = @args[:id]
    
    #Define finalizer so we can remove the object on PHPs side, when it is collected on the Ruby-side.
    ObjectSpace.define_finalizer(self, @args[:php].method(:objects_unsetter))
  end
  
  #Returns the PHP-class of the object that this object refers to as a symbol.
  #===Examples
  # proxy_obj.__phpclass #=> :PHPExcel
  def __phpclass
    return @args[:class]
  end
  
  #Sets an instance-variable on the object.
  #===Examples
  # proxy_obj = php.new("stdClass")
  # proxy_obj.__set_var("testvar", 5)
  # proxy_obj.__get_var("testvar") #=> 5
  def __set_var(name, val)
    @args[:php].send(:type => "set_var", :id => @args[:id], :name => name, :val => val)
    return nil
  end
  
  #Returns an instance-variable by name.
  #===Examples
  # proxy_obj = php.new("stdClass")
  # proxy_obj.__set_var("testvar", 5)
  # proxy_obj.__get_var("testvar") #=> 5
  def __get_var(name)
    return @args[:php].send(:type => "get_var", :id => @args[:id], :name => name)["result"]
  end
  
  #Uses 'method_missing' to proxy all other calls onto the PHP-process and the PHP-object. Then returns the parsed result.
  def method_missing(method_name, *args)
    return @args[:php].send(:type => :object_call, :method => method_name, :args => args, :id => @args[:id])["result"]
  end
end