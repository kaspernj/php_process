class PhpProcess::ObjectsHandler
  #A hash that contains links between Ruby object IDs and the PHP object IDs. It can be read because the proxy-objects adds their data to it.
  attr_reader :object_ids
  attr_accessor :communicator
  
  def initialize(args)
    @php_process = args[:php_process]
    @debug = @php_process.instance_variable_get(:@debug)
    @object_ids = Tsafe::MonHash.new
    @object_unset_ids = Tsafe::MonArray.new
    @objects = Wref_map.new
  end
  
  #This object controls which IDs should be unset on the PHP-side by being a destructor on the Ruby-side.
  def objects_unsetter(id)
    obj_count_id = @object_ids[id]
    
    if @object_unset_ids.index(obj_count_id) == nil
      @object_unset_ids << obj_count_id
    end
    
    @object_ids.delete(id)
  end
  
  #This flushes the unset IDs to the PHP-process and frees memory. This is automatically called if 500 IDs are waiting to be flushed. Normally you would not need or have to call this manually.
  #===Examples
  # php.flush_unset_ids(true)
  def flush_unset_ids(force = false)
    return nil if @php_process.destroyed? or (!force and @object_unset_ids.length < 500)
    while @object_unset_ids.length > 0 and elements = @object_unset_ids.shift(500)
      $stderr.print "Sending unsets: #{elements}\n" if @debug
      @communicator.__send__(:communicate_real, "type" => "unset_ids", "ids" => elements)
    end
    
    #Clean wref-map.
    @objects.clean
  end
  
  def find_by_id(id)
    @objects.get!(id)
  end
  
  def spawn_by_id(id)
    $stderr.print "Spawn new proxy-obj!\n" if @debug
    proxy_obj = ::PhpProcess::ProxyObject.new(
      :php_process => @php_process,
      :objects_handler => self,
      :communicator => @communicator,
      :id => id
    )
    @objects[id] = proxy_obj
  end
end
