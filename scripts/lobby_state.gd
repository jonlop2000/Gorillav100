extends Control
const MIN_PLAYERS = 2
onready var list = $MarginContainer/Panel/VBoxContainer/PlayerList
onready var btnStart = $MarginContainer/Panel/VBoxContainer/HBoxContainer2/StartButton
onready var btnReady = $MarginContainer/Panel/VBoxContainer/HBoxContainer2/ReadyButton
onready var lblWait  = $MarginContainer/Panel/VBoxContainer/HBoxContainer2/WaitingLabel

var Playroom = JavaScript.get_interface("Playroom")

func _ready():
	btnStart.visible = Playroom.isHost()
	btnStart.disabled = true
	lblWait.visible  = not Playroom.isHost()
	btnReady.visible = not Playroom.isHost()

	_add_row(Playroom.me())                
	for st in Playroom.room().players:
		if str(st.id) != str(Playroom.me().id):
			_add_row(st)
	_update_start_enable()

	PlayroomManager.connect("player_ready_changed", self, "_on_ready_changed")
	PlayroomManager.connect("match_started", self, "_on_match_started")
	PlayroomManager.connect("player_joined", self, "_on_player_joined")
	PlayroomManager.connect("player_left",  self, "_on_player_left")

func _on_player_joined(id):
	var st = PlayroomManager.players[id].state
	_add_row(st)
	_update_start_enable()

func _on_player_left(id):
	for row in list.get_children():
		if row.id == id:
			row.queue_free()
	_update_start_enable()

func _add_row(st):
	var row = preload("res://ui/PlayerEntry.tscn").instance()
	row.id = str(st.id)
	row.set_name_and_avatar(st)
	row.set_ready(st.get("ready") == true)
	list.add_child(row)

func _on_ReadyButton_pressed():
	var me = Playroom.me()
	me.setState("ready", !(me.get("ready") == true))

func _on_ready_changed(id, flag):
	for row in list.get_children():
		if row.id == id:
			row.set_ready(flag)
	_update_start_enable()

func _update_start_enable():
	if not Playroom.isHost():
		return
	var all_ready = true                  # ← fix 2
	for st in Playroom.room().players:
		if st.get("ready") != true:
			all_ready = false
			break
	btnStart.disabled = !(all_ready and Playroom.room().players.size() >= MIN_PLAYERS)

func _on_StartButton_pressed():
	Playroom.setState("matchStarted", true)  # host broadcasts
	_begin_match()

func _on_match_started():
	_begin_match()

func _begin_match():
	get_tree().change_scene("res://scenes/Arena.tscn")
