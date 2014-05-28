# coding: utf-8

require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "PhpProcess" do
  it "should be able to start" do
    require "timeout"
    
    #Spawn PHP-process.
    PhpProcess.new(:debug => false, :debug_stderr => true) do |php|
      #It should be able to handle constants very fast by using cache.
      php.func("define", "TEST_CONSTANT", 5)
      raise "Expected 'TEST_CONSTANT'-constant to exist but it didnt." if !php.func("defined", "TEST_CONSTANT")
      
      Timeout.timeout(1) do
        0.upto(10000) do
          const = php.constant_val("TEST_CONSTANT")
          raise "Expected const to be 5 but it wasnt: #{const}." if const != 5
        end
      end
      
      
      #Test function calls without arguments.
      pid = php.func("getmypid")
      pid.should > 0
      
      
      #Test encoding.
      test_str = "æøå"
      php.func("file_put_contents", "/tmp/php_process_test_encoding", test_str)
      test_str_read = File.read("/tmp/php_process_test_encoding")
      test_str.should eq test_str_read
      
      
      #Test function calls with arguments.
      res = php.func("explode", ";", "1;2;4;5")
      res.length.should eq 4
      
      
      #Test eval.
      resp = php.eval("return array(1 => 2)")
      resp.class.should eq Hash
      resp[1].should eq 2
      
      
      #Test spawn object and set instance variables.
      proxy_obj = php.new("stdClass")
      proxy_obj.__set_var("testvar", 5)
      proxy_obj.__get_var("testvar").should eq 5
    end
  end
  
  it "should be able to report fatal errors" do
    expect{
      PhpProcess.new(:debug => false, :debug_output => false, :debug_stderr => false) do |php|
        php.func(:require_once, "file_that_doesnt_exist.php")
      end
    }.to raise_error(PhpProcess::FatalError)
  end
  
  it "should be able to create functions and call them" do
    PhpProcess.new(:debug => false, :debug_stderr => true) do |php|
      #Test ability to create functions and do callbacks.
      $callback_from_php = "test"
      func = php.create_func do |arg|
        $callback_from_php = arg
      end
      
      #Send argument 'kasper' which will be what "$callback_from_php" will be changed to.
      func.call("kasper")
      sleep 0.1
      $callback_from_php.should eq "kasper"
    end
  end
  
  it "should survive a lot of threadded calls in a row" do
    PhpProcess.new(:debug => false, :debug_stderr => true) do |php|
      #Test thread-safety and more.
      ts = []
      1.upto(10) do |tcount|
        ts << Thread.new do
          str = php.func("substr", "Kasper Johansen", 0, 100)
          
          0.upto(100) do
            kasper_str = php.func("substr", str, 0, 6)
            johansen_str = php.func("substr", str, 7, 15)
            
            raise "Expected 'Kasper' but got '#{kasper_str}'." if kasper_str != "Kasper"
            raise "Expected 'Johansen' but got '#{johansen_str}'." if johansen_str != "Johansen"
          end
        end
      end
      
      ts.each do |t|
        t.join
      end
    end
  end
  
  it "should catch calls to functions that does not exist" do
    PhpProcess.new do |php|
      expect{
        php.func("func_that_does_not_exist", "kasper")
      }.to raise_error(NoMethodError)
    end
  end
  
  it "should not do the strip error when errors occur" do
    PhpProcess.new(:debug => false) do |php|
      100.times do
        expect{
          php.func("func_that_does_not_exist")
        }.to raise_error(NoMethodError)
        
        expect{
          php.static("class_that_doesnt_exit", "method_that_doesnt_exist")
        }.to raise_error(NameError)
      end
    end
  end
  
  it "should throw destroyed error when the process has been destroyed" do
    PhpProcess.new(:debug => false, :debug_stderr => false) do |php|
      expect{
        php.eval("some_fatal_error()")
      }.to raise_error(PhpProcess::FatalError)
      
      expect{
        php.func("getmypid")
      }.to raise_error(PhpProcess::DestroyedError)
    end
  end
end