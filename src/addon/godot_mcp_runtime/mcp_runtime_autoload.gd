extends Node

## MCP Runtime Autoload
## This singleton runs in the game and provides runtime inspection capabilities.
## It starts a TCP server that the MCP server can connect to.

const DEFAULT_PORT = 7777
const PROTOCOL_VERSION = "1.0"

var _server: TCPServer
var _clients: Array[StreamPeerTCP] = []
var _port: int = DEFAULT_PORT
var _enabled: bool = true
var _watched_signals: Dictionary = {}  # { "node_path:signal_name": callable }

signal client_connected
signal client_disconnected
signal command_received(command: String, params: Dictionary)


func _ready() -> void:
	name = "MCPRuntime"
	# Match whatever port the launching gopeak will dial. A fixed 7777 means two
	# projects cannot both run their game under runtime verification, which caps
	# concurrent prototyping at one; the env var is inherited from gopeak, which
	# spawns the game process.
	var raw := OS.get_environment("GOPEAK_RUNTIME_PORT")
	if raw.is_valid_int():
		var configured := int(raw)
		if configured > 0 and configured < 65536:
			_port = configured
	_start_server()
	print("[MCP Runtime] Autoload ready, server starting on port %d" % _port)


func _process(_delta: float) -> void:
	if not _enabled or _server == null:
		return
	
	# Accept new connections
	if _server.is_connection_available():
		var client = _server.take_connection()
		if client:
			_clients.append(client)
			print("[MCP Runtime] Client connected")
			client_connected.emit()
			_send_welcome(client)
	
	# Process client messages
	var clients_to_remove: Array[StreamPeerTCP] = []
	for client in _clients:
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients_to_remove.append(client)
			continue
		
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients_to_remove.append(client)
			continue
		var available = client.get_available_bytes()
		if available > 0:
			var data = client.get_utf8_string(available)
			_handle_message(client, data)
	
	# Remove disconnected clients
	for client in clients_to_remove:
		_clients.erase(client)
		print("[MCP Runtime] Client disconnected")
		client_disconnected.emit()


func _start_server() -> void:
	_server = TCPServer.new()
	var error = _server.listen(_port)
	if error != OK:
		push_error("[MCP Runtime] Failed to start server on port %d: %s" % [_port, error])
		_enabled = false
	else:
		print("[MCP Runtime] Server listening on port %d" % _port)


func _send_welcome(client: StreamPeerTCP) -> void:
	var welcome = {
		"type": "welcome",
		"protocol_version": PROTOCOL_VERSION,
		"godot_version": Engine.get_version_info(),
		"project_name": ProjectSettings.get_setting("application/config/name", "Unknown")
	}
	_send_response(client, welcome)


func _handle_message(client: StreamPeerTCP, data: String) -> void:
	var json = JSON.new()
	var error = json.parse(data)
	if error != OK:
		_send_error(client, "Invalid JSON: " + json.get_error_message())
		return
	
	var message = json.get_data()
	if not message is Dictionary:
		_send_error(client, "Message must be an object")
		return
	
	var command = message.get("command", "")
	var params = message.get("params", {})
	var request_id = message.get("id", null)
	
	command_received.emit(command, params)
	
	var result = _execute_command(command, params)
	if request_id != null:
		result["id"] = request_id
	
	_send_response(client, result)


func _execute_command(command: String, params: Dictionary) -> Dictionary:
	match command:
		"ping":
			return {"type": "pong", "timestamp": Time.get_unix_time_from_system()}
		
		"get_tree":
			return _cmd_get_tree(params)
		
		"get_node":
			return _cmd_get_node(params)
		
		"set_property":
			return _cmd_set_property(params)
		
		"call_method":
			return _cmd_call_method(params)
		
		"get_metrics":
			return _cmd_get_metrics(params)
		
		"capture_screenshot":
			return _cmd_capture_screenshot(params)
		
		"capture_viewport":
			return _cmd_capture_viewport(params)
		
		"inject_action":
			return _cmd_inject_action(params)
		
		"inject_key":
			return _cmd_inject_key(params)
		
		"inject_mouse_click":
			return _cmd_inject_mouse_click(params)
		
		"inject_mouse_motion":
			return _cmd_inject_mouse_motion(params)
		
		"watch_signal":
			return _cmd_watch_signal(params)
		
		"unwatch_signal":
			return _cmd_unwatch_signal(params)
		
		_:
			return {"type": "error", "message": "Unknown command: " + command}


