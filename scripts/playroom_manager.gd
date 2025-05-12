extends Node

var Playroom
var _js_refs = []
var players = {}  
var is_playroom_ready = false
var boss_node: Node = null

# boss snapshot throttle (10 Hz)
var _boss_state_timer = 0.0
const BOSS_STATE_RATE = 0.1

func bridge_to_js(cb_name):
	var cb = JavaScript.create_callback(self, cb_name)
	_js_refs.append(cb)
	return cb

func _ready():
	print("PlayroomManager initializing")
	if OS.has_feature("HTML5"):
		print("HTML5 mode detected, setting up Playroom")
		Playroom = JavaScript.get_interface("Playroom")
		var opts = JavaScript.create_object("Object")
		opts.gameId = "I2okszCMAwuMeW4fxFGD"
		opts.maxPlayersPerRoom = 100
		# Set host mode to first
		opts.hostMode = "first"
		print("Calling Playroom.insertCoin with options:", opts)
		Playroom.insertCoin(opts, bridge_to_js("on_insert_coin"))
	else:
		# Local/editor fallback
		print("Local/editor mode detected")
		is_playroom_ready = true
		_spawn_player({ "id":"local_player", "isHost":true })
		boss_node = _spawn_boss()
		boss_node.is_host = true

func on_insert_coin(args):
	print("on_insert_coin called with args:", args)
	is_playroom_ready = true
	register_rpc()

	# Join / Quit hooks
	print("Setting up Playroom.onPlayerJoin")
	Playroom.onPlayerJoin(bridge_to_js("on_player_join"))
	
	# Debug host status
	var me = Playroom.me()
	var is_host = Playroom.isHost()
	print("Local player info - ID:", me.id, " isHost:", is_host)
	
	# Spawn ourselves
	_spawn_player(me)

	# Spawn boss if we're the host
	if is_host:
		print("We are host, spawning boss")
		boss_node = _spawn_boss()
		boss_node.is_host = true
		# Initialize room state
		_initialize_room_state()
	else:
		print("We are NOT host, waiting for state updates")

func _initialize_room_state():
	if not Playroom.isHost():
		return
	
	print("Initializing room state")
	# Set initial state for all players
	for entry in players.values():
		var player_id = str(entry.state.id)
		var pos = entry.node.global_transform.origin
		var player_state = {
			"pos": {"x": pos.x, "y": pos.y, "z": pos.z},
			"rot": entry.node.rotation.y
		}
		Playroom.setState("player_" + player_id, player_state)
		print("Set initial state for player:", player_id)
	
	# Set initial boss state if boss exists
	if boss_node:
		var bp = boss_node.global_transform.origin
		Playroom.setState("boss", {
			"pos": [bp.x, bp.y, bp.z],
			"rot": boss_node.rotation.y
		})
		print("Set initial boss state")

# Called whenever someone joins the room
func on_player_join(args):
	var state = args[0]
	var id = str(state.id)

	# Debug: print the official ID plus the local JS wrapper reference
	print("--- on_player_join debug ---")
	print("  state.id    =", state.id)
	print("  wrapper obj =", state)  
	print("  isHost      =", Playroom.isHost())
	print("-----------------------------")
	
	# Your existing logic...
	if id == str(Playroom.me().id):
		return
	var pnode = _spawn_player(state)
	players[id] = { "state": state, "node": pnode }
	state.onQuit(bridge_to_js("on_player_quit"))
	
	# If we're host, initialize state for the new player
	if Playroom.isHost():
		print("Host: Initializing state for new player:", id)
		var pos = pnode.global_transform.origin
		var player_state = {
			"pos": {"x": pos.x, "y": pos.y, "z": pos.z},
			"rot": pnode.rotation.y
		}
		Playroom.setState("player_" + id, player_state)

func on_player_quit(args):
	var state = args[0]
	var id = str(state.id)
	if players.has(id):
		players[id].node.queue_free()
		players.erase(id)
	
