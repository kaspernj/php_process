# coding: utf-8

require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "PhpProcess" do
  it "should not do the strip error when errors occur" do
    Php_process.new(:debug => false) do |php|
      php.func("require_once", "PHPExcel.php")
      php.static("PHPExcel_IOFactory", "load", "#{File.dirname(__FILE__)}/../examples/example_phpexcel.xlsx")
      
      100.times do
        begin
          php.func("func_that_does_not_exist")
          raise "Did not expect that to run."
        rescue NoMethodError
          #ignore - expected.
        end
        
        begin
          php.static("class_that_doesnt_exit", "method_that_doesnt_exist")
          raise "Did not expect that to run."
        rescue NameError
          #ignore - expected.
        end
      end
      
      begin
        php.eval("some_fatal_error()")
        raise "Did not expect that to run."
      rescue Php_process::FatalError
        #ignore - expected.
      end
      
      begin
        php.func("getmypid")
        raise "Did not expect that to run."
      rescue Php_process::DestroyedError
        #ignore - expected.
      end
    end
  end
end