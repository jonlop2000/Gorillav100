extends Camera

var enabled := false setget set_enabled

func set_enabled(v):
	if v:
		# only allow *local* players to enable spectator
		if not get_parent().is_local:
			return
		enabled = true
	else:
		# always allow disabling
		enabled = false

	# flip the Camera.current flag to match
	current = enabled

	# cursor mode
	if enabled:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _input(event):
	if not enabled:
		return
	# TODO: your free-fly input here

func _process(delta):
	if not enabled:
		return
	# TODO: your free-fly movement here
