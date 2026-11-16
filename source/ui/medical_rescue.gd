class_name MedicalRescue
extends CanvasLayer
## Safety net (this is a training simulation, so there's no real "game over").
## If the O2 tank is empty and the astronaut collapses (stamina gone or blood oxygen
## critical) before reaching a base or outpost:
##   1. A red PRIORITY 1 alert: medical personnel have flagged your location.
##      (Core temperature reaching 43 °C, e.g. in a radiation zone, triggers it too,
##      with its own hyperthermia message: Mission Control extracts you right away.)
##   2. The screen fades to black and the astronaut is retrieved to the home base.
##   3. Vitals are reset and a message confirms health systems are optimal again.
## Only the player is frozen during this: the world (rover, collected samples)
## keeps running and keeps everything it has done since the start.

@export var critical_spo2 := 80.0       ## On an empty tank, a collapse at this SpO2...
@export var alert_time := 6.0           ## Red alert on screen before the fade.
@export var fade_time := 1.5
@export var black_time := 2.0
@export var restored_time := 5.0        ## "Health systems optimal" message after fading back in.
@export var icon: Texture2D = preload("uid://cf0fh2qk370p7")  # HUD icon - notification.png

const RED := Color(1.0, 0.3, 0.26)
const GREEN := Color(0.4, 1.0, 0.6)
const WHITE := Color(0.94, 0.97, 1.0)

enum Phase { WATCHING, ALERT, FADE_OUT, BLACK, FADE_IN, RESTORED }

var _phase := Phase.WATCHING
var _heat := false   # this rescue is for hyperthermia (not O2 / exhaustion)
var rescues := 0          ## Medical rescues this expedition (for the STATS log)...
var heat_rescues := 0     ## ...and how many of them were for hyperthermia.
var _t := 0.0
var _player: CharacterBody3D
var _vitals: Vitals
var _spawn: Transform3D
var _canvas: Control
var _font: Font
var _icons := {}  # color -> recolored icon


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS  # keeps running while the player is frozen
	_player = get_parent() as CharacterBody3D
	_vitals = _player.get_node_or_null("Vitals") as Vitals
	_spawn = _player.global_transform
	_font = ThemeDB.fallback_font
	for col in [RED, GREEN, WHITE]:
		_icons[col] = _recolor(icon, col)
	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_overlay)
	add_child(_canvas)


func is_active() -> bool:
	return _phase != Phase.WATCHING and _phase != Phase.RESTORED


func _process(delta: float) -> void:
	if get_tree().paused:
		return
	_t += delta
	match _phase:
		Phase.WATCHING:
			if _vitals and _needs_rescue():
				_begin()
		Phase.ALERT:
			if _t >= alert_time:
				_go(Phase.FADE_OUT)
		Phase.FADE_OUT:
			if _t >= fade_time:
				_retrieve()
				_go(Phase.BLACK)
		Phase.BLACK:
			if _t >= black_time:
				_set_player_frozen(false)
				_set_hud(true)
				_go(Phase.FADE_IN)
		Phase.FADE_IN:
			if _t >= fade_time:
				_go(Phase.RESTORED)
		Phase.RESTORED:
			if _t >= restored_time + 0.8:
				_phase = Phase.WATCHING
	_canvas.queue_redraw()


func _needs_rescue() -> bool:
	if _vitals.is_overheated():
		_heat = true
		return true
	_heat = false
	return _vitals.is_tank_empty() and (_vitals.is_exhausted() or _vitals.spo2 <= critical_spo2)


func _begin() -> void:
	rescues += 1
	if _heat:
		heat_rescues += 1
	var menu := _player.get_node_or_null("PauseMenu")
	if menu and menu.has_method("is_open") and menu.is_open():
		menu.close()
	_set_player_frozen(true)
	_set_hud(false)
	_go(Phase.ALERT)


func _go(p: Phase) -> void:
	_phase = p
	_t = 0.0


## Medical team brings the astronaut back to the home base, fully restored.
func _retrieve() -> void:
	_player.global_transform = _spawn
	_player.velocity = Vector3.ZERO
	var head := _player.get_node_or_null("head") as Node3D
	if head:
		head.rotation.x = 0.0
	_vitals.rest()


## Freezes only the player (movement, camera, interaction, vitals); the rest of
## the world keeps going.
func _set_player_frozen(frozen: bool) -> void:
	_player.process_mode = Node.PROCESS_MODE_DISABLED if frozen else Node.PROCESS_MODE_INHERIT


func _set_hud(on: bool) -> void:
	var hud := _player.get_node_or_null("HUD") as CanvasLayer
	if hud:
		hud.visible = on
	# Side toasts (rover updates) wait behind the emergency; they still time out normally.
	for toasts in get_tree().get_nodes_in_group("notifications"):
		(toasts as Control).visible = on


# ------------------------------------------------------------------ drawing

