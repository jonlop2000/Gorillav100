# gorilla_boss.gd   –  host‑authoritative build
# NOTE: paths (AnimationTree, NavigationAgent, etc.) must match your scene.

extends KinematicBody

## ───────────────  Tunables  ─────────────── ##
enum State { IDLE, CHASE, ATTACK, RECOVER, DESPERATION, JUMP, FALL }

export(int)   var max_health := 2000
export(float) var move_speed := 2.0
export(float) var attack_range := 1.6
export(float) var rotation_speed := 5.0
export(float) var jump_speed = 12.0
export(float) var jump_height_threshold = 1.5 
export(float) var gravity = 9.8
export(bool) var _test_freeze := true
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
var _attack_active := false
var _hit_targets := []        # list of player IDs already hit this attack
var _current_move := ""       # name of the move we’re in the middle of
var _next_stagger_hp : int   # set in _ready() → max_health * 0.75
var _is_staggered : bool = false
var _stagger_time : float = 10.5   # seconds boss stays kneeling
var _stagger_timer : float = 0.0

##  AnimationTree shortcuts
onready var anim_tree : AnimationTree  = $visual/GorillaBossGD/AnimationTree
onready var sm  = anim_tree.get("parameters/StateMachine/playback")
onready var anim_player : AnimationPlayer = $visual/GorillaBossGD/AnimationPlayer

##  Navigation + hit / HUD
onready var nav_agent : NavigationAgent = $NavigationAgent
onready var hit_area = $visual/GorillaBossGD/Armature/Skeleton/BoneAttachment/HitArea
onready var hp_bar = $HealthViewport/UIRoot/Healthbar
onready var ground_ray = $RayCast
onready var boss_mesh : MeshInstance = $visual/GorillaBossGD/Armature/Skeleton/Cube
onready var hit_particles : CPUParticles = $visual/GorillaBossGD/Armature/Skeleton/Cube/CPUParticles
onready var hit_sfx : AudioStreamPlayer3D = $HitSound
var _orig_albedo : Color = Color(1, 1, 1)   # <── add this line

var _ai_enabled := true
var is_dead
var invincible : bool = false
var during_countdown := false

##  Signals  (manager listens to these)
signal anim_changed(anim_name)
signal health_changed(hp)
signal died 

var moves = {
	"Melee": {"range":1.0, "cooldown":2.0,  "weight":5, "knockback": 2.0, "damage":0, "func":"_do_melee"},
	"MeleeCombo": {"range":1.0, "cooldown":2.0,  "weight":3, "knockback": 2.0, "damage":0, "func":"_do_combo"},
	"360Swing": {"range":2.0, "cooldown":3.0,  "weight":1.5, "knockback": 6.0, "damage":0, "func":"_do_swing"},
	"BattleCry": {"range":2.0, "cooldown":2.0, "weight":0.5, "knockback": 5.0, "damage":0, "func":"_do_battlecry"},
	"HurricaneKick": {"range":2.0,"cooldown":4.0,  "weight":1, "knockback": 10.0, "damage":0,  "func":"_do_despair_combo", "desperation_only":true}
}

## ───────────────  Setup  ─────────────── ##
func _ready():
	hp_bar.min_value = 0
	hp_bar.max_value = max_health
	hp_bar.value = health
	_next_stagger_hp = int(max_health * 0.75)
	anim_tree.active = true
	_target_pos = global_transform.origin
	_target_rot_y = rotation.y
	randomize()
	for name in moves.keys():
		_last_used[name] = -INF
	_nav_map = get_world().get_navigation_map()
	
	var mat = boss_mesh.get_active_material(0)
	if mat is SpatialMaterial:
		_orig_albedo = mat.albedo_color
		
	hit_area.monitoring = true
	hit_area.connect("body_entered", self, "_on_hit_area_body_entered")
	hit_area.connect("body_exited", self, "_on_hit_area_body_exited")
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
		

# ─────────── helper method ───────────
# ─── signal callbacks ───
func _on_hit_area_body_entered(body):
	if not _attack_active or not body.is_in_group("players"):
		return

	var target_id = body.name.replace("player_","")
	if target_id in _hit_targets:
		print("   already hit, skipping")
		return
	_hit_targets.append(target_id)
	_broadcast_attack_to_target(_current_move, body)


func _on_hit_area_body_exited(body):
	if body.is_in_group("players"):
		print("Boss: player exited hit area: ", body.name)

# ─── at the top of GorillaBoss.gd ───
func _broadcast_attack_to_target(move_name:String, body:Node) -> void:
	if not is_host:
		return
	print("--> Broadcasting attack:", move_name, "to", body.name)
	var m = moves.get(move_name)
	if m == null:
		push_error("Unknown move for attack broadcast: %s" % move_name)
		return

	var dir = (body.global_transform.origin - global_transform.origin).normalized()
	var payload = {
		"target_id": body.name.replace("player_",""),
		"attack_name": move_name,
		"direction": [dir.x, dir.y, dir.z],
		"force":  m.knockback,
		"damage": m.damage
	}
	print("    payload:", payload)
	Playroom.RPC.call(
		"apply_attack",
		JSON.print(payload),
		Playroom.RPC.Mode.ALL
	)

func _broadcast_attack(move_name:String) -> void:
	if not is_host:
		return
	var m = moves.get(move_name)
	if m == null:
		push_error("Unknown move: %s" % move_name)
		return

	var targets = []
	if move_name in ["Melee","MeleeCombo","360Swing"]:
		# melee‐style: use your hit_area overlaps
		for body in hit_area.get_overlapping_bodies():
			if body.is_in_group("players"):
				targets.append(body)
	else:
		# AOE moves: range check
		for p in get_tree().get_nodes_in_group("players"):
			if global_transform.origin.distance_to(p.global_transform.origin) <= m.range:
				targets.append(p)

	for body in targets:
		_broadcast_attack_to_target(move_name, body)
		

