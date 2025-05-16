# gorilla_boss.gd   –  host‑authoritative build
# NOTE: paths (AnimationTree, NavigationAgent, etc.) must match your scene.

extends KinematicBody

## ───────────────  Tunables  ─────────────── ##
enum State { IDLE, CHASE, ATTACK, RECOVER, DESPERATION, JUMP, FALL }

export(int)   var max_health := 2000
export(float) var move_speed := 2.0
export(float) var attack_range := 2.0
export(float) var rotation_speed := 5.0
export(float) var jump_speed = 12.0
export(float) var jump_height_threshold = 1.5 
export(float) var gravity = 9.8
## ───────────────  Runtime  ─────────────── ##

var Playroom = JavaScript.get_interface("Playroom")

var health : int  = max_health
var state : int  = State.IDLE
var state_timer : float = 0.0
var target = null
var is_host : bool = false      # set by PlayroomManager
var current_attack_dmg  : int = 0
var _nav_map : RID
var _target_pos   : Vector3
var _target_rot_y : float
var _last_used = {}
var _vert_vel: float = 0.0 
var _velocity: Vector3 = Vector3.ZERO
var _airborne: bool = false
var _grounded : bool = false

##  AnimationTree shortcuts
onready var anim_tree : AnimationTree  = $visual/GorillaBossGD/AnimationTree
onready var sm  = anim_tree.get("parameters/StateMachine/playback")
onready var anim_player : AnimationPlayer = $visual/GorillaBossGD/AnimationPlayer

##  Navigation + hit / HUD
onready var nav_agent : NavigationAgent = $NavigationAgent
onready var hit_area = $visual/GorillaBossGD/Armature/Skeleton/BoneAttachment/HitArea
onready var hp_bar = $HealthViewport/UIRoot/Healthbar
onready var ground_ray = $RayCast

##  Signals  (manager listens to these)
signal anim_changed(anim_name)
signal health_changed(hp)

var moves = {
	"Melee": {"range":1.0, "cooldown":1.0,  "weight":3,   "func":"_do_melee"},
	"MeleeCombo": {"range":1.0, "cooldown":2.0,  "weight":2,   "func":"_do_combo"},
	"360Swing": {"range":2.0, "cooldown":3.0,  "weight":1,   "func":"_do_swing"},
	"BattleCry": {"range":3.0, "cooldown":2.0, "weight":0.5, "func":"_do_battlecry"},
	"HurricaneKick": {"range":2.0,"cooldown":4.0,  "weight":1,   "func":"_do_despair_combo", "desperation_only":true}
}

## ───────────────  Setup  ─────────────── ##
func _ready():
	hp_bar.min_value = 0
	hp_bar.max_value = max_health
	hp_bar.value = health
	anim_tree.active = true
	_target_pos = global_transform.origin
	_target_rot_y = rotation.y
	randomize()
	for name in moves.keys():
		_last_used[name] = -INF
	_nav_map = get_world().get_navigation_map()
	if _nav_map == RID():
		push_error("⚠️ Failed to grab navigation map RID!")
	else:
		print("✅ Navigation map RID is", _nav_map)

	hit_area.monitoring = false
	if not is_in_group("boss"):
		add_to_group("boss")


## ───────────────  API for PlayroomManager  ─────────────── ##
func get_snapshot() -> Dictionary:
	return {
		"pos" : [global_transform.origin.x,
				 global_transform.origin.y,
				 global_transform.origin.z],
		"rot" : rotation.y,
		"hp"  : health,
		"anim": sm.get_current_node()
	}

func apply_remote_state(d : Dictionary) -> void:
	# Called by manager on non‑host clients
	var p = d["pos"]
	_target_pos   = Vector3(p[0], p[1], p[2])
	_target_rot_y = d["rot"]
	if health != d["hp"]:
		health   = d["hp"]
		hp_bar.value = health
	_ensure_anim(d["anim"])

##  Fast local helper
func _ensure_anim(name : String) -> void:
	if sm.get_current_node() != name:
		sm.travel(name)

## ───────────────  Host‑only physics / AI  ─────────────── ##
func _physics_process(delta):
	_grounded = ground_ray.is_colliding()
	if is_host:
		_state_machine(delta)
		_update_hp_bar()
	else:
		# remote smoothing
		var cur = global_transform.origin
		cur = cur.linear_interpolate(_target_pos, delta * 8.0)
		global_transform.origin = cur
		rotation.y = lerp_angle(rotation.y, _target_rot_y, delta * 8.0)
		# still update the health bar if you like
		_update_hp_bar()


	# Manager polls `get_snapshot()` at 10 Hz – nothing else to do here.

