@tool
extends EditorPlugin

const MCPEditorClientScript = preload("mcp_client.gd")
const MCPToolExecutorScript = preload("tool_executor.gd")

var _mcp_client: Node
var _tool_executor: Node
var _status_button: Button


func _enter_tree() -> void:
	_mcp_client = MCPEditorClientScript.new()
	_mcp_client.name = "MCPEditorClient"
	add_child(_mcp_client)

	_tool_executor = MCPToolExecutorScript.new()
	_tool_executor.name = "MCPToolExecutor"
	add_child(_tool_executor)
	_tool_executor.set_editor_plugin(self)

	_mcp_client.connected.connect(_on_connected)
	_mcp_client.disconnected.connect(_on_disconnected)
	_mcp_client.tool_requested.connect(_on_tool_requested)

	_setup_status_indicator()
	_mcp_client.connect_to_server()


func _exit_tree() -> void:
	if _mcp_client:
		if _mcp_client.connected.is_connected(_on_connected):
			_mcp_client.connected.disconnect(_on_connected)
		if _mcp_client.disconnected.is_connected(_on_disconnected):
			_mcp_client.disconnected.disconnect(_on_disconnected)
		if _mcp_client.tool_requested.is_connected(_on_tool_requested):
			_mcp_client.tool_requested.disconnect(_on_tool_requested)
		_mcp_client.disconnect_from_server()
		_mcp_client.queue_free()
		_mcp_client = null

	if _tool_executor:
		_tool_executor.queue_free()
		_tool_executor = null

	if _status_button:
		remove_control_from_container(CONTAINER_TOOLBAR, _status_button)
		_status_button.queue_free()
		_status_button = null


func _setup_status_indicator() -> void:
	# A flat toolbar button that doubles as a status readout and a click-to-reconnect control —
	# the addon doesn't auto-retry a failed initial connection, so this is the manual recovery.
	_status_button = Button.new()
	_status_button.flat = true
	_status_button.focus_mode = Control.FOCUS_NONE
	_status_button.tooltip_text = "Click to reconnect the MCP editor bridge"
	_status_button.add_theme_font_size_override("font_size", 12)
	_status_button.pressed.connect(_on_status_button_pressed)
	add_control_to_container(CONTAINER_TOOLBAR, _status_button)
	_set_status("MCP: Connecting...", Color.YELLOW)


func _on_status_button_pressed() -> void:
	if _mcp_client == null:
		return
	_set_status("MCP: Connecting...", Color.YELLOW)
	_mcp_client.connect_to_server()


## Set the button's label and colour. Overrides every font-colour state so the status reads the
## same whether the button is idle, hovered, or pressed.
func _set_status(text: String, color: Color) -> void:
	if _status_button == null:
		return
	_status_button.text = text
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		_status_button.add_theme_color_override(key, color)


func _on_connected() -> void:
	_set_status("MCP: Connected", Color.GREEN)


func _on_disconnected() -> void:
	_set_status("MCP: Disconnected", Color.RED)


func _on_tool_requested(request_id: String, tool_name: String, args: Dictionary) -> void:
	if _tool_executor == null or _mcp_client == null:
		return

	var result: Dictionary = _tool_executor.execute_tool(tool_name, args)
	var success: bool = result.get("ok", false)

	if success:
		var payload := result.duplicate(true)
		payload.erase("ok")
		_mcp_client.send_tool_result(request_id, true, payload, "")
	else:
		_mcp_client.send_tool_result(request_id, false, null, str(result.get("error", "Unknown error")))
