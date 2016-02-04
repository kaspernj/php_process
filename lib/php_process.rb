require "wref" unless Kernel.const_defined?(:Wref)
require "tsafe" unless Kernel.const_defined?(:Tsafe)
require "php-serialize4ruby"
require "base64"
require "open3"
require "thread"
require "string-cases"

# This class starts a PHP-process and proxies various calls to it. It also spawns proxy-objects, which can you can call like they were normal Ruby-objects.
#===Examples
# php = PhpProcess.new
# print "PID of PHP-process: #{php.func("getmypid")}\n"
# print "Explode test: #{php.func("explode", ";", "1;2;3;4;5")}\n"
class PhpProcess
  # Autoloader for subclasses.
  def self.const_missing(name)
    path = "#{File.dirname(__FILE__)}/php_process/#{::StringCases.camel_to_snake(name)}.rb"

    if File.exist?(path)
      require path
      return ::PhpProcess.const_get(name) if ::PhpProcess.const_defined?(name)
    end

    super
  end

  # Returns the path to the gem.
  def self.path
    File.realpath(File.dirname(__FILE__))
  end

  # Spawns various used variables, launches the process and more.
  #===Examples
  # If you want debugging printed to stderr:
  # php = PhpProcess.new(debug: true)
  INITIALIZE_VALID_ARGS = [:debug, :debug_output, :debug_stderr, :cmd_php, :on_err].freeze
  def initialize(args = {})
    parse_args_and_set_vars(args)
    start_php_process
    @communicator.check_alive
    $stderr.puts "PHP-script ready." if @debug

    if block_given?
      begin
        yield(self)
      ensure
        destroy
      end
    end
  end

  def parse_args_and_set_vars(args)
    args.each do |key, _val|
      raise "Invalid argument: '#{key}'." unless INITIALIZE_VALID_ARGS.include?(key)
    end

    @args = args
    @debug = @args[:debug]
    @debug_output = @args[:debug_output]
    @constant_val_cache = Tsafe::MonHash.new
    @objects_handler = ::PhpProcess::ObjectsHandler.new(php_process: self)

    # Used for 'create_func'.
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

    @stderr_handler = ::PhpProcess::StderrHandler.new(php_process: self)

    check_php_process_startup

    @communicator = ::PhpProcess::Communicator.new(php_process: self)
    @communicator.objects_handler = @objects_handler
    @objects_handler.communicator = @communicator
    @stderr_handler.communicator = @communicator
  end

  # Returns various info in a hash about the object-cache on the PHP-side.
  def object_cache_info
    communicate(type: :object_cache_info)
  end

  # Joins all the threads.
  def join
    @thread.join if @thread
    @err_thread.join if @err_thread
  end

  # Destroys the object closing and unsetting everything.
  def destroy
    @destroyed = true
    @stdout.close if @stdout && !@stdout.closed?
    @stdin.close if @stdin && !@stdin.closed?
    @stderr.close if @stderr && !@stderr.closed?

    # Respond to any waiting queues to avoid locking those threads.
    if @responses
      @responses.each do |_id, queue|
        queue.push(::PhpProcess::DestroyedError.new)
      end
    end
  end

  # Returns the if the object has been destroyed.
  def destroyed?
    return true if @destroyed
    false
  end

  # Evaluates a string containing PHP-code and returns the result.
  #===Examples
  # print php.eval("array(1 => 2);") #=> {1=>2}
  def eval(eval_str)
    @communicator.communicate(type: :eval, eval_str: eval_str)
  end

  # Spawns a new object from a given class with given arguments and returns it.
  #===Examples
  # pe = php.new("PHPExcel")
  # pe.getProperties.setCreator("kaspernj")
  def new(classname, *args)
    @communicator.communicate(type: :new, class: classname, args: parse_data(args))
  end

  # Call a function in PHP.
  #===Examples
  # arr = php.func("explode", ";", "1;2;3;4;5")
  # pid_of_php_process = php.func("getmypid")
  # php.func("require_once", "PHPExcel.php")
  def func(func_name, *args)
    @communicator.communicate(type: :func, func_name: func_name, args: parse_data(args))
  end

  # Sends a call to a static method on a class with given arguments.
  #===Examples
  # php.static("Gtk", "main_quit")
  def static(class_name, method_name, *args)
    @communicator.communicate(type: :static_method_call, class_name: class_name, method_name: method_name, args: parse_data(args))
  end

  # Parses argument-data into special hashes that can be used on the PHP-side. It is public because the proxy-objects uses it. Normally you would never use it.
  def parse_data(data)
    if data.is_a?(PhpProcess::ProxyObject)
      return {type: :proxyobj, id: data.args[:id]}
    elsif data.is_a?(PhpProcess::CreatedFunction)
      return {type: :php_process_created_function, id: data.args[:id]}
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

  # Creates a function on the PHP-side. When the function is called, it callbacks to the Ruby-side which then can execute stuff back to PHP.
  #===Examples
  # func = php.create_func do |d|
  #   d.php.static("Gtk", "main_quit")
  # end
  #
  # button.connect("clicked", func)
  def create_func(_args = {}, &block)
    callback_id = nil
    func = nil
    @callbacks_mutex.synchronize do
      callback_id = @callbacks_count
      func = PhpProcess::CreatedFunction.new(php_process: self, communicator: @communicator, id: callback_id)
      @callbacks[callback_id] = {block: block, func: func, id: callback_id}
      @callbacks_count += 1
    end

    raise "No callback-ID?" unless callback_id
    @communicator.communicate(type: :create_func, callback_id: callback_id)

    func
  end

  # Returns the value of a constant on the PHP-side.
  def constant_val(name)
    const_name = name.to_s

    unless @constant_val_cache.key?(const_name)
      @constant_val_cache[const_name] = @communicator.communicate(type: :constant_val, name: name)
    end

    @constant_val_cache[const_name]
  end

private

  def check_php_process_startup
    $stderr.print "Waiting for PHP-script to be ready.\n" if @debug
    started = false
    @stdout.each_line do |line|
      puts "Line: #{line}" if @debug

      if (match = line.match(/^php_script_ready:(\d+)\n/))
        started = true
        break
      end

      $stderr.print "Line gotten while waiting: #{line}" if @debug
    end

    unless started
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
      cmd_str = (@args[:cmd_php]).to_s
    else
      bin_path_tries.each do |bin_path|
        next unless File.exist?(bin_path)
        cmd_str << bin_path
        break
      end

      if cmd_str.empty? && File.exist?("/usr/bin/env")
        cmd_str = "/usr/bin/env php5"
      end
    end

    cmd_str << " \"#{File.dirname(__FILE__)}/php_process/php_script.php\""

    cmd_str
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
end
