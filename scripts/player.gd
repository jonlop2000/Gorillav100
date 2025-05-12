# player.gd  –  works with the new host‑agnostic Playroom manager
# NOTE: paths to child nodes (Camera, AnimationPlayer, etc.) may differ in
# your scene – adjust the `onready` vars if needed.

extends KinematicBody

var Playroom = JavaScript.get_interface("Playroom")
# ────────────────────────────────────────────────────────────────────
#  Tunables
# ────────────────────────────────────────────────────────────────────
export var move_speed : float = 8.0
export var jump_speed : float = 12.0
export var gravity : float = -24.0
export var mouse_sensitivity : float = 0.002
export var roll_speed : float = 15.0
export var roll_time : float = 0.8


# ────────────────────────────────────────────────────────────────────
#  Public flags set by PlayroomManager
# ────────────────────────────────────────────────────────────────────
var is_local : bool = false       # TRUE  → this client owns / controls the avatar
								  # FALSE → remote representation; movement is external
var profile_color : Color = Color.white    # set for tinting, optional


# ────────────────────────────────────────────────────────────────────
#  Internal state
# ────────────────────────────────────────────────────────────────────
var _velocity        : Vector3  = Vector3.ZERO
var _pending_roll    : bool     = false
var _roll_timer      : float    = 0.0
var _camera_pitch    : float    = 0.0
const _pitch_min     : float    = deg2rad(-80)
const _pitch_max     : float    = deg2rad( 60)

# cache children
onready var _camera_mount : Spatial = $camera_mount
onready var _camera : Camera = $camera_mount/Camera
onready var _anim : AnimationPlayer = $visuals/Soldier/AnimationPlayer


# ────────────────────────────────────────────────────────────────────
#  External initialisation helpers (called by the manager)
# ────────────────────────────────────────────────────────────────────
func make_local():
	is_local = true
	set_process_input(true)
	_camera.current = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func make_remote():
	is_local = false
	set_process_input(false)   # no local input
	_camera.current = false
	# keep _physics_process ⇒ still want to update animations


# ────────────────────────────────────────────────────────────────────
#  Input
# ────────────────────────────────────────────────────────────────────
func _input(event):
	if not is_local:
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)

		_camera_pitch = clamp(
			_camera_pitch + event.relative.y * mouse_sensitivity,
			_pitch_min, _pitch_max
		)
		_camera_mount.rotation.x = _camera_pitch


# ────────────────────────────────────────────────────────────────────
#  Main loop
# ────────────────────────────────────────────────────────────────────
func _physics_process(delta):
	if is_local:
		_local_movement(delta)
	else:
		_calc_remote_velocity(delta)   # derive velocity for animation
	_update_animation(delta)
	if is_local and not Playroom.isHost():
		var my_state = Playroom.me()          # ← 1️⃣ grab *your* player object
		my_state.setState("px", global_transform.origin.x)
		my_state.setState("py", global_transform.origin.y)
		my_state.setState("pz", global_transform.origin.z)
		my_state.setState("rot", rotation.y)

# ────────────────────────────────────────────────────────────────────
#  Local‑player movement & jumping
# ────────────────────────────────────────────────────────────────────
func _local_movement(delta):
	# basic WASD directional vector (z forward)
	var dir = Vector3(
		Input.get_action_strength("move_left")  - Input.get_action_strength("move_right"),
		0,
		Input.get_action_strength("move_back")  - Input.get_action_strength("move_fwd")
	)

	dir = dir.normalized()
	dir = -global_transform.basis.z * dir.z + -global_transform.basis.x * dir.x

	# rolling takes priority over normal movement
	if _pending_roll:
		_handle_roll(delta)
	else:
		_velocity.x = dir.x * move_speed
		_velocity.z = dir.z * move_speed

		# jumping
		if is_on_floor():
			if Input.is_action_just_pressed("jump"):
				_velocity.y = jump_speed
		else:
			_velocity.y += gravity * delta

		# start roll
		if Input.is_action_just_pressed("roll"):
			_pending_roll = true
			_roll_timer = roll_time
			_anim.play("Roll")

	_velocity = move_and_slide(_velocity, Vector3.UP)


# ────────────────────────────────────────────────────────────────────
#  Remote avatar helper – estimate velocity for animations
# ────────────────────────────────────────────────────────────────────
var _prev_pos : Vector3 = Vector3.ZERO
func _calc_remote_velocity(delta):
	var new_pos = global_transform.origin
	_velocity   = (new_pos - _prev_pos) / max(delta, 0.0001)
	_prev_pos   = new_pos


# ────────────────────────────────────────────────────────────────────
#  Rolling Coroutine
# ────────────────────────────────────────────────────────────────────
func _handle_roll(delta):
	_roll_timer -= delta
	if _roll_timer <= 0.0:
		_pending_roll = false
		return

	var fwd = -global_transform.basis.z
	_velocity = fwd * roll_speed
	_velocity.y += gravity * delta
	_velocity   = move_and_slide(_velocity, Vector3.UP)


# ────────────────────────────────────────────────────────────────────
#  Animation FSM
# ────────────────────────────────────────────────────────────────────
func _update_animation(delta):
	if _pending_roll:
		return        # Roll clip already playing

	var horizontal_vel = Vector3(_velocity.x, 0, _velocity.z).length()

	if horizontal_vel > 0.2:
		_anim.play("JogFwd")
	else:
		_anim.play("Idle")

