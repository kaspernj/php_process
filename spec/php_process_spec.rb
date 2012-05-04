require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "PhpProcess" do
  it "should be able to start" do
    require "timeout"
    
    $php = Php_process.new(:debug => true)
    
    
    #Test eval.
    resp = $php.eval("return array(1 => 2)")
    raise "Expected hash: '#{resp.class.name}'." if !resp.is_a?(Hash)
    raise "Expected key 1 to be 2: #{resp}." if resp[1] != 2
    
    
    #Test spawn object and set instance variables.
    proxy_obj = $php.new("stdClass")
    proxy_obj.__set_var("testvar", 5)
    val = proxy_obj.__get_var("testvar")
    raise "Expected val to be 5 but it wasnt: #{val}" if val != 5
    proxy_obj = nil
    
    
    #Test spawn require and method-calling on objects.
    $php.require_once "knj/http.php"
    http = $php.new "knj_httpbrowser"
    http.connect("www.partyworm.dk")
    resp = http.get("/?show=frontpage")
    raise "Expected length of HTML to be longer than 200: #{resp.to_s.length}" if resp.to_s.length < 200
    http = nil
    
    
    #Test Table-Writer.
    $php.require_once "knj/table_writer.php"
    $php.require_once "knj/csv.php"
    tw = $php.new("knj_table_writer", {
      "filepath" => "/tmp/php_process_test.csv",
      "format" => "csv",
      "expl" => ";",
      "surr" => '"',
      "encoding" => "utf8"
    })
    
    
    #Should be able to write 1000 rows in less than 2 sec.
    Timeout.timeout(2) do
      0.upto(1000) do |i|
        tw.write_row(["test#{i}", i, "test#{i}", i.to_f])
      end
    end
    
    tw.close
    tw = nil
    
    
    #Test function calls without arguments.
    pid = $php.func("getmypid")
    raise "Expected PIDs to be the same: #{pid}, #{$php.pid}" if pid != $php.pid
    
    
    #Test function calls with arguments.
    res = $php.func("explode", ";", "1;2;4;5")
    raise "Expected length of result to be 4 but it wasnt: #{res.length}" if res.length != 4
    
    
    #Test PHPExcel.
    $php.require_once("PHPExcel.php")
    tw = $php.new("knj_table_writer", {
      "filepath" => "/tmp/php_process_test.xlsx",
      "format" => "excel2007"
    })
    #Should be able to write 1000 rows in less than 2 sec.
    Timeout.timeout(2) do
      0.upto(1000) do |i|
        tw.write_row(["test#{i}", i, "test#{i}", i.to_f])
      end
    end
    
    tw.close
    tw = nil
    
    
    #Check garbage collection, cache and stuff.
    cache_info = $php.object_cache_info
    print "Cache count: #{cache_info["count"]}\n"
    GC.start
    $php.flush_unset_ids(true)
    cache_info = $php.object_cache_info
    raise "Cache count should be below 4 but isnt: #{cache_info}." if cache_info["count"] >= 4
    
    
    #Try some really advanced object-stuff.
    pe = $php.new("PHPExcel")
    prop = pe.getProperties
    prop.setCreator("kaspernj")
  end
end
