# SpectatorController.gd – simple look-fly camera
extends Camera

export var look_sensitivity := 0.002   # radians per pixel
export var move_speed       := 6.0     # m/s

var _enabled := false                  # private backing field
var enabled  setget set_enabled, get_enabled   # public property

var _yaw   := 0.0
var _pitch := 0.0

func set_enabled(v: bool) -> void:
	# Enable only for the real local player; disabling is always allowed
	if v and not get_parent().is_local:
		return
	_enabled = v
	current  = v                       # toggle this Camera’s “current” flag

	if v:
		# initialize yaw/pitch from current orientation
		var basis := global_transform.basis
		_yaw   = atan2(-basis.z.x, -basis.z.z)
		_pitch = asin(basis.z.y)
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func get_enabled() -> bool:
	return _enabled

# ───── Mouse-look ─────
func _input(event):
	if not _enabled: return
	if event is InputEventMouseMotion:
		_yaw   -= event.relative.x * look_sensitivity
		_pitch -= event.relative.y * look_sensitivity
		rotation_degrees = Vector3(rad2deg(_pitch), rad2deg(_yaw), 0)

# ───── Fly movement ─────
func _process(delta):
	if not _enabled:
		return

	var dir := Vector3.ZERO
	if Input.is_action_pressed("move_fwd"):
		dir -= global_transform.basis.z        # forward
	if Input.is_action_pressed("move_back"):
		dir += global_transform.basis.z        # back
	if Input.is_action_pressed("move_left"):
		dir -= global_transform.basis.x        # strafe-left
	if Input.is_action_pressed("move_right"):
		dir += global_transform.basis.x        # strafe-right

	if dir != Vector3.ZERO:
		dir = dir.normalized() * move_speed * delta
		# Move in world space by updating the global transform
		var t := global_transform
		t.origin += dir
		global_transform = t

