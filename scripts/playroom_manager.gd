extends Node
signal player_ready_changed(id, is_ready)
signal match_started
# ---------------------------------------------------------------------#
#  Playroom bridge & constants                                         #
# ---------------------------------------------------------------------#
var Playroom            = JavaScript.get_interface("Playroom")

const PLAYER_SEND_RATE  = 0.033     # 30 Hz
const BOSS_SEND_RATE    = 0.10      # 10 Hz

# Packed scene for avatars
const PLAYER_SCENE : PackedScene = preload("res://scenes/player.tscn")
const PLAYER_HUD_SCENE : PackedScene = preload("res://scenes/PlayerHUD.tscn")
const PLAYROOM_GAME_ID := "I2okszCMAwuMeW4fxFGD"

# ---------------------------------------------------------------------#
#  State                                                               #
# ---------------------------------------------------------------------#
var players   := {}  # id → { state, node, joy? }
var boss_node : Node = null
var has_started  = false
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
	var inst = PLAYER_SCENE.instance()          # ❶  use “=” in Godot 3
	var base_name = "player_%s" % state.id
	inst.name = _make_unique_name(base_name)    # no collision now
	_players_root.add_child(inst)
	inst.add_to_group("players")
	var col = state.getProfile().color.hexString if state.getProfile() else "#FFFFFF"
	if inst.has_method("set_player_color"):
		inst.set_player_color(ColorN(col))
	if str(state.id) == str(Playroom.me().id):
		inst.make_local()
		_create_hud_for(inst)
	else:
		inst.make_remote()
	print("%s spawned – local=%s" % [inst.name, inst.is_local])
	return inst

func _create_hud_for(player_node):
	var hud := PLAYER_HUD_SCENE.instance()
	hud.player_path = player_node.get_path()
	get_tree().get_root().get_node("arena/UI").add_child(hud)


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
	Playroom.RPC.register("jump", _bridge("_on_player_jump"))
	Playroom.RPC.register("show_hit_effects", _bridge("_on_show_hit_effects"))
	Playroom.onPlayerStateChange(_bridge("_on_state_change"))
	Playroom.onStateChange("matchStarted", _bridge("_on_match_started"))
	if OS.has_feature("HTML5"):
		var opts = JavaScript.create_object("Object")
		opts.gameId = PLAYROOM_GAME_ID
		opts.discord = true
		opts.persistentMode = true 
		opts.skipLobby = false  
		Playroom.insertCoin(opts, _bridge("_on_insert_coin"))
	else:
		# editor debug: spawn one local player + boss
		var dummy_state = {}
		dummy_state.id = "LOCAL"
		var local_node = _spawn_player(dummy_state)
		local_node.make_local()  
		players["LOCAL"] = { "state": dummy_state, "node": local_node }
		boss_node = _spawn_boss()
		
func _make_unique_name(base: String) -> String:
	var name = base
	var n = 1
	while _players_root.has_node(name):
		name = "%s_%d" % [base, n]
		n += 1
	return name

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
				Playroom.RPC.call("show_hit_effects", "", Playroom.RPC.Mode.ALL)
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
				Playroom.RPC.call("show_hit_effects", "", Playroom.RPC.Mode.ALL)
				Playroom.setState("boss", JSON.print(_pack_boss()))

func _on_show_hit_effects(_args:Array) -> void:
	# Whenever this runs (on host AND clients), trigger the boss VFX
	if boss_node:
		boss_node._react_to_hit()

func _on_roll(args):
	var data = JSON.parse(args[0]).result
	var id   = str(args[1].id)
	if players.has(id):
		players[id].node._begin_roll(data)

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
	var target_id = str(data.get("target_id", ""))
	if not players.has(target_id):
		return
	var player_node = players[target_id].node
	var attack_name = data.get("attack_name", "")
	print("→ attack_name =", attack_name)
	var anim = "KnockBack"
	if attack_name == "Melee" or attack_name == "MeleeCombo" or attack_name == "BattleCry":
		anim = "Hit"
	var dir_arr = data.get("direction", [])
	if dir_arr.size() == 3:
		var dir = Vector3(dir_arr[0], dir_arr[1], dir_arr[2]).normalized()
		player_node.remote_apply_knockback(dir, float(data.get("force", 0)), anim)
	var dmg = int(data.get("damage", 0))
	if dmg > 0:
		player_node.remote_apply_damage(dmg)
		