## ───────────────────────────────────────────────────────── ##
##                     AI STATE MACHINE                     ##
## ───────────────────────────────────────────────────────── ##
func _state_machine(delta):
	state_timer = max(state_timer - delta, 0)
	target = _pick_target()
	if not target:
		_enter_state(State.IDLE)
		return

	var dist = global_transform.origin.distance_to(target.global_transform.origin)
	var in_range = dist <= attack_range

	match state:
		State.IDLE:
			if in_range:
				_enter_state(State.ATTACK)
			else:
				_enter_state(State.CHASE)

		State.CHASE:
			if in_range:
				_enter_state(State.ATTACK)
			else:
				var dy = target.global_transform.origin.y - global_transform.origin.y
				if _grounded and dy > jump_height_threshold:
					_enter_state(State.JUMP)

		State.JUMP:
			print("--- In JUMP state --- airborne=", _airborne, " on_floor=", is_on_floor())
			if not _airborne and not _grounded:
				_airborne = true
			elif _airborne and _grounded:
				_enter_state(State.CHASE)

		State.ATTACK:
			if not in_range:
				_enter_state(State.CHASE)
			elif state_timer == 0:
				_choose_attack(state == State.DESPERATION)

		State.DESPERATION:
			if not in_range:
				_enter_state(State.CHASE)
			elif state_timer == 0:
				_enter_state(State.ATTACK)
				_choose_attack(true)

	# Movement only in CHASE
	if state == State.CHASE and target:
		_move_toward(target.global_transform.origin, delta)
	
	elif state == State.JUMP:
		var dir = (target.global_transform.origin - global_transform.origin)
		dir.y = 0
		dir = dir.normalized() * move_speed
		
		_vert_vel -= 9.8 * delta
		var vel = Vector3(dir.x, _vert_vel, dir.z)
		_velocity = move_and_slide(vel, Vector3.UP)
		return

func _enter_state(new_state: int) -> void:
	state = new_state
	state_timer = 0.0
	
	match state:
		State.IDLE:
			sm.travel("Idle")
			emit_signal("anim_changed", "Idle")
		State.CHASE, State.DESPERATION:
			sm.travel("Run")
			emit_signal("anim_changed", "Run")
			nav_agent.set_physics_process(true)
		State.ATTACK:
			pass
		State.JUMP:
			sm.travel("Run")
			emit_signal("anim_changed", "Run")
			nav_agent.set_physics_process(false)
			_vert_vel = jump_speed
			_airborne = false

func _pick_target():
	var players = get_tree().get_nodes_in_group("players")
	print("players in group:", players.size())
	var best : Node = null
	var best_d := INF
	for p in players:
		if not is_instance_valid(p):
			continue
			
		# Skip players at origin (likely not properly initialized)
		if p.global_transform.origin == Vector3.ZERO:
			print("Skipping player at origin")
			continue
			
		var d = global_transform.origin.distance_squared_to(p.global_transform.origin)
		print("Player at:", p.global_transform.origin, " distance:", d)
		if d < best_d:
			best_d = d; best = p
			
	if best:
		print("Selected target at:", best.global_transform.origin)
	else:
		print("No valid target found")
	return best

func _choose_attack(desperation := false) -> void:
	var dist = global_transform.origin.distance_to(target.global_transform.origin)
	var now  = OS.get_ticks_msec() / 1000.0

	# build your candidate list exactly as before…
	var candidates = []
	for name in moves.keys():
		var m = moves[name]
		if m.has("desperation_only") and not desperation:
			continue
		if dist > m.range:
			continue
		if now - _last_used[name] < m.cooldown:
			continue
		candidates.append(name)

	# fallback to melee if needed
	if candidates.empty():
		candidates = ["Melee"]

	# weighted pick
	var total = 0.0
	for n in candidates:
		total += moves[n].weight
	var pick = randf() * total
	for n in candidates:
		pick -= moves[n].weight
		if pick <= 0.0:
			# perform the move
			call(moves[n].func)
			_last_used[n] = now
			state_timer = moves[n].cooldown
			return


## ───────────────  Moves (host only)  ─────────────── ##
func _do_melee():
	current_attack_dmg = 20
	sm.travel("Melee")
	emit_signal("anim_changed", "Melee")
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	hit_area.monitoring = false
	state_timer = moves["Melee"].cooldown
	