func _cmd_get_tree(params: Dictionary) -> Dictionary:
	var root_path = params.get("root", "/root")
	var max_depth = params.get("depth", 3)
	var include_properties = params.get("include_properties", false)
	
	var root = get_tree().root.get_node_or_null(root_path)
	if root == null:
		return {"type": "error", "message": "Node not found: " + root_path}
	
	return {
		"type": "tree",
		"root": _serialize_node_tree(root, 0, max_depth, include_properties)
	}


func _cmd_get_node(params: Dictionary) -> Dictionary:
	var node_path = params.get("path", "")
	if node_path.is_empty():
		return {"type": "error", "message": "Node path required"}
	
	var node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		return {"type": "error", "message": "Node not found: " + node_path}
	
	return {
		"type": "node",
		"data": _serialize_node(node, true)
	}


func _cmd_set_property(params: Dictionary) -> Dictionary:
	var node_path = params.get("path", "")
	var property = params.get("property", "")
	var value = params.get("value")
	
	if node_path.is_empty() or property.is_empty():
		return {"type": "error", "message": "Node path and property required"}
	
	var node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		return {"type": "error", "message": "Node not found: " + node_path}
	
	var info := _property_info(node, property)
	if info.is_empty():
		return {"type": "error", "message": "Property not found on %s: %s" % [node_path, property]}
	var old_value = node.get(property)
	var expected_type := int(info.get("type", TYPE_NIL))
	# An untyped script var: take the shape of what it holds, except numbers,
	# where an int would truncate a float the caller meant.
	if expected_type == TYPE_NIL and old_value != null and not (typeof(old_value) in [TYPE_INT, TYPE_FLOAT]):
		expected_type = typeof(old_value)
	var converted := _coerce_value(value, expected_type)
	if converted.has("error"):
		return {"type": "error", "message": "Cannot set %s.%s: %s" % [node_path, property, converted["error"]]}
	node.set(property, converted["value"])
	
	return {
		"type": "property_set",
		"path": node_path,
		"property": property,
		"old_value": _serialize_value(old_value),
		"new_value": _serialize_value(node.get(property))
	}


func _cmd_call_method(params: Dictionary) -> Dictionary:
	var node_path = params.get("path", "")
	var method = params.get("method", "")
	var args = params.get("args", [])
	
	if node_path.is_empty() or method.is_empty():
		return {"type": "error", "message": "Node path and method required"}
	
	var node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		return {"type": "error", "message": "Node not found: " + node_path}
	
	if not node.has_method(method):
		return {"type": "error", "message": "Method not found: " + method}
	
	var arg_types := _method_arg_types(node, method)
	var deserialized_args = []
	for i in args.size():
		var expected_type: int = arg_types[i] if i < arg_types.size() else TYPE_NIL
		var converted := _coerce_value(args[i], expected_type)
		if converted.has("error"):
			return {"type": "error", "message": "Cannot convert argument %d of %s: %s" % [i, method, converted["error"]]}
		deserialized_args.append(converted["value"])
	
	var result = node.callv(method, deserialized_args)
	
	return {
		"type": "method_result",
		"path": node_path,
		"method": method,
		"result": _serialize_value(result)
	}