## ───────────────  Host‑only physics / AI  ─────────────── ##
func _physics_process(delta):
	if not _ai_enabled or _is_dead:
		return
	_update_stagger(delta) 
	if _is_staggered:
		_update_hp_bar()
		return
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

func set_invincible(enable: bool) -> void:
	invincible = enable
	during_countdown = enable
	# Optional visual feedback:
	var mat = boss_mesh.get_active_material(0)
	if mat is SpatialMaterial:
		if enable:
			# lighten toward white
			mat.albedo_color = Color(1,1,1,1).linear_interpolate(_orig_albedo, 0.5)
		else:
			mat.albedo_color = _orig_albedo

func _state_machine(delta):
	if during_countdown:
		return 
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
	var best : Node = null
	var best_d := INF
	for p in players:
		if not is_instance_valid(p):
			continue
			
		# Skip players at origin (likely not properly initialized)
		if p.global_transform.origin == Vector3.ZERO:
			continue
			
		var d = global_transform.origin.distance_squared_to(p.global_transform.origin)
		if d < best_d:
			best_d = d; best = p
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
func _do_melee() -> void:
	_current_move  = "Melee"
	_attack_active = true
	_hit_targets.clear()
	sm.travel("Melee")
	emit_signal("anim_changed","Melee")
	hit_area.monitoring = true
	yield(anim_player,"animation_finished")
	_attack_active = false
	state_timer = moves["Melee"].cooldown

	
func _do_combo():
	_current_move = "MeleeCombo"
	_attack_active = true
	_hit_targets.clear()
	sm.travel("MeleeCombo")
	emit_signal("anim_changed", "MeleeCombo")
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	_attack_active = false
	state_timer = moves["MeleeCombo"].cooldown
	
func _do_swing():
	_current_move = "360Swing"
	_attack_active = true
	_hit_targets.clear()
	sm.travel("360Swing")
	emit_signal("anim_changed", "360Swing")
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	_attack_active = false
	state_timer = moves["360Swing"].cooldown

func _do_battlecry() -> void:
	sm.travel("BattleCry")
	emit_signal("anim_changed", "BattleCry")
	yield(anim_player, "animation_finished")
	_broadcast_attack("BattleCry")
	state_timer = moves["BattleCry"].cooldown

func _do_despair_combo() -> void:
	sm.travel("HurricaneKick")
	emit_signal("anim_changed", "HurricaneKick")
	yield(anim_player, "animation_finished")
	_broadcast_attack("HurricaneKick")
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

# at top
var _is_dead := false

func apply_damage(amount:int) -> void:
	if invincible or _is_dead:
		return
	health = max(health - amount, 0)
	emit_signal("health_changed", health)

	if health > 0 and health <= _next_stagger_hp and not _is_staggered:
		_enter_stagger()

	if health <= 0:
		_is_dead = true
		sm.travel("Death")
		emit_signal("died")

		# once the Death animation finishes, free yourself
		anim_player.connect(
			"animation_finished",
			self,
			"_on_death_animation_finished",
			[], CONNECT_ONESHOT
		)

func _on_death_animation_finished(anim_name:String) -> void:
	if anim_name == "Death":
		call_deferred("queue_free")


func _on_animation_finished(anim_name:String):
	if anim_name == "Death":
		call_deferred("queue_free")

func _enter_stagger() -> void:
	if _is_staggered: return
	_is_staggered  = true
	_stagger_timer = _stagger_time
	_current_move   = "" 
	_attack_active  = false
	sm.travel("StandToKneel")       
	nav_agent.set_physics_process(false)
	_next_stagger_hp = max(_next_stagger_hp - int(max_health * 0.25), 0)

func _update_stagger(delta: float) -> void:
	if not _is_staggered:
		return
	_stagger_timer -= delta
	if _stagger_timer > 0:
		_update_hp_bar()
		return
	_is_staggered = false
	sm.travel("KneelToStand")
	nav_agent.set_physics_process(true)
	_queue_hurricane()

func _queue_hurricane() -> void:
	# push a desperation move right after recovery
	_current_move = "HurricaneKick"
	_do_despair_combo()     # or whatever you named the HK function


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
#func take_damage(amount : int) -> void:
#	if invincible: return
#	if not is_host: return
#	health = clamp(health - amount, 0, max_health)
#	emit_signal("health_changed", health)
#	if health == 0:
#		emit_signal("died") 
#		_die()

func _update_hp_bar():
	hp_bar.value = health

func _die():
	sm.travel("Death")
	emit_signal("anim_changed", "Death")
	set_physics_process(false)
	nav_agent.set_enabled(false)

## ───────────────  Utilities  ─────────────── ##
func get_current_anim() -> String:
	return sm.get_current_node()
	

# ─── Hit-flash ───────────────────────────────────────────
func _flash_hit() -> void:
	var mat = boss_mesh.get_active_material(0)
	if mat is SpatialMaterial:
		mat.albedo_color = Color(1,0.25,0.25)
		yield(get_tree().create_timer(0.08), "timeout")
		mat.albedo_color = _orig_albedo

func _emit_hit_particles() -> void:
	hit_particles.emitting = false
	hit_particles.emitting = true

func _play_hit_sfx() -> void:
	hit_sfx.pitch_scale = 1.0 + rand_range(-0.1, 0.1)
	hit_sfx.play()

func _react_to_hit() -> void:
	_flash_hit()
	_emit_hit_particles()
	_play_hit_sfx()

# ----- AI enable flag -----
func freeze_ai() -> void:
	_ai_enabled = false

func unfreeze_ai() -> void:
	_ai_enabled = true