func _on_player_jump(args:Array) -> void:
	var sender_state = null
	if args.size() > 1:
		sender_state = args[1]
	if sender_state == null:
		return
	# extract the player ID and find their node
	var id = str(sender_state.id)
	if not players.has(id):
		return

	# tell that player to go into the Jump state
	players[id].node._begin_jump()


# ---------------------------------------------------------------------#
#  Lobby / join / quit                                                 #
# ---------------------------------------------------------------------#
func _on_insert_coin(_args):
	# 1. register player join/quit callbacks
	Playroom.onPlayerJoin(_bridge("_on_player_join"))
	
	# 2. record *my* state in the dictionary (no node yet)
	var me_state = Playroom.me()
	players[str(me_state.id)] = { "state": me_state, "node": null }
	# 3. host pre-loads boss data for later snapshot (no node yet)
	if Playroom.isHost():
		# pre-initialize boss health / phase variables if you need
		pass
	# 4. late-joiners: consume host snapshot so our players dict is complete
	var snap_json = Playroom.getState("room.init")
	if snap_json:
		var snap = JSON.parse(snap_json).result
		for id in snap.players.keys():
			if not players.has(id):
				players[id] = { "state": Playroom.getPlayer(id), "node": null }
	# Ready for lobby UI — emit a custom signal if you like
	emit_signal("insert_coin_ready")            # optional

func _on_player_join(args):
	var st = args[0]
	var id = str(st.id)
	if players.has(id):          
		return
	players[id] = { "state": st, "node": null }
	emit_signal("player_joined", id)   # optional for lobby updates
	
	st.onQuit(_bridge("_on_player_quit"))

func _on_player_quit(args):
	var st = args[0]
	var id = str(st.id)
	if players.has(id):
		if players[id].node:
			players[id].node.queue_free()
		players.erase(id)
		emit_signal("player_left", id)

func _on_state_change(args):
	var st = args[0]
	emit_signal("player_ready_changed", str(st.id), st.get("ready") == true)

func _on_match_started(value):
	if value == true or value == "true":
		emit_signal("match_started")

# called by Arena scene once it loads
func start_match():
	if has_started:
		return
	has_started = true
	# 1. spawn every player we have in the dictionary
	for id in players.keys():
		if players[id].node == null:
			var node = _spawn_player(players[id].state)
			players[id].node = node 
	# 2. host spawns the boss and broadcasts snapshot
	if Playroom.isHost():
		if boss_node == null:
			boss_node = _spawn_boss()
		boss_node._test_freeze = false          # unfreeze AI
		_push_room_init_snapshot()              # pack & setState("room.init", …)   
	# 3. non-hosts consume the boss snapshot if they don’t have the node yet
	if not Playroom.isHost() and boss_node == null:
		boss_node = _spawn_boss()   
	print("Match started – players:", players.size())

func _send_room_init_snapshot():
	var snapshot := {
		"boss"   : _pack_boss(),
		"players": {}
	}
	for id in players.keys():
		snapshot.players[id] = _pack_player(players[id].node)
	Playroom.setState("room.init", JSON.print(snapshot))

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

				# 1) publish your own state
				if node.is_local:
					var packed = _pack_player(node)  # {px,py,pz,rot}
					for k in packed.keys():
						state.setState(k, packed[k])
					continue
				
				# 3) otherwise consume snapshots
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

	# ─── CLIENTS: poll, publish & interpolate transforms ───────────────
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

				# 1) publish your own state on clients, too!
				if node.is_local:
					var packed = _pack_player(node)
					for k in packed.keys():
						state.setState(k, packed[k])
					continue

				# 3) otherwise consume snapshots
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