func _cmd_get_metrics(params: Dictionary) -> Dictionary:
	var metrics = params.get("metrics", [])
	var result = {
		"type": "metrics",
		"data": {}
	}
	
	# Always include basic metrics
	result["data"]["fps"] = Engine.get_frames_per_second()
	result["data"]["frame_time"] = Performance.get_monitor(Performance.TIME_PROCESS)
	result["data"]["physics_time"] = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	
	# Memory metrics
	result["data"]["memory_static"] = Performance.get_monitor(Performance.MEMORY_STATIC)
	result["data"]["memory_static_max"] = Performance.get_monitor(Performance.MEMORY_STATIC_MAX)
	
	# Object counts
	result["data"]["object_count"] = Performance.get_monitor(Performance.OBJECT_COUNT)
	result["data"]["object_resource_count"] = Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	result["data"]["object_node_count"] = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	result["data"]["object_orphan_node_count"] = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	
	# Render metrics
	result["data"]["render_total_objects"] = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	result["data"]["render_total_primitives"] = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	result["data"]["render_total_draw_calls"] = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	
	return result


func _cmd_capture_screenshot(params: Dictionary) -> Dictionary:
	var viewport = get_viewport()
	if viewport == null:
		return {"type": "error", "message": "No viewport available"}
	return _capture_viewport_image(viewport, params)


func _cmd_capture_viewport(params: Dictionary) -> Dictionary:
	var viewport_path = String(params.get("viewportPath", params.get("viewport_path", "")))
	if viewport_path.is_empty():
		return _cmd_capture_screenshot(params)
	
	var node = get_tree().root.get_node_or_null(viewport_path)
	if node == null:
		return {"type": "error", "message": "Viewport not found: " + viewport_path}
	if not node is Viewport:
		return {"type": "error", "message": "Node is not a Viewport: " + viewport_path}
	return _capture_viewport_image(node as Viewport, params)


func _capture_viewport_image(viewport: Viewport, params: Dictionary) -> Dictionary:
	var viewport_texture = viewport.get_texture()
	if viewport_texture == null:
		return {"type": "error", "message": "No viewport texture available"}
	
	var image = viewport_texture.get_image()
	if image == null:
		return {"type": "error", "message": "Failed to capture viewport image"}
	
	var width = int(params.get("width", 0))
	var height = int(params.get("height", 0))
	if width > 0 and height > 0:
		image.resize(width, height)
	
	var requested_path = String(params.get("output_path", params.get("outputPath", "")))
	if requested_path.is_empty():
		var png_bytes = image.save_png_to_buffer()
		if png_bytes.is_empty():
			return {"type": "error", "message": "Failed to encode screenshot as PNG"}

		return {
			"type": "screenshot",
			"format": "png",
			"encoding": "base64",
			"width": image.get_width(),
			"height": image.get_height(),
			"data": Marshalls.raw_to_base64(png_bytes)
		}

	var screenshot_path = requested_path
	if screenshot_path.begins_with("user://") or screenshot_path.begins_with("res://"):
		screenshot_path = ProjectSettings.globalize_path(screenshot_path)
	var save_error = image.save_png(screenshot_path)
	if save_error != OK:
		return {"type": "error", "message": "Failed to save screenshot as PNG: " + str(save_error)}
	
	return {
		"type": "screenshot_file",
		"format": "png",
		"encoding": "file",
		"width": image.get_width(),
		"height": image.get_height(),
		"path": screenshot_path
	}


func _cmd_inject_action(params: Dictionary) -> Dictionary:
	var action = String(params.get("action", ""))
	var pressed = bool(params.get("pressed", true))
	var strength = float(params.get("strength", 1.0))
	
	if action.is_empty():
		return {"type": "error", "message": "Action name required"}
	
	if not InputMap.has_action(action):
		return {"type": "error", "message": "Action not found: " + action}
	
	var event = InputEventAction.new()
	event.action = action
	event.pressed = pressed
	event.strength = strength
	Input.parse_input_event(event)
	
	return {
		"type": "input_injected",
		"input_type": "action",
		"action": action,
		"pressed": pressed
	}