func _draw_overlay() -> void:
	var c := _canvas
	var sz := c.size
	var k := clampf(sz.y / 648.0, 0.8, 2.0)  # scale text with the window
	var blink := 0.5 + 0.5 * cos(_t * TAU / 1.4)
	var black := 0.0
	match _phase:
		Phase.WATCHING:
			return
		Phase.FADE_OUT:
			black = clampf(_t / fade_time, 0.0, 1.0)
		Phase.BLACK:
			black = 1.0
		Phase.FADE_IN:
			black = 1.0 - clampf(_t / fade_time, 0.0, 1.0)

	if _phase == Phase.ALERT or _phase == Phase.FADE_OUT:
		# Pulsing red wash over the scene, darker at the edges.
		c.draw_rect(Rect2(Vector2.ZERO, sz), Color(0.5, 0.0, 0.0, lerpf(0.18, 0.38, blink)))
	if black > 0.0:
		c.draw_rect(Rect2(Vector2.ZERO, sz), Color(0, 0, 0, black))

	match _phase:
		Phase.ALERT, Phase.FADE_OUT:
			var a := minf(_t * 4.0, 1.0) if _phase == Phase.ALERT else 1.0
			if _heat:
				_draw_message(sz, k, RED, lerpf(0.45, 1.0, blink) * a, "PRIORITY 1  -  CRITICAL HYPERTHERMIA", [
					"Core temperature has reached 43 °C. Radiation exposure",
					"is overheating your body to a life-threatening level.",
					"Mission Control is extracting you right away.",
				])
			else:
				_draw_message(sz, k, RED, lerpf(0.45, 1.0, blink) * a, "PRIORITY 1  -  MEDICAL EMERGENCY", [
					"O2 depleted. Your vitals have reached a critical level.",
					"Medical personnel have flagged your location",
					"and are on their way to retrieve you.",
				])
		Phase.BLACK:
			_draw_message(sz, k, WHITE, minf(_t * 2.0, 1.0), "RETRIEVED TO HOME BASE", [
				"Medical team is cooling you down and restoring your suit..." if _heat else "Medical team is restoring your suit and vitals...",
			])
		Phase.FADE_IN, Phase.RESTORED:
			var a := 1.0
			if _phase == Phase.RESTORED:
				a = 1.0 - clampf((_t - restored_time) / 0.8, 0.0, 1.0)
			_draw_message(sz, k, GREEN, a, "HEALTH SYSTEMS OPTIMAL", [
				"All vitals restored. O2 tank and stamina refilled.",
				"Your samples and the rover's progress are saved.",
			])


func _draw_message(sz: Vector2, k: float, col: Color, a: float, title: String, lines: Array) -> void:
	var c := _canvas
	var tfs := roundi(34 * k)
	var bfs := roundi(22 * k)
	var icon_s := tfs * 1.4
	var line_h := bfs + 12.0 * k
	var tw := _font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs).x
	var w := icon_s + 16.0 * k + tw
	for l: String in lines:
		w = maxf(w, _font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs).x)
	var h := icon_s + 20.0 * k + line_h * lines.size()
	var box := Rect2((sz.x - w) * 0.5 - 28.0 * k, sz.y * 0.36 - 22.0 * k, w + 56.0 * k, h + 44.0 * k)
	c.draw_rect(box, Color(0.0, 0.02, 0.04, 0.94 * a))
	c.draw_rect(Rect2(box.position, Vector2(box.size.x, 3.0 * k)), Color(col, a))
	c.draw_rect(Rect2(Vector2(box.position.x, box.end.y - 3.0 * k), Vector2(box.size.x, 3.0 * k)), Color(col, a))
	# Title row: icon + title, centered.
	var y := sz.y * 0.36
	var x := (sz.x - (icon_s + 16.0 * k + tw)) * 0.5
	c.draw_texture_rect(_icons.get(col, icon), Rect2(Vector2(x, y), Vector2(icon_s, icon_s)), false, Color(1, 1, 1, a))
	var base := Vector2(x + icon_s + 16.0 * k, y + icon_s * 0.5 + tfs * 0.36)
	c.draw_string_outline(_font, base, title, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, roundi(5 * k), Color(0, 0, 0, 0.7 * a))
	c.draw_string(_font, base, title, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, Color(col, a))
	y += icon_s + 20.0 * k
	for l: String in lines:
		var lw := _font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs).x
		var p := Vector2((sz.x - lw) * 0.5, y + bfs * 0.8)
		c.draw_string_outline(_font, p, l, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs, roundi(4 * k), Color(0, 0, 0, 0.6 * a))
		c.draw_string(_font, p, l, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs, Color(WHITE, a))
		y += line_h


## The pack's notification icon is yellow; make a copy in another color (keeps the "!").
func _recolor(t: Texture2D, col: Color) -> Texture2D:
	var img := t.get_image()
	if img == null:
		return t
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	for py in img.get_height():
		for px in img.get_width():
			var c := img.get_pixel(px, py)
			if c.a > 0.0:
				var lum := c.get_luminance() * 1.25
				img.set_pixel(px, py, Color(col.r * lum, col.g * lum, col.b * lum, c.a))
	return ImageTexture.create_from_image(img)
