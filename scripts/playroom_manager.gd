extends Node 

var Playroom = JavaScript.get_interface("Playroom")
var _js_refs = []
var players = {}

func bridge_to_js(cb_func):
	var cb = JavaScript.create_callback(self, cb_func)
	_js_refs.append(cb)
	return cb

func _ready():
	if OS.has_feature("HTML5"):
		# --- only run when actually in a browser build ---
		Playroom = JavaScript.get_interface("Playroom")
		var opts = JavaScript.create_object("Object")
		opts.gameId = "<YOUR GAME ID>"
		opts.maxPlayersPerRoom = 100
		Playroom.insertCoin(opts, bridge_to_js("on_insert_coin"))
	else:
		# in the editor / desktop, we just skip the JS bridge
		print("PlayroomManager: skipping JS init (not HTML5).")

	# --- now do the “spawn local player & boss” steps in both cases ---
	var me = null
	if OS.has_feature("HTML5"):
		me = Playroom.me()
	else:
		# fake a “local” state for testing
		me = { "id": 1, "isHost": true }
	var pnode = _spawn_player(me)
	players[str(me.id)] = pnode
	# if we’re host (real or fake) spawn the boss:
	if me.isHost:
		var bnode = _spawn_boss()
		bnode.is_host = true



func on_insert_coin(args):
	print("Playroom: coin inserted – lobby is up!")
	# hook join/quit/rpc
	Playroom.onPlayerJoin(bridge_to_js("on_player_join") )
	Playroom.onPlayerQuit(bridge_to_js("on_player_quit") )
	Playroom.on("rpc", bridge_to_js("on_rpc"))
	var me = Playroom.me()
	var p_self = _spawn_player(me)
	players[str(me.id)] = p_self
	if me.isHost():
		_spawn_boss()

func on_player_join(args):
	var state = args[0]
	print("Player joined:", state.id)
	var pnode = _spawn_player(state)
	players[str(state.id)] = pnode
	state.onQuit(bridge_to_js("on_player_quit"))

func on_player_quit(args):
	var state = args[0]
	print("Player quit:", state.id)
	var key = str(state.id)
	if players.has(key):
		players[key].queue_free()
		players.erase(key)
	
func send_rpc(cmd:String, data:Dictionary = {}) -> void:
	# only forward to JS when running under HTML5 and Playroom is valid
	if OS.has_feature("HTML5") and Playroom != null:
		Playroom.rpc(cmd, data)
	# else: no-op in editor/desktop

	
func on_rpc(args):
	var from_id = str(args[0])
	var cmd = str(args[1])
	var data = args[2]
	var pnode = players.get(from_id)
	if pnode == null:
		return

	match cmd:
		"jump":
			pnode.remote_jump()
		"punch":
			pnode.remote_do_punch()
		"hook":
			pnode.remote_do_hook()
		"roll":
			pnode.remote_roll()
		"move":
			pnode.apply_remote_move(data)
	
func _spawn_player(state):
	var scene = preload("res://scenes/player.tscn")
	var p = scene.instance()
	p.name = str(state.id)
	if OS.has_feature("HTML5"):
		# in an actual HTML5 export, we have a real Playroom interface
		p.is_owner = state.id == Playroom.me().id
	else:
		# in the editor/desktop, assume anyone we spawn is local owner
		p.is_owner = true
	var players_parent = get_tree().get_root().get_node("prototype/Players")
	players_parent.add_child(p)
	return p
		  
	
func _spawn_boss():
	var scene = preload("res://scenes/gorilla_boss.tscn")
	var b = scene.instance()
	b.name = "Boss"
	# only ask the JS bridge for host state when running under HTML5
	if OS.has_feature("HTML5"):
		b.is_host = Playroom.me().isHost()
	else:
		b.is_host = false
	# add it into the real scene tree, not under the manager
	get_tree().get_root().get_node("prototype/Boss").add_child(b)
	return b


