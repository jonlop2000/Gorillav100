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

onready var _cd_label := get_node_or_null("/root/arena/UI/CountdownContainer/CountdownLabel")
var _cd  := 5

var _state_poll_accum := 0.0
const STATE_POLL_RATE := 0.2      # seconds

# ----------   PHASE / TIMER KEYS  ----------
const KEY_PHASE      := "phase"        # int  (0-3)
const KEY_TIME_LEFT  := "time_left"    # float (s)
enum Phase { LOBBY, COUNTDOWN, PLAYING, GAME_OVER }

const PRE_GAME_SECONDS  := 5           # "get ready" delay
const POST_GAME_SECONDS := 7           # time to show Victory/Game-Overs

# ---------------------------------------------------------------------#
#  State                                                               #
# ---------------------------------------------------------------------#
var players   := {}  # id → { state, node, joy? }
var boss_node : Node = null
var _ready_cache := {} #id->bool
var _game_started := false
var _joined_room := false

# timers
var _accum_player := 0.0
var _accum_boss   := 0.0
var start_timer : Timer
var end_timer : Timer
var _current_phase    : int   = Phase.LOBBY
var _phase_time_left  : float = 0.0


# root holders are updated every time we switch scenes
var _players_root : Node = null
var _ui_root      : Node = null
var _boss_parent  : Node = null
var lobby_panel: Control = null
var _countdown_lbl  : Label   = null      # shows 5-4-3-2-1
var _gameover_panel : Control = null      # Victory / Game-Over splash
var _is_frozen := false
var players_alive := []
# keep JS callbacks alive
var _js_refs := []

# ---------------------------------------------------------------------#
#  Helpers                                                             #
# ---------------------------------------------------------------------#
func _bridge(method:String):
	var cb = JavaScript.create_callback(self, method)
	_js_refs.append(cb)
	return cb

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
	Playroom.RPC.register("boss_die", _bridge("_on_boss_die_rpc"))
	Playroom.waitForState(KEY_PHASE, _bridge("_on_phase_set"))
   # ---------------------------------------------------------------------
	if OS.has_feature("HTML5"):
		var opts = JavaScript.create_object("Object")
		opts.gameId = "I2okszCMAwuMeW4fxFGD"
		opts.discord = true
		opts.skipLobby = true
		Playroom.insertCoin(opts, _bridge("_on_insert_coin"))
		# sync to whatever host already set (ulate join case)
		_current_phase    = _safe_int_state(KEY_PHASE, Phase.LOBBY)
		_phase_time_left  = _safe_float_state(KEY_TIME_LEFT, 0.0)
	else:
		# editor debug: spawn one local player + boss
		var dummy_state = {}
		dummy_state.id = "LOCAL"
		var local_node = _spawn_player(dummy_state)
		local_node.make_local()  
		players["LOCAL"] = { "state": dummy_state, "node": local_node }
		boss_node = _spawn_boss()

func _safe_int_state(key: String, fallback: int) -> int:
	var v = Playroom.getState(key)
	if v == null:
		return fallback
	return int(v)

func _safe_float_state(key: String, fallback: float) -> float:
	var v = Playroom.getState(key)
	if v == null:
		return fallback
	return float(v)

func _on_phase_set(args):
	if args.size() == 0 or args[0] == null:
		return
	var new_phase = int(args[0])
	print("-- PHASE CHANGE →", new_phase)
	_current_phase = new_phase
	_apply_phase()