func _cmd_inject_key(params: Dictionary) -> Dictionary:
	var keycode_raw: Variant = params.get("keycode", 0)
	var pressed = bool(params.get("pressed", true))
	var key_label = String(params.get("key_label", ""))

	if keycode_raw is String and not (keycode_raw as String).is_empty() and key_label.is_empty():
		key_label = keycode_raw as String
	var keycode: int = 0 if keycode_raw is String else int(keycode_raw)

	var event = InputEventKey.new()
	event.pressed = pressed

	if not key_label.is_empty():
		event.keycode = OS.find_keycode_from_string(key_label)
		if event.keycode == KEY_NONE:
			return {"type": "error", "message": "Invalid key_label: " + key_label}
	elif keycode > 0:
		event.keycode = keycode
	else:
		return {"type": "error", "message": "keycode or key_label required"}
	
	Input.parse_input_event(event)
	
	return {
		"type": "input_injected",
		"input_type": "key",
		"keycode": event.keycode,
		"pressed": pressed
	}


func _cmd_inject_mouse_click(params: Dictionary) -> Dictionary:
	var position: Vector2
	if params.has("x") and params.has("y"):
		position = Vector2(float(params["x"]), float(params["y"]))
	else:
		var pos_raw = params.get("position", Vector2.ZERO)
		if pos_raw is Array:
			if pos_raw.size() < 2:
				return {"type": "error", "message": "position array must contain [x, y]"}
			position = Vector2(float(pos_raw[0]), float(pos_raw[1]))
		elif pos_raw is Vector2:
			position = pos_raw
		else:
			return {"type": "error", "message": "position must be Vector2 or [x, y]"}
	var button: int = _resolve_mouse_button(params.get("button", MOUSE_BUTTON_LEFT))
	var pressed = bool(params.get("pressed", true))

	var event = InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)
	
	return {
		"type": "input_injected",
		"input_type": "mouse_click",
		"position": [position.x, position.y],
		"button": button,
		"pressed": pressed
	}


func _cmd_inject_mouse_motion(params: Dictionary) -> Dictionary:
	var position: Vector2
	if params.has("x") and params.has("y"):
		position = Vector2(float(params["x"]), float(params["y"]))
	else:
		var pos_raw = params.get("position", Vector2.ZERO)
		if pos_raw is Array:
			if pos_raw.size() < 2:
				return {"type": "error", "message": "position array must contain [x, y]"}
			position = Vector2(float(pos_raw[0]), float(pos_raw[1]))
		elif pos_raw is Vector2:
			position = pos_raw
		else:
			return {"type": "error", "message": "position must be Vector2 or [x, y]"}
	var rel_raw = params.get("relative", Vector2.ZERO)
	var relative: Vector2
	if params.has("relativeX") and params.has("relativeY"):
		relative = Vector2(float(params["relativeX"]), float(params["relativeY"]))
	elif rel_raw is Array:
		if rel_raw.size() < 2:
			return {"type": "error", "message": "relative array must contain [x, y]"}
		relative = Vector2(float(rel_raw[0]), float(rel_raw[1]))
	elif rel_raw is Vector2:
		relative = rel_raw
	else:
		return {"type": "error", "message": "relative must be Vector2 or [x, y]"}
	
	var event = InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = relative
	Input.parse_input_event(event)
	
	return {
		"type": "input_injected",
		"input_type": "mouse_motion",
		"position": [position.x, position.y],
		"relative": [relative.x, relative.y]
	}


func _cmd_watch_signal(params: Dictionary) -> Dictionary:
	var node_path = params.get("path", "")
	var signal_name = params.get("signal", "")
	
	if node_path.is_empty() or signal_name.is_empty():
		return {"type": "error", "message": "Node path and signal name required"}
	
	var node = get_tree().root.get_node_or_null(node_path)
	if node == null:
		return {"type": "error", "message": "Node not found: " + node_path}
	
	if not node.has_signal(signal_name):
		return {"type": "error", "message": "Signal not found: " + signal_name}
	
	var key = node_path + ":" + signal_name
	if _watched_signals.has(key):
		return {"type": "error", "message": "Signal already being watched"}
	
	var callable = func(args = []):
		_broadcast_signal_event(node_path, signal_name, args)
	
	node.connect(signal_name, callable)
	_watched_signals[key] = callable
	
	return {
		"type": "signal_watched",
		"path": node_path,
		"signal": signal_name
	}


