extends KinematicBody

var Playroom = JavaScript.get_interface("Playroom")
# ────────────────────────────────────────────────────────────────────
#  Tunables
# ────────────────────────────────────────────────────────────────────
const BUSY_STATES = ["Punch", "Hook", "Hit", "Death"]

export var move_speed : float = 10.0
export var jump_speed : float = 10.0
export var gravity : float = -28.0
export var mouse_sensitivity : float = 0.002
export var roll_speed : float = 18.0
export var roll_time : float = 0.8
export(int) var max_health := 100
export(int) var punch_damage = 10
export(int) var hook_damage  = 25
onready var _tree : AnimationTree = $visuals/Soldier/AnimationTree
onready var _sm : AnimationNodeStateMachinePlayback = _tree.get("parameters/StateMachine/playback")

var _prev_pos : Vector3 = Vector3.ZERO
var _current_anim : String = ""
var _smoothed_speed : float = 0.0      # shared by both local & remote
var _current_state : String = ""
var health := max_health

var _kb_vel: Vector3 = Vector3.ZERO
var _kb_timer: float = 0.0
var _recover_after_kb: bool = false

# ────────────────────────────────────────────────────────────────────
#  Public flags set by PlayroomManager
# ────────────────────────────────────────────────────────────────────
var is_local : bool = false       
var profile_color : Color = Color.white    

# ────────────────────────────────────────────────────────────────────
#  Internal state
# ────────────────────────────────────────────────────────────────────
var _velocity : Vector3  = Vector3.ZERO
var _roll_timer  : float    = 0.0
var _roll_dir   := Vector3.ZERO
var _roll_elapsed_bias  = 0.0
var _remote_roll_timer := 0.0
var _remote_roll_dir   := Vector3.ZERO
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
	# —— KNOCKBACK OVERRIDE ——
	if _kb_timer > 0.0:
		_kb_timer -= delta
		# apply the impulse + gravity
		_velocity = _kb_vel + Vector3(0, -9.8 * delta, 0)
		_velocity = move_and_slide(_velocity, Vector3.UP)
		
		if _kb_timer <= 0.0 and _recover_after_kb:
			_recover_after_kb = false
			
		return   # skip all your normal movement & interp

	if is_local:
		_local_movement(delta)
	else:
		if _remote_roll_timer > 0.0:
			_simulate_remote_roll(delta)      # simulate first, then skip lerp
		else:
			_calc_remote_velocity(delta)      # normal snapshot interp
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
	# ───── 0. If we're in an un‑interruptible clip, just slide and bail ─────
	if BUSY_STATES.has(_current_state):
		_velocity = move_and_slide(_velocity, Vector3.UP)
		return

	# ───── 1. If we’re currently rolling, keep rolling and bail ─────
	if _roll_timer > 0.0:
		_roll_timer -= delta
		_velocity = _roll_dir * roll_speed
		_velocity.y += gravity * delta
		_velocity = move_and_slide(_velocity, Vector3.UP)
		if _roll_timer <= 0.0:
			# roll finished – decide Idle vs Jog for the next frame
			var dir = Vector3(
				Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
				0,
				Input.get_action_strength("move_back")  - Input.get_action_strength("move_fwd")
			).normalized()
			if dir != Vector3.ZERO:
				_travel("JogFwd")
				_velocity = transform.basis.xform(dir) * move_speed
			else:
				_travel("Idle")
				_velocity = Vector3.ZERO
		return    # ← skip everything else while rolling

	# ───── 2. NEW single‑key actions (they take precedence over movement) ─────
	if Input.is_action_just_pressed("roll"):
		_roll_dir = global_transform.basis.z       # forward
		_roll_timer = roll_time
		_travel("StandToRoll")
		var payload = {
				"dir": [_roll_dir.x, _roll_dir.y, _roll_dir.z],
				"t":   OS.get_ticks_msec()
			}
			# stringify it
		var raw = JSON.print(payload)
			# send that string
		Playroom.RPC.call("roll", raw, Playroom.RPC.Mode.OTHERS)
		return
	if Input.is_action_just_pressed("punch"):
		_do_punch()        
		return
	if Input.is_action_just_pressed("hook"):
		_do_hook()           #
		return

	# ───── 3. Normal WASD / jump movement ─────
	var dir = Vector3(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		0,
		Input.get_action_strength("move_back")  - Input.get_action_strength("move_fwd")
	).normalized()
	dir = -global_transform.basis.z * dir.z + -global_transform.basis.x * dir.x

	if dir != Vector3.ZERO:
		_velocity.x = dir.x * move_speed
		_velocity.z = dir.z * move_speed
	else:
		_velocity.x = lerp(_velocity.x, 0, 0.2)
		_velocity.z = lerp(_velocity.z, 0, 0.2)

	# gravity / jump
	if is_on_floor():
		if Input.is_action_just_pressed("jump"):
			_velocity.y = jump_speed
	else:
		_velocity.y += gravity * delta

	# move & update smoothed speed
	_velocity = move_and_slide(_velocity, Vector3.UP)
	var h_speed = Vector3(_velocity.x, 0, _velocity.z).length()
	_smoothed_speed = lerp(_smoothed_speed, h_speed, delta * 10.0)


