extends KinematicBody

var Playroom = JavaScript.get_interface("Playroom")
# ────────────────────────────────────────────────────────────────────
#  Tunables
# ────────────────────────────────────────────────────────────────────
const BUSY_STATES = ["Punch", "Hook", "Hit", "Death", "KnockBack"]

export var move_speed : float = 10.0
export var jump_speed : float = 6.0
export var gravity : float = -30.0
export var mouse_sensitivity : float = 0.002
export var roll_speed : float = 4.0
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
var _send_timer := 0.0
var _kb_vel: Vector3 = Vector3.ZERO
var _kb_timer: float = 0.0
var _jump_timer: float = 0.0
var _recover_after_kb: bool = false
var _remote_roll_start : Vector3
var _remote_roll_end   : Vector3
var _remote_roll_elapsed : float = 0.0
var _recover_after_roll    = false
var _jump_buffered := false

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
var _camera_pitch    : float    = 0.0
const _pitch_min     : float    = deg2rad(-80)
const _pitch_max     : float    = deg2rad( 60)
const PLAYER_SEND_RATE := 1.0 / 30.0
const JUMP_DURATION := 0.967     # total airtime, roughly = 2 * jump_speed / -gravity
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
	_update_animation(delta)
	# Jump override
	if _jump_timer > 0.0:
		_jump_timer -= delta
		# apply jump physics
		_velocity.y += gravity * delta
		_velocity = move_and_slide(_velocity, Vector3.UP)
		if _jump_timer <= 0.0:
			_travel("Idle")
		return
	
	if _kb_timer > 0.0:
		_kb_timer -= delta
		_velocity = _kb_vel + Vector3(0, -9.8 * delta, 0)
		_velocity = move_and_slide(_velocity, Vector3.UP)
		return
	if _current_state == "KnockBack":
		return
	# —— ROLL OVERRIDE ——
	if _roll_timer > 0.0:
		_roll_timer -= delta
		# full, deterministic roll movement
		var v = _roll_dir * roll_speed
		v.y += gravity * delta
		_velocity = move_and_slide(v, Vector3.UP)

		# once it finishes, zero out and flag recovery if needed
		if _roll_timer <= 0.0:
			_velocity = Vector3.ZERO
			_recover_after_roll = true
		return    # skip the rest of _physics_process while rolling

	# Local vs Remote movement
	if is_local:
		_local_movement(delta)
	else:
		_calc_remote_velocity(delta)


	# ─── Throttle & send per-axis state (non-host only) ──────────────
	if is_local and not Playroom.isHost():
		_send_timer += delta
		if _send_timer >= PLAYER_SEND_RATE:
			_send_timer -= PLAYER_SEND_RATE

			var me_state = Playroom.me()
			var p        = global_transform.origin
			var yaw      = rotation.y

			me_state.setState("px",  p.x)
			me_state.setState("py",  p.y)
			me_state.setState("pz",  p.z)
			me_state.setState("rot", yaw)

# ────────────────────────────────────────────────────────────────────
#  Local‑player movement & jumping
# ────────────────────────────────────────────────────────────────────
func _local_movement(delta):
	# ───── 0. If we're in an un‑interruptible clip, just slide and bail ─────
	if BUSY_STATES.has(_current_state):
		_velocity = move_and_slide(_velocity, Vector3.UP)
		return
	if Input.is_action_just_pressed("jump") and is_on_floor():
		_jump_buffered = true
	# ───── 1. If we’re currently rolling, keep rollsing and bail ─────
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
		var forward = global_transform.basis.z.normalized()
		_roll_dir = forward
		var payload = {
			"dir": [forward.x, forward.y, forward.z],
			"t":   OS.get_ticks_msec(),
			"pos": [
				global_transform.origin.x,
				global_transform.origin.y,
				global_transform.origin.z
			]
		}
		var raw = JSON.print(payload)
		Playroom.RPC.call("roll", raw, Playroom.RPC.Mode.OTHERS)
		_begin_roll(payload)
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

	# Always apply gravity
	_velocity.y += gravity * delta

	# If the player tapped jump while in the air, queue it
	if _jump_buffered and is_on_floor():
		_jump_buffered = false
		_jump_timer = JUMP_DURATION
		_velocity.y = jump_speed
		_travel("Jump")
		Playroom.RPC.call("jump", "", Playroom.RPC.Mode.OTHERS)

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
	# no more _travel("Hit") here

func remote_apply_knockback(dir:Vector3, force:float, anim:String="KnockBack") -> void:
	_kb_vel   = dir * force
	_kb_timer = 0.3
	_travel(anim)      # now uses whatever anim you passed in

func _begin_jump() -> void:
	# same as local: start your physics timer + anim
	_velocity.y = jump_speed
	_jump_timer = JUMP_DURATION
	_travel("Jump")


func _begin_roll(data: Dictionary) -> void:
	# 4a) snap to the exact position the roller saw
	var p = data.pos
	global_transform.origin = Vector3(p[0], p[1], p[2])

	# 4b) set up your timer + direction
	var a = data.dir
	_roll_dir = Vector3(a[0], a[1], a[2])
	_roll_timer = roll_time

	# 4c) trigger your anim state
	_travel("StandToRoll")
	

func _update_animation(delta):
	# --- keep cache in sync ---
	var tree_state = _sm.get_current_node()
	if tree_state != _current_state:
		_current_state = tree_state
	if _roll_timer > 0.0:
		_travel("StandToRoll")
		return
	if BUSY_STATES.has(_current_state):
		return
	var speed = _smoothed_speed
	if speed > 0.1:          # was 0.25
		_travel("JogFwd")
	elif speed < 0.05:       # was 0.15
		_travel("Idle")