func _cmd_unwatch_signal(params: Dictionary) -> Dictionary:
	var node_path = params.get("path", "")
	var signal_name = params.get("signal", "")
	
	var key = node_path + ":" + signal_name
	if not _watched_signals.has(key):
		return {"type": "error", "message": "Signal not being watched"}
	
	var node = get_tree().root.get_node_or_null(node_path)
	if node != null:
		node.disconnect(signal_name, _watched_signals[key])
	
	_watched_signals.erase(key)
	
	return {
		"type": "signal_unwatched",
		"path": node_path,
		"signal": signal_name
	}


func _broadcast_signal_event(node_path: String, signal_name: String, args: Array) -> void:
	var event = {
		"type": "signal_event",
		"path": node_path,
		"signal": signal_name,
		"args": []
	}
	for arg in args:
		event["args"].append(_serialize_value(arg))
	
	for client in _clients:
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			_send_response(client, event)


func _serialize_node_tree(node: Node, depth: int, max_depth: int, include_properties: bool) -> Dictionary:
	var result = _serialize_node(node, include_properties)
	
	if depth < max_depth:
		var children = []
		for child in node.get_children():
			children.append(_serialize_node_tree(child, depth + 1, max_depth, include_properties))
		result["children"] = children
	
	return result


func _serialize_node(node: Node, include_properties: bool) -> Dictionary:
	var result = {
		"name": node.name,
		"type": node.get_class(),
		"path": str(node.get_path())
	}
	
	if node.get_script():
		result["script"] = node.get_script().resource_path
	
	if include_properties:
		result["properties"] = {}
		for prop in node.get_property_list():
			if prop["usage"] & PROPERTY_USAGE_STORAGE:
				var name = prop["name"]
				if not name.begins_with("_"):
					result["properties"][name] = _serialize_value(node.get(name))
	
	return result


