# coding: utf-8

require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "PhpProcess" do
  it "should be able  to work with constants and cache them" do
    require "timeout"
    
    PhpProcess.new do |php|
      php.func("define", "TEST_CONSTANT", 5)
      raise "Expected 'TEST_CONSTANT'-constant to exist but it didnt." if !php.func("defined", "TEST_CONSTANT")
      
      Timeout.timeout(1) do
        0.upto(10000) do
          const = php.constant_val("TEST_CONSTANT")
          raise "Expected const to be 5 but it wasnt: #{const}." if const != 5
        end
      end
    end
  end
  
  it "should work with functions that doesnt take arguments" do
    PhpProcess.new do |php|
      pid = php.func("getmypid")
      pid.should > 0
    end
  end
  
  it "should work correctly with UTF-8 encoding" do
    PhpProcess.new do |php|
      test_str = "æøå"
      php.func("file_put_contents", "/tmp/php_process_test_encoding", test_str)
      test_str_read = File.read("/tmp/php_process_test_encoding")
      test_str.should eq test_str_read
    end
  end
  
  it "should call functions with arguments" do
    PhpProcess.new do |php|
      res = php.func("explode", ";", "1;2;4;5")
      res.length.should eq 4
    end
  end
  
  it "should work with arrays and convert them to hashes" do
    PhpProcess.new do |php|
      resp = php.eval("return array(1 => 2)")
      resp.class.should eq Hash
      resp[1].should eq 2
    end
  end
  
  it "should spawn instances of classes and set variables on them" do
    PhpProcess.new do |php|
      proxy_obj = php.new("stdClass")
      proxy_obj.__set_var("testvar", 5)
      proxy_obj.__get_var("testvar").should eq 5
    end
  end
  
  it "should be able to report fatal errors back" do
    expect{
      PhpProcess.new do |php|
        php.func(:require_once, "file_that_doesnt_exist.php")
      end
    }.to raise_error(PhpProcess::FatalError)
  end
  
  it "should be able to create functions and call them" do
    PhpProcess.new do |php|
      $callback_from_php = "test"
      func = php.create_func do |arg|
        $callback_from_php = arg
      end
      
      func.call("kasper")
      sleep 0.1
      $callback_from_php.should eq "kasper"
    end
  end
  
  it "should survive a lot of threadded calls in a row" do
    PhpProcess.new do |php|
      ts = []
      1.upto(10) do |tcount|
        ts << Thread.new do
          str = php.func("substr", "Kasper Johansen", 0, 100)
          
          0.upto(100) do
            kasper_str = php.func("substr", str, 0, 6)
            johansen_str = php.func("substr", str, 7, 15)
            
            kasper_str.should eq "Kasper"
            johansen_str.should eq "Johansen"
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
    PhpProcess.new do |php|
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
    PhpProcess.new do |php|
      expect{
        php.eval("some_fatal_error()")
      }.to raise_error(PhpProcess::FatalError)
      
      expect{
        php.func("getmypid")
      }.to raise_error(PhpProcess::DestroyedError)
    end
  end
  
  it "should call methods on classes" do
    PhpProcess.new do |php|
      php.eval("
        class TestClass{
          function __construct($test){
            $this->test = $test;
          }
          
          function testMethod($var){
            return $this->test . $var;
          }
        }
      ")
      
      instance = php.new(:TestClass, "1")
      instance.testMethod("2").should eq "12"
    end
  end
end