#This object proxies calls to the object it refers to on the PHP-side. It is automatically spawned from "php.new" and should not be spawned manually.
#===Examples
# php = PhpProcess.new
# pe = php.new("PHPExcel")
# pe.getProperties.setCreator("kaspernj")
class PhpProcess::ProxyObject
  #Contains the various data about the object like ID and class. It is readable because it needs to be converted to special hashes when used as arguments.
  attr_reader :args
  
  #Sets required instance-variables and defines the finalizer for unsetting on the PHP-side.
  def initialize(args)
    @args = args
    @args[:php].object_ids[self.__id__] = @args[:id]
    
    #Define finalizer so we can remove the object on PHPs side, when it is collected on the Ruby-side.
    ObjectSpace.define_finalizer(self, @args[:php].method(:objects_unsetter))
  end
  
  #Returns the PHP-class of the object that this object refers to as a symbol.
  #===Examples
  # proxy_obj.__phpclass #=> :PHPExcel
  def __phpclass
    return @args[:php].func("get_class", self)
  end
  
  #Sets an instance-variable on the object.
  #===Examples
  # proxy_obj = php.new("stdClass")
  # proxy_obj.__set_var("testvar", 5)
  # proxy_obj.__get_var("testvar") #=> 5
  def __set_var(name, val)
    @args[:php].send(:type => "set_var", :id => @args[:id], :name => name, :val => val)
    return nil
  end
  
  #Returns an instance-variable by name.
  #===Examples
  # proxy_obj = php.new("stdClass")
  # proxy_obj.__set_var("testvar", 5)
  # proxy_obj.__get_var("testvar") #=> 5
  def __get_var(name)
    return @args[:php].send(:type => "get_var", :id => @args[:id], :name => name)
  end
  
  #Uses 'method_missing' to proxy all other calls onto the PHP-process and the PHP-object. Then returns the parsed result.
  def method_missing(method_name, *args)
    return @args[:php].send(:type => :object_call, :method => method_name, :args => @args[:php].parse_data(args), :id => @args[:id])
  end
end