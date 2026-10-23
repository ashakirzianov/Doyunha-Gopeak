extends SceneTree
## Headless regression for the editor scene tools: connect_signal persistence,
## instance_scene, and scenes surviving a round trip through the tools.
## Run by test-regressions.mjs inside a throwaway project.

var _tools
var _failed := false


func _fail(message: String) -> void:
	if not _failed:
		printerr("FAIL: " + message)
	_failed = true


func _text(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _save(root: Node, path: String) -> void:
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, path)
	root.free()


func _call(method: String, args: Dictionary) -> Dictionary:
	args["projectPath"] = ProjectSettings.globalize_path("res://")
	return _tools.call(method, args)


func _init() -> void:
	_tools = load("res://addons/godot_mcp_editor/tools/scene_tools.gd").new()

	var receiver := GDScript.new()
	receiver.source_code = "extends Node2D\nfunc _on_timeout() -> void:\n\tpass\n"
	ResourceSaver.save(receiver, "res://receiver.gd")

	var main := Node2D.new()
	main.name = "Main"
	main.set_script(load("res://receiver.gd"))
	var timer := Timer.new()
	timer.name = "T"
	main.add_child(timer)
	timer.owner = main
	_save(main, "res://Main.tscn")

	var enemy := Node2D.new()
	enemy.name = "Enemy"
	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	enemy.add_child(sprite)
	sprite.owner = enemy
	_save(enemy, "res://Enemy.tscn")

	# 1. connect_signal must write a [connection] line.
	var r := _call("connect_signal", {"scenePath": "res://Main.tscn", "sourceNodePath": "T", "signalName": "timeout", "targetNodePath": ".", "methodName": "_on_timeout"})
	if not r.get("ok", false):
		_fail("connect_signal: %s" % JSON.stringify(r))
	if not _text("res://Main.tscn").contains('[connection signal="timeout" from="T" to="." method="_on_timeout"]'):
		_fail("connect_signal persisted nothing:\n" + _text("res://Main.tscn"))
	r = _call("list_connections", {"scenePath": "res://Main.tscn"})
	if r.get("connections", []).size() != 1:
		_fail("list_connections: %s" % JSON.stringify(r))

	# 2. instance_scene writes a PackedScene ext_resource and an instance node.
	r = _call("instance_scene", {"scenePath": "res://Main.tscn", "instanceScenePath": "Enemy.tscn", "properties": {"position": {"x": 10, "y": 20}}})
	if not r.get("ok", false) or r.get("nodeName") != "Enemy":
		_fail("instance_scene: %s" % JSON.stringify(r))
	var text := _text("res://Main.tscn")
	if not text.contains('[ext_resource type="PackedScene"') or not text.contains('path="res://Enemy.tscn"'):
		_fail("instance_scene: no PackedScene ext_resource:\n" + text)
	if not RegEx.create_from_string('\\[node name="Enemy" parent="\\." [^\\]]*instance=ExtResource\\(').search(text):
		_fail("instance_scene: no instance node:\n" + text)
	if text.contains('name="Sprite"'):
		_fail("instance_scene baked the instanced scene's children:\n" + text)
	if not text.contains("position = Vector2(10, 20)"):
		_fail("instance_scene: property override missing:\n" + text)

	r = _call("instance_scene", {"scenePath": "res://Main.tscn", "instanceScenePath": "res://Enemy.tscn"})
	if r.get("nodeName") != "Enemy2":
		_fail("instance_scene default name not made unique: %s" % JSON.stringify(r))
	r = _call("instance_scene", {"scenePath": "res://Main.tscn", "instanceScenePath": "res://Enemy.tscn", "nodeName": "T"})
	if r.get("ok", true):
		_fail("instance_scene accepted a taken explicit name")
	r = _call("instance_scene", {"scenePath": "res://Enemy.tscn", "instanceScenePath": "res://Main.tscn"})
	if r.get("ok", true):
		_fail("instance_scene accepted a cyclic instance")
	r = _call("instance_scene", {"scenePath": "res://Main.tscn", "instanceScenePath": "res://Main.tscn"})
	if r.get("ok", true):
		_fail("instance_scene accepted instancing a scene into itself")

	# A connection from inside an instance whose children are not editable is
	# dropped by Godot on save; the tool must say so, not report success.
	r = _call("connect_signal", {"scenePath": "res://Main.tscn", "sourceNodePath": "Enemy/Sprite", "signalName": "texture_changed", "targetNodePath": ".", "methodName": "_on_timeout"})
	if r.get("ok", true) or not str(r.get("error", "")).contains("Editable Children") or not str(r.get("error", "")).contains("res://Enemy.tscn"):
		_fail("connect_signal from a non-editable instance child: %s" % JSON.stringify(r))
	if _text("res://Main.tscn").contains('signal="texture_changed"'):
		_fail("unexpected texture_changed connection written")

	# 3. A later edit keeps the connection and the instances as instances.
	r = _call("add_node", {"scenePath": "res://Main.tscn", "nodeType": "Node2D", "nodeName": "Later"})
	text = _text("res://Main.tscn")
	if not text.contains('[connection signal="timeout"'):
		_fail("round trip dropped the connection:\n" + text)
	if RegEx.create_from_string('\\[node name="Enemy" type=').search(text) or text.contains('name="Sprite"'):
		_fail("round trip rewrote the instance as plain nodes:\n" + text)
	var loaded := (load("res://Main.tscn") as PackedScene).instantiate()
	if loaded.get_node_or_null("Enemy/Sprite") == null or loaded.get_node("Enemy").position != Vector2(10, 20):
		_fail("instanced scene does not load back with its children and override")
	loaded.free()

	# 4. An inherited scene stays inherited after an edit.
	var boss := FileAccess.open("res://Boss.tscn", FileAccess.WRITE)
	boss.store_string('[gd_scene format=3]\n\n[ext_resource type="PackedScene" path="res://Enemy.tscn" id="1"]\n\n[node name="Enemy" instance=ExtResource("1")]\n')
	boss.close()
	_call("add_node", {"scenePath": "res://Boss.tscn", "nodeType": "Node2D", "nodeName": "Crown"})
	text = _text("res://Boss.tscn")
	if not RegEx.create_from_string('\\[node name="Enemy" [^\\]]*instance=ExtResource\\(').search(text) or text.contains('name="Sprite"'):
		_fail("round trip flattened an inherited scene:\n" + text)

	if _failed:
		quit(1)
		return
	print(JSON.stringify({"ok": true}))
	quit(0)
