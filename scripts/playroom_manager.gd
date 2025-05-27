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
const LOBBY_SCENE = preload("res://scenes/Lobby3D.tscn")
const ARENA_SCENE = preload("res://scenes/arena.tscn")

var _state_poll_accum := 0.0
const STATE_POLL_RATE := 0.2      # seconds
# ---------------------------------------------------------------------#
#  State                                                               #
# ---------------------------------------------------------------------#
var players   := {}  # id → { state, node, joy? }
var boss_node : Node = null
var _ready_cache := {} #id->bool
var _game_started := false
var _last_force_start := false
var _joined_room := false

# timers
var _accum_player := 0.0
var _accum_boss   := 0.0

# root holders are updated every time we switch scenes
var _players_root : Node = null
var _ui_root      : Node = null
var _boss_parent  : Node = null
var lobby_panel: Control = null
# keep JS callbacks alive
var _js_refs := []

# ---------------------------------------------------------------------#
#  Helpers                                                             #
# ---------------------------------------------------------------------#
func _bridge(method:String):
	var cb = JavaScript.create_callback(self, method)
	_js_refs.append(cb)
	return cb

func _spawn_player(state):
	var inst = PLAYER_SCENE.instance()
	inst.name = "player_%s" % state.id
	_players_root.add_child(inst)
	inst.add_to_group("players")

	if str(state.id) == str(Playroom.me().id):
		inst.make_local()
		# HUD
		var hud = PLAYER_HUD_SCENE.instance()
		hud.player_path = inst.get_path()
		if _ui_root:
			_ui_root.add_child(hud)
	else:
		inst.make_remote()
		# apply any existing position/rotation from state
		var px = state.getState("px")
		if px != null:
			var py = state.getState("py")
			var pz = state.getState("pz")
			inst.global_transform.origin = Vector3(px, py, pz)
		var rot = state.getState("rot")
		if rot != null:
			inst.rotation.y = rot

	print("%s spawned – local=%s" % [inst.name, inst.is_local])
	return inst


	print("%s spawned – local=%s" % [inst.name, inst.is_local])
	return inst

func _spawn_boss():
	var scene = preload("res://scenes/gorilla_boss.tscn")
	var inst  = scene.instance()
	inst.is_host = Playroom.isHost()
	print("Spawning boss - is_host:", inst.is_host)

	if _boss_parent:
		_boss_parent.add_child(inst)
	else:
		push_error("Cannot spawn boss: _boss_parent is null!")
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

	if OS.has_feature("HTML5"):
		var opts = JavaScript.create_object("Object")
		opts.gameId = "I2okszCMAwuMeW4fxFGD"
		opts.discord = true
		opts.skipLobby = true
		Playroom.insertCoin(opts, _bridge("_on_insert_coin"))
	else:
		# editor debug: spawn one local player + boss
		var dummy_state = {}
		dummy_state.id = "LOCAL"
		var local_node = _spawn_player(dummy_state)
		local_node.make_local()  
		players["LOCAL"] = { "state": dummy_state, "node": local_node }
		boss_node = _spawn_boss()

# Returns an Array of the current PlayerState objects
func get_player_states() -> Array:
	var out := []
	for id in players.keys():
		out.append(players[id]["state"])
	return out


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

# ------------------------------------------------------------------#
#  Lobby / join / quit                                              #
# ------------------------------------------------------------------#
func _on_insert_coin(_args):
	# 1) register for future joins
	Playroom.onPlayerJoin(_bridge("_on_player_join"))
	# 2) seed local host‐status cache...
	_cached_is_host = Playroom.isHost()
	if _cached_is_host:
		_on_became_host()
	else:
		_on_lost_host()
	_last_force_start = (Playroom.getState("force_start") == true)
	_joined_room = true

	# ——————— NEW: pre‐fetch every current avatar ———————
	for state in get_player_states():
		var id  = str(state.id)
		var url = state.getProfile().photo
		if url.begins_with("http"):
			AvatarCache.fetch(id, url)
	# ————————————————————————————————————————————————

	# 3) finally go show the lobby UI
	_goto_lobby()

func _on_player_join(args):
	var state = args[0]
	var id    = str(state.id)

	var url = state.getProfile().photo
	if url.begins_with("http"):
		AvatarCache.fetch(id, url)

	if not players.has(id):
		players[id] = { "state": state, "node": null }
		_ready_cache[id] = false
	if _players_root and players[id].node == null:
		var node = _spawn_player(state)
		players[id].node = node

func _on_player_quit(args):
	var state = args[0]
	var id    = str(state.id)
	# remove ready flag
	_ready_cache.erase(id)
	# free node if it exists
	if players.has(id) and is_instance_valid(players[id].node):
		players[id].node.queue_free()
	# remove the player entry
	players.erase(id)

