extends Node 

var Playroom
var _js_refs = []
var players = {}
var is_playroom_ready = false
var boss_node: Node = null

func bridge_to_js(cb_func):
	var cb = JavaScript.create_callback(self, cb_func)
	_js_refs.append(cb)
	return cb

func _ready():
	if OS.has_feature("HTML5"):
		Playroom = JavaScript.get_interface("Playroom")
		var opts = JavaScript.create_object("Object")
		opts.gameId = "I2okszCMAwuMeW4fxFGD"
		opts.maxPlayersPerRoom = 100
		Playroom.insertCoin(opts, bridge_to_js("on_insert_coin"))
		return
	else:
		print("PlayroomManager: editor/local mode, spawning single player.")
		is_playroom_ready = true
		var me = { "id": "local_player", "isHost": true }
		var pnode = _spawn_player(me)
		pnode.add_to_group("players") # Ensure the player is in the players group
		players[str(me.id)] = pnode
		var bnode = _spawn_boss()
		bnode.is_host = true

func on_insert_coin(args):
	is_playroom_ready = true
	print("Playroom: coin inserted – lobby is up!")
	register_rpc()
	Playroom.onPlayerJoin(bridge_to_js("on_player_join"))
	# spawn *your* player
	var me = Playroom.me()
	var pself = _spawn_player(me)
	players[str(me.id)] = pself
	
	# spawn the boss, marking it 'host' if *you* are host
	boss_node = _spawn_boss()
	boss_node.is_host = Playroom.isHost()


func on_player_join(args):
	var state = args[0]
	if state.id == Playroom.me().id:
		return

	print("Player joined:", state.id)
	var pnode = _spawn_player(state)
	players[str(state.id)] = pnode
	state.onQuit( bridge_to_js("on_player_quit") )


func on_player_quit(args):
	var state = args[0]
	print("Player quit:", state.id)
	var key = str(state.id)
	if players.has(key):
		players[key].queue_free()
		players.erase(key)
		
func register_rpc():
	for cmd in ["jump","punch","hook","roll","move","boss_move","boss_anim","boss_health"]:
		Playroom.RPC.register(cmd, bridge_to_js("on_rpc"))
	

func send_rpc(cmd:String, data:Dictionary = {}) -> void:
	if not is_playroom_ready:
		return
	Playroom.RPC.call(cmd, data, Playroom.RPC.Mode.OTHERS)
	
func on_rpc(args):
	var sender_id = str(args[0])
	if sender_id == str(Playroom.me().id):
		return
	var cmd = str(args[1])
	var data = args[2]
	match cmd:
		"jump","punch","hook","roll","move":
			var p = players.get(sender_id)
			if p:
				match cmd:
					"jump":  p.remote_jump()
					"punch": p.remote_do_punch()
					"hook":  p.remote_do_hook()
					"roll":  p.remote_roll()
					"move":  p.apply_remote_move(data)
		"boss_move":
			if boss_node: boss_node.remote_boss_move(data)
		"boss_anim":
			if boss_node: boss_node.remote_boss_anim(data)
		"boss_health":
			if boss_node: boss_node.remote_boss_health(data)

	
func _spawn_player(state):
	var scene = preload("res://scenes/player.tscn")
	var p = scene.instance()
	p.name = str(state.id)
	if OS.has_feature("HTML5"):
		p.is_owner = state.id == Playroom.me().id
	else:
		p.is_owner = true
	var players_parent = get_tree().get_root().get_node("prototype/Players")
	players_parent.add_child(p)
	p.add_to_group("players") # Always add to players group
	if p.is_owner:
		var hud_scene = preload("res://scenes/PlayerHUD.tscn")
		var hud = hud_scene.instance()
		# point the exported player_path at our new player node
		hud.player_path = p.get_path()
		# add the HUD under your UI CanvasLayer
		var ui_parent = get_tree().get_root().get_node("prototype/UI")
		ui_parent.add_child(hud)
	return p
	 
	
func _spawn_boss():
	var scene = preload("res://scenes/gorilla_boss.tscn")
	var b = scene.instance()
	b.name = "Boss"
	var parent = get_tree().get_root().get_node_or_null(
		"prototype/Navigation/NavigationMeshInstance/Boss"
	)
	if parent:
		parent.add_child(b)
	else:
		push_error("Boss spawn parent not found at prototype/Navigation/NavigationMeshInstance/Boss")
	return b


