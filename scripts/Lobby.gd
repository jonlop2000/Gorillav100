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
var Playroom := JavaScript.get_interface("Playroom")

var _poll_accum := 0.0
const POLL_RATE := 0.2


func _ready():
	_start_btn.visible = Playroom.isHost()
	_start_btn.disabled = true

	# build initial roster
	for p in PlayroomManager.get_player_states():
		_add_or_update_row(p)

	# wire signals
	Playroom.onPlayerJoin(_bridge("_on_player_join")) 
	_ready_btn.connect("pressed", self, "_on_ready_pressed")
	_start_btn.connect("pressed", self, "_on_start_pressed")

func _add_or_update_row(player):
	var id  = str(player.id)
	var row = _list.get_node_or_null(id)
	if row == null:
		row = preload("res://scenes/ui/PlayerRow.tscn").instance()
		row.name = id
		_list.add_child(row)
	var profile = player.getProfile()
	row.get_node("Name").text = profile.name
	row.get_node("Avatar").texture = _avatar_from_profile(profile)


func _avatar_from_profile(profile) -> Texture:
	var photo : String = profile.photo
	if photo == null or photo == "":
		return preload("res://art/default_avatar.jpg")

	# Split only once; ensure we actually got two chunks
	var arr := photo.split(",", false, 1)
	if arr.size() < 2:
		return preload("res://art/default_avatar.jpg")

	var tex := ImageTexture.new()
	var img := Image.new()

	if photo.begins_with("data:image/svg"):
		var svg_str : String = String(arr[1].percent_decode())
		if img.load_svg_from_string(svg_str) != OK:
			return preload("res://art/default_avatar.jpg")
	else:
		var raw : PoolByteArray = Marshalls.base64_to_raw(arr[1])
		if img.load_png_from_buffer(raw) != OK:
			return preload("res://art/default_avatar.jpg")
	tex.create_from_image(img, 0)
	return tex


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
	if Playroom.isHost():
		Playroom.setState("force_start", true)  # host triggers match

#------------------------------------------------------------------#
#  Event listeners                                                  #
#------------------------------------------------------------------#
func _on_player_join(args):
	_add_or_update_row(args[0])

func _on_player_quit(args):
	var id = str(args[0].id)
	if _list.has_node(id):
		_list.get_node(id).queue_free()

func _on_ready_state(args):
	var player = args[0]
	_add_or_update_row(player)
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
		_poll_accum -= POLL_RATE
		_refresh_player_rows()
		_check_force_start()

func _refresh_player_rows():
	for p in PlayroomManager.get_player_states():
		_add_or_update_row(p)

func _check_force_start():
	if Playroom.getState("force_start") == true:
		# avoid double-start
		if get_tree().current_scene.filename != "res://scenes/Arena.tscn":
			PlayroomManager.start_game()
		