func _apply_phase():
	match _current_phase:
		Phase.LOBBY:
			print("→ _apply_phase: entering LOBBY")
			# Everyone returns to the lobby scene & UI
			_goto_lobby()
			players_alive.clear()
			_ready_cache.clear() 
			boss_node = null
		Phase.COUNTDOWN:
			# If we haven’t loaded the arena yet, do so
			if get_tree().current_scene.filename != ARENA_SCENE.resource_path:
				start_game()
			# Boss kneels & is invulnerable
			if boss_node and is_instance_valid(boss_node):
				boss_node.set_invincible(true)
				boss_node.during_countdown = true
				boss_node.sm.travel("KneelToStand")
			# Show countdown UI
			if _countdown_lbl and is_instance_valid(_countdown_lbl):
				_countdown_lbl.get_parent().visible = true
		Phase.PLAYING:
			# Boss becomes vulnerable again and AI resumes
			if boss_node and is_instance_valid(boss_node):
				boss_node.set_invincible(false)
				boss_node.during_countdown = false
				_unfreeze_boss()
			# Hide countdown UI
			if _countdown_lbl and is_instance_valid(_countdown_lbl):
				_countdown_lbl.get_parent().visible = false
		Phase.GAME_OVER:
			# Stop the boss
			_freeze_boss()
			# Make sure countdown UI is hidden
			if _countdown_lbl and is_instance_valid(_countdown_lbl):
				_countdown_lbl.get_parent().visible = false

			# Show Game Over panel with explicit if/else
			if _gameover_panel and _gameover_panel.has_node("CenterBox/VBox/Title"):
				var title_lbl = _gameover_panel.get_node("CenterBox/VBox/Title") as Label
				var victory = Playroom.getState("result", false)
				print("→ Showing GameOverPanel; victory =", victory)
				if victory:
					title_lbl.text = "Victory!"
				else:
					title_lbl.text = "Game Over"
				_gameover_panel.show()
			else:
				push_error("Missing Title label under GameOverPanel!")

# --------------------------------------------------
#  Freeze / unfreeze every LOCAL player on this client
# --------------------------------------------------
func _freeze_boss() -> void:
	if boss_node:
		boss_node.freeze_ai()      # your existing “hard stop” for AI
		boss_node.set_invincible(true)
		boss_node.during_countdown = true

func _unfreeze_boss() -> void:
	if boss_node:
		boss_node.unfreeze_ai()

### ----------  MATCH-FLOW  ----------
func _host_begin_countdown():
	_current_phase   = Phase.COUNTDOWN
	_phase_time_left = PRE_GAME_SECONDS
	Playroom.setState(KEY_PHASE, _current_phase)         # reliable default :contentReference[oaicite:1]{index=1}
	Playroom.setState(KEY_TIME_LEFT, _phase_time_left)  # we'll spam this once a sec
	_apply_phase()

func _host_start_gameplay():
	_current_phase = Phase.PLAYING
	Playroom.setState(KEY_PHASE, _current_phase)
	_apply_phase()

func _host_end_game(victory: bool):
	_current_phase   = Phase.GAME_OVER
	_phase_time_left = POST_GAME_SECONDS
	Playroom.setState(KEY_PHASE, _current_phase)
	Playroom.setState(KEY_TIME_LEFT, _phase_time_left, false)
	Playroom.setState("result", victory)  # true = players win
	_apply_phase()

func _host_return_to_lobby():
	# 1) Broadcast “we’re in Lobby”
	_current_phase = Phase.LOBBY
	Playroom.setState(KEY_TIME_LEFT, 0.0, false)
	Playroom.setState(KEY_PHASE,      _current_phase)
	Playroom.setState("result",       null)
	# 2) Clear every player’s ready flag (so we don’t auto-start)
	for id in players.keys():
		var st = players[id].state
		st.setState("ready", false, true)   # reliable send
		_ready_cache[id] = false            # local cache too
	# 3) Disconnect & null out old player nodes
	for id in players.keys():
		var pnode = players[id].node
		if pnode and is_instance_valid(pnode):
			if pnode.is_connected("died", self, "_on_player_died"):
				pnode.disconnect("died", self, "_on_player_died")
		players[id].node = null
	# 4) Disconnect & null out the old boss
	if boss_node and is_instance_valid(boss_node):
		if boss_node.is_connected("died", self, "_on_boss_died"):
			boss_node.disconnect("died", self, "_on_boss_died")
	boss_node = null
	# 5) Finally, run the lobby logic locally
	_apply_phase()


