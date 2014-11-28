[![Build Status](https://travis-ci.org/kaspernj/php_process.svg?branch=master)](https://travis-ci.org/kaspernj/php_process)
[![Code Climate](https://codeclimate.com/github/kaspernj/php_process.png)](https://codeclimate.com/github/kaspernj/php_process)
[![Test Coverage](https://codeclimate.com/github/kaspernj/php_process/coverage.png)](https://codeclimate.com/github/kaspernj/php_process)

# PhpProcess

This project helps developers use PHP libraries or extensions directly from Ruby. It was originally made in order to allow me to use the exellent PHPExcel directly in Ruby, but it can be used
with any library or extension.

It works by spawning a PHP-process and then manipulating that to execute commands. For that reason there is an overhead by using it.

Here is a small example:
```ruby
require "rubygems"
require "php_process"

PhpProcess.new do |php|
  php.func("require_once", "#{File.dirname(__FILE__)}/PHPExcel/PHPExcel.php")
  objPHPExcel = php.new("PHPExcel")
  
  objPHPExcel.getProperties.setCreator("Kasper Johansen")
  objPHPExcel.getProperties.setLastModifiedBy("Kasper Johansen")
  objPHPExcel.getProperties.setTitle("Office 2007 XLSX Test Document")
  objPHPExcel.getProperties.setSubject("Office 2007 XLSX Test Document")
  objPHPExcel.getProperties.setDescription("Test document for Office 2007 XLSX, generated using PHP classes.")
  
  objPHPExcel.setActiveSheetIndex(0)
  objPHPExcel.getActiveSheet.SetCellValue('A1', 'Hello')
  objPHPExcel.getActiveSheet.SetCellValue('B2', 'world!')
  objPHPExcel.getActiveSheet.SetCellValue('C1', 'Hello')
  objPHPExcel.getActiveSheet.SetCellValue('D2', 'world!')
  
  objPHPExcel.getActiveSheet.setTitle('Simple')
  
  objWriter = php.new("PHPExcel_Writer_Excel2007", objPHPExcel)
  objWriter.save(__FILE__.gsub(".rb", ".xlsx"))
end
```

#Usage
## Eval'ing PHP-code
```ruby
number = php.eval("return 5")
```

## Getting and calling instances of objects.
```ruby
instance = php.new(:ClassName, "FirstArgument")
result = instance.someMethod("AnArgument")
```

## Calling static methods.
```ruby
php.static(:ClassName, :methodName, "firstArgumentForMethodInPHP")
```

## Setting variables on objects.
```ruby
instance.__set_var(:varName, "varValue")
instance.__get_var(:varName).should eq "varValue"
```

## Getting constants.
```ruby
php.constant_val("CONSTANT_NAME")
```

## Defining constants.
```ruby
php.func("define", "TEST_CONSTANT", 5)
```


## Contributing to php_process
 
* Check out the latest master to make sure the feature hasn't been implemented or the bug hasn't been fixed yet.
* Check out the issue tracker to make sure someone already hasn't requested it and/or contributed it.
* Fork the project.
* Start a feature/bugfix branch.
* Commit and push until you are happy with your contribution.
* Make sure to add tests for it. This is important so I don't break it in a future version unintentionally.
* Please try not to mess with the Rakefile, version, or history. If you want to have your own version, or is otherwise necessary, that is fine, but please isolate to its own commit so I can cherry-pick around it.

## Copyright

Copyright (c) 2012 Kasper Johansen. See LICENSE.txt for
further details.

