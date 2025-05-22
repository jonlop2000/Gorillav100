extends Control
const MIN_PLAYERS := 2
onready var list = $PlayerList
onready var btnStart = $StartButton
onready var btnReady = $ReadyButton
onready var lblWait  = $WaitingLabel

var Playroom = JavaScript.get_interface("Playroom")

func _ready():
	btnStart.visible = Playroom.isHost()
	btnStart.disabled = true
	lblWait.visible = not Playroom.isHost()

	# fill current room
	for st in Playroom.room().players:
		_add_row(st)

	PlayroomManager.connect("player_ready_changed", self, "_on_ready_changed")
	PlayroomManager.connect("match_started",        self, "_on_match_started")

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
	var all_ready := true
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