# Returns an Array of the current PlayerState objects
func get_player_states() -> Array:
	var out := []
	for id in players.keys():
		out.append(players[id]["state"])
	return out

func _spawn_player(state) -> Node:
	# Ensure our _players_root is valid for the current scene
	if not _players_root or not is_instance_valid(_players_root):
		_hook_scene_paths()
	var inst = PLAYER_SCENE.instance()
	inst.name = "player_%s" % state.id
	if _players_root and is_instance_valid(_players_root):
		_players_root.add_child(inst)
	else:
		push_error("Cannot spawn player: _players_root is invalid or null!")
	inst.add_to_group("players")
	if str(state.id) == str(Playroom.me().id):
		inst.make_local()
		# HUD
		var hud = PLAYER_HUD_SCENE.instance()
		hud.player_path = inst.get_path()
		# Ensure _ui_root is valid
		if not _ui_root or not is_instance_valid(_ui_root):
			_hook_scene_paths()
		if _ui_root and is_instance_valid(_ui_root):
			_ui_root.add_child(hud)
		else:
			push_error("Cannot add player HUD: _ui_root is invalid or null!")
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


func _spawn_boss() -> Node:
	if not _boss_parent or not is_instance_valid(_boss_parent):
		_hook_scene_paths()
	var scene = preload("res://scenes/gorilla_boss.tscn")
	var inst  = scene.instance()
	inst.is_host = Playroom.isHost()
	print("Spawning boss - is_host:", inst.is_host)

	if _boss_parent and is_instance_valid(_boss_parent):
		_boss_parent.add_child(inst)
	else:
		push_error("Cannot spawn boss: _boss_parent is invalid or null!")

	return inst

func _pack_player(node:Node) -> Dictionary:
	return {
		"px": node.global_transform.origin.x,
		"py": node.global_transform.origin.y,
		"pz": node.global_transform.origin.z,
		"rot": node.rotation.y
	}

func _pack_boss() -> Dictionary:
	# Don’t try to read a freed or null instance
	if boss_node == null or not is_instance_valid(boss_node):
		return {}
	var pos = boss_node.global_transform.origin
	return {
		"px": pos.x,
		"py": pos.y,
		"pz": pos.z,
		"rot": boss_node.rotation.y,
		"anim": boss_node.get_current_anim(),
		"hp": boss_node.health
	}


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
	
func _on_boss_die_rpc(_args:Array) -> void:
	if boss_node and is_instance_valid(boss_node):
		# Force the Death animation on every client
		boss_node.sm.travel("Death")
		# Queue‐free it when that animation finishes, just like the host does
		boss_node.anim_player.connect(
			"animation_finished",
			boss_node,
			"_on_death_animation_finished",
			[], CONNECT_ONESHOT
		)

# ------------------------------------------------------------------#
#  Lobby / join / quit                                              #
# ------------------------------------------------------------------#
func _on_insert_coin(_args):
	Playroom.onPlayerJoin(_bridge("_on_player_join"))

	# 1) Seed roster with yourself
	var me_state = Playroom.me()
	if me_state:
		_on_player_join([me_state])
	# 2) Cache host flag & other room state
	_cached_is_host = Playroom.isHost()
	if _cached_is_host:
		_on_became_host()
	else:
		_on_lost_host()
	_joined_room = true    
	# 3) Prefetch avatars
	for state in get_player_states():
		var url = state.getProfile().photo
		if url and url.begins_with("http"):
			AvatarCache.fetch(str(state.id), url)
	# 5) Load lobby
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
	
	state.onQuit(_bridge("_on_player_quit"))

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
		return
	print("→ _goto_lobby: lobby panel visible")
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