# ——————————————
# RPC helper (so boss can call playroom.send_rpc)
# ——————————————
func send_rpc(cmd:String, data:Dictionary = {}):
	if not is_playroom_ready:
		return
	data.id = Playroom.me().id
	Playroom.RPC.call(cmd, data, Playroom.RPC.Mode.OTHERS)
	
	
# ———————————————
# 1) RPCs for discrete events
# ———————————————

func register_rpc():
	for cmd in ["jump","punch","hook","roll","move"]:
		Playroom.RPC.register(cmd, bridge_to_js("on_rpc_" + cmd))
	Playroom.RPC.register("boss_anim", bridge_to_js("on_rpc_boss_anim"))
	Playroom.RPC.register("boss_move", bridge_to_js("on_rpc_boss_move"))

func on_rpc_jump(data, sender):
	if not Playroom.isHost(): return
	var key = str(sender.id)
	if players.has(key):
		players[key].node.remote_jump()

func on_rpc_move(data, sender):
	if not Playroom.isHost(): 
		print("Non-host received move RPC, ignoring")
		return
		
	var key = str(sender.id)
	print("Host received move RPC from player: ", key, " data: ", data)
	
	if players.has(key):
		var pnode = players[key].node
		# Apply the movement
		pnode.apply_remote_move(data)
		# Update the state immediately after applying movement
		var pos = pnode.global_transform.origin
		
		# Update room state for this player
		var player_state = {
			"pos": {"x": pos.x, "y": pos.y, "z": pos.z},
			"rot": pnode.rotation.y
		}
		Playroom.setState("player_" + key, player_state)
		
		print("Host applied move RPC to player: ", key, " new pos: ", pos)
	else:
		print("ERROR: Player not found for move RPC: ", key)

func on_rpc_punch(data, sender):
	# Only the host processes these inputs
	if not Playroom.isHost():
		return
	var key = str(sender.id)
	if players.has(key):
		players[key].node.remote_do_punch()

func on_rpc_hook(data, sender):
	if not Playroom.isHost():
		return
	var key = str(sender.id)
	if players.has(key):
		players[key].node.remote_do_hook()

func on_rpc_roll(data, sender):
	if not Playroom.isHost():
		return
	var key = str(sender.id)
	if players.has(key):
		players[key].node.remote_roll()


func on_rpc_boss_anim(data:Dictionary, sender):
	# data is your payload, sender is the PlayroomPlayer who called the RPC
	if boss_node and data.has("state"):
		boss_node.remote_boss_anim(data["state"])

func on_rpc_boss_move(data, sender):
	if boss_node and not Playroom.isHost():
		print("Received boss_move RPC: ", data)
		boss_node.remote_boss_move(data)

#————————————————————
# 2) setState / getState for movement & boss
#————————————————————

