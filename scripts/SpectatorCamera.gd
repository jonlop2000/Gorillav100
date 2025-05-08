extends Camera 

export var move_speed := 5.0
export var look_sens := 0.002

var _pitch := 0.0

func _ready():
	current = false

func _unhandled_input(event):
	if not current:
		return
	
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.is_pressed():
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		get_tree().set_input_as_handled()


func _input(event):
	if not current:
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * look_sens)
		_pitch = clamp(_pitch - event.relative.y * look_sens, deg2rad(-80), deg2rad(80))
		rotation.x = _pitch
		
func _physics_process(delta):
	if not current:
		return
	
	var forward = -global_transform.basis.z
	var right   =  global_transform.basis.x
	
	var dir = Vector3.ZERO
	if Input.is_action_pressed("move_fwd"):
		dir += forward
	if Input.is_action_pressed("move_back"):
		dir -= forward
	if Input.is_action_pressed("move_left"):
		dir -= right
	if Input.is_action_pressed("move_right"):
		dir += right
	
	if dir != Vector3.ZERO:
		dir = dir.normalized() * move_speed * delta
	
		var nt = global_transform
		nt.origin += dir
		global_transform = nt


