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
	hp_bar.value     = health
	hit_area.monitoring = false
	if not is_host:
		# Disable heavy AI loops for clients
		set_physics_process(false)

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
	if not is_host:
		return                            # clients do nothing

	_state_machine(delta)
	_update_hp_bar()

	# Manager polls `get_snapshot()` at 10 Hz – nothing else to do here.

## ───────────────────────────────────────────────────────── ##
##                     AI STATE MACHINE                     ##
## ───────────────────────────────────────────────────────── ##
func _state_machine(delta):
	state_timer = max(state_timer - delta, 0)

	match state:
		State.IDLE:
			_pick_target()
			if target:
				_enter_state(State.CHASE)
		State.CHASE:
			_think_attack_or_chase(delta)
		State.ATTACK:
			pass        # attack coroutines drive transitions
		State.RECOVER:
			if state_timer == 0 and target:
				_enter_state(State.CHASE)
		State.DESPERATION:
			_think_attack_or_chase(delta, true)

	if state in [State.CHASE, State.DESPERATION]:
		_move_toward(target.global_transform.origin, delta)

func _enter_state(new_state : int):
	state       = new_state
	state_timer = 0.0

func _pick_target():
	var best : Node = null
	var best_d := INF
	for p in get_tree().get_nodes_in_group("players"):
		var d = global_transform.origin.distance_squared_to(p.global_transform.origin)
		if d < best_d:
			best_d = d; best = p
	target = best

func _think_attack_or_chase(delta, desperation=false):
	if not target: return
	var dist = global_transform.origin.distance_to(target.global_transform.origin)

	if dist <= attack_range:
		_enter_state(State.ATTACK)
		_choose_attack(desperation)
	else:
		pass    # keep chasing

func _choose_attack(desperation):
	# very condensed example – keep your original move table if you like
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
func _move_toward(dest : Vector3, delta):
	nav_agent.set_target_location(dest)
	if nav_agent.is_navigation_finished(): return

	var next_pt = nav_agent.get_next_location()
	var dir = (next_pt - global_transform.origin).normalized()

	# smooth rotate
	var look = dest - global_transform.origin
	look.y = 0
	if look.length() > 0:
		var target_rot = atan2(look.x, look.z)
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
