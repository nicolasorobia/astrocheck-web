class_name MissionComplete
extends CanvasLayer
## End screen: appears once every lunar sample has been collected (by the player or by
## Perseverance). Shows how many surface days it took, then sends the
## astronaut home (back to the main menu).

@export var delay := 2.5                ## Seconds after the last sample before the screen appears.
@export var main_menu_scene := "res://ui/main_menu.tscn"
@export var sound: AudioStream = preload("uid://yrwbhd8xu0bx")   # achievement.wav

const T_BTN := preload("uid://byidglunp2u4s")         # ShockFrame Input/Btn.png
const T_BTN_HOVER := preload("uid://d4bfrjs34nfmu")   # ShockFrame Input/Btn - hovered.png
const DESIGN := Vector2(1920, 1080)
const TEXT := Color(0.86, 0.97, 1.0)
const CYAN := Color(0.55, 0.95, 1.0)
const DIM := Color(0.55, 0.95, 1.0, 0.7)
const GREEN := Color(0.4, 0.95, 0.55)

const MESSAGE := "You were able to manage your health and collect all samples in %s. Your performance gave us great data in how to prepare future astronauts for the longer expeditions ahead as we get closer in reaching out further into our solar system.\n\nPrepare for extraction and let's get you home, explorer."

var _total := 0
var _done := 0
var _by_rover := 0
var _start_ms := 0
var _shown := false
var _root: Control
var _stage: Control
var _player: Node


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()
	layer = 45
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = get_parent()
	_hook_samples.call_deferred()


func _hook_samples() -> void:
	for n in get_tree().get_nodes_in_group("sample_rock"):
		_total += 1
		(n as Interactable).completed.connect(_on_sample)


func _on_sample(by: Node) -> void:
	_done += 1
	if by and by.is_in_group("rover"):
		_by_rover += 1
	if _done >= _total and _total > 0 and not _shown:
		_shown = true
		get_tree().create_timer(delay).timeout.connect(_show)


func _show() -> void:
	_record()
	# The astronaut's work is done: stop the controls, close any menu, hide the HUD.
	var menu := _player.get_node_or_null("PauseMenu")
	if menu and menu.has_method("is_open") and menu.is_open():
		menu.close()
	GameSettings.controls_locked = true
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	var hud := _player.get_node_or_null("HUD") as CanvasLayer
	if hud:
		hud.visible = false
	for toasts in get_tree().get_nodes_in_group("notifications"):
		(toasts as Control).visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build()
	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 1.2)
	if sound:
		var sfx := AudioStreamPlayer.new()
		sfx.bus = &"SFX"
		sfx.stream = sound
		add_child(sfx)
		sfx.play()


## Logs this expedition to the STATS page (saved in user://, survives restarts).
func _record() -> void:
	var bio := get_tree().get_first_node_in_group("biometrics") as Biometrics
	var r := _player.get_node_or_null("MedicalRescue")
	ExpeditionLog.record({
		"days": bio.mission_day if bio else 1,
		"rescues": int(r.get("rescues")) if r else 0,
		"heat_rescues": int(r.get("heat_rescues")) if r else 0,
		"samples": _total,
		"rover_samples": _by_rover,
		"player_samples": _done - _by_rover,
		"play_seconds": (Time.get_ticks_msec() - _start_ms) / 1000.0,
		"steps": roundi(bio.total_steps) if bio else 0,
		"game_seconds": bio.sim_seconds if bio else 0.0,
	})


func _days_text() -> String:
	var bio := get_tree().get_first_node_in_group("biometrics") as Biometrics
	var days := bio.mission_day if bio else 1
	return "%d day" % days if days == 1 else "%d days" % days


func _build() -> void:
	var font := ThemeDB.fallback_font
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.02, 0.04, 0.82)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	_stage = Control.new()
	_stage.size = DESIGN
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_stage)
	_root.resized.connect(_fit)
	_fit.call_deferred()

	var box := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.01, 0.06, 0.08, 0.96)
	sb.border_color = Color(CYAN, 0.45)
	sb.set_border_width_all(2)
	sb.border_width_top = 6
	sb.border_color = Color(CYAN, 0.6)
	box.add_theme_stylebox_override("panel", sb)
	box.position = Vector2(330, 150)
	box.size = Vector2(1260, 730)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(box)

	_add_label("MISSION COMPLETE", 72, CYAN, Vector2(330, 195), 1260)
	_add_label("ALL %d LUNAR SAMPLES COLLECTED" % _total, 32, GREEN, Vector2(330, 290), 1260)

	_add_label(MESSAGE % _days_text(), 34, TEXT, Vector2(420, 370), 1080, 330.0)

	var btn := Button.new()
	btn.text = "RETURN TO MAIN MENU"
	btn.position = Vector2(760, 770)
	btn.size = Vector2(400, 72)
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_override("font", font)
	btn.add_theme_font_size_override("font_size", 30)
	for state in ["normal", "focus", "disabled"]:
		btn.add_theme_stylebox_override(state, _tex(T_BTN))
	btn.add_theme_stylebox_override("hover", _tex(T_BTN_HOVER))
	btn.add_theme_stylebox_override("pressed", _tex(T_BTN_HOVER))
	btn.add_theme_color_override("font_color", TEXT)
	btn.add_theme_color_override("font_hover_color", Color(0.02, 0.09, 0.12))
	btn.add_theme_color_override("font_pressed_color", Color(0.02, 0.09, 0.12))
	btn.pressed.connect(_to_main_menu)
	_stage.add_child(btn)


## height > 0: word-wrapped block of that height.
func _add_label(text: String, fs: int, col: Color, pos: Vector2, width: float, height := 0.0) -> Label:
	var l := Label.new()
	if height > 0.0:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(width, 0)
	l.text = text
	l.position = pos
	l.size = Vector2(width, height if height > 0.0 else fs * 1.4)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", col)
	_stage.add_child(l)
	return l


func _tex(t: Texture2D) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = t
	return sb


func _fit() -> void:
	var sz := _root.size
	var k := minf(sz.x / DESIGN.x, sz.y / DESIGN.y)
	_stage.scale = Vector2(k, k)
	_stage.position = (sz - DESIGN * k) * 0.5


func _to_main_menu() -> void:
	GameSettings.controls_locked = false
	GameSettings.save_settings()
	get_tree().change_scene_to_file(main_menu_scene)
