#!/usr/bin/env php5
<?php

class php_process{
  function __construct(){
    $this->sock_stdin = fopen("php://stdin", "r");
    $this->sock_stdout = fopen("php://stdout", "w");
    $this->objects = array();
    $this->objects_count = 0;
    $proxy_to_func = array("func", "get_var", "object_cache_info", "object_call", "require_once_path", "set_var", "unset_ids");
    
    print "php_script_ready:" . getmypid() . "\n";
    
    while(true){
      $line = fgets($this->sock_stdin, 1048576);
      $data = explode(":", $line);
      $type = $data[0];
      $id = intval($data[1]);
      $args = unserialize(base64_decode($data[2]));
      
      try{
        if ($type == "send"){
          if ($args["type"] == "eval"){
            $res = eval($args["eval_str"] . ";");
            $this->answer($id, $res);
          }elseif($args["type"] == "new"){
            $this->new_object($id, $args);
          }elseif(in_array($args["type"], $proxy_to_func)){
            $this->$args["type"]($id, $args);
          }else{
            throw new exception("Unknown send-type: " . $args["type"]);
          }
        }else{
          throw new exception("Invalid type: " . $type);
        }
      }catch(exception $e){
        $this->answer($id, array("type" => "error", "msg" => $e->getMessage(), "bt" => $e->getTraceAsString()));
      }
    }
  }
  
  function parse_data($data){
    if (is_array($data)){
      foreach($data as $key => $val){
        if (is_object($val)){
          $this->objects[$this->objects_count] = $val;
          $data[$key] = array("type" => "php_process_proxy", "id" => $this->objects_count);
          $this->objects_count++;
        }
      }
      
      return $data;
    }elseif(is_object($data)){
      $this->objects[$this->objects_count] = $val;
      $ret = array("type" => "php_process_proxy", "id" => $this->objects_count);
      $this->objects_count++;
      return $ret;
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
    $new_args = $args["args"];
    
    $klass = new ReflectionClass($class);
    $thing = $klass->newInstanceArgs($new_args);
    
    $this->objects[$this->objects_count] = $thing;
    $count = $this->objects_count;
    $this->objects_count++;
    
    $this->answer($id, array(
      "object_id" => $count
    ));
  }
  
  function set_var($id, $args){
    $object = $this->objects[$args["id"]];
    if (!$object){
      throw new exception("No object by that ID: " . $args["id"]);
    }
    
    $object->$args["name"] = $args["val"];
    $this->answer($id, true);
  }
  
  function get_var($id, $args){
    $object = $this->objects[$args["id"]];
    if (!$object){
      throw new exception("No object by that ID: " . $args["id"]);
    }
    
    $this->answer($id, array(
      "result" => $object->$args["name"]
    ));
  }
  
  function require_once_path($id, $args){
    require_once $args["filepath"];
    $this->answer($id, true);
  }
  
  function object_call($id, $args){
    $object = $this->objects[$args["id"]];
    if (!$object){
      throw new exception("No object by that ID: " . $args["id"]);
    }
    
    $res = call_user_func_array(array($object, $args["method"]), $args["args"]);
    $this->answer($id, array(
      "result" => $res
    ));
  }
  
  function func($id, $args){
    $res = call_user_func_array($args["func_name"], $args["args"]);
    $this->answer($id, array("result" => $res));
  }
  
  function unset_ids($id, $args){
    foreach($args["ids"] as $obj_id){
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
}

$php_process = new php_process();