# ────────────────────────────────────────────────────────────────────
#  Remote avatar helper – estimate velocity for animations
# ────────────────────────────────────────────────────────────────────
func _calc_remote_velocity(delta):
	var new_pos = global_transform.origin
	var frame_v = (new_pos - _prev_pos) / max(delta, 0.0001)
	_prev_pos = new_pos
	_velocity = frame_v

	var raw_speed = Vector3(frame_v.x, 0, frame_v.z).length()
	_smoothed_speed = lerp(_smoothed_speed, raw_speed, delta * 10.0)
	
# ────────────────────────────────────────────────────────────────────
#  Rolling Coroutine
# ────────────────────────────────────────────────────────────────────
func _handle_roll(delta):
	_roll_timer -= delta
	# just move you forward while rolling
	var fwd = global_transform.basis.z
	_velocity = fwd * roll_speed
	_velocity.y += gravity * delta
	_velocity = move_and_slide(_velocity, Vector3.UP)


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
	var payload = { "damage": punch_damage }
	Playroom.RPC.call("punch", JSON.print(payload), Playroom.RPC.Mode.ALL)
	
func _do_hook(): 
	_travel("Hook")
	var payload = { "damage": hook_damage }
	Playroom.RPC.call("hook", JSON.print(payload), Playroom.RPC.Mode.ALL)
	
func remote_apply_damage(amount:int) -> void:
	health = max(health - amount, 0)
	emit_signal("health_changed", health)
	if health <= 0:
		_travel("Death")
	else:
		_travel("Hit")

		
func remote_apply_knockback(dir:Vector3, force:float) -> void:
	_kb_vel   = dir * force
	_kb_timer = 0.3
	_travel("Knockback")   # or "Stagger"

# called only by the manager when someone else rolls
# called by PlayroomManager when a roll RPC arrives
func _start_remote_roll(data: Dictionary) -> void:
	if not data.has("dir") or not data.has("t"):
		return
	# extract direction and elapsed time
	var dir_array = data["dir"]             # [x,y,z]
	_remote_roll_dir = Vector3(dir_array[0], dir_array[1], dir_array[2]).normalized()
	var sent_ms = float(data["t"])
	var elapsed = clamp((OS.get_ticks_msec() - sent_ms) / 1000.0, 0.0, roll_time)
	# 1) always predict the full duration
	_remote_roll_timer = roll_time
	# 2) store how much of the roll we should skip past
	_roll_elapsed_bias = elapsed
	# 3) advance the position immediately to match host up to 'elapsed'
	#    so that when we start simulating, we're in the right spot.
#	var bias_distance = roll_speed * elapsed
#	global_transform.origin += _remote_roll_dir * bias_distance
#	_prev_pos = global_transform.origin

	# 4) switch animation/state into rolling
	_travel("StandToRoll")   # or whatever your state machine uses

# called every physics frame to simulate the remote roll
func _simulate_remote_roll(delta: float) -> void:
	if _remote_roll_timer <= 0.0:
		return
	# decrement timer
	_remote_roll_timer -= delta

	# compute how far we'd move this frame
	var frame_distance = roll_speed * delta
	# if we still have bias to consume, subtract it from this frame
	if _roll_elapsed_bias > 0.0:
		var bias_consumed = min(_roll_elapsed_bias, frame_distance)
		_roll_elapsed_bias -= bias_consumed
		frame_distance -= bias_consumed
	# after bias is gone, frame_distance is the "new" movement
	# move directly without physics collisions
	global_translate(_remote_roll_dir * frame_distance)
	# optional: you can still apply simple gravity if you need vertical arc
	# velocity.y += gravity * delta
	# global_translate(Vector3(0, velocity.y * delta, 0))
	_prev_pos = global_transform.origin

func is_remotely_rolling() -> bool:
	return _remote_roll_timer > 0.0

func _update_animation(delta):
	# --- keep cache in sync ---
	var tree_state = _sm.get_current_node()
	if tree_state != _current_state:
		_current_state = tree_state
	if _roll_timer > 0.0 or _remote_roll_timer > 0.0:
		_travel("StandToRoll")
		return
	if BUSY_STATES.has(_current_state):
		return
	var speed = _smoothed_speed
	if speed > 0.1:          # was 0.25
		_travel("JogFwd")
	elif speed < 0.05:       # was 0.15
		_travel("Idle")