func _do_combo() -> void:
	current_attack_dmg = 25
	sm.travel("MeleeCombo")
	emit_signal("anim_changed", "MeleeCombo")
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	hit_area.monitoring = false
	state_timer = moves["MeleeCombo"].cooldown
	
func _do_swing() -> void:
	current_attack_dmg = 15
	sm.travel("360Swing")
	emit_signal("anim_changed", "360Swing")
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	hit_area.monitoring = false
	state_timer = moves["360Swing"].cooldown
	

func _do_battlecry() -> void:
	current_attack_dmg = 0
	sm.travel("BattleCry")
	emit_signal("anim_changed", "BattleCry")

	if is_host:
		for p in get_tree().get_nodes_in_group("players"):
			var d = global_transform.origin.distance_to(p.global_transform.origin)
			if d <= moves["BattleCry"].range:
				# build a *pure-GDScript* payload with only primitive types
				var payload = {
					"target_id": p.name.replace("player_", ""),
					"direction": [
						p.global_transform.origin.x - global_transform.origin.x,
						p.global_transform.origin.y - global_transform.origin.y,
						p.global_transform.origin.z - global_transform.origin.z
					],
					"force": 20.0
				}
				# stringify it
				var raw = JSON.print(payload)
				# call RPC with (name, string, mode)
				Playroom.RPC.call(
					"apply_knockback",
					raw,
					Playroom.RPC.Mode.ALL   
				)

	yield(anim_player, "animation_finished")
	state_timer = moves["BattleCry"].cooldown


# called when moves["HurricaneKick"].func == "_do_despair_combo"
func _do_despair_combo() -> void:
	current_attack_dmg = 40
	sm.travel("HurricaneKick")      # reuse your HurricaneKick anim
	emit_signal("anim_changed", "HurricaneKick")
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	hit_area.monitoring = false
	state_timer = moves["HurricaneKick"].cooldown

## ───────────────  Movement helpers (host) ─────────────── ##
func _move_toward(dest: Vector3, delta: float) -> void:
	if not is_host:
		return

	# ─── HORIZONTAL ───
	nav_agent.set_target_location(dest)
	if nav_agent.is_navigation_finished():
		# no nav target → maybe just fall?
		_apply_vertical(delta)
		return

	var next_pt = nav_agent.get_next_location()
	var dir     = (next_pt - global_transform.origin)
	dir.y = 0
	if dir.length() < 0.01:
		# too close, only apply gravity
		_apply_vertical(delta)
		return
	dir = dir.normalized()

	# smooth rotation toward your final DEST, not just the next_pt
	var look = (dest - global_transform.origin)
	look.y = 0
	if look.length() > 0:
		var t_rot = atan2(look.x, look.z)
		rotation.y = lerp_angle(rotation.y, t_rot, rotation_speed * delta)

	# ─── VERTICAL ───
	_apply_vertical(delta)

	# ─── COMBINE & MOVE ───
	var full_vel = Vector3(dir.x * move_speed,
						   _vert_vel,
						   dir.z * move_speed)
	_velocity = move_and_slide(full_vel, Vector3.UP)

func _apply_vertical(delta: float) -> void:
	match state:
		State.JUMP:
			_vert_vel -= gravity * delta
		_:
			# fall when not grounded
			if not _grounded:
				_vert_vel -= gravity * delta
			else:
				_vert_vel = 0.0



func _direct_steer(dest: Vector3, delta: float) -> void:
	var dir = dest - global_transform.origin
	dir.y = 0
	var dist = dir.length()
	if dist < 0.1:
		return
	dir = dir.normalized()
	var target_rot = atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, target_rot, rotation_speed * delta)
	move_and_slide(dir * move_speed, Vector3.UP)


## ───────────────  Damage interface  ─────────────── ##
func take_damage(amount : int) -> void:
	if not is_host: return
	health = clamp(health - amount, 0, max_health)
	emit_signal("health_changed", health)
	_flash_damage()
	if health == 0:
		_die()

func _update_hp_bar():
	hp_bar.value = health

func _flash_damage():
	# quick red flash – placeholder
	pass

func _die():
	sm.travel("Death")
	emit_signal("anim_changed", "Death")
	set_physics_process(false)
	nav_agent.set_enabled(false)

## ───────────────  Utilities  ─────────────── ##
func get_current_anim() -> String:
	return sm.get_current_node()
