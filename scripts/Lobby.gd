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
var _avatar_cache := {}  #Dictionary 
 
const POLL_RATE := 0.2

func _ready():
	_start_btn.visible = Playroom.isHost()
	_start_btn.disabled = true

	# build initial roster
	for p in PlayroomManager.get_player_states():
		_prefetch_avatar(p)
		_add_or_update_row(p)
	# wire signals
	Playroom.onPlayerJoin(_bridge("_on_player_join")) 
	_ready_btn.connect("pressed", self, "_on_ready_pressed")
	_start_btn.connect("pressed", self, "_on_start_pressed")

func _prefetch_avatar(player):
	var id  = str(player.id)
	if _avatar_cache.has(id):
		return   # already have it

	var url = player.getProfile().photo
	if url and url.begins_with("http"):
		var http = HTTPRequest.new()
		add_child(http)
		http.connect("request_completed", self,
					 "_on_avatar_request_completed", [id, http])
		http.request(url)

func _add_or_update_row(player):
	var id   = str(player.id)
	var row  = _list.get_node_or_null(id)
	if row == null:
		# 1) Grab the template in the scene
		var template = $Card/VBox/PlayerPanel/PlayerList/PlayerRowTemplate
		# 2) Duplicate it (deep copy), show it, give it the right name
		row = template.duplicate()
		row.name    = id
		row.visible = true
		# 3) Add it into the list instead of the hidden template
		_list.add_child(row)
	# populate fields
	var profile = player.getProfile()
	row.get_node("Name").text   = profile.name

	if _avatar_cache.has(id):
		row.get_node("Avatar").texture = _avatar_cache[id]
	else:
		row.get_node("Avatar").texture = preload("res://art/default_avatar.jpg")
		_prefetch_avatar(player)   # kick off download if needed

func _on_avatar_request_completed(result, response_code, headers, body, id, http: HTTPRequest):
	# Always free the node at the end
	http.queue_free()

	if result != OK or response_code != 200:
		push_warning("Avatar download failed for " + id)
		return

	var img = Image.new()
	if img.load_png_from_buffer(body) != OK:
		push_warning("Invalid image data for " + id)
		return

	img.resize(40, 40)
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	_avatar_cache[id] = tex

	var row = _list.get_node_or_null(id)
	if row:
		row.get_node("Avatar").texture = tex


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
	var player = args[0]
	_prefetch_avatar(player)
	_add_or_update_row(player)

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
		
