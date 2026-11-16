extends CanvasLayer
## In-game menu on [Tab]: the Mission Control view (live BIOMETRICS, mission briefing,
## settings, controls). [Tab] or [Esc] again, RESUME or the [X] closes it.
## The simulation does NOT pause: vitals, the rover and everything else keep running so
## the biometrics stay in sync with the field. The astronaut can still walk, sprint, jump
## and toggle the flashlight (hold right mouse to look around) to watch the readings react;
## only [E] interact is off. The menu is drawn see-through so the field stays visible.
## Won't open while something else has the game paused (resting, the crew panel) or
## during a medical rescue.

@export var main_menu_scene := "res://ui/main_menu.tscn"

var _menu: GameMenu
var _open := false


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_menu = GameMenu.new()
	_menu.mode = GameMenu.Mode.PAUSE
	_menu.visible = false
	add_child(_menu)
	_menu.resume_requested.connect(close)
	_menu.main_menu_requested.connect(_to_main_menu)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		get_viewport().set_input_as_handled()
		if _open:
			close()
		elif not get_tree().paused and not _rescue_active() and not GameSettings.controls_locked:
			open()
	elif _open and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


func open() -> void:
	_open = true
	_menu.reset_to_first_section()
	_menu.visible = true
	GameSettings.menu_open = true
	_set_hud(false)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_menu._play(_menu.confirm_sound)


func close() -> void:
	if not _open:
		return
	_open = false
	_menu.visible = false
	GameSettings.menu_open = false
	_set_hud(true)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_menu.play_cancel()
	GameSettings.save_settings()


func is_open() -> bool:
	return _open


func _exit_tree() -> void:
	GameSettings.menu_open = false


func _rescue_active() -> bool:
	var r := get_parent().get_node_or_null("MedicalRescue") as MedicalRescue
	return r != null and r.is_active()


func _to_main_menu() -> void:
	_open = false
	GameSettings.menu_open = false
	GameSettings.save_settings()
	get_tree().change_scene_to_file(main_menu_scene)


## The game HUD (bars, vitals, compass) is hidden behind the menu so it doesn't clash.
func _set_hud(on: bool) -> void:
	var hud := get_parent().get_node_or_null("HUD") as CanvasLayer
	if hud:
		hud.visible = on
	for toasts in get_tree().get_nodes_in_group("notifications"):
		(toasts as Control).visible = on
