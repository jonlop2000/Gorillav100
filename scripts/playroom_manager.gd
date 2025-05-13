extends Node

# ---------------------------------------------------------------------#
#  Playroom bridge & constants                                         #
# ---------------------------------------------------------------------#
var Playroom            = JavaScript.get_interface("Playroom")

const PLAYER_SEND_RATE  = 0.033     # 30 Hz
const BOSS_SEND_RATE    = 0.10      # 10 Hz

# Packed scene for avatars
const PLAYER_SCENE : PackedScene = preload("res://scenes/player.tscn")

# ---------------------------------------------------------------------#
#  State                                                               #
# ---------------------------------------------------------------------#
var players   := {}  # id → { state, node, joy? }
var boss_node : Node = null

# timers
var _accum_player := 0.0
var _accum_boss   := 0.0

# keep JS callbacks alive
var _js_refs := []

# cached node look‑ups
onready var _players_root = get_tree().get_root().get_node("prototype/Players")
onready var _boss_parent  = get_tree().get_root().get_node("prototype/Navigation/NavigationMeshInstance/Boss")

# ---------------------------------------------------------------------#
#  Helpers                                                             #
# ---------------------------------------------------------------------#
func _bridge(method:String):
	var cb = JavaScript.create_callback(self, method)
	_js_refs.append(cb)
	return cb

func _spawn_player(state):
	var inst : Node = PLAYER_SCENE.instance()
	inst.name = "player_%s" % state.id
	_players_root.add_child(inst)
	inst.add_to_group("players")
	# Colour tint (optional)
	var col = state.getProfile().color.hexString if state.getProfile() else "#FFFFFF"
	if inst.has_method("set_player_color"):
		inst.set_player_color(ColorN(col))

	# Tell the avatar whether **this** client owns it
	if str(state.id) == str(Playroom.me().id):
		inst.make_local()          # <- you control this one
	else:
		inst.make_remote()         # <- visual‑only
	print("%s spawned – local=%s" % [inst.name, inst.is_local])
	return inst


func _spawn_boss():
	var scene = preload("res://scenes/gorilla_boss.tscn")
	var inst  = scene.instance()
	inst.is_host = Playroom.isHost()   # ← add this line
	print("Spawning boss - is_host:", inst.is_host)  # Debug log
	_boss_parent.add_child(inst)
	return inst

func _pack_player(node:Node) -> Dictionary:
	return {
		"px": node.global_transform.origin.x,
		"py": node.global_transform.origin.y,
		"pz": node.global_transform.origin.z,
		"rot": node.rotation.y
	}


func _pack_boss() -> Dictionary:
	return {
		"px": boss_node.global_transform.origin.x,
		"py": boss_node.global_transform.origin.y,
		"pz": boss_node.global_transform.origin.z,
		"rot": boss_node.rotation.y,
		"anim": boss_node.get_current_anim(),
		"hp" : boss_node.get("health") if boss_node else 0
	}

# ---------------------------------------------------------------------#
#  Boot                                                                #
# ---------------------------------------------------------------------#
func _ready():
	JavaScript.eval("")   # initialise bridge
	Playroom.RPC.register("punch", _bridge("_on_punch"))
	Playroom.RPC.register("hook", _bridge("_on_hook"))
	if OS.has_feature("HTML5"):
		var opts = JavaScript.create_object("Object")
		opts.gameId = "I2okszCMAwuMeW4fxFGD"
		Playroom.insertCoin(opts, _bridge("_on_insert_coin"))
	else:
		# editor debug: spawn one local player + boss
		var dummy_state = {}
		dummy_state.id = "LOCAL"
		var local_node = _spawn_player(dummy_state)
		local_node.make_local()  
		players["LOCAL"] = { "state": dummy_state, "node": local_node }
		boss_node = _spawn_boss()

func _on_punch(args):
	var sender_state = args[1]           # ➊ second slot
	if sender_state == null:
		return
	var sender_id = str(sender_state.id)

	if players.has(sender_id):
		var node = players[sender_id].node
		if node and node.has_method("_travel"):
			node._travel("Punch")

func _on_hook(args):
	var sender_state = args[1]
	if sender_state == null:
		return
	var sender_id = str(sender_state.id)

	if players.has(sender_id):
		var node = players[sender_id].node
		if node and node.has_method("_travel"):
			node._travel("Hook")


# ---------------------------------------------------------------------#
#  Lobby / join / quit                                                 #
# ---------------------------------------------------------------------#
func _on_insert_coin(_args):
	Playroom.onPlayerJoin(_bridge("_on_player_join"))
	if Playroom.isHost():
		# Host also gets a callback for itself; wait till that fires to have players dict filled
		boss_node = _spawn_boss()
		Playroom.setState("boss", JSON.print(_pack_boss()))
		_push_room_init_snapshot()

func _on_player_join(args):
	var state = args[0]
	var id    = str(state.id)

	# reuse local avatar if this is me, otherwise spawn
	var node : Node = null
	if id == str(Playroom.me().id):
		node = _players_root.get_node_or_null("player_%s" % id)
		if node == null:
			node = _spawn_player(state)
	else:
		node = _spawn_player(state)

	players[id] = { "state":state, "node":node }

	# late‑joiners: if boss already exists on host, spawn placeholder
	if not boss_node and not Playroom.isHost():
		boss_node = _spawn_boss()

	state.onQuit(_bridge("_on_player_quit"))