func _serialize_value(value) -> Variant:
	if value == null:
		return null
	elif value is Vector2:
		return {"_type": "Vector2", "x": value.x, "y": value.y}
	elif value is Vector3:
		return {"_type": "Vector3", "x": value.x, "y": value.y, "z": value.z}
	elif value is Vector2i:
		return {"_type": "Vector2i", "x": value.x, "y": value.y}
	elif value is Vector3i:
		return {"_type": "Vector3i", "x": value.x, "y": value.y, "z": value.z}
	elif value is Color:
		return {"_type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
	elif value is Rect2:
		return {"_type": "Rect2", "position": _serialize_value(value.position), "size": _serialize_value(value.size)}
	elif value is Transform2D:
		return {"_type": "Transform2D", "origin": _serialize_value(value.origin), "x": _serialize_value(value.x), "y": _serialize_value(value.y)}
	elif value is NodePath:
		return {"_type": "NodePath", "path": str(value)}
	elif value is Resource:
		return {"_type": "Resource", "path": value.resource_path, "class": value.get_class()}
	elif value is Array:
		var arr = []
		for item in value:
			arr.append(_serialize_value(item))
		return arr
	elif value is Dictionary:
		var dict = {}
		for key in value:
			dict[str(key)] = _serialize_value(value[key])
		return dict
	elif value is Object:
		return {"_type": "Object", "class": value.get_class()}
	else:
		return value


func _deserialize_value(value) -> Variant:
	if value == null:
		return null
	elif value is Dictionary:
		if value.has("_type"):
			match value["_type"]:
				"Vector2":
					return Vector2(value.get("x", 0), value.get("y", 0))
				"Vector3":
					return Vector3(value.get("x", 0), value.get("y", 0), value.get("z", 0))
				"Vector2i":
					return Vector2i(value.get("x", 0), value.get("y", 0))
				"Vector3i":
					return Vector3i(value.get("x", 0), value.get("y", 0), value.get("z", 0))
				"Color":
					return Color(value.get("r", 0), value.get("g", 0), value.get("b", 0), value.get("a", 1))
				"NodePath":
					return NodePath(value.get("path", ""))
				_:
					return value
		else:
			var dict = {}
			for key in value:
				dict[key] = _deserialize_value(value[key])
			return dict
	elif value is Array:
		var arr = []
		for item in value:
			arr.append(_deserialize_value(item))
		return arr
	else:
		return value


func _property_info(node: Object, property: String) -> Dictionary:
	for prop in node.get_property_list():
		if str(prop.get("name", "")) == property:
			return prop
	return {}


func _method_arg_types(node: Object, method: String) -> Array:
	var script = node.get_script()
	var lists: Array = []
	if script:
		lists.append(script.get_script_method_list())
	lists.append(node.get_method_list())
	for list in lists:
		for info in list:
			if str(info.get("name", "")) == method:
				var types: Array = []
				for arg in info.get("args", []):
					types.append(int(arg.get("type", TYPE_NIL)))
				return types
	return []


## Convert a value that arrived as JSON into the type the target expects.
## MCP clients send what the tool schema asks for — usually a string such as
## "false", "[10, 20]", "{\"x\": 1, \"y\": 2}" or "Vector2(10, 20)" — or a real
## JSON value. Assigning those as-is made every Vector2 (0, 0) and every
## non-empty string `true`. Returns {"value": v} or {"error": message}.
func _coerce_value(raw: Variant, expected_type: int) -> Dictionary:
	var value = raw
	if value is String:
		match expected_type:
			TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
				var text: String = value
				if text.length() >= 2 and text.begins_with("\"") and text.ends_with("\""):
					var unquoted = _parse_json(text)
					if unquoted is String:
						text = unquoted
				if expected_type == TYPE_STRING_NAME:
					return {"value": StringName(text)}
				if expected_type == TYPE_NODE_PATH:
					return {"value": NodePath(text)}
				return {"value": text}
		value = _parse_string_value(value)
	value = _deserialize_value(value)
	if expected_type == TYPE_NIL or typeof(value) == expected_type:
		return {"value": value}

	match expected_type:
		TYPE_BOOL:
			if value is int or value is float:
				return {"value": value != 0}
			if value is String:
				match (value as String).strip_edges().to_lower():
					"true", "1", "yes", "on":
						return {"value": true}
					"false", "0", "no", "off", "":
						return {"value": false}
		TYPE_INT:
			if value is float or value is bool:
				return {"value": int(value)}
			if value is String and (value as String).is_valid_float():
				return {"value": int(float(value))}
		TYPE_FLOAT:
			if value is int or value is bool:
				return {"value": float(value)}
			if value is String and (value as String).is_valid_float():
				return {"value": float(value)}
		TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I:
			var keys := ["x", "y", "z", "w"].slice(0, _vector_size(expected_type))
			var parts = _components(value, keys)
			if parts != null:
				return {"value": _make_vector(expected_type, parts)}
		TYPE_COLOR:
			if value is String:
				var sentinel := Color(0.12345, 0.0, 0.0, 0.0)
				var color := Color.from_string(value, sentinel)
				if color != sentinel:
					return {"value": color}
			else:
				var rgba = _components(value, ["r", "g", "b"])
				if rgba != null:
					var alpha := 1.0
					if value is Dictionary:
						alpha = float(value.get("a", 1.0))
					elif value is Array and value.size() >= 4:
						alpha = float(value[3])
					return {"value": Color(rgba[0], rgba[1], rgba[2], alpha)}
		TYPE_RECT2, TYPE_RECT2I:
			var r = null
			if value is Dictionary and value.has("position") and value.has("size"):
				var pos = _components(value["position"], ["x", "y"])
				var size = _components(value["size"], ["x", "y"])
				if pos != null and size != null:
					r = pos + size
			else:
				r = _components(value, ["x", "y", "width", "height"])
			if r != null:
				var rect := Rect2(r[0], r[1], r[2], r[3])
				return {"value": rect if expected_type == TYPE_RECT2 else Rect2i(rect)}
		TYPE_STRING:
			return {"value": str(value)}
		TYPE_STRING_NAME:
			return {"value": StringName(str(value))}
		TYPE_NODE_PATH:
			return {"value": NodePath(str(value))}
		TYPE_OBJECT:
			if value == null:
				return {"value": null}
			var resource_path := ""
			if value is String:
				resource_path = value
			elif value is Dictionary:
				resource_path = str(value.get("path", ""))
			if resource_path.begins_with("res://") or resource_path.begins_with("uid://"):
				var resource = load(resource_path)
				if resource != null:
					return {"value": resource}

	# Last resort for the remaining scalar types. Shapes (arrays, dictionaries,
	# strings) are never forced: Godot converts those to a zero value silently,
	# which is the bug this helper exists to stop.
	if value != null and not (value is Array or value is Dictionary or value is String):
		var fallback = type_convert(value, expected_type)
		if typeof(fallback) == expected_type:
			return {"value": fallback}
	return {"error": "expected %s, got %s %s" % [type_string(expected_type), type_string(typeof(raw)), JSON.stringify(raw)]}


func _parse_json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


## A string from an MCP client: JSON first ("false", "3", "[1, 2]", "{...}"),
## then a Godot constructor ("Vector2(1, 2)"); otherwise the string itself.
func _parse_string_value(text: String) -> Variant:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return text
	var json := JSON.new()
	if json.parse(trimmed) == OK:
		return json.data
	if RegEx.create_from_string("^[A-Za-z][A-Za-z0-9_]*\\(.*\\)$").search(trimmed):
		var parsed = str_to_var(trimmed)
		if parsed != null:
			return parsed
	return text


func _vector_size(type: int) -> int:
	match type:
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return 2
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return 3
	return 4


## Numeric components from {x, y, …}, [x, y, …], "(x, y, …)" or a Vector*;
## null when the shape doesn't fit.
func _components(value: Variant, keys: Array) -> Variant:
	var out: Array = []
	match typeof(value):
		TYPE_DICTIONARY:
			for key in keys:
				if not value.has(key):
					return null
				out.append(float(value[key]))
		TYPE_ARRAY:
			if value.size() < keys.size():
				return null
			for i in keys.size():
				if not (value[i] is int or value[i] is float):
					return null
				out.append(float(value[i]))
		TYPE_STRING:
			var parts: PackedStringArray = (value as String).strip_edges().trim_prefix("(").trim_suffix(")").split(",")
			if parts.size() < keys.size():
				return null
			for i in keys.size():
				if not parts[i].strip_edges().is_valid_float():
					return null
				out.append(float(parts[i]))
		TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I:
			for i in keys.size():
				if i >= _vector_size(typeof(value)):
					return null
				out.append(float(value[i]))
		_:
			return null
	return out


func _make_vector(type: int, c: Array) -> Variant:
	match type:
		TYPE_VECTOR2:
			return Vector2(c[0], c[1])
		TYPE_VECTOR2I:
			return Vector2i(int(c[0]), int(c[1]))
		TYPE_VECTOR3:
			return Vector3(c[0], c[1], c[2])
		TYPE_VECTOR3I:
			return Vector3i(int(c[0]), int(c[1]), int(c[2]))
		TYPE_VECTOR4:
			return Vector4(c[0], c[1], c[2], c[3])
	return Vector4i(int(c[0]), int(c[1]), int(c[2]), int(c[3]))


func _resolve_mouse_button(raw: Variant) -> int:
	if raw is String:
		match (raw as String).to_lower():
			"left": return MOUSE_BUTTON_LEFT
			"right": return MOUSE_BUTTON_RIGHT
			"middle": return MOUSE_BUTTON_MIDDLE
			"wheel_up", "wheelup": return MOUSE_BUTTON_WHEEL_UP
			"wheel_down", "wheeldown": return MOUSE_BUTTON_WHEEL_DOWN
			_: return MOUSE_BUTTON_LEFT
	return int(raw)


func _send_response(client: StreamPeerTCP, data: Dictionary) -> void:
	var json_str = JSON.stringify(data) + "\n"
	client.put_utf8_string(json_str)


func _send_error(client: StreamPeerTCP, message: String) -> void:
	_send_response(client, {"type": "error", "message": message})


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_cleanup()


func _cleanup() -> void:
	for client in _clients:
		client.disconnect_from_host()
	_clients.clear()
	
	if _server:
		_server.stop()
		_server = null
	
	print("[MCP Runtime] Cleanup complete")
