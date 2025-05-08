extends CanvasLayer

export(NodePath) var player_path

onready var player = get_node(player_path)
onready var health_bar = $HUDContainer/HealthBarRow/HealthBar

func _ready():
	health_bar.min_value = 0
	health_bar.max_value = player.max_health
	health_bar.value = player.health
	
	if player.has_signal("health_changed"):
		player.connect("health_changed", self, "_on_health_changed")
	
func _on_health_changed(new_health: int) -> void:
	health_bar.value = new_health
