extends Node

func _ready():
	# now that we’re in the Arena scene, actually spawn everything
	PlayroomManager.start_match()
