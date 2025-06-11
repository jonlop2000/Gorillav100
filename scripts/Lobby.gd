extends Control
# ----------------------------------------------------
#  JS bridge helpers (add these lines)
# ----------------------------------------------------
var _js_refs := []         

func _bridge(method_name: String):
	var cb = JavaScript.create_callback(self, method_name)
	_js_refs.append(cb)
	return cb

onready var _list := $Card/VBox/PlayerPanel/PlayerList
onready var _ready_btn := $Card/VBox/BtnRow/ReadyButton
onready var _start_btn := $Card/VBox/BtnRow/StartButton
onready var _status_lbl  := $Card/VBox/StatusLabel
onready var _template := $Card/VBox/PlayerPanel/PlayerList/PlayerRowTemplate

var Playroom := JavaScript.get_interface("Playroom")
var _poll_accum := 0.0
var _ready_cache := {}
const POLL_RATE := 0.2

func _ready() -> void:
	# Hide the template immediately
	_template.visible = false
	# Start polling until Playroom comes alive
	call_deferred("_wait_for_playroom")

# --------------  deferred bootstrap --------------
func _wait_for_playroom() -> void:
	if Playroom == null:
		# JavaScript bridge not ready yet – try again next frame
		call_deferred("_wait_for_playroom")
		return

	_do_initial_setup()

# --------------  former contents of _ready() --------------
func _do_initial_setup() -> void:
	# 1) Clear rows
	for child in _list.get_children():
		if child != _template:
			child.queue_free()

	# 2) Avatar-ready hookup (once)
	if not AvatarCache.is_connected("avatar_ready", self, "_on_avatar_ready"):
		AvatarCache.connect("avatar_ready", self, "_on_avatar_ready")

	# 3) Build UI for existing players
	_start_btn.visible   = Playroom.isHost()
	_start_btn.disabled  = true

	for p in PlayroomManager.get_player_states():
		_add_or_update_row(p)

	# 4) Wire Playroom signals & buttons
	Playroom.onPlayerJoin(_bridge("_on_player_join"))
	
	_ready_btn.connect("pressed", self, "_on_ready_pressed")
	_start_btn.connect("pressed", self, "_on_start_pressed")

func _add_or_update_row(player):
	var id  = str(player.id)
	var row = _list.get_node_or_null(id)
	if row == null:
		row = _template.duplicate()
		row.name    = id
		row.visible = true
		row.get_node("Avatar").visible = false
		_list.add_child(row)

	row.get_node("Name").text = player.getProfile().name
	if AvatarCache.has(id):
		_apply_avatar(id, row)

func _on_avatar_ready(player_id: String):
	var row = _list.get_node_or_null(player_id)
	if row:
		_apply_avatar(player_id, row)

func _apply_avatar(player_id: String, row):
	var av = row.get_node("Avatar")
	av.texture = AvatarCache.get(player_id)
	av.visible = true

#------------------------------------------------------------------#
#  Button callbacks                                                 #
#------------------------------------------------------------------#
func _on_ready_pressed():
	if Playroom == null:
		return                        # JS bridge not ready yet
	var me = Playroom.me()
	if me == null:
		return                        # safety—shouldn't happen
	var current = me.getState("ready") == true
	me.setState("ready", not current, true)   # toggle, reliable send
	if current:
		_ready_btn.text = "Ready"     # we just un-readied
	else:
		_ready_btn.text = "Un-ready"  # we just readied

	_refresh_start_button()

func _on_start_pressed():
	PlayroomManager.host_start_match()           

#------------------------------------------------------------------#
#  Event listeners                                                  #
#------------------------------------------------------------------#

func _on_player_join(args):
	var state  = args[0]
	_add_or_update_row(state)
	state.onQuit(_bridge("_on_player_quit"))
	
	_refresh_player_rows()
	_refresh_start_button()

func _on_player_quit(args):
	var id = str(args[0].id)
	if _list.has_node(id):
		_list.get_node(id).queue_free()

	# ─── IMMEDIATELY refresh both the player list AND the Start button ───
	_refresh_player_rows()
	_refresh_start_button()


func _on_ready_state(args):
	var p_state = args[0]
	_add_or_update_row(p_state)
	_refresh_start_button()

func _refresh_start_button():
	if Playroom == null or not Playroom.isHost():
		return
	var all_ready := true
	for p in PlayroomManager.get_player_states():
		if p.getState("ready") != true:
			all_ready = false
			break
	_start_btn.disabled = not all_ready

func _process(delta):
	_poll_accum += delta
	if _poll_accum >= POLL_RATE:
		_poll_accum = 0
		for p in PlayroomManager.get_player_states():
			var id = str(p.id)
			var is_ready = p.getState("ready") == true
			_ready_cache[id] = is_ready
		_refresh_start_button()
		_refresh_player_rows()

func _refresh_player_rows():
	var active_ids = []
	# 1) Gather all currently joined player IDs and ensure their rows exist
	for p in PlayroomManager.get_player_states():
		var id = str(p.id)
		active_ids.append(id)
		_add_or_update_row(p)

	# 2) Remove any leftover rows for players who have quit
	for row in _list.get_children():
		if row == _template:
			continue
		if not active_ids.has(row.name):
			row.queue_free()

func _exit_tree():
	_js_refs.clear()  

