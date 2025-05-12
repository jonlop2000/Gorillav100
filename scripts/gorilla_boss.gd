extends KinematicBody

#states
enum State { IDLE, CHASE, ATTACK, RECOVER, DESPERATION }

export (int) var max_health = 2000
export (float) var move_speed = 5.0
export (float) var attack_range = 3.0
export (float) var rotation_speed = 5.0

var health = max_health
var state = State.IDLE
var state_timer = 0.0
var target = null
var current_attack_damage = 0
var is_host = false
var velocity = Vector3.ZERO

# -- move def --

var moves = {
	"Melee": {"range":3.0, "cooldown":1.0, "weight":3, "func":"_do_melee"},
	"MeleeCombo": {"range":2.5, "cooldown":2.0, "weight":2, "func":"_do_combo"},
	"360Swing": {"range":6.0, "cooldown":5.0, "weight":1, "func":"_do_swing"},
	"BattleCry": {"range":8.0, "cooldown":10.0, "weight":0.5,"func":"_do_battlecry"},
	"HurricaneKick": {"range":4.0, "cooldown":8.0, "weight":1, "func":"_do_despair_combo", "desperation_only":true}
}

onready var playroom   = get_node("/root/PlayroomManager")
onready var anim_tree = $visual/GorillaBossGD/AnimationTree
onready var sm = anim_tree.get("parameters/StateMachine/playback")
onready var nav_agent = $NavigationAgent
onready var anim_player = $visual/GorillaBossGD/AnimationPlayer
onready var hit_area = $visual/GorillaBossGD/Armature/Skeleton/BoneAttachment/HitArea
onready var hp_bar = $HealthViewport/UIRoot/Healthbar

func _ready():
	health = max_health
	hp_bar.min_value = 0
	hp_bar.max_value = max_health
	hp_bar.value = health
	
	anim_tree.active = true
	hit_area.monitoring = false
	hit_area.connect("body_entered", self, "_on_hit_area_body_entered")
	hit_area.connect("body_exited", self, "_on_hit_area_body_exited")
	sm.travel("Idle")
	randomize()
	
	# Make sure boss is in the boss group
	if not is_in_group("boss"):
		add_to_group("boss")

func _physics_process(delta):
	if is_host or Engine.editor_hint:
		_run_local_ai(delta)
	# else: remote clients do nothing here (they update via RPC callbacks)

func _run_local_ai(delta):
	state_timer = max(state_timer - delta, 0)
	target = _find_closest_player()
	var dist = INF
	if target:
		dist = global_transform.origin.distance_to(target.global_transform.origin)

	# desperation entry
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
					var choice = _choose_move(dist, state == State.DESPERATION)
					if choice:
						call_deferred(moves[choice]["func"], target)
						state_timer = moves[choice]["cooldown"]
						_enter_state(State.RECOVER)
			State.RECOVER:
				if state_timer == 0 and target:
					_enter_state(State.CHASE)
			State.DESPERATION:
				if not target:
					_enter_state(State.IDLE)
				elif dist <= attack_range:
					_enter_state(State.ATTACK)
				else:
					_enter_state(State.CHASE)

	if state == State.CHASE or state == State.DESPERATION:
		_move_toward(target.global_transform.origin, delta)
	
# -- Utility Helpers --
func _choose_move(dist, desperation):
	var pool = []
	for name in moves.keys():
		var m = moves[name]
		var allow = true
		if m.has("desperation_only") and not desperation:
			allow = false
		if dist < m["range"] and state_timer == 0 and allow:
			var mult = 1.0
			if desperation:
				mult = 1.5
			var count = int(m["weight"] * mult)
			for i in range(count):
				pool.append(name)
	# pick randomly or return null
	if pool.size() > 0:
		var idx = randi() % pool.size()
		return pool[idx]
	else:
		return null
	
	
func _find_closest_player():
	var best = null; 
	var best_d = INF
	for p in get_tree().get_nodes_in_group("players"):
		var d = global_transform.origin.distance_to(p.global_transform.origin)
		if d < best_d:
			best_d = d;
			best = p
	return best
	
	
func _on_hit_area_body_entered(body):
	if body.is_in_group("players") and body.has_method("take_damage"):
		# Prevent multiple hits at once by checking if we're already tracking this player
		var player_id = body.name
		body.take_damage(current_attack_damage)
		print("Boss hit player: ", player_id)
	
func _on_hit_area_body_exited(body):
	# Clean up tracking when player exits hit area
	if body.is_in_group("players"):
		print("Boss: player exited hit area: ", body.name)
	
	
func take_damage(amount):
	health = max(health - amount, 0)
	hp_bar.value = health
	if is_host:
		playroom.send_rpc("boss_health", {"hp": health})
	if health <= 0:
		sm.travel("Death")
		if is_host:
			playroom.send_rpc("boss_anim", {"state":"Death"})
		set_physics_process(false)
	
# -- State helpers --- #
func _enter_state(new_state):
	state = new_state
	# reset timer on Idle/Chase
	if state == State.IDLE or state == State.CHASE:
		state_timer = 0
	match state:
		State.IDLE:
			sm.travel("Idle")
			if is_host:
				playroom.send_rpc("boss_anim", {"state":"Idle"})
		State.CHASE:
			sm.travel("Run")
			if is_host:
				playroom.send_rpc("boss_anim", {"state":"Run"})
		State.ATTACK:
			pass
		State.RECOVER:
			sm.travel("KneelToStand")
			if is_host:
				playroom.send_rpc("boss_anim", {"state":"KneelToStand"})
		State.DESPERATION:
			sm.travel("BattleCry")
			state_timer = moves["BattleCry"]["cooldown"]
			if is_host:
				playroom.send_rpc("boss_anim", {"state":"BattleCry"})

	
func _move_toward(dest: Vector3, delta):
	nav_agent.set_target_location(dest)
	if nav_agent.is_navigation_finished():
		return
	var next_pt = nav_agent.get_next_location()
	var dir = (next_pt - global_transform.origin).normalized()

	# smoothly rotate
	var look_dir = dest - global_transform.origin
	look_dir.y = 0
	if look_dir.length() > 0:
		var target_rot = atan2(look_dir.x, look_dir.z)
		rotation.y = lerp_angle(rotation.y, target_rot, rotation_speed * delta)

	# move & broadcast
	move_and_slide(dir * move_speed, Vector3.UP)
	print("Boss moving to: ", global_transform.origin, " rotation: ", rotation.y)
	
	# Update room state directly for immediate sync
	playroom.Playroom.setState("boss", {
		"pos":[global_transform.origin.x, global_transform.origin.y, global_transform.origin.z],
		"rot": rotation.y
	})
	
	# Also send RPC for animation state
	playroom.send_rpc("boss_anim", {"state":"Run"})
	
	# Send move RPC for clients that might have missed the state update
	playroom.send_rpc("boss_move", {
		"pos": global_transform.origin,
		"rot": rotation.y
	})
	
# ——— remote RPC handlers ———
func remote_boss_anim(state_name:String) -> void:
	sm.travel(state_name)

func remote_boss_move(data):
	print("Received remote boss move: ", data)
	global_transform.origin = data.pos
	rotation.y = data.rot

func remote_boss_health(data):
	health = data.hp
	hp_bar.value = health
	
# -- Move implementations --
	
func _do_melee(target):
	current_attack_damage = 20
	sm.travel("Melee")
	playroom.send_rpc("boss_anim", {"state":"Melee"})
	hit_area.monitoring = true
	var finished_anim = yield(anim_player, "animation_finished")
	if finished_anim == "Melee":
		hit_area.set_deferred("monitoring", false)
	
	
func _do_combo(target):
	current_attack_damage = 35
	sm.travel("MeleeCombo")
	playroom.send_rpc("boss_anim", {"state":"MeleeCombo"})
	hit_area.monitoring = true
	var finished_anim = yield(anim_player, "animation_finished")
	if finished_anim == "MeleeCombo":
		hit_area.set_deferred("monitoring", false)
	
	
func _do_swing(target):
	sm.travel("360Swing")
	playroom.send_rpc("boss_anim", {"state":"360Swing"})
	yield(get_tree().create_timer(0.5), "timeout")
	# Get players in range and damage them safely
	var players_in_area = []
	for p in get_tree().get_nodes_in_group("players"):
		if p.health > 0 and global_transform.origin.distance_to(p.global_transform.origin) <= moves["360Swing"]["range"]:
			players_in_area.append(p)
	
	# Apply damage after collecting all valid players
	for p in players_in_area:
		if is_instance_valid(p) and p.has_method("take_damage"):
			p.take_damage(30)
			print("360Swing hit player: ", p.name)

func _do_battlecry(target):
	sm.travel("BattleCry")
	playroom.send_rpc("boss_anim", {"state":"BattleCry"})
	yield(get_tree().create_timer(0.3), "timeout")
	# e.g. slow all players
	for p in get_tree().get_nodes_in_group("players"):
		if global_transform.origin.distance_to(p.global_transform.origin) <= moves["BattleCry"]["range"]:
			p.apply_status("slowed", 2.0)

func _do_despair_combo(target):
	sm.travel("HurricaneKick")
	playroom.send_rpc("boss_anim", {"state":"HurricaneKick"})
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	hit_area.set_deferred("monitoring", false)
	if target and is_instance_valid(target) and target.has_method("take_damage"):
		target.take_damage(60)
