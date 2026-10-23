extends SceneTree
## Headless regression for the runtime autoload's value conversion:
## set_property and call_method must turn JSON-borne values into the types
## their targets expect. Run by test-regressions.mjs inside a throwaway project.

var _runtime: Node
var _target: Node2D
var _failed := false


func _fail(message: String) -> void:
	printerr("FAIL: " + message)
	_failed = true


func _set_prop(property: String, value: Variant, path := "/root/Target") -> Dictionary:
	return _runtime._execute_command("set_property", {"path": path, "property": property, "value": value})


## A value that cannot become the target's type must be an error and leave the
## property as it was, never a zero vector, black, or a cleared resource.
func _expect_rejected(property: String, value: Variant, path := "/root/Target") -> void:
	var node := root.get_node(path.trim_prefix("/root/"))
	var before = node.get(property)
	var r := _set_prop(property, value, path)
	if r.get("type") != "error" or node.get(property) != before:
		_fail("%s <- %s should be rejected and leave %s; got %s, response %s" % [property, JSON.stringify(value), before, node.get(property), JSON.stringify(r)])


func _expect(property: String, value: Variant, expected: Variant) -> void:
	var r := _set_prop(property, value)
	var actual = _target.get(property)
	if r.get("type") != "property_set" or typeof(actual) != typeof(expected) or actual != expected:
		_fail("%s <- %s: got %s (%s), want %s; response %s" % [property, JSON.stringify(value), actual, type_string(typeof(actual)), expected, JSON.stringify(r)])


func _initialize() -> void:
	var target_script := GDScript.new()
	target_script.source_code = """extends Node2D
var flag: bool = true
var count: int = 0
var speed: float = 1.0
var label_text: String = ""
var untyped_vec = Vector2.ZERO
var untyped_num = 1
func move(to: Vector2, fast: bool, steps: int) -> String:
	return "%s %s %s %s" % [to, fast, steps, typeof(steps)]
func takes_int(n: int) -> int:
	return n
func untyped(a, b):
	return [a, b]
"""
	target_script.reload()
	_target = Node2D.new()
	_target.name = "Target"
	_target.set_script(target_script)
	root.add_child(_target)

	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	sprite.texture = PlaceholderTexture2D.new()
	_target.add_child(sprite)

	_runtime = load("res://addons/godot_mcp_runtime/mcp_runtime_autoload.gd").new()
	root.add_child(_runtime)


var _ran := false


# Checks run on the first frame, once both nodes are inside the tree.
func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	_expect("position", "[10, 20]", Vector2(10, 20))
	_expect("position", {"x": 3, "y": 4}, Vector2(3, 4))
	_expect("position", "{\"x\": 5, \"y\": 6}", Vector2(5, 6))
	_expect("position", "Vector2(7, 8)", Vector2(7, 8))
	_expect("position", "(9, 10)", Vector2(9, 10))
	_expect("position", [11, 12], Vector2(11, 12))
	_expect("position", {"_type": "Vector2", "x": 13, "y": 14}, Vector2(13, 14))
	_expect("visible", "false", false)
	_expect("visible", "true", true)
	_expect("visible", false, false)
	_expect("flag", "false", false)
	_expect("flag", 1, true)
	_expect("count", "42", 42)
	_expect("count", 3.0, 3)
	_expect("count", "5", 5)
	_expect("count", "2.9", 2)
	_expect("speed", "3", 3.0)
	_expect("label_text", 42, "42")
	_expect("label_text", "123", "123")
	_expect("label_text", "\"quoted\"", "quoted")
	_expect("untyped_vec", "[1, 2]", Vector2(1, 2))
	_expect("untyped_num", "2.5", 2.5)
	_expect("modulate", "#ff0000", Color(1, 0, 0, 1))
	_expect("modulate", {"r": 0, "g": 1, "b": 0}, Color(0, 1, 0, 1))
	_expect("rotation", "0.5", 0.5)

	_target.position = Vector2(1, 1)
	var bad: Dictionary = _set_prop("position", "garbage")
	if bad.get("type") != "error" or _target.position != Vector2(1, 1):
		_fail("unconvertible Vector2 should be an error and leave the value: %s" % JSON.stringify(bad))
	_target.position = Vector2(5, 5)
	_target.modulate = Color(0.5, 0.5, 0.5)
	_expect_rejected("position", "100")
	_expect_rejected("position", 100)
	_expect_rejected("modulate", "1")
	_expect_rejected("texture", "0", "/root/Target/Sprite")
	_expect_rejected("texture", "false", "/root/Target/Sprite")
	_expect_rejected("position", {"x": 1, "y": "a"})
	_expect_rejected("modulate", {"r": 1, "g": 0, "b": 0, "a": "x"})
	# A string that is not a valid form of a scalar target is an error too,
	# never 0, 0.0 or true.
	_target.count = 7
	_target.speed = 1.5
	_target.flag = false
	_expect_rejected("count", "abc")
	_expect_rejected("count", "")
	_expect_rejected("speed", "abc")
	_expect_rejected("flag", "abc")
	var bad_arg: Dictionary = _runtime._execute_command("call_method", {"path": "/root/Target", "method": "takes_int", "args": ["abc"]})
	if bad_arg.get("type") != "error":
		_fail("typed int method argument \"abc\" should be an error: %s" % JSON.stringify(bad_arg))
	var cleared := _set_prop("texture", "null", "/root/Target/Sprite")
	if cleared.get("type") != "property_set" or root.get_node("Target/Sprite").texture != null:
		_fail("an explicit null should still clear a resource: %s" % JSON.stringify(cleared))
	if _set_prop("no_such_property", 1).get("type") != "error":
		_fail("unknown property should be an error")

	var call: Dictionary = _runtime._execute_command("call_method", {"path": "/root/Target", "method": "move", "args": ["[1, 2]", "false", "3"]})
	if call.get("result") != "(1.0, 2.0) false 3 %d" % TYPE_INT:
		_fail("call_method args not converted: %s" % JSON.stringify(call))
	call = _runtime._execute_command("call_method", {"path": "/root/Target", "method": "move", "args": [{"x": 4, "y": 5}, true, 6]})
	if call.get("result") != "(4.0, 5.0) true 6 %d" % TYPE_INT:
		_fail("call_method JSON args not converted: %s" % JSON.stringify(call))
	call = _runtime._execute_command("call_method", {"path": "/root/Target", "method": "untyped", "args": ["7", "hello"]})
	if call.get("result") != [7.0, "hello"]:
		_fail("call_method untyped args: %s" % JSON.stringify(call))
	call = _runtime._execute_command("call_method", {"path": "/root/Target", "method": "set_visible", "args": ["false"]})
	if _target.visible != false:
		_fail("native method bool arg not converted: %s" % JSON.stringify(call))

	if _failed:
		quit(1)
		return false
	print(JSON.stringify({"ok": true}))
	quit(0)
	return false