func _on_player_quit(args):
	var state = args[0]
	var id    = str(state.id)
	if players.has(id):
		players[id].node.queue_free()
		players.erase(id)

# ---------------------------------------------------------------------#
#  Room initialisation snapshot (host)                                 #
# ---------------------------------------------------------------------#
func _push_room_init_snapshot():
	var snap = {
		"boss": _pack_boss(),
		"players": {}
	}
	for id in players.keys():
		snap.players[id] = _pack_player(players[id].node)
	Playroom.setState("room.init", JSON.print(snap))

# ---------------------------------------------------------------------#
#  Main loops                                                          #
# ---------------------------------------------------------------------#
func _physics_process(delta):
	if not OS.has_feature("HTML5"):
		return

	# --------------------------------------------------------------#
	#  HOST: publish authoritative transforms                       #
	# --------------------------------------------------------------#
	if Playroom.isHost():
		_accum_player += delta
		if _accum_player >= PLAYER_SEND_RATE:
			_accum_player = 0.0
			for id in players.keys():
				var node  = players[id].node
				var state = players[id].state

				if node.is_local:
					# ← host publishes only its own snapshot
					var packed = _pack_player(node)
					for k in packed.keys():
						state.setState(k, packed[k])
				else:
					# ← host *consumes* snapshots from remote players
					var px  = state.getState("px")  if state.getState("px")  else node.global_transform.origin.x
					var py  = state.getState("py")  if state.getState("py")  else node.global_transform.origin.y
					var pz  = state.getState("pz")  if state.getState("pz")  else node.global_transform.origin.z
					var rot = state.getState("rot") if state.getState("rot") else node.rotation.y

					var target = Vector3(px, py, pz)
					if node.global_transform.origin.distance_to(target) > 2.5:
						node.global_transform.origin = target
					else:
						node.global_transform.origin = node.global_transform.origin.linear_interpolate(target, delta * 8.0)
					node.rotation.y = lerp_angle(node.rotation.y, rot, delta * 8.0)

		# boss state
		if boss_node:
			_accum_boss += delta
			if _accum_boss >= BOSS_SEND_RATE:
				_accum_boss = 0.0
				Playroom.setState("boss", JSON.print(_pack_boss()))

	# --------------------------------------------------------------#
	#  CLIENTS: read host transforms                                #
	# --------------------------------------------------------------#
	else:
		# players (simple lerp)
		for id in players.keys():
			var entry = players[id]
			var s     = entry.state
			var node  = entry.node
			if not node: continue

			var x = s.getState("px") if s.getState("px") else node.global_transform.origin.x
			var y = s.getState("py") if s.getState("py") else node.global_transform.origin.y
			var z = s.getState("pz") if s.getState("pz") else node.global_transform.origin.z
			var rot = s.getState("rot") if s.getState("rot") else node.rotation.y

			var target = Vector3(x,y,z)
			if node.global_transform.origin.distance_to(target) > 2.5:
				node.global_transform.origin = target
			else:
				node.global_transform.origin = node.global_transform.origin.linear_interpolate(target, delta * 8.0)
			node.rotation.y = lerp_angle(node.rotation.y, rot, delta * 8.0)
			
		# ───────────────────────────────────────────────────
		# CLIENTS: poll boss state at BOSS_SEND_RATE and apply
		# ───────────────────────────────────────────────────
		_accum_boss += delta
		if _accum_boss >= BOSS_SEND_RATE:
			_accum_boss = 0.0
			var raw = Playroom.getState("boss")
			if raw:
				var dict = JSON.parse(raw).result
				if not boss_node:
					boss_node = _spawn_boss()
				boss_node.apply_remote_state({
					"pos":  [dict["px"], dict["py"], dict["pz"]],
					"rot":  dict["rot"],
					"hp":   dict["hp"],
					"anim": dict["anim"]
				})

# ---------------------------------------------------------------------#
#  Boss update helpers                                                 #
# ---------------------------------------------------------------------#
func _apply_boss_state(dict:Dictionary):
	if not boss_node: return
	boss_node.global_transform.origin = Vector3(dict["px"], dict["py"], dict["pz"])
	boss_node.rotation.y              = dict["rot"]
	boss_node.set("health", dict["hp"])

func _on_boss_state(raw_json):
	var dict = JSON.parse(raw_json).result
	_apply_boss_state(dict)

func _on_boss_health(args):
	if boss_node:
		boss_node.set("health", args[0])

# ---------------------------------------------------------------------#
#  Event subscriptions (clients)                                       #
# ---------------------------------------------------------------------#
#func _register_boss_listeners():
#	if Playroom.isHost(): return      # host does its own thing
#	Playroom.onState("boss", _bridge("_on_boss_state"))

# ---------------------------------------------------------------------#
#  Clean‑up                                                            #
# ---------------------------------------------------------------------#
func _exit_tree():
	_js_refs.clear()
