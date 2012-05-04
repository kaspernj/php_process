require "knjrbfw"
require "base64"
require "php_serialize"
require "monitor"

class Php_process
  #The PID of the PHP-process.
  attr_reader :pid
  
  #A hash that contains links between Ruby object IDs and the PHP object IDs.
  attr_reader :object_ids
  
  def objects_unsetter(id)
    @object_unset_ids << @object_ids[id]
    @object_ids.delete(id)
  end
  
  def initialize(args = {})
    @args = args
    @debug = @args[:debug]
    @send_count = 0
    @responses = Knj::Threadsafe::Synced_hash.new
    @object_ids = Knj::Threadsafe::Synced_hash.new
    @object_unset_ids = Knj::Threadsafe::Synced_array.new
    @mutex = Monitor.new
    
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
        
        if @args[:on_err]
          @args[:on_err].call(str)
        else
          $stderr.print "Process error: #{str}"
        end
      end
    end
    
    $stderr.print "Waiting for PHP-script to be ready.\n" if @debug
    @stdout.lines do |line|
      if match = line.match(/^php_script_ready:(\d+)\n/)
        @pid = match[1].to_i
        break
      end
      
      $stderr.print "Line gotten while waiting: #{line}" if @debug
    end
    
    raise "No PID was given." if !@pid
    raise "stdout closed." if @stdout.closed? or @stdin.closed? or @stderr.closed?
    
    $stderr.print "PHP-script ready.\n" if @debug
    self.start_read_loop
  end
  
  def flush_unset_ids(force = false)
    return nil if !force and @object_unset_ids.length < 500
    while @object_unset_ids.length > 0 and elements = @object_unset_ids.shift(500)
      self.send_real("type" => "unset_ids", "ids" => elements)
    end
  end
  
  def object_cache_info
    return self.send(:type => :object_cache_info)
  end
  
  def read_parsed_data(data)
    if data.is_a?(Hash) and data["type"] == "php_process_proxy" and data.key?("id")
      return Proxy_obj.new(
        :php => self,
        :id => data["id"].to_i
      )
    elsif data.is_a?(Hash)
      newdata = {}
      data.each do |key, val|
        newdata[key] = self.read_parsed_data(val)
      end
    else
      return data
    end
  end
  
  def start_read_loop
    @thread = Knj::Thread.new do
      @stdout.lines do |line|
        $stderr.print "Line received: #{line}" if @debug
        
        data = line.split(":")
        args = PHP.unserialize(Base64.strict_decode64(data[2].strip))
        type = data[0]
        id = data[1].to_i
        
        if type == "answer"
          @mutex.synchronize do
            @responses[id] = args
          end
        else
          raise "Unknown type: '#{type}'."
        end
      end
    end
  end
  
  def join
    @thread.join if @thread
    @err_thread.join if @err_thread
  end
  
  #Proxies to 'send_real' but calls 'flush_unset_ids' first.
  def send(hash)
    self.flush_unset_ids
    return self.send_real(hash)
  end
  
  def send_real(hash)
    $stderr.print "Sending: #{hash}\n" if @debug
    str = Base64.strict_encode64(PHP.serialize(hash))
    @stdin.write("send:#{@send_count}:#{str}\n")
    id = @send_count
    @send_count += 1
    
    #Slep a tiny bit to wait for first answer.
    sleep 0.001
    
    #Then return result.
    return self.read(id)
  end
  
  def read(id)
    loop do
      @mutex.synchronize do
        if @responses.key?(id)
          resp = @responses[id]
          @responses.delete(id)
          
          if resp.is_a?(Hash) and resp["type"] == "error"
            raise "#{resp["msg"]}\n\n#{resp["bt"]}"
          end
          
          return self.read_parsed_data(resp)
        end
      end
      
      self.check_alive
      sleep 0.05
      $stderr.print "Waiting for answer to ID: #{id}\n" if @debug
    end
  end
  
  def eval(eval_str)
    return self.send(:type => :eval, :eval_str => eval_str)
  end
  
  def check_alive
    raise "stdout closed." if @stdout and @stdout.closed?
    raise @fatal if @fatal
  end
  
  def new(classname, *args)
    ret = self.send(:type => :new, :class => classname, :args => args)
    
    return Proxy_obj.new(
      :php => self,
      :id => ret["object_id"].to_i
    )
  end
  
  def require_once(filepath)
    self.send(:type => :require_once_path, :filepath => filepath)
    return nil
  end
  
  def func(func_name, *args)
    return self.send(:type => :func, :func_name => func_name, :args => args)["result"]
  end
  
  class Proxy_obj
    def initialize(args)
      @args = args
      @args[:php].object_ids[self.__id__] = @args[:id]
      
      #Define finalizer so we can remove the object on PHPs side, when it is collected on the Ruby-side.
      ObjectSpace.define_finalizer(self, @args[:php].method(:objects_unsetter))
    end
    
    def __set_var(name, val)
      @args[:php].send(:type => "set_var", :id => @args[:id], :name => name, :val => val)
      return nil
    end
    
    def __get_var(name)
      return @args[:php].send(:type => "get_var", :id => @args[:id], :name => name)["result"]
    end
    
    def method_missing(method_name, *args)
      res = @args[:php].send(:type => :object_call, :method => method_name, :args => args, :id => @args[:id])
      return res["result"]
    end
  end
end