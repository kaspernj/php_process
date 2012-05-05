#!/usr/bin/env php5
<?php

class php_process{
  function __construct(){
    $this->sock_stdin = fopen("php://stdin", "r");
    $this->sock_stdout = fopen("php://stdout", "w");
    $this->objects = array();
    $this->objects_spl = array();
    $this->objects_count = 0;
    $this->created_functions = array();
    $this->proxy_to_func = array("call_created_func", "constant_val", "create_func", "func", "get_var", "memory_info", "object_cache_info", "object_call", "require_once_path", "set_var", "static_method_call", "unset_ids");
    $this->send_count = 0;
    
    print "php_script_ready:" . getmypid() . "\n";
  }
  
  function start_listening(){
    while(true){
      $line = fgets($this->sock_stdin, 1048576);
      $this->handle_line($line);
    }
  }
  
  function send($data){
    $id = $this->send_count;
    $this->send_count++;
    $data_packed = trim(base64_encode(serialize($data)));
    if (!fwrite($this->sock_stdout, "send:" . $id . ":" . $data_packed . "\n")){
      throw new exception("Could not write to stdout.");
    }
    
    //return $this->read_answer($id);
  }
  
  function handle_line($line){
    $data = explode(":", $line);
    $type = $data[0];
    $id = intval($data[1]);
    $args = unserialize(base64_decode($data[2]));
    if ($args === false){
      throw new exception("The args-data was not unserializeable: " . utf8_encode(base64_decode($data[2])));
    }
    
    try{
      if ($type == "send"){
        if ($args["type"] == "eval"){
          $res = eval($args["eval_str"] . ";");
          $this->answer($id, $res);
        }elseif($args["type"] == "new"){
          $this->new_object($id, $args);
        }elseif(in_array($args["type"], $this->proxy_to_func)){
          $this->$args["type"]($id, $args);
        }else{
          throw new exception("Unknown send-type: " . $args["type"] . " (" . implode(", ", array_keys($args)) . ") (" . base64_decode($data[2]) . ")");
        }
      }else{
        throw new exception("Invalid type: " . $type);
      }
    }catch(exception $e){
      $this->answer($id, array("type" => "error", "msg" => $e->getMessage(), "bt" => $e->getTraceAsString()));
    }
  }
  
  function parse_data($data){
    if (is_array($data)){
      foreach($data as $key => $val){
        if (is_object($val)){
          $data[$key] = $this->parse_data($val);
        }
      }
      
      return $data;
    }elseif(is_object($data)){
      $spl = spl_object_hash($data);
      
      if (array_key_exists($spl, $this->objects_spl)){
        $id = $this->objects_spl[$spl];
      }else{
        $id = $this->objects_count;
        $this->objects_count++;
        
        if (array_key_exists($id, $this->objects)){
          throw new exception("Object with that ID already exists: " . $id);
        }
        
        $this->objects[$id] = array("obj" => $data, "spl" => $spl);
        $this->objects_spl[$spl] = $id;
      }
      
      $ret = array("proxyobj", $id);
      return $ret;
    }else{
      return $data;
    }
  }
  
  function read_parsed_data($data){
    if (is_array($data) and array_key_exists("type", $data) and $data["type"] == "proxyobj" and array_key_exists("id", $data)){
      $object = $this->objects[$data["id"]]["obj"];
      if (!$object){
        throw new exception("No object by that ID: " . $data["id"]);
      }
      
      return $object;
    }elseif(is_array($data) and array_key_exists("type", $data) and $data["type"] == "php_process_created_function" and array_key_exists("id", $data)){
      $func = $this->created_functions[$data["id"]]["func"];
      return $func;
    }elseif(is_array($data)){
      foreach($data as $key => $val){
        $data[$key] = $this->read_parsed_data($val);
      }
      
      return $data;
    }else{
      return $data;
    }
  }
  
  function answer($id, $data){
    if (!fwrite($this->sock_stdout, "answer:" . $id . ":" . base64_encode(serialize($this->parse_data($data))) . "\n")){
      throw new exception("Could not write to socket.");
    }
  }
  
  function new_object($id, $args){
    $class = $args["class"];
    $new_args = $this->read_parsed_data($args["args"]);
    
    $klass = new ReflectionClass($class);
    $object = $klass->newInstanceArgs($new_args);
    
    $this->answer($id, $object);
  }
  
  function set_var($id, $args){
    $object = $this->objects[$args["id"]]["obj"];
    if (!$object){
      throw new exception("No object by that ID: " . $args["id"]);
    }
    
    $object->$args["name"] = $args["val"];
    $this->answer($id, true);
  }
  
  function get_var($id, $args){
    $object = $this->objects[$args["id"]]["obj"];
    if (!$object){
      throw new exception("No object by that ID: " . $args["id"]);
    }
    
    $this->answer($id, $object->$args["name"]);
  }
  
