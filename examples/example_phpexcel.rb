#!/usr/bin/env ruby

#Remember to install 'php5-cli' like under Ubuntu: apt-get install php5-cli
#Load 'PhpProcess' through RubyGems.
require "rubygems"
require "php_process"
php = PhpProcess.new

#Load PHPExcel (can be downloaded here: 'http://phpexcel.codeplex.com/releases/view/45412')
php.func("require_once", "#{File.dirname(__FILE__)}/PHPExcel/PHPExcel.php")

#Create new PHPExcel object
print "#{Time.now} Create new PHPExcel object\n"
objPHPExcel = php.new("PHPExcel")

#Set properties
print "#{Time.now} Set properties\n"
objPHPExcel.getProperties.setCreator("Maarten Balliauw")
objPHPExcel.getProperties.setLastModifiedBy("Maarten Balliauw")
objPHPExcel.getProperties.setTitle("Office 2007 XLSX Test Document")
objPHPExcel.getProperties.setSubject("Office 2007 XLSX Test Document")
objPHPExcel.getProperties.setDescription("Test document for Office 2007 XLSX, generated using PHP classes.")

#Add some data
print "#{Time.now} Add some data\n"
objPHPExcel.setActiveSheetIndex(0)
objPHPExcel.getActiveSheet.SetCellValue('A1', 'Hello')
objPHPExcel.getActiveSheet.SetCellValue('B2', 'world!')
objPHPExcel.getActiveSheet.SetCellValue('C1', 'Hello')
objPHPExcel.getActiveSheet.SetCellValue('D2', 'world!')

#Rename sheet
print "#{Time.now} Rename sheet\n";
objPHPExcel.getActiveSheet.setTitle('Simple')
    
#Save Excel 2007 file
print "#{Time.now} Write to Excel2007 format\n"
objWriter = php.new("PHPExcel_Writer_Excel2007", objPHPExcel)
objWriter.save(__FILE__.gsub(".rb", ".xlsx"))

#Echo done
print "#{Time.now} Done writing file.\n"