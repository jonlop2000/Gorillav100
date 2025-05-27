extends Node

onready var gorilla_anim = $gorilla_boss/visual/GorillaBossGD/AnimationPlayer

func _ready():
	var panel = $UiRoot/CanvasLayer/Lobby
	PlayroomManager.register_lobby_panel(panel)
	# play the ChickenDance animation
	if gorilla_anim.has_animation("ChickenDance"):
		gorilla_anim.play("ChickenDance")
	else:
		push_error("AnimationPlayer has no 'ChickenDance' animation!")
