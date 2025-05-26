extends Node

onready var vp = $ViewportContainer/Viewport

func _ready():
	vp.size_override_stretch = true
	vp.size_override = $ViewportContainer.rect_size
