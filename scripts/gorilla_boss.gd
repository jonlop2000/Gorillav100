# gorilla_boss.gd   –  host‑authoritative build
# NOTE: paths (AnimationTree, NavigationAgent, etc.) must match your scene.

extends KinematicBody

## ───────────────  Tunables  ─────────────── ##
enum State { IDLE, CHASE, ATTACK, RECOVER, DESPERATION }

export(int)   var max_health      := 2000
export(float) var move_speed      := 5.0
export(float) var attack_range    := 3.0
export(float) var rotation_speed  := 5.0

## ───────────────  Runtime  ─────────────── ##
var health              : int     = max_health
var state               : int     = State.IDLE
var state_timer         : float   = 0.0
var target                        = null
var is_host             : bool    = false      # set by PlayroomManager
var current_attack_dmg  : int     = 0
var _nav_map : RID


##  AnimationTree shortcuts
onready var anim_tree : AnimationTree  = $visual/GorillaBossGD/AnimationTree
onready var sm  = anim_tree.get("parameters/StateMachine/playback")
onready var anim_player : AnimationPlayer = $visual/GorillaBossGD/AnimationPlayer

##  Navigation + hit / HUD
onready var nav_agent : NavigationAgent = $NavigationAgent
onready var hit_area = $visual/GorillaBossGD/Armature/Skeleton/BoneAttachment/HitArea
onready var hp_bar = $HealthViewport/UIRoot/Healthbar

##  Signals  (manager listens to these)
signal anim_changed(anim_name)
signal health_changed(hp)

## ───────────────  Setup  ─────────────── ##
func _ready():
	hp_bar.min_value = 0
	hp_bar.max_value = max_health
	hp_bar.value = health
	anim_tree.active = true

	_nav_map = get_world().get_navigation_map()
	if _nav_map == RID():
		push_error("⚠️ Failed to grab navigation map RID!")
	else:
		print("✅ Navigation map RID is", _nav_map)

	hit_area.monitoring = false
	if not is_host:
		set_physics_process(false)
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
	print("📡 [Client] apply_remote_state:", d)
	var p = d["pos"]
	global_transform.origin = Vector3(p[0], p[1], p[2])
	rotation.y              = d["rot"]
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
	print("🛑 is_host =", is_host)
	if not is_host:
		return                            # clients do nothing
	_state_machine(delta)
	_update_hp_bar()

	# Manager polls `get_snapshot()` at 10 Hz – nothing else to do here.

## ───────────────────────────────────────────────────────── ##
##                     AI STATE MACHINE                     ##
## ───────────────────────────────────────────────────────── ##
func _state_machine(delta):
	state_timer = max(state_timer - delta, 0)
	target = _pick_target()
	var dist = INF
	if target:
		dist = global_transform.origin.distance_to(target.global_transform.origin)

	# 1) Desperation entry
	if health < max_health * 0.3 and state != State.DESPERATION:
		_enter_state(State.DESPERATION)
	else:
		match state:
			State.IDLE:
				if target:
					_enter_state(State.CHASE)

			State.CHASE:
				if not target:
					_enter_state(State.IDLE)
				elif dist <= attack_range:
					_enter_state(State.ATTACK)

			State.ATTACK:
				if state_timer == 0 and target:
					_enter_state(State.RECOVER)
					_choose_attack(state == State.DESPERATION)

			State.RECOVER:
				if state_timer == 0 and target:
					if dist <= attack_range:
						_enter_state(State.ATTACK)
						_choose_attack()
					else:
						_enter_state(State.CHASE)

			State.DESPERATION:
				if not target:
					_enter_state(State.IDLE)
				elif dist <= attack_range:
					_enter_state(State.ATTACK)
				else:
					_enter_state(State.CHASE)

	# 2) Movement: only when chasing or in desperation
	if state in [ State.CHASE, State.DESPERATION ] and target:
		_move_toward(target.global_transform.origin, delta)



func _enter_state(new_state : int):
	state  = new_state
	state_timer = 0.0
	
	match state:
		State.IDLE:
			sm.travel("Idle")
			emit_signal("anim_changed", "Idle")

		State.CHASE, State.DESPERATION:
			sm.travel("Run")               # ← your chase clip
			emit_signal("anim_changed", "Run")

		State.ATTACK:
			# Attack moves call travel themselves
			pass

		State.RECOVER:
			sm.travel("Idle")
			emit_signal("anim_changed", "Idle")

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

func _think_attack_or_chase(delta, desperation := false) -> void:
	if not target:
		return
	var dist          = global_transform.origin.distance_to(target.global_transform.origin)
	var attack_inner  = attack_range - 0.3   # how far inside before attacking
	var attack_outer  = attack_range         # how far outside before chasing
	if dist > attack_outer:
		_enter_state(State.CHASE)
	elif dist < attack_inner:
		_enter_state(State.ATTACK)
		_choose_attack(desperation)

func _choose_attack(desperation := false) -> void:
	if desperation:
		_do_hurricane_kick()
	else:
		_do_melee()

## ───────────────  Moves (host only)  ─────────────── ##
func _do_melee():
	current_attack_dmg = 20
	sm.travel("Melee")
	emit_signal("anim_changed", "Melee")
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	hit_area.monitoring = false
	_enter_state(State.RECOVER); state_timer = 1.0

func _do_hurricane_kick():
	current_attack_dmg = 40
	sm.travel("HurricaneKick")
	emit_signal("anim_changed", "HurricaneKick")
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	hit_area.monitoring = false
	_enter_state(State.RECOVER); state_timer = 2.0

## ───────────────  Movement helpers (host) ─────────────── ##
func _move_toward(dest: Vector3, delta: float) -> void:
	if not is_host:
		return
	nav_agent.set_target_location(dest)
	# if we’ve no path or already there, bail
	if nav_agent.is_navigation_finished():
		return

	var next_pt = nav_agent.get_next_location()
	var dir     = next_pt - global_transform.origin
	dir.y = 0
	if dir.length() < 0.01:
		return
	dir = dir.normalized()

	# rotate smoothly toward dest
	var look = dest - global_transform.origin
	look.y = 0
	if look.length() > 0:
		var t_rot = atan2(look.x, look.z)
		rotation.y = lerp_angle(rotation.y, t_rot, rotation_speed * delta)

	move_and_slide(dir * move_speed, Vector3.UP)


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
