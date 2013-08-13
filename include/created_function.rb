#This class handels the ability to create functions on the PHP-side.
#===Examples
# $callback_from_php = "test"
# func = php.create_func do |arg|
#   $callback_from_php = arg
# end
#
# $callback_from_php #=> "test"
# func.call('test2')
# $callback_from_php #=> "test2"
#
# The function could also be called from PHP, but for debugging purposes it can also be done from Ruby.
class Php_process::CreatedFunction
  #Various data about the create function will can help identify it on both the Ruby and PHP-side.
  attr_reader :args
  
  #Sets the data. This is done from "Php_process" automatically.
  def initialize(args)
    @args = args
  end
  
  #Asks PHP to execute the function on the PHP-side, which will trigger the callback in Ruby afterwards. This method is useually called for debugging purposes.
  def call(*args)
    @args[:php].send(:type => :call_created_func, :id => @args[:id], :args => @args[:php].parse_data(args))
  end
end