func start_game() -> void:
	get_tree().change_scene_to(ARENA_SCENE)
	yield(get_tree(), "idle_frame")
	_hide_lobby_panel()
	_hook_scene_paths()

	# Spawn existing players
	for id in players.keys():
		var entry = players[id]
		if entry.node == null or not is_instance_valid(entry.node):
			entry.node = _spawn_player(entry.state)

	# Spawn boss once
	if boss_node == null:
		boss_node = _spawn_boss()

	# Only the host sets up end‐game logic
	if Playroom.isHost():
		# 1) Boss death → players win
		boss_node.connect("died", self, "_on_boss_died")

		# 2) Player death → track survivors
		players_alive.clear()
		for id in players.keys():
			var p = players[id].node
			players_alive.append(p)
			p.connect("died", self, "_on_player_died")

		_host_begin_countdown()

func _on_boss_died():
	if boss_node:
		boss_node.disconnect("died", self, "_on_boss_died")
		boss_node = null

	_host_end_game(true)

func _on_player_died(dead_player):
	players_alive.erase(dead_player)
	if players_alive.empty():
		_host_end_game(false)

# --------------------------------------------------
#  Kick-off from the lobby (host only)
# --------------------------------------------------
func host_start_match() -> void:
	if not Playroom.isHost():
		return                      # safety – clients do nothing
	start_game()                    # your existing scene-load helper


func _hide_lobby_panel():
	if lobby_panel and is_instance_valid(lobby_panel):
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

	if scene.has_node("UI/CountdownContainer"):
		var container = scene.get_node("UI/CountdownContainer")
		container.visible = false
		if container.has_node("CountdownLabel"):
			_countdown_lbl = container.get_node("CountdownLabel")

	if scene.has_node("UI/GameOverPanel"):
		_gameover_panel = scene.get_node("UI/GameOverPanel")
		_gameover_panel.hide()

# ------------------------------------------------------------------#
#  Ready / start logic                                              #
# ------------------------------------------------------------------#
func _on_ready_state(args):
	var p      = args[0]              # Player object
	var is_rdy = args[1]              # bool
	_ready_cache[str(p.id)] = is_rdy
	# Host: auto-start when everyone ready
	if Playroom.isHost() and _all_ready():
		host_start_match()          

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

func _update_remote_boss():
	# 1) Get the raw JSON the host set under "boss"
	var raw = Playroom.getState("boss")
	if not raw:
		return
	var parsed = JSON.parse(raw)
	if parsed.error != OK:
		push_error("Failed to parse boss state JSON")
		return
	var state = parsed.result
	# 2) Bail on empty dicts (e.g. after boss is freed)
	if not (state is Dictionary) or state.empty():
		return
	# 3) Spawn a boss on P2 if needed
	if not boss_node:
		boss_node = _spawn_boss()
	# 4) Safely apply via the boss's own RPC helper
	if is_instance_valid(boss_node):
		boss_node.apply_remote_state({
			"pos":  [state["px"], state["py"], state["pz"]],
			"rot":   state["rot"],
			"hp":    state["hp"],
			"anim":  state["anim"]
		})



# ---------------------------------------------------------------------#
#  Main loops                                                          #
# ---------------------------------------------------------------------#
func _physics_process(delta: float) -> void:
	# ─── Only run in Playroom (HTML5) context ───────────────────────────
	if not OS.has_feature("HTML5"):
		return

	# ─── Only in the Arena phases ──────────────────────────────────────
	if _current_phase != Phase.COUNTDOWN and _current_phase != Phase.PLAYING and _current_phase != Phase.GAME_OVER:
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
					entry.node = null
					continue

				# 1) publish your own state
				if node.is_local:
					var packed = _pack_player(node)  # {px,py,pz,rot}
					for k in packed.keys():
						state.setState(k, packed[k])
					continue

				# 2) consume snapshots for remote players
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

		# publish boss state
		if boss_node:
			_accum_boss += delta
			if _accum_boss >= BOSS_SEND_RATE:
				_accum_boss -= BOSS_SEND_RATE
				Playroom.setState("boss", JSON.print(_pack_boss()))

	# ─── CLIENTS: poll & apply transforms ──────────────────────────────
	else:
		_accum_player += delta
		if _accum_player >= PLAYER_SEND_RATE:
			_accum_player -= PLAYER_SEND_RATE
			for id in players.keys():
				var entry = players[id]
				var node  = entry.node
				var state = entry.state

				if node == null or not is_instance_valid(node):
					continue

				if node.is_local:
					var packed = _pack_player(node)
					for k in packed.keys():
						state.setState(k, packed[k])
					continue

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

		_accum_boss += delta
		if _accum_boss >= BOSS_SEND_RATE:
			_accum_boss -= BOSS_SEND_RATE
			_update_remote_boss()



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

