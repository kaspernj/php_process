# coding: utf-8

require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "PhpProcess" do
  it "should be able to start" do
    require "timeout"
    
    
    #Spawn PHP-process.
    $php = Php_process.new(:debug => false, :debug_stderr => true)
    
    
    #It should be able to handle constants very fast by using cache.
    $php.func("define", "TEST_CONSTANT", 5)
    raise "Expected 'TEST_CONSTANT'-constant to exist but it didnt." if !$php.func("defined", "TEST_CONSTANT")
    
    Timeout.timeout(1) do
      0.upto(10000) do
        const = $php.constant_val("TEST_CONSTANT")
        raise "Expected const to be 5 but it wasnt: #{const}." if const != 5
      end
    end
    
    
    #Test function calls without arguments.
    pid = $php.func("getmypid")
    raise "Invalid PID: #{pid}" if pid.to_i <= 0
    
    
    #Test encoding.
    test_str = "æøå"
    $php.func("file_put_contents", "/tmp/php_process_test_encoding", test_str)
    test_str_read = File.read("/tmp/php_process_test_encoding")
    raise "Expected the two strings to be the same, but they werent: '#{test_str}', '#{test_str_read}'." if test_str != test_str_read
    
    
    #Test function calls with arguments.
    res = $php.func("explode", ";", "1;2;4;5")
    raise "Expected length of result to be 4 but it wasnt: #{res.length}" if res.length != 4
    
    
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
    $php.func("require_once", "knj/http.php")
    http = $php.new("knj_httpbrowser")
    http.connect("www.partyworm.dk")
    resp = http.get("/?show=frontpage")
    raise "Expected length of HTML to be longer than 200: #{resp.to_s.length}" if resp.to_s.length < 200
    http = nil
    
    
    #Test Table-Writer.
    $php.func("require_once", "knj/table_writer.php")
    $php.func("require_once", "knj/csv.php")
    tw = $php.new("knj_table_writer", {
      "filepath" => "/tmp/php_process_test.csv",
      "format" => "csv",
      "expl" => ";",
      "surr" => '"',
      "encoding" => "utf8"
    })
    
    
    #Should be able to write 1000 rows in less than 5 sec.
    Timeout.timeout(5) do
      0.upto(1000) do |i|
        #tw.write_row(["test#{i}", i, "test#{i}", i.to_f])
      end
    end
    
    tw.close
    tw = nil
    
        
    #Test PHPExcel.
    $php.func("require_once", "PHPExcel.php")
    tw = $php.new("knj_table_writer", {
      "filepath" => "/tmp/php_process_test.xlsx",
      "format" => "excel2007"
    })
    
    
    #Should be able to write 1000 rows in less than 5 sec.
    Timeout.timeout(5) do
      0.upto(1000) do |i|
        #tw.write_row(["test#{i}", i, "test#{i}", i.to_f])
      end
    end
    
    tw.close
    tw = nil
    
    
    #Try some really advanced object-stuff.
    pe = $php.new("PHPExcel")
    pe.getProperties.setCreator("kaspernj")
    pe.setActiveSheetIndex(0)
    
    sheet = pe.getActiveSheet
    
    const_border_thick = $php.constant_val("PHPExcel_Style_Border::BORDER_THICK")
    
    sheet.getStyle("A1:C1").getBorders.getTop.setBorderStyle(const_border_thick)
    sheet.getStyle("A1:A5").getBorders.getLeft.setBorderStyle(const_border_thick)
    sheet.getStyle("A5:C5").getBorders.getBottom.setBorderStyle(const_border_thick)
    sheet.getStyle("C1:C5").getBorders.getRight.setBorderStyle(const_border_thick)
    
    sheet.setCellValue("A1", "Kasper Johansen - æøå")
    sheet.getStyle("A1").getFont.setBold(true)
    
    writer = $php.new("PHPExcel_Writer_Excel2007", pe)
    writer.save("/tmp/test_excel.xlsx")
    
    pe = nil
    sheet = nil
    writer = nil
    
    
    #Try to play a little with GTK2-extension.
    $php.func("dl", "php_gtk2.so")
    win = $php.new("GtkWindow")
    win.set_title("Test")
    
    button = $php.new("GtkButton")
    button.set_label("Weee!")
    
    win.add(button)
    win.show_all
    #$php.static("Gtk", "main")
    
    
    #Test ability to create functions and do callbacks.
    $callback_from_php = "test"
    func = $php.create_func do |arg|
      $callback_from_php = arg
    end
    
    #Send argument 'kasper' which will be what "$callback_from_php" will be changed to.
    func.call("kasper")
    sleep 0.1
    raise "Expected callback from PHP to change variable but it didnt: '#{$callback_from_php}'." if $callback_from_php != "kasper"
    
    
    #Check garbage collection, cache and stuff.
    cache_info1 = $php.object_cache_info
    GC.start
    $php.flush_unset_ids(true)
    cache_info2 = $php.object_cache_info
    raise "Cache count should be below #{cache_info1["count"]} but it wasnt: #{cache_info2}." if cache_info2["count"] >= cache_info1["count"]
    
    
    #Test thread-safety and more.
    ts = []
    1.upto(25) do |tcount|
      ts << Thread.new do
        str = $php.func("substr", "Kasper Johansen", 0, 100)
        
        0.upto(250) do
          kasper_str = $php.func("substr", str, 0, 6)
          johansen_str = $php.func("substr", str, 7, 15)
          
          raise "Expected 'Kasper' but got '#{kasper_str}'." if kasper_str != "Kasper"
          raise "Expected 'Johansen' but got '#{johansen_str}'." if johansen_str != "Johansen"
          
          STDOUT.print "."
        end
      end
    end
    
    ts.each do |t|
      t.join
    end
    
    
    #Destroy the object.
    $php.destroy
  end
end