extends KinematicBody

# ——— exports & internal state ———
export (float) var speed = 8.0
export (float) var jump_speed = 12.0
export (float) var gravity = -24.0
export (int) var max_health = 100
export (float) var mouse_sensitivity = 0.002
export (float) var roll_speed = 15.0
export (float) var roll_duration = 0.8

var health = max_health
var velocity = Vector3.ZERO
var _camera_pitch = 0.0
var pitch_max = deg2rad(80)
var pitch_min = deg2rad(-80)
var _roll_dir = Vector3.ZERO
var _roll_timer = 0.0
var current_attack_damage = 20
var is_dead = false
var is_owner := false
var _last_move_dir := Vector3.ZERO
var _move_rpc_timer :=  0.0
var _remote_move_timeout := 0.0  # Track time since last remote movement
const MOVE_RPC_INTERVAL := 0.1
const REMOTE_MOVE_TIMEOUT := 0.3  # Time after which to stop remote movement

# ——— cached nodes ———
onready var camera_mount = $camera_mount
onready var player_camera = $camera_mount/Camera
onready var spectator_camera = get_tree().get_root().get_node("prototype/SpectatorCamera")
onready var tree = $visuals/Soldier/AnimationTree
onready var sm = tree.get("parameters/StateMachine/playback")
onready var hit_area = $visuals/Soldier/Armature/Skeleton/BoneAttachment/HitArea
onready var anim_player = $visuals/Soldier/AnimationPlayer
onready var playroom = get_node("/root/PlayroomManager")

const TS_PATH = "parameters/TS/scale"

signal health_changed(new_health)

func _ready():
	# only the owner should own the camera & capture the mouse
	if is_owner:
		player_camera.current = true
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		# remote players never grab focus
		player_camera.current = false
	spectator_camera.current = false
	tree.active = true
	sm.travel("Idle")
	anim_player.get_animation("Death").loop = false
	anim_player.connect("animation_finished", self, "_on_animation_finished")
	hit_area.monitoring = false
	hit_area.connect("body_entered", self, "_on_hit_area_body_entered")
	
	# Make sure player is in the players group
	if not is_in_group("players"):
		add_to_group("players")
	
	velocity = Vector3.ZERO # Reset velocity on spawn
	print("Player ready – ID: ", name, " owner? ", is_owner)


func _unhandled_input(event):
	if event is InputEventKey and event.scancode == KEY_ESCAPE and event.is_pressed():
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		get_tree().set_input_as_handled()
	
func _input(event):
	if is_dead or Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_camera_pitch = clamp(
			_camera_pitch + event.relative.y * mouse_sensitivity,
			pitch_min, pitch_max
		)
		camera_mount.rotation.x = _camera_pitch
	
func _physics_process(delta):
	if is_dead:
		return
	if is_owner or Engine.editor_hint:
		_handle_input_and_send_rpcs(delta)
		return
	
	# For remote players, gradually slow down if no movement updates received
	_remote_move_timeout += delta
	if _remote_move_timeout > REMOTE_MOVE_TIMEOUT:
		velocity.x = lerp(velocity.x, 0, 0.2)
		velocity.z = lerp(velocity.z, 0, 0.2)
		if velocity.length() < 0.1:
			velocity = Vector3.ZERO
			_do_idle()
	
	velocity = move_and_slide(velocity, Vector3.UP)