# ------------------------------------------------------------------#
#  Scene helpers                                                    #
# ------------------------------------------------------------------#
func _goto_lobby():
	if get_tree().current_scene == LOBBY_SCENE:
		return          # already there, no reload
	get_tree().change_scene_to(LOBBY_SCENE)
	yield(get_tree(), "idle_frame")
	_hook_scene_paths()
	_show_lobby_panel() 
	
func register_lobby_panel(panel: Control):
	lobby_panel = panel
	lobby_panel.visible = false

func _show_lobby_panel():
	if lobby_panel:
		lobby_panel.visible = true

func start_game():
	if _game_started:
		return
	_game_started = true
	get_tree().change_scene_to(ARENA_SCENE)
	yield(get_tree(), "idle_frame")
	_hide_lobby_panel() 
	_hook_scene_paths()
	# spawn all players...
	for id in players.keys():
		var entry = players[id]
		if entry.node == null:
			entry.node = _spawn_player(entry.state)
	# spawn boss once
	if boss_node == null:
		boss_node = _spawn_boss()
	# ── NEW: reset the global "force_start" flag on the host ──
	if Playroom.isHost():
		Playroom.setState("force_start", false, true)

func _hide_lobby_panel():
	if lobby_panel:
		lobby_panel.visible = false

func _hook_scene_paths():
	var scene = get_tree().current_scene                # refresh cached roots
	if scene.has_node("Players"):
		_players_root = scene.get_node("Players")
	if scene.has_node("UI"):
		_ui_root = scene.get_node("UI")
	var boss_path = "Navigation/NavigationMeshInstance/GridMap/Boss"
	if scene.has_node(boss_path):
		_boss_parent = scene.get_node(boss_path)
	else:
		_boss_parent = null
		_boss_parent = null

# ------------------------------------------------------------------#
#  Ready / start logic                                              #
# ------------------------------------------------------------------#
func _on_ready_state(args):
	var p      = args[0]        # Player object
	var is_rdy = args[1]        # bool
	_ready_cache[str(p.id)] = is_rdy
	# host: auto-start when everyone ready
	if Playroom.isHost() and _all_ready():
		_broadcast_force_start()

func _on_force_start(_args):
	# anyone receiving this just loads the arena
	start_game()

func _broadcast_force_start():
	Playroom.setState("force_start", true)

func _all_ready() -> bool:
	for v in _ready_cache.values():
		if not v: return false
	return true

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

				if node == null or not is_instance_valid(node):
					# clean up so future loops don’t see it
					entry.node = null
					continue

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
#  Clean‑up                                                            #
# ---------------------------------------------------------------------#
func _exit_tree():
	_js_refs.clear()

var _cached_is_host := false

func _process(delta):
	_state_poll_accum += delta
	if _state_poll_accum >= STATE_POLL_RATE:
		_state_poll_accum -= STATE_POLL_RATE
		_check_host_change()
		_poll_lobby_state()   # the ready-state poll you already have

func _check_host_change():
	if Playroom == null:
		return
	var now_is_host = Playroom.isHost()
	if now_is_host != _cached_is_host:
		_cached_is_host = now_is_host
		if now_is_host:
			print("⚡ Host migrated to ME")
			# promote authority (e.g., enable boss AI, allow Start button)
			_on_became_host()
		else:
			print("⚡ Another player became host")
			# disable host-only systems here
			_on_lost_host()

func _on_became_host():
	print("⚡ I am now host")

	# 1) Lobby UI — show the Start button
	if get_tree().current_scene == LOBBY_SCENE and _ui_root:
		var btn = _ui_root.get_node_or_null("StartButton")
		if btn:
			btn.visible  = true
			btn.disabled = ! _all_ready()    # enable only if everyone ready

	# 2) Arena — ensure boss exists and set authority
	if get_tree().current_scene == ARENA_SCENE:
		if boss_node == null and _boss_parent:
			boss_node = _spawn_boss()
		if boss_node:
			boss_node.is_host = true      # your own flag
			boss_node.activate_ai()       # example host-only task

	# 3) Any other host-only systems (timers, match clock, etc.)
	# start_match_timer()

# -------------------------------------------------
func _on_lost_host():
	print("⚡ I am no longer host")

	# 1) Lobby UI — hide the Start button
	if get_tree().current_scene == LOBBY_SCENE and _ui_root:
		var btn = _ui_root.get_node_or_null("StartButton")
		if btn:
			btn.visible = false

	# 2) Arena — relinquish boss authority
	if boss_node:
		boss_node.is_host = false
		boss_node.deactivate_ai()         # stop host-only logic

	# 3) Stop or pause any host-only timers you own
	# stop_match_timer()

func _poll_lobby_state():
	if not _joined_room or _game_started:
		return
	for state in get_player_states():
		var id  = str(state.id)
		_ready_cache[id] = state.getState("ready") == true

	# auto‐start when host sees everyone ready
	if Playroom.isHost() and _all_ready():
		Playroom.setState("force_start", true, true)

	var now = Playroom.getState("force_start") == true
	if now and not _last_force_start:
		start_game()
	_last_force_start = now
