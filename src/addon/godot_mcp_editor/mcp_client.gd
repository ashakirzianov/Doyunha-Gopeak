@tool
extends Node
class_name MCPEditorClient

signal connected
signal disconnected
signal tool_requested(request_id: String, tool_name: String, args: Dictionary)

const DEFAULT_URL := "ws://127.0.0.1:6505/godot"
const RECONNECT_DELAY := 3.0
const MAX_RECONNECT_DELAY := 30.0
# Bridge lease written by scripts/gopeak-launch.sh / bridge-claim.sh — points the
# editor at whichever agent session currently holds the bridge (see
# docs/godot-mcp-multiagent.md). Polled so a lease handoff reconnects live.
const LEASE_PATH := "res://.godot/mcp-bridge/lease.json"
const LEASE_POLL_INTERVAL := 3.0

var socket: WebSocketPeer = WebSocketPeer.new()
var server_url: String = DEFAULT_URL
var _is_connected := false
var _reconnect_timer: Timer
var _lease_timer: Timer
var _current_reconnect_delay := RECONNECT_DELAY
var _should_reconnect := true
var _project_path: String
var _initialized := false


func _ready() -> void:
	_project_path = ProjectSettings.globalize_path("res://")

	_reconnect_timer = Timer.new()
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_on_reconnect_timer)
	add_child(_reconnect_timer)

	_lease_timer = Timer.new()
	_lease_timer.wait_time = LEASE_POLL_INTERVAL
	_lease_timer.timeout.connect(_on_lease_poll)
	add_child(_lease_timer)
	_lease_timer.start()

	set_process(true)
	_initialized = true


func _process(_delta: float) -> void:
	if not _initialized:
		return

	if socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		if _is_connected:
			_handle_disconnect()
		return

	socket.poll()

	match socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _is_connected:
				_handle_connect()

			while socket.get_available_packet_count() > 0:
				var packet := socket.get_packet()
				_handle_message(packet.get_string_from_utf8())

		WebSocketPeer.STATE_CLOSING:
			pass

		WebSocketPeer.STATE_CLOSED:
			if _is_connected:
				_handle_disconnect()


func connect_to_server(url: String = "") -> void:
	server_url = _resolve_server_url(url)
	_should_reconnect = true
	_current_reconnect_delay = RECONNECT_DELAY
	_attempt_connection()


func _resolve_server_url(explicit_url: String) -> String:
	if explicit_url != "":
		return explicit_url

	var lease_url := _read_lease_url()
	if lease_url != "":
		return lease_url

	var env_keys := ["GODOT_BRIDGE_PORT", "MCP_BRIDGE_PORT", "GOPEAK_BRIDGE_PORT"]
	for key in env_keys:
		var raw := OS.get_environment(key)
		if raw == "":
			continue
		if raw.is_valid_int():
			var port := int(raw)
			if port >= 1 and port <= 65535:
				return "ws://127.0.0.1:%d/godot" % port

	return DEFAULT_URL


## Returns the ws URL from the bridge lease, or "" when there is no live lease.
## A lease whose pid is no longer running is stale (crashed holder) and ignored,
## which lets the env/default fallbacks take over without any manual reset.
func _read_lease_url() -> String:
	if not FileAccess.file_exists(LEASE_PATH):
		return ""
	var file := FileAccess.open(LEASE_PATH, FileAccess.READ)
	if file == null:
		return ""
	var data = JSON.parse_string(file.get_as_text())
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	var port := int(data.get("port", 0))
	if port < 1 or port > 65535:
		return ""
	var pid := int(data.get("pid", 0))
	if not _pid_is_live(pid):
		return ""
	return "ws://127.0.0.1:%d/godot" % port


## True when `pid` names a live process.
##
## Deliberately NOT OS.is_process_running(): on Unix that is implemented with
## waitpid(), which answers only for *child* processes and returns false (with an
## ERROR spam) for anything else. The bridge holder is a gopeak launched by the
## agent session, never a child of the editor — so is_process_running() called
## every live lease stale, the editor fell through to the dead :6505 default, and
## the bridge never connected. Observed on Godot 4.7 / macOS.
func _pid_is_live(pid: int) -> bool:
	if pid <= 0:
		return false
	var out := []
	return OS.execute("kill", ["-0", str(pid)], out, true) == 0


## Follow lease handoffs: when the resolved target changes (new holder claimed the
## lease, or the holder died and a fallback applies), reconnect to the new target.
func _on_lease_poll() -> void:
	if not _should_reconnect:
		return
	var target := _resolve_server_url("")
	if target != server_url:
		server_url = target
		_current_reconnect_delay = RECONNECT_DELAY
		if _reconnect_timer:
			_reconnect_timer.stop()
		_attempt_connection()
		return
	# Self-heal: a failed *initial* connect leaves the socket CLOSED with no retry
	# scheduled (the reconnect timer only arms after a drop) — retry it here.
	if not _is_connected \
			and socket.get_ready_state() == WebSocketPeer.STATE_CLOSED \
			and _reconnect_timer and _reconnect_timer.is_stopped():
		_attempt_connection()


func disconnect_from_server() -> void:
	_should_reconnect = false
	if _reconnect_timer:
		_reconnect_timer.stop()
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.close()
	_is_connected = false


func _attempt_connection() -> void:
	if socket.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		# connect_to_url fails on a peer that is still open/closing (e.g. a lease
		# handoff away from a live bridge) — abandon it and start from a fresh peer.
		socket.close()
		socket = WebSocketPeer.new()
		if _is_connected:
			_is_connected = false
			disconnected.emit()

	var err := socket.connect_to_url(server_url)
	if err != OK:
		push_error("[MCP Editor] Failed to connect: %s" % err)
		_schedule_reconnect()


func _handle_connect() -> void:
	_is_connected = true
	_current_reconnect_delay = RECONNECT_DELAY

	_send_message({
		"type": "godot_ready",
		"project_path": _project_path
	})

	connected.emit()


func _handle_disconnect() -> void:
	_is_connected = false
	disconnected.emit()

	if _should_reconnect:
		_schedule_reconnect()


func _schedule_reconnect() -> void:
	if _reconnect_timer == null:
		return
	_reconnect_timer.start(_current_reconnect_delay)
	_current_reconnect_delay = min(_current_reconnect_delay * 2.0, MAX_RECONNECT_DELAY)


func _on_reconnect_timer() -> void:
	_attempt_connection()


func _handle_message(json_string: String) -> void:
	var message = JSON.parse_string(json_string)
	if message == null:
		push_error("[MCP Editor] Failed to parse message: %s" % json_string)
		return

	match message.get("type", ""):
		"ping":
			_send_message({"type": "pong"})

		"tool_invoke":
			var request_id: String = message.get("id", "")
			var tool_name: String = message.get("tool", "")
			var args: Dictionary = message.get("args", {})
			tool_requested.emit(request_id, tool_name, args)

		_:
			pass


func send_tool_result(request_id: String, success: bool, result = null, error: String = "") -> void:
	var response := {
		"type": "tool_result",
		"id": request_id,
		"success": success
	}

	if success:
		response["result"] = result
	else:
		response["error"] = error

	_send_message(response)


func _send_message(message: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(message))


func is_connected_to_server() -> bool:
	return _is_connected