func _handle_input_and_send_rpcs(delta):
	var current = sm.get_current_node()
	var busy_states = ["StandToRoll","Hit","Death"]
	if not busy_states.has(current):
		if Input.is_action_just_pressed("jump"):
			velocity.y = jump_speed
			sm.travel("Jump")
			playroom.send_rpc("jump", {})
			return
		elif Input.is_action_just_pressed("punch"):
			print("   • punch pressed!")
			_do_punch()
			playroom.send_rpc("punch", {})
			return
		elif Input.is_action_just_pressed("hook"):
			_do_hook()
			playroom.send_rpc("hook", {})
			return
		elif Input.is_action_just_pressed("roll"):
			_roll_dir = transform.basis.z
			_roll_timer = roll_duration
			velocity = _roll_dir * roll_speed
			sm.travel("StandToRoll")
			playroom.send_rpc("roll", {})
			return
	if _roll_timer > 0.0:
		_roll_timer -= delta
		velocity = _roll_dir * roll_speed
		move_and_slide(velocity, Vector3.UP)
		if _roll_timer <= 0.0:
			var dir = Vector3(
				Input.get_action_strength("move_left")  - Input.get_action_strength("move_right"),
				0,
				Input.get_action_strength("move_fwd")   - Input.get_action_strength("move_back")
			).normalized()
			if dir != Vector3.ZERO:
				_do_jogfwd()
				velocity = transform.basis.xform(dir) * speed
			else:
				_do_idle()
				velocity = Vector3.ZERO
		return
	if busy_states.has(current):
		move_and_slide(velocity, Vector3.UP)
		return
	if not is_on_floor():
		velocity.y += gravity * delta
	else:
		velocity.y = 0
	var dir = Vector3(
		Input.get_action_strength("move_left")  - Input.get_action_strength("move_right"),
		0,
		Input.get_action_strength("move_fwd")   - Input.get_action_strength("move_back")
	).normalized()
	if dir != Vector3.ZERO:
		_do_jogfwd()
		velocity = transform.basis.xform(dir) * speed
	else:
		velocity.x = lerp(velocity.x, 0, 0.2)
		velocity.z = lerp(velocity.z, 0, 0.2)
		_do_idle()
	
	_move_rpc_timer += delta
	if _move_rpc_timer >= MOVE_RPC_INTERVAL or dir != _last_move_dir:
		_move_rpc_timer = 0
		_last_move_dir = dir
		playroom.send_rpc("move", { "x": dir.x, "z": dir.z })
	
	velocity = move_and_slide(velocity, Vector3.UP)
	
func _travel(state_name: String, speed: float = 1.0) -> void:
	tree.set_deferred(TS_PATH, speed)
	sm.travel(state_name)
	
func _do_jogfwd():
	_travel("JogFwd", 1.0)
	
func _do_idle():
	if not ["Punch","Hook"].has(sm.get_current_node()):
		_travel("Idle", 1.0)
	else:
		tree.set_deferred(TS_PATH, 1.6)
	
func _do_punch():
	_travel("Punch", 1.6)
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	hit_area.monitoring = false
	_travel("Idle", 1.0)
	
func _do_hook():
	_travel("Hook", 1.6)
	hit_area.monitoring = true
	yield(anim_player, "animation_finished")
	hit_area.set_deferred("monitoring", false)
	
func _on_hit_area_body_entered(body):
	if body.is_in_group("boss"):
		body.take_damage(current_attack_damage)
		hit_area.set_deferred("monitoring", false)

func take_damage(amount: int) -> void:
	health = max(health - amount, 0)
	emit_signal("health_changed", health)
	if health == 0 and not is_dead:
		is_dead = true
		tree.active = false
		hit_area.monitoring = false
		anim_player.play("Death", 0.1, 1.0)
		yield(anim_player, "animation_finished")
		_start_spectating()
		queue_free()
	elif health > 0:
		sm.travel("Hit")

	
func _on_animation_finished(anim_name: String):
	print("🎬 _on_animation_finished fired for: ", anim_name)
	if is_dead and anim_name == "Death":
		print("✔️ Death clip done; switching to spectate and freeing player.")
		_start_spectating()
		queue_free()
	
func _start_spectating() -> void:
	player_camera.current = false
	spectator_camera.current = true
	
	for p in get_tree().get_nodes_in_group("players"):
		if p != self and p.health > 0:
			spectator_camera.global_transform = p.camera_mount.global_transform
			return
		
	spectator_camera.global_transform = camera_mount.global_transform
	
	
#--RPCs for playroommanager --
# — RPC entry-points, called by PlayroomManager when an RPC arrives ——

func remote_jump():
	velocity.y = jump_speed
	sm.travel("Jump")

func remote_do_punch():
	_travel("Punch", 1.6)
	yield(anim_player, "animation_finished")
	_travel("Idle", 1.0)

func remote_do_hook():
	_travel("Hook", 1.6)
	yield(anim_player, "animation_finished")
	_travel("Idle", 1.0)

func remote_roll():
	_roll_dir   = -transform.basis.z
	_roll_timer = roll_duration
	velocity    = _roll_dir * roll_speed
	sm.travel("StandToRoll")

func apply_remote_move(data:Dictionary):
	var rd = Vector3(data.x, 0, data.z)
	# Only apply movement if there's actual input
	if rd.length_squared() > 0.01:
		velocity = transform.basis.xform(rd) * speed
		_travel("JogFwd", 1.0)
	else:
		velocity = Vector3.ZERO
		_do_idle()
	_remote_move_timeout = 0.0  # Reset timeout when movement received