func _process(delta):
	if not is_playroom_ready:
		return
		
	# Debug info about host status
	if OS.has_feature("HTML5"):
		var is_host = Playroom.isHost()
		print("Processing frame - Player ID: ", Playroom.me().id, " isHost: ", is_host)
		
		# Force recheck host status if needed
		if not is_host and players.size() == 1:
			print("Single player in room, rechecking host status")
			is_host = Playroom.isHost()
			if is_host:
				print("Host status updated to true")
				# Spawn boss if we just became host
				if not boss_node:
					print("Spawning boss as new host")
					boss_node = _spawn_boss()
					boss_node.is_host = true
					_initialize_room_state()
		
	# 2a) **Host** writes every player's pos/rot + boss pos/rot/health
	if Playroom.isHost():
		# Debug all current state
		print("DEBUG: Current room state:", Playroom.getState("debug_all"))
		
		# players
		for entry in players.values():
			var pnode = entry.node
			var player_id = str(entry.state.id)
			var pos = pnode.global_transform.origin
			
			# Set state in room state instead of player state
			var player_state = {
				"pos": {"x": pos.x, "y": pos.y, "z": pos.z},
				"rot": pnode.rotation.y
			}
			
			# Use consistent key format
			var state_key = "player." + player_id
			Playroom.setState(state_key, player_state)
			print("Host setting state key:", state_key, " value:", player_state)
			
		# Update debug state to see all current states
		var debug_state = {
			"timestamp": OS.get_system_time_msecs(),
			"host_id": Playroom.me().id,
			"player_count": players.size()
		}
		Playroom.setState("debug_all", debug_state)
			
		# boss
		if boss_node:
			_boss_state_timer += delta
			if _boss_state_timer >= BOSS_STATE_RATE:
				_boss_state_timer = 0
				var bp = boss_node.global_transform.origin
				# Set boss state directly
				Playroom.setState("boss.state", {
					"pos":[bp.x,bp.y,bp.z],
					"rot":boss_node.rotation.y
				})
				Playroom.setState("boss.health", boss_node.health)
				print("Host updating boss state: ", bp)
	else:
		# Non-host debug
		print("Non-host client processing, player count: ", players.size())
		# Debug state access
		print("DEBUG: Current room state:", Playroom.getState("debug_all"))
		
		for entry in players.values():
			var player_id = str(entry.state.id)
			var state_key = "player." + player_id
			print("Checking room state for key:", state_key)
			var player_state = Playroom.getState(state_key)
			print("  - Room state for player: ", player_state)
	
	# 2b) **All clients** read and apply state updates from room state
	if not Playroom.isHost():  # Only non-host clients need to apply state
		for entry in players.values():
			var pnode = entry.node
			var player_id = str(entry.state.id)
			
			# Use consistent key format
			var state_key = "player." + player_id
			var player_state = Playroom.getState(state_key)
			
			if player_state and player_state.has("pos"):
				# Smoothly interpolate to new position
				var pos = player_state["pos"]
				var target_pos = Vector3(pos.x, pos.y, pos.z)
				pnode.global_transform.origin = pnode.global_transform.origin.linear_interpolate(target_pos, 0.3)
				print("Client updating player:", player_id, " pos:", target_pos)
				
				# Update rotation if available
				if player_state.has("rot"):
					pnode.rotation.y = player_state["rot"]
			else:
				print("No room state for key:", state_key)
				
		# boss state updates
		if boss_node:
			var bs = Playroom.getState("boss.state")
			if bs:
				var p = bs["pos"]
				boss_node.global_transform.origin = boss_node.global_transform.origin.linear_interpolate(
					Vector3(p[0],p[1],p[2]), 0.3)
				boss_node.rotation.y = bs["rot"]
				print("Client updating boss state: ", p)
			else:
				print("No boss state available")
			
			# Update boss health
			var hp = Playroom.getState("boss.health")
			if hp != null:
				boss_node.health = hp
				boss_node.hp_bar.value = hp

#————————————————————
# Spawning helpers
#————————————————————

func _spawn_player(state):
	var scene = preload("res://scenes/player.tscn")
	var p = scene.instance()
	p.name = str(state.id)
	p.is_owner = (state.id == Playroom.me().id) or not OS.has_feature("HTML5")
	p.is_server = Playroom.isHost()   
	get_tree().get_root().get_node("prototype/Players").add_child(p)
	players[str(state.id)] = { "state": state, "node": p }

	if p.is_owner:
		p.set_process(true)
		var hud = preload("res://scenes/PlayerHUD.tscn").instance()
		hud.player_path = p.get_path()
		get_tree().get_root().get_node("prototype/UI").add_child(hud)

	return p

func _spawn_boss():
	var scene = preload("res://scenes/gorilla_boss.tscn")
	var b = scene.instance()
	b.name = "Boss"
	get_tree().get_root().get_node_or_null("prototype/Navigation/NavigationMeshInstance/Boss").add_child(b)
	return b
