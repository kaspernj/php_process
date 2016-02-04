class PhpProcess::Communicator
  attr_accessor :objects_handler

  def initialize(args)
    @php_process = args[:php_process]

    vars = [:@stdin, :@stdout, :@responses, :@debug]
    vars.each do |var|
      instance_variable_set(var, @php_process.instance_variable_get(var))
    end

    @send_count = 0
    @send_mutex = Mutex.new
    @responses = Tsafe::MonHash.new
    start_read_loop
  end

  # Proxies to 'communicate_real' but calls 'flush_unset_ids' first.
  def communicate(hash)
    raise ::PhpProcess::DestroyedError if @php_process.destroyed?
    @objects_handler.flush_unset_ids
    communicate_real(hash)
  end

  def check_alive
    if @fatal
      message = @fatal
      @fatal = nil
      error = ::PhpProcess::FatalError.new(message)

      @responses.each do |_id, queue|
        queue.push(error)
      end

      $stderr.puts "php_process: Throwing fatal error for: #{caller}" if @debug
      @php_process.destroy
    elsif @php_process.destroyed?
      error = ::PhpProcess::DestroyedError.new
      @responses.each do |_id, queue|
        queue.push(error)
      end

      raise error
    end

    raise "stdout closed." if !@stdout || @stdout.closed?
  end

  # Checks the given string for special input like when a fatal error occurred or the sub-process is killed off.
  def check_for_special(str)
    if str =~ /^(PHP |)Fatal error: (.+)\s*/
      $stderr.puts "Fatal error detected: #{str}" if @debug
      @fatal = str.strip
      check_alive
    elsif str =~ /^Killed\s*$/
      $stderr.puts "Killed error detected: #{str}" if @debug
      @fatal = "Process was killed."
      check_alive
    end
  end

private

  # Generates the command from the given object and sends it to the PHP-process. Then returns the parsed result.
  def communicate_real(hash)
    $stderr.print "Sending: #{hash[:args]}\n" if @debug && hash[:args]
    str = ::Base64.strict_encode64(::PHP.serialize(hash))

    # Find new ID for the communicate-request.
    id = nil
    @send_mutex.synchronize do
      id = @send_count
      @send_count += 1
    end

    @responses[id] = ::Queue.new

    begin
      @stdin.write("send:#{id}:#{str}\n")
    rescue Errno::EPIPE, IOError => e
      # Wait for fatal error and then throw it.
      Thread.pass
      check_alive

      # Or just throw the normal error.
      raise e
    end

    # Then return result.
    read_result(id)
  end

  def wait_for_and_read_response(id)
    $stderr.print "php_process: Waiting for answer to ID: #{id}\n" if @debug
    check_alive

    begin
      resp = @responses[id].pop
    rescue Exception => e
      if e.class.name.to_s == "fatal"
        $stderr.puts "php_process: Deadlock error detected." if @debug

        # Wait for fatal error to be registered through thread and then throw it.
        sleep 0.2
        Thread.pass
        $stderr.puts "php_process: Checking for alive." if @debug
        check_alive
      end

      raise
    ensure
      @responses.delete(id)
    end
  end

  def generate_php_error(resp)
    raise ::Kernel.const_get(resp["ruby_type"]), resp["msg"] if resp.key?("ruby_type")
    raise ::PhpProcess::PhpError, resp["msg"]
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

  # Searches for a result for a ID and returns it. Runs 'check_alive' to see if the process should be interrupted.
  def read_result(id)
    resp = wait_for_and_read_response(id)

    # Errors are pushed in case of fatals and destroys to avoid deadlock.
    raise resp if resp.is_a?(Exception)

    if resp.is_a?(Hash) && resp["type"] == "error" && resp.key?("msg") && resp.key?("bt")
      generate_php_error(resp)
    end

    $stderr.print "Found answer #{id} - returning it.\n" if @debug
    read_parsed_data(resp)
  end

  # Parses special hashes to proxy-objects and leaves the rest. This is used automatically.
  def read_parsed_data(data)
    if data.is_a?(Array) && data.length == 2 && data[0] == "proxyobj"
      id = data[1].to_i

      if (proxy_obj = @objects_handler.find_by_id(id))
        $stderr.print "Reuse proxy-obj!\n" if @debug
        return proxy_obj
      else
        return @objects_handler.spawn_by_id(id)
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

  def parse_line(line)
    if line.empty? || @stdout.closed?
      $stderr.puts "Got empty line from process - skipping: #{line}" if @debug
      return :next
    end

    check_for_special(line)

    match = line.match(/\A(.*?)%\{\{php_process:begin\}\}(.+)%\{\{php_process:end\}\}\Z/)

    if match && match[1] && !match[1].empty?
      $stdout.print "[php_process] #{match[1]}"
    elsif !match
      $stdout.puts "[php_process] #{line}"
      return :next
    end

    data = match[2].split(":")
    raise "Didn't contain any data: #{data}" if !data[2] || data[2].empty?
    args = ::PHP.unserialize(::Base64.strict_decode64(data[2].strip))

    {type: data[0], id: data[1].to_i, args: args}
  end

  # Starts the thread which reads answers from the PHP-process. This is called automatically from the constructor.
  def start_read_loop
    @thread = Thread.new do
      begin
        read_loop
        $stderr.puts "php_process: Read-loop stopped." if @debug
      rescue => e
        unless @php_process.destroyed?
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
      id = parsed[:id]
      type = parsed[:type]
      args = parsed[:args]
      $stderr.print "Received: #{id}:#{type}:#{args}\n" if @debug

      if type == "answer"
        @responses[id].push(args)
      elsif type == "send"
        @php_process.__send__(:spawn_call_back_created_func, args) if args["type"] == "call_back_created_func"
      else
        raise "Unknown type: '#{type}'."
      end
    end
  end
end