  function object_call($id, $args){
    if (!array_key_exists($args["id"], $this->objects)){
      throw new exception("No object by that ID: " . $args["id"]);
    }
    
    $object = $this->objects[$args["id"]]["obj"];
    $call_arr = array($object, $args["method"]);
    
    //Error handeling.
    if (!$object){
      throw new exception("No object by that ID: " . $args["id"]);
    }elseif(!method_exists($object, $args["method"])){
      throw new exception("No such method: " . get_class($object) . "->" . $args["method"] . "()");
    }elseif(!is_callable($call_arr)){
      throw new exception("Not callable: " . get_class($object) . "->" . $args["method"] . "()");
    }
    
    $res = call_user_func_array($call_arr, $this->read_parsed_data($args["args"]));
    $this->answer($id, $res);
  }
  
  function func($id, $args){
    //These functions cant be called normally. Hack them with eval instead.
    $specials = array("die", "exit", "require", "require_once", "include", "include_once");
    $newargs = $this->read_parsed_data($args["args"]);
    
    if (in_array($args["func_name"], $specials)){
      $eval_str = $args["func_name"] . "(";
      $count = 0;
      foreach($newargs as $key => $val){
        if (!is_numeric($key)){
          throw new exception("Invalid key: '" . $key . "'.");
        }
        
        if ($count > 0){
          $eval_str .= ",";
        }
        
        $eval_str .= "\$args['args'][" . $count . "]";
        $count++;
      }
      $eval_str .= ");";
      
      $res = eval($eval_str);
    }else{
      $res = call_user_func_array($args["func_name"], $newargs);
    }
    
    $this->answer($id, $res);
  }
  
  function unset_ids($id, $args){
    foreach($args["ids"] as $obj_id){
      if (!array_key_exists($obj_id, $this->objects)){
        continue;
      }
      
      $spl = $this->objects[$obj_id]["spl"];
      
      if (!array_key_exists($spl, $this->objects_spl)){
        throw new exception("SPL could not be found: " . $spl);
      }
      
      unset($this->objects_spl[$spl]);
      unset($this->objects[$obj_id]);
    }
    
    $this->answer($id, true);
  }
  
  function object_cache_info($id, $args){
    $types = array();
    foreach($this->objects as $key => $val){
      if (is_object($val)){
        $types[] = "object: " . get_class($val);
      }else{
        $types[] = gettype($val);
      }
    }
    
    $this->answer($id, array(
      "count" => count($this->objects),
      "types" => $types
    ));
  }
  
  function static_method_call($id, $args){
    $call_arr = array($args["class_name"], $args["method_name"]);
    
    if (!class_exists($args["class_name"])){
      throw new exception("Class does not exist: '" . $args["class_name"] . "'.");
    }elseif(!method_exists($args["class_name"], $args["method_name"])){
      throw new exception("Such a static method does not exist: " . $args["class_name"] . "::" . $args["method_name"] . "()");
    }elseif(!is_callable($call_arr)){
      throw new exception("Invalid class-name (" . $args["class_name"] . ") or method-name (" . $args["method_name"] . "). It was not callable.");
    }
    
    $newargs = $this->read_parsed_data($args["args"]);
    $res = call_user_func_array($call_arr, $newargs);
    
    $this->answer($id, $res);
  }
  
  function create_func($id, $args){
    $cb_id = $args["callback_id"];
    $func = create_function("", "global \$php_process; \$php_process->call_back_created_func(" . $cb_id . ", func_get_args());");
    if (!$func){
      throw new exception("Could not create function.");
    }
    
    $this->created_functions[$cb_id] = array("func" => $func);
    $this->answer($id, true);
  }
  
  function call_back_created_func($func_id, $args){
    $this->send(array(
      "type" => "call_back_created_func",
      "func_id" => $func_id,
      "args" => $args
    ));
  }
  
  function call_created_func($id, $args){
    $func = $this->created_functions[$args["id"]]["func"];
    if (!$func){
      throw new exception("No created function by that ID: '" . $args["id"] . "'.\n\n" . print_r($args, true) . "\n\n" . print_r($this->created_functions, true));
    }
    
    $eval_str = "\$func(";
    $count = 0;
    
    foreach($args["args"] as $key => $val){
      if ($count > 0){
        $eval_str .= ", ";
      }
      
      $eval_str .= "\$args['args'][" . $count . "]";
      $count++;
    }
    
    $eval_str .= ");";
    $res = eval($eval_str);
    $this->answer($id, $res);
  }
  
  function constant_val($id, $args){
    $this->answer($id, constant($args["name"]));
  }
  
  function memory_info($id, $args){
    $this->answer($id, array(
      "objects" => count($this->objects),
      "objects_spl" => count($this->objects_spl),
      "created_functions" => count($this->created_functions)
    ));
  }
}

$php_process = new php_process();
$php_process->start_listening();