class_name ShockFrameDialog
extends Control
## Reusable pop-up window in the ShockFrame style (the "dialog - popup 1" frame:
## title tab at the top, close [X] in the corner). Meant to be reused for the
## main menu / pause menu later.
##
## Put the window's contents under a child Control named "Content"; it is resized
## to fill the frame's inner area. Call open() / close().
## While open: the game is paused (optional), the mouse is freed, and the window
## closes with the [X], Esc, or the interact key (E).
## Sounds: confirm.wav when it opens, cancel.wav when it closes.

signal opened
signal closed

@export var frame: Texture2D = preload("uid://bq8dxr3dbgwti")  # Panels & Dialog/dialog - popup 1.png
@export var title := "DIALOG"
@export_range(0.3, 1.0) var height_fraction := 0.9   ## Window height relative to the screen.
@export var pause_game := true
@export var dim_color := Color(0, 0, 0, 0.55)       ## Darkens the game behind the window.
@export var open_sound: AudioStream = preload("uid://bpvp3snhvqjaj")   # confirm.wav
@export var close_sound: AudioStream = preload("uid://b3v3bn877sbtf")  # cancel.wav
@export var ui_volume_db := -4.0

# Areas of the frame art, in its own pixels (663 x 606).
const TITLE_RECT := Rect2(205, 6, 253, 62)
const CLOSE_RECT := Rect2(612, 10, 44, 42)
const CONTENT_RECT := Rect2(56, 92, 551, 486)
const TITLE_COLOR := Color(0.83, 1.0, 0.99)

var _scale := 1.0
var _origin := Vector2.ZERO
var _close_button: Button
var _content: Control
var _font: Font
var _sfx: AudioStreamPlayer


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS  # keeps working while the game is paused
	_font = ThemeDB.fallback_font
	_content = get_node_or_null("Content") as Control

	_close_button = Button.new()
	_close_button.flat = true
	_close_button.focus_mode = Control.FOCUS_NONE
	_close_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_close_button.pressed.connect(close)
	add_child(_close_button)

	_sfx = AudioStreamPlayer.new()
	_sfx.bus = &"SFX"
	_sfx.volume_db = ui_volume_db
	add_child(_sfx)

	resized.connect(_layout)
	visible = false
	_layout()


func open() -> void:
	if visible:
		return
	visible = true
	_layout()
	if pause_game:
		get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_play(open_sound)
	opened.emit()


func close() -> void:
	if not visible:
		return
	visible = false
	if pause_game:
		get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_play(close_sound)
	# Don't let the key press that closed the window start a new interaction.
	var interactor := get_tree().get_first_node_in_group("interactor")
	if interactor and interactor.has_method("block_until_release"):
		interactor.block_until_release()
	closed.emit()


## UI click sounds keep playing after the window hides (the player isn't hidden).
func _play(s: AudioStream) -> void:
	if s and _sfx:
		_sfx.stream = s
		_sfx.play()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("interact"):
		get_viewport().set_input_as_handled()
		close()


func _layout() -> void:
	if frame == null:
		return
	var fs := frame.get_size()
	_scale = size.y * height_fraction / fs.y
	_scale = minf(_scale, size.x * 0.95 / fs.x)
	_origin = (size - fs * _scale) * 0.5
	if _content:
		_content.position = _origin + CONTENT_RECT.position * _scale
		_content.size = CONTENT_RECT.size * _scale
	if _close_button:
		_close_button.position = _origin + CLOSE_RECT.position * _scale
		_close_button.size = CLOSE_RECT.size * _scale
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), dim_color)
	if frame == null:
		return
	draw_texture_rect(frame, Rect2(_origin, frame.get_size() * _scale), false)
	var fsz := roundi(24 * _scale)
	var text := title.to_upper()
	var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz).x
	var r := Rect2(_origin + TITLE_RECT.position * _scale, TITLE_RECT.size * _scale)
	draw_string(_font, Vector2(r.get_center().x - tw * 0.5, r.get_center().y + fsz * 0.35), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, TITLE_COLOR)
