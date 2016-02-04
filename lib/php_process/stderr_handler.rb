class PhpProcess::StderrHandler
  attr_accessor :communicator

  def initialize(args)
    @args = args
    @php_process = @args[:php_process]

    vars = [:@debug, :@args]
    vars.each do |var|
      instance_variable_set(var, @php_process.instance_variable_get(var))
    end

    @stderr = @php_process.instance_variable_get(:@stderr)
    @stderr.sync = true
    # @stderr.set_encoding("utf-8:iso-8859-1")
    @debug = @args[:debug]

    start_error_reader_thread
  end

private

  def start_error_reader_thread
    @err_thread = Thread.new do
      begin
        read_loop
        $stderr.puts "stderr thread died!" if @debug
      rescue => e
        unless @php_process.destroyed?
          $stderr.puts "Error while reading from stderr."
          $stderr.puts e.inspect
          $stderr.puts e.backtrace
        end
      end
    end
  end

  def read_loop
    @stderr.each_line do |str|
      @args[:on_err].call(str) if @args[:on_err]
      $stderr.print "Process error: #{str}" if @debug || @args[:debug_stderr]
      @communicator.__send__(:check_for_special, str.to_s)
      break if (!@args && str.to_s.strip.empty?) || (@stderr && @stderr.closed?)
    end
  end
end
