# coding: utf-8

require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "PhpProcess" do
  it "should not do the strip error" do
    php = Php_process.new(:debug => false)
    php.func("require_once", "PHPExcel.php")
    php.static("PHPExcel_IOFactory", "load", "#{File.dirname(__FILE__)}/../examples/example_phpexcel.xlsx")
  end
end