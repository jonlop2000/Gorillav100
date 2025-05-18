extends Node

# ---------------------------------------------------------------------#
#  Playroom bridge & constants                                         #
# ---------------------------------------------------------------------#
var Playroom            = JavaScript.get_interface("Playroom")

const PLAYER_SEND_RATE  = 0.033     # 30 Hz
const BOSS_SEND_RATE    = 0.10      # 10 Hz

# Packed scene for avatars
const PLAYER_SCENE : PackedScene = preload("res://scenes/player.tscn")
const PLAYER_HUD_SCENE : PackedScene = preload("res://scenes/PlayerHUD.tscn")

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
onready var _players_root = get_tree().get_root().get_node("arena/Players")
onready var _boss_parent  = get_tree().get_root().get_node("arena/Navigation/NavigationMeshInstance/GridMap/Boss")

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

	# tell it who's local vs. remote
	if str(state.id) == str(Playroom.me().id):
		inst.make_local()
		# ────────────── HUD for the local player ──────────────
		var hud = PLAYER_HUD_SCENE.instance()
		# this assumes your HUD script has an `export(NodePath) var player_path`
		hud.player_path = inst.get_path()
		var ui_parent = get_tree().get_root().get_node("arena/UI")
		ui_parent.add_child(hud)
	else:
		inst.make_remote()

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
	if boss_node == null:
		return {}  
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
	Playroom.RPC.register("roll", _bridge("_on_roll"))
	Playroom.RPC.register("apply_attack", _bridge("_on_apply_attack"))
	Playroom.RPC.register("punch", _bridge("_on_punch"))
	Playroom.RPC.register("hook",  _bridge("_on_hook"))
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

func _on_punch(args:Array) -> void:
	# ── play the punch animation for other clients ──
	var sender_state = null
	if args.size() > 1:
		sender_state = args[1]
	if sender_state and players.has(str(sender_state.id)):
		var node = players[str(sender_state.id)].node
		if node and node.has_method("_travel"):
			node._travel("Punch")

	# ── unpack & apply damage on host ──
	if Playroom.isHost() and boss_node:
		var raw = null
		if args.size() > 0:
			raw = args[0]
		if typeof(raw) == TYPE_STRING:
			var parsed = JSON.parse(raw)
			if parsed.error == OK and parsed.result.has("damage"):
				boss_node.apply_damage(int(parsed.result.damage))
				Playroom.setState("boss", JSON.print(_pack_boss()))

func _on_hook(args:Array) -> void:
	# ── play the hook animation for other clients ──
	var sender_state = null
	if args.size() > 1:
		sender_state = args[1]
	if sender_state and players.has(str(sender_state.id)):
		var node = players[str(sender_state.id)].node
		if node and node.has_method("_travel"):
			node._travel("Hook")

	# ── unpack & apply damage on host ──
	if Playroom.isHost() and boss_node:
		var raw = null
		if args.size() > 0:
			raw = args[0]
		if typeof(raw) == TYPE_STRING:
			var parsed = JSON.parse(raw)
			if parsed.error == OK and parsed.result.has("damage"):
				boss_node.apply_damage(int(parsed.result.damage))
				Playroom.setState("boss", JSON.print(_pack_boss()))

func _on_roll(args):
	# 1) Extract the raw JSON string
	var raw = args[0]
	if typeof(raw) != TYPE_STRING:
		push_error("Expected roll RPC payload as String, got %s" % typeof(raw))
		return
	# 2) Parse it back into a Dictionary
	var parsed = JSON.parse(raw)
	if parsed.error != OK:
		push_error("Failed to parse roll JSON: %s" % parsed.error_string)
		return
	var data = parsed.result
	# 3) Grab the sender_state safely
	var sender_state = null
	if args.size() > 1:
		sender_state = args[1]
	if sender_state == null:
		return
	# 4) Find the player node and invoke the roll
	var id = str(sender_state.id)
	if players.has(id):
		var node = players[id].node
		if node and node.has_method("_start_remote_roll"):
			node._start_remote_roll(data)
			
	
func _on_apply_attack(args:Array) -> void:
	print("<<< apply_attack RPC received, args:", args)
	if args.size() < 1:
		return
	var raw = args[0]
	if typeof(raw) != TYPE_STRING:
		push_error("apply_attack RPC: expected String, got %s" % typeof(raw))
		return
	var parsed = JSON.parse(raw)
	if parsed.error != OK:
		push_error("apply_attack RPC: JSON.parse error %s" % parsed.error_string)
		return
	var data = parsed.result

	var target_id = str(data.get("target_id",""))
	if not players.has(target_id):
		return
	var player_node = players[target_id].node

	# apply knockback
	var dir_arr = data.get("direction", [])
	if dir_arr.size() == 3:
		var dir = Vector3(dir_arr[0], dir_arr[1], dir_arr[2]).normalized()
		player_node.remote_apply_knockback(dir, float(data.get("force",0)))

	# apply damage
	var dmg = int(data.get("damage", 0))
	if dmg > 0 and player_node.has_method("remote_apply_damage"):
		player_node.remote_apply_damage(dmg)
	print("applying knockback & damage to:", target_id)


# ---------------------------------------------------------------------#
#  Lobby / join / quit                                                 #
# ---------------------------------------------------------------------#
func _on_insert_coin(_args):
	# 1) register future join events
	Playroom.onPlayerJoin(_bridge("_on_player_join"))
	# 2) force-spawn *your* player
	var me_state = Playroom.me()
	var me_id    = str(me_state.id)
	if not players.has(me_id):
		var me_node = _spawn_player(me_state)   # calls make_local() internally
		players[me_id] = { "state": me_state, "node": me_node }
	# 3) spawn boss & push the room snapshot (host only)
	if boss_node == null:
		boss_node = _spawn_boss()
	# host pushes the real boss state
	if Playroom.isHost():
		Playroom.setState("boss", JSON.print(_pack_boss()))
		_push_room_init_snapshot()


func _on_player_join(args):
	var state = args[0]
	var id    = str(state.id)
	# skip yourself (you already spawned in _on_insert_coin)
	if id == str(Playroom.me().id):
		return
	# spawn everyone else as remote
	var node = _spawn_player(state)
	players[id] = { "state": state, "node": node }
	# late-joiners: if boss already exists on host, spawn placeholder
	if not boss_node and not Playroom.isHost():
		boss_node = _spawn_boss()
	# wire up quit handling
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
	# ─ Only run in Playroom (HTML5) context ───────────────────────────
	if not OS.has_feature("HTML5"):
		return

	# ─── HOST: throttle & publish authoritative transforms ─────────────
	if Playroom.isHost():
		_accum_player += delta
		if _accum_player >= PLAYER_SEND_RATE:
			_accum_player -= PLAYER_SEND_RATE

			for id in players.keys():
				var entry = players[id]
				var node  = entry.node
				var state = entry.state

				if node.is_local:
					# ← throttle your own snapshot
					var packed = _pack_player(node)  # returns {px,py,pz,rot}
					for k in packed.keys():
						state.setState(k, packed[k])
				else:
					# ← consume remote snapshots
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

		# ─── HOST: publish boss state ────────────────────────────────────
		if boss_node:
			_accum_boss += delta
			if _accum_boss >= BOSS_SEND_RATE:
				_accum_boss -= BOSS_SEND_RATE
				Playroom.setState("boss", JSON.print(_pack_boss()))

	# ─── CLIENTS: poll & interpolate transforms ────────────────────────
	else:
		_accum_player += delta
		if _accum_player >= PLAYER_SEND_RATE:
			_accum_player -= PLAYER_SEND_RATE

			for id in players.keys():
				var entry = players[id]
				var node  = entry.node
				var state = entry.state
				if not node:
					continue
				if node.has_method("is_remotely_rolling") and node.is_remotely_rolling():
					continue

				# Read per-axis keys
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

		# ─── CLIENTS: poll & apply boss state ────────────────────────────
		_accum_boss += delta
		if _accum_boss >= BOSS_SEND_RATE:
			_accum_boss -= BOSS_SEND_RATE
			var raw = Playroom.getState("boss")
			if raw:
				var dict = JSON.parse(raw).result
				if not boss_node:
					boss_node = _spawn_boss()
				boss_node.apply_remote_state({
					"pos":  [dict["px"], dict["py"], dict["pz"]],
					"rot":   dict["rot"],
					"hp":    dict["hp"],
					"anim":  dict["anim"]
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
