extends KinematicBody

# ——— exports & internal state ———
export (float) var speed = 8.0
export (float) var jump_speed = 12.0
export (float) var gravity = -24.0
export (int) var max_health = 100
export (float) var mouse_sensitivity = 0.002
export (float) var roll_speed = 15.0
export (float) var roll_duration = 0.8
export(bool) var is_server = false

var health = max_health
var velocity = Vector3.ZERO
var _pending_dir = Vector3.ZERO
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
	print("Player initializing - ID: ", name)
	# only the owner should own the camera & capture the mouse
	if is_owner:
		print("Setting up owner player: ", name)
		player_camera.current = true
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		# remote players never grab focus
		print("Setting up remote player: ", name)
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
	if is_dead:
		return
	
	if is_owner and event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		print("Processing mouse input for player: ", name)
		rotate_y(-event.relative.x * mouse_sensitivity)
		_camera_pitch = clamp(
			_camera_pitch + event.relative.y * mouse_sensitivity,
			pitch_min, pitch_max
		)
		camera_mount.rotation.x = _camera_pitch
	
func apply_remote_move(data:Dictionary) -> void:
	print("Received remote move for player: ", name, " data: ", data)
	_pending_dir = Vector3(data["x"], 0, data["z"])
	# Movement will be processed in _physics_process

func _physics_process(delta):
	if is_dead:
		return

	# Debug info
	var is_host = playroom.Playroom.isHost()
	print("Player physics: ", name, " is_owner: ", is_owner, " is_host: ", is_host)

	# Handle movement for owner player
	if is_owner:
		var dir = Vector3(
			Input.get_action_strength("move_left")  - Input.get_action_strength("move_right"),
			0,
			Input.get_action_strength("move_fwd")   - Input.get_action_strength("move_back")
		)
		
		# If we're not the host, send movement to host
		if not is_host:
			_send_inputs_to_host(dir)
			print("Client sending movement to host")
		else:
			print("Host processing local movement")
		
		# Apply movement locally
		if dir.length() > 0.01:
			_do_jogfwd()
			velocity.x = dir.x * speed
			velocity.z = dir.z * speed
		else:
			velocity.x = lerp(velocity.x, 0, 0.2)
			velocity.z = lerp(velocity.z, 0, 0.2)
			_do_idle()
		
		# Apply gravity
		if not is_on_floor():
			velocity.y += gravity * delta
		else:
			velocity.y = 0
			
		velocity = move_and_slide(velocity, Vector3.UP)
		
		# If we're host, update state immediately
		if is_host:
			var pos = global_transform.origin
			var state_key = "player." + name
			var player_state = {
				"pos": {"x": pos.x, "y": pos.y, "z": pos.z},
				"rot": rotation.y
			}
			playroom.Playroom.setState(state_key, player_state)
			print("Host updating own state - key:", state_key, " state:", player_state)
	else:
		# Non-owner players are updated via state synchronization
		if not is_host:
			# Get state from room state
			var state_key = "player." + name
			var player_state = playroom.Playroom.getState(state_key)
			print("Non-owner checking state - key:", state_key, " state:", player_state)
			
			if player_state and player_state.has("pos"):
				var pos = player_state["pos"]
				var target_pos = Vector3(pos.x, pos.y, pos.z)
				global_transform.origin = global_transform.origin.linear_interpolate(target_pos, 0.3)
				if player_state.has("rot"):
					rotation.y = player_state["rot"]
		
	# Process pending movement from remote RPCs (for host)
	if is_host and not is_owner and _pending_dir.length() > 0:
		print("Host processing pending movement for: ", name, " dir: ", _pending_dir)
		if _pending_dir.length() > 0.01:
			_do_jogfwd()
			velocity.x = _pending_dir.x * speed
			velocity.z = _pending_dir.z * speed
		else:
			velocity.x = lerp(velocity.x, 0, 0.2)
			velocity.z = lerp(velocity.z, 0, 0.2)
			_do_idle()
		
		# Apply gravity
		if not is_on_floor():
			velocity.y += gravity * delta
		else:
			velocity.y = 0
			
		velocity = move_and_slide(velocity, Vector3.UP)
		
		# Update state after processing movement
		var pos = global_transform.origin
		var state_key = "player." + name
		var player_state = {
			"pos": {"x": pos.x, "y": pos.y, "z": pos.z},
			"rot": rotation.y
		}
		playroom.Playroom.setState(state_key, player_state)
		print("Host updating remote player state - key:", state_key, " state:", player_state)
		
		# Reset pending direction
		_pending_dir = Vector3.ZERO

func _send_inputs_to_host(dir:Vector3):
	print("Sending inputs to host: ", dir)
	playroom.send_rpc("move", {"x":dir.x, "z":dir.z})
	if Input.is_action_just_pressed("jump"):
		playroom.send_rpc("jump", {})
	if Input.is_action_just_pressed("punch"):
		playroom.send_rpc("punch", {})
	if Input.is_action_just_pressed("hook"):
		playroom.send_rpc("hook", {})
	if Input.is_action_just_pressed("roll"):
		playroom.send_rpc("roll", {})

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