func _process(delta: float) -> void:
	# ─── 1) Always: host migration & phase polling ──────────────────────
	_state_poll_accum += delta
	if _state_poll_accum >= STATE_POLL_RATE:
		_state_poll_accum -= STATE_POLL_RATE

		_check_host_change()
		_poll_lobby_state()

		if not Playroom.isHost():
			var phase_raw = Playroom.getState(KEY_PHASE)
			if phase_raw != null:
				var new_phase = int(phase_raw)
				if new_phase != _current_phase:
					_current_phase = new_phase
					_apply_phase()
			if _current_phase == Phase.COUNTDOWN:
				var time_raw = Playroom.getState(KEY_TIME_LEFT)
				if time_raw != null:
					_phase_time_left = float(time_raw)

	# ─── 2) Always on host: drive your phase timers ────────────────────
	if Playroom.isHost():
		_tick_host_phase(delta)

	# ─── 3) Arena-only UI updates (skip in GAME_OVER & LOBBY) ─────────
	if _current_phase == Phase.COUNTDOWN:
		if _countdown_lbl and is_instance_valid(_countdown_lbl):
			var container = _countdown_lbl.get_parent()
			if container:
				container.visible = true
				_countdown_lbl.text = str(int(ceil(_phase_time_left)))
	elif _current_phase == Phase.PLAYING:
		if _countdown_lbl and is_instance_valid(_countdown_lbl):
			var container = _countdown_lbl.get_parent()
			if container:
				container.visible = false
	# (GAME_OVER UI is handled in _apply_phase(), LOBBY has no per-frame UI)

	


func _tick_host_phase(delta: float) -> void:
	match _current_phase:
		Phase.COUNTDOWN:
			_phase_time_left = max(_phase_time_left - delta, 0.0)
			var int_left = int(_phase_time_left)
			# only broadcast when the integer part changes
			if int_left != int(_safe_float_state(KEY_TIME_LEFT, -1.0)):
				Playroom.setState(KEY_TIME_LEFT, _phase_time_left)   # reliable
			if _phase_time_left <= 0.0:
				_host_start_gameplay()

		Phase.GAME_OVER:
			_phase_time_left = max(_phase_time_left - delta, 0.0)
			var int_left2 = int(_phase_time_left)
			if int_left2 != int(_safe_float_state(KEY_TIME_LEFT, -1.0)):
				Playroom.setState(KEY_TIME_LEFT, _phase_time_left)
			if _phase_time_left <= 0.0:
				_host_return_to_lobby()
		_:
			# no ticking in LOBBY or PLAYING
			pass

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
	print("⚡ Host migrated to ME")
	_current_phase   = _safe_int_state(KEY_PHASE, Phase.LOBBY)
	_phase_time_left = _safe_float_state(KEY_TIME_LEFT, 0.0)
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

	if boss_node:
		boss_node.is_host = false
		boss_node.deactivate_ai()        

func _poll_lobby_state():
	if not _joined_room or _current_phase != Phase.LOBBY:
		return
	# only when you’re actually in the Lobby scene:
	if get_tree().current_scene.filename != LOBBY_SCENE.resource_path:
		return
	for state in get_player_states():
		var id = str(state.id)
		_ready_cache[id] = state.getState("ready") == true
	if Playroom.isHost() and _all_ready():
		host_start_match()
