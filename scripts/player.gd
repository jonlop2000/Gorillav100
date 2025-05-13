extends KinematicBody

var Playroom = JavaScript.get_interface("Playroom")
# ────────────────────────────────────────────────────────────────────
#  Tunables
# ────────────────────────────────────────────────────────────────────
const BUSY_STATES = ["StandToRoll", "Punch", "Hook", "Hit", "Death"]

export var move_speed : float = 8.0
export var jump_speed : float = 12.0
export var gravity : float = -24.0
export var mouse_sensitivity : float = 0.002
export var roll_speed : float = 15.0
export var roll_time : float = 0.8
export(int) var max_health := 100
onready var _tree : AnimationTree = $visuals/Soldier/AnimationTree
onready var _sm : AnimationNodeStateMachinePlayback = _tree.get("parameters/StateMachine/playback")

var _prev_pos : Vector3 = Vector3.ZERO
var _current_anim : String = ""
var _smoothed_speed : float = 0.0      # shared by both local & remote
var _current_state : String = ""
var health := max_health
# ────────────────────────────────────────────────────────────────────
#  Public flags set by PlayroomManager
# ────────────────────────────────────────────────────────────────────
var is_local : bool = false       
var profile_color : Color = Color.white    

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

signal health_changed(hp)

func _ready():
	_tree.active = true        
	_travel("Idle")  

func _notification(what):
	if what == MainLoop.NOTIFICATION_WM_FOCUS_OUT:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	elif what == MainLoop.NOTIFICATION_WM_FOCUS_IN:
		# wait for click to re‑capture
		pass

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
	# ── 1. If the mouse is *not* captured, grab it on the next click ──
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseButton and event.pressed:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		return              # ignore all other input until locked again
	# ── 2. Normal look‑around when we do have pointer‑lock ──
	if event is InputEventMouseMotion:
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
	# WASD → world‑space direction
	var dir = Vector3(
		Input.get_action_strength("move_right")  - Input.get_action_strength("move_left"),
		0,
		Input.get_action_strength("move_back")   - Input.get_action_strength("move_fwd")
	).normalized()
	dir = -global_transform.basis.z * dir.z + -global_transform.basis.x * dir.x
	print("dir:", dir, "state:", _current_state)

	# Ignore movement/attacks while an uninterruptible anim is playing
	if BUSY_STATES.has(_current_state):
		if is_local:
			print("Locked by busy state:", _current_state)
		_velocity = move_and_slide(_velocity, Vector3.UP)
		return

	# ── attacks ─
	if Input.is_action_just_pressed("punch"):
		_do_punch()
		return
	elif Input.is_action_just_pressed("hook"):
		_do_hook()
		return

	# ── roll ──
	if Input.is_action_just_pressed("roll"):
		_pending_roll = true
		_roll_timer   = roll_time
		_travel("StandToRoll")

	if _pending_roll:
		_handle_roll(delta)
	else:
		_velocity.x = dir.x * move_speed
		_velocity.z = dir.z * move_speed
		# jump / gravity
		if is_on_floor():
			if Input.is_action_just_pressed("jump"):
				_velocity.y = jump_speed
		else:
			_velocity.y += gravity * delta
	_velocity = move_and_slide(_velocity, Vector3.UP)
	# update smoothed speed for FSM
	var raw_speed = Vector3(_velocity.x, 0, _velocity.z).length()
	_smoothed_speed = lerp(_smoothed_speed, raw_speed, delta * 10.0)

# ────────────────────────────────────────────────────────────────────
#  Remote avatar helper – estimate velocity for animations
# ────────────────────────────────────────────────────────────────────
func _calc_remote_velocity(delta):
	var new_pos   = global_transform.origin
	var frame_v   = (new_pos - _prev_pos) / max(delta, 0.0001)
	_prev_pos     = new_pos
	_velocity   = frame_v

	var raw_speed = Vector3(frame_v.x, 0, frame_v.z).length()
	_smoothed_speed = lerp(_smoothed_speed, raw_speed, delta * 10.0)
	
# ────────────────────────────────────────────────────────────────────
#  Rolling Coroutine
# ────────────────────────────────────────────────────────────────────
func _handle_roll(delta):
	_roll_timer -= delta
	if _roll_timer <= 0.0:
		_pending_roll = false
		_travel("Idle")
		return

	var fwd = -global_transform.basis.z
	_velocity = fwd * roll_speed
	_velocity.y += gravity * delta
	_velocity   = move_and_slide(_velocity, Vector3.UP)

# ────────────────────────────────────────────────────────────────────
#  Animation via AnimationTree StateMachine
# ────────────────────────────────────────────────────────────────────
func _travel(state_name : String) -> void:
	if state_name == _current_state:
		return               # avoid retriggering → no jitter
	_sm.travel(state_name)
	_current_state = state_name

func _do_punch():
	_travel("Punch")
	Playroom.RPC.call("punch", {}, Playroom.RPC.Mode.OTHERS)
	
func _do_hook():
	_travel("Hook")
	Playroom.RPC.call("hook", {}, Playroom.RPC.Mode.OTHERS)

func _update_animation(delta):
	# --- keep cache in sync ---
	var tree_state = _sm.get_current_node()
	if tree_state != _current_state:
		_current_state = tree_state

	if _pending_roll:
		_travel("StandToRoll")
		return

	if BUSY_STATES.has(_current_state):
		return
	var speed = _smoothed_speed
	if _smoothed_speed > 0.25:
		_travel("JogFwd")
	elif _smoothed_speed < 0.15:
		_travel("Idle")
