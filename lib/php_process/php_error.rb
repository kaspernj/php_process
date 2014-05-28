class PhpProcess::PhpError < RuntimeError
  attr_accessor :php_class
end
