extends Control
# ----------------------------------------------------
#  JS bridge helpers (add these lines)
# ----------------------------------------------------
var _js_refs := []         

func _bridge(method_name: String):
	var cb = JavaScript.create_callback(self, method_name)
	_js_refs.append(cb)
	return cb

onready var _list        := $MarginContainer/VBoxContainer
onready var _ready_btn   := $ReadyButton
onready var _start_btn   := $StartButton
onready var _status_lbl  := $StatusLabel
var Playroom             := JavaScript.get_interface("Playroom")

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
	row.get_node("Name").text = player.getProfile().name
	row.get_node("Avatar").texture = _get_avatar(player)

# Lobby.gd  – inside the PlayerRow helper
func _get_avatar(player) -> Texture:
	var url = null
	if player != null and player.getProfile():
		url = player.getProfile().avatarUrl
	# 1) No URL?  Return fallback texture immediately
	if url == null or url == "":
		return preload("res://art/Gorilla.jpg")   #  32×32 placeholder
	# 2) Normal Discord path – download the avatar
	var tex  = ImageTexture.new()
	var http = HTTPRequest.new()
	add_child(http)
	var err  = http.request(url)
	if err != OK:
		http.queue_free()
		return preload("res://art/Gorilla.jpg")
	yield(http, "request_completed")
	var body  = http.get_response_body()
	var image = Image.new()
	if image.load_png_from_buffer(body) != OK:
		tex = preload("res://art/Gorilla.jpg")
	else:
		tex.create_from_image(image, 0)
	http.queue_free()
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
		
