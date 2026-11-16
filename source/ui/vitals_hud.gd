extends Control
## Astronaut vitals HUD (ShockFrame art), reading from the player's Vitals node.
## - Top left: green stamina bar and blue O2 tank bar under it (no numbers).
## - Bottom right: heart rate (with a live pulse trace), core temperature and suit CO2.
## - Bottom left: blood oxygen (SpO2) and suit pressure (the ESP32 sensor readings).
##   Readouts turn yellow / red as they get dangerous.
## - High CO2 / low SpO2: screen edges darken.
## - Warnings (CO2, SpO2, O2 tank, pressure) show in the upper middle of the screen
##   with the notification icon, blinking slowly. Each stays up until that system is
##   back in balance (plus a short hold so it doesn't flicker on the edge).

# ShockFrame art (res://assets/HUD/sci-fi - ShockFrame/PNG/1080p/HUD/In-game/), loaded by UID.
@export var stamina_frame: Texture2D = preload("uid://dsnlr6ylnf24f")  # HUD - progress bars container.png
@export var stamina_bg: Texture2D = preload("uid://1rhb3j2wghm0")     # HUD - progress bar 1 BG.png
@export var stamina_fg: Texture2D = preload("uid://dph8rm0xekaph")     # HUD - progress bar 1 FG.png
@export var oxygen_bg: Texture2D = preload("uid://uf1pid26xuhs")      # HUD - progress bar 2 BG.png
@export var oxygen_fg: Texture2D = preload("uid://3gl46jtq7btq")      # HUD - progress bar 2 FG.png
@export var arrows: Texture2D = preload("uid://c2ttx3wrbgvfr")         # HUD - icon -arrows.png
@export var alert_icon: Texture2D = preload("uid://cf0fh2qk370p7")    # HUD icon - notification.png
@export var vitals_frame: Texture2D = preload("uid://cchds2qn62vh2")   # HUD - weapon select container.png

@export var vitals_path: NodePath = ^"../../Vitals"
@export var art_scale := 0.8         ## The art is drawn for 1080p; the game's base resolution is smaller.
@export var stamina_scale := 0.6     ## Smaller so it clears the compass markers.
@export var margin := 16.0
@export var bottom_margin := 16.0    ## Vitals panel sits in the bottom-right corner.

@export_group("Warning levels")
@export var hr_warn := 135.0
@export var hr_danger := 155.0
@export var temp_warn := 37.8
@export var temp_danger := 38.3
@export var co2_warn := 7.0
@export var co2_danger := 11.0
@export var spo2_warn := 94.0        ## Below this: yellow...
@export var spo2_danger := 90.0      ## ...below this: red.
@export var pressure_warn := 5.0     ## psi. Above this: yellow (suit stiffening)...
@export var pressure_danger := 6.5   ## ...above this: red.
@export var o2_low := 0.25           ## Tank fraction for the "return to base" warning.

@export_group("Center warnings")
@export var alert_font_size := 24
@export var alert_y := 0.27          ## Vertical position of the first warning (fraction of screen height).
@export var alert_blink_period := 1.8  ## Seconds per slow blink.
@export var alert_hold := 1.5        ## Seconds a warning stays after its system is balanced again.

const CYAN := Color(0.55, 0.95, 1.0)
const DIM := Color(0.55, 0.95, 1.0, 0.45)
const YELLOW := Color(1.0, 0.84, 0.2)
const RED := Color(1.0, 0.32, 0.26)
const PURPLE := Color(0.8, 0.48, 1.0)
const PANEL_BG := Color(0.02, 0.07, 0.09, 0.45)

var _vitals: Vitals
var _purple_icon: Texture2D  # radiation alerts
var _font: Font
var _time := 0.0
var _pulse_phase := 0.0
var _trace: PackedFloat32Array = []  # pulse trace samples, newest last
var _vignette: ColorRect
var _alerts := {}  # text -> [is_danger, seconds left after the condition clears]

# Warnings in priority order: [text, danger?]. Filled each frame by _collect_alerts().
const A_O2_EMPTY := "O2 TANK EMPTY - ON RESERVE"
const A_PRESSURE := "HIGH PRESSURE - TURN BACK"
const A_CO2 := "CO2 HIGH - SLOW DOWN"
const A_SPO2 := "SpO2 LOW - REST"
const A_O2_LOW := "O2 LOW - GET TO A BASE OR OUTPOST"
const A_ZONE := "PRESSURE ANOMALY AHEAD"
const A_HEAT := "CORE TEMP CRITICAL - COOL DOWN"
const A_RAD := "RADIATION ZONE - GET OUT NOW"
const A_RAD_AHEAD := "RADIATION ZONE AHEAD"
const ALERT_ORDER := [A_HEAT, A_RAD, A_O2_EMPTY, A_PRESSURE, A_CO2, A_SPO2, A_O2_LOW, A_RAD_AHEAD, A_ZONE]
const PURPLE_ALERTS := [A_RAD, A_RAD_AHEAD]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	_vitals = get_node_or_null(vitals_path) as Vitals
	_trace.resize(64)
	_build_vignette()


func _process(delta: float) -> void:
	_time += delta
	if _vitals:
		# Pulse trace: advance a heartbeat waveform at the current heart rate.
		var bpm: float = Esp32Link.hr_bpm if Esp32Link.has_hr() else _vitals.heart_rate
		_pulse_phase += delta * bpm / 60.0
		var p := fposmod(_pulse_phase, 1.0)
		var v := 0.0
		if p < 0.06: v = p / 0.06
		elif p < 0.12: v = 1.0 - (p - 0.06) / 0.06 * 1.5
		elif p < 0.18: v = -0.5 + (p - 0.12) / 0.06 * 0.5
		elif p > 0.35 and p < 0.5: v = sin((p - 0.35) / 0.15 * PI) * 0.18
		_trace.remove_at(0)
		_trace.append(v)
		var mat := _vignette.material as ShaderMaterial
		mat.set_shader_parameter("amount", _vitals.lightheaded)
		_update_alerts(delta)
	queue_redraw()


func _draw() -> void:
	if _vitals == null:
		return
	_draw_stamina()
	_draw_vitals_panel()
	_draw_sensor_panel()
	_draw_alerts()


# ------------------------------------------------------------------ stamina

func _draw_stamina() -> void:
	var s := stamina_scale
	var origin := Vector2(margin, margin)
	var frame_h := stamina_frame.get_height() * s
	_draw_bar(origin, "STAMINA", _vitals.stamina_fraction(), stamina_bg, stamina_fg, 0.2)
	var o2_origin := origin + Vector2(0, frame_h + 4)
	_draw_bar(o2_origin, "O2 TANK", _vitals.oxygen_fraction(), oxygen_bg, oxygen_fg, o2_low)


## One framed bar (ShockFrame "progress bars container"): label, arrows, bar.
func _draw_bar(origin: Vector2, label: String, fraction: float, bg: Texture2D, fg: Texture2D, low: float) -> void:
	var s := stamina_scale
	draw_texture_rect(stamina_frame, Rect2(origin, stamina_frame.get_size() * s), false, Color(1, 1, 1, 0.9))
	draw_string(_font, origin + Vector2(16, 26) * s + Vector2(0, 6), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, CYAN)
	draw_texture_rect(arrows, Rect2(origin + Vector2(18, 40) * s, arrows.get_size() * s), false, DIM)

	var bar_pos := origin + Vector2(130, 22) * s
	draw_texture_rect(bg, Rect2(bar_pos, bg.get_size() * s), false)
	var f := clampf(fraction, 0.0, 1.0)
	if f > 0.0:
		var a := 1.0
		if f < low:
			a = 0.55 + 0.45 * absf(sin(_time * 4.0))  # pulse when nearly empty
		draw_texture_rect_region(fg,
			Rect2(bar_pos + Vector2(0.5, 0.5) * s, Vector2(fg.get_width() * f, fg.get_height()) * s),
			Rect2(0, 0, fg.get_width() * f, fg.get_height()), Color(1, 1, 1, a))


# ------------------------------------------------------------------ vitals panel

func _draw_vitals_panel() -> void:
	var s := art_scale
	var size_px := vitals_frame.get_size() * s
	var origin := Vector2(size.x - margin - size_px.x, size.y - bottom_margin - size_px.y)
	draw_rect(Rect2(origin + Vector2(4, 4), size_px - Vector2(6, 6)), PANEL_BG)
	draw_texture_rect(vitals_frame, Rect2(origin, size_px), false)

	var row_h := (size_px.y - 12.0) / 3.0
	var y := origin.y + 8.0
	var x := origin.x + 12.0
	var w := size_px.x - 24.0

	# Heart rate (or the ESP32 kit's MAX30102 while connected)
	var live := Esp32Link.is_live()
	var hr := _vitals.heart_rate
	var hr_col := _status_color(hr, hr_warn, hr_danger)
	var hr_txt := "%03d" % roundi(hr)
	var hr_label := "HEART RATE"
	if live:
		hr_label = "HEART RATE · ESP32" if Esp32Link.has_hr() else "HR · MEASURING"
		hr_txt = "%03d" % roundi(Esp32Link.hr_bpm) if Esp32Link.has_hr() else "---"
		hr_col = _level_color(Esp32Link.hr_level(Esp32Link.hr_bpm)) if Esp32Link.has_hr() else YELLOW
	_draw_heart(Vector2(x + 9, y + row_h * 0.5), 8.0, hr_col, fposmod(_pulse_phase, 1.0))
	_draw_value(Vector2(x + 26, y), row_h, hr_txt, "BPM", hr_label, hr_col)
	_draw_trace(Rect2(x + w * 0.64, y + 6, w * 0.36, row_h - 12), hr_col)
	y += row_h
	draw_line(Vector2(x, y), Vector2(x + w, y), Color(CYAN, 0.25), 1.0)

	# Core temperature (or skin temperature from the ESP32 kit's MLX90614 when live)
	var measuring := Esp32Link.skin_live() and not Esp32Link.has_skin_temp()
	var live_t := Esp32Link.has_skin_temp() or measuring
	var t: float = Esp32Link.skin_temp_c if Esp32Link.has_skin_temp() else _vitals.temperature
	var t_col := _status_color(t, temp_warn, temp_danger)
	if live_t:
		t_col = [CYAN, Color(1.0, 0.82, 0.3), Color(1.0, 0.36, 0.3)][BiometricsPanel.skin_level(t)]
	_draw_thermometer(Vector2(x + 9, y + row_h * 0.5), t_col)
	var no_skin := live_t and not Esp32Link.skin_detected()  # measuring, or aimed at the room
	if no_skin:
		t_col = Color(1.0, 0.82, 0.3)
	var end := _draw_value(Vector2(x + 26, y), row_h, "--.-" if no_skin else "%.1f" % t, "°C",
		("SKIN TEMP · MEASURING" if measuring else "SKIN TEMP · AIM AT SKIN") if no_skin
		else ("SKIN TEMP · ESP32" if live_t else "CORE TEMP"), t_col)
	# Fahrenheit next to it, smaller.
	if not no_skin:
		draw_string(_font, Vector2(end + 5, y + row_h * 0.5 + 13), "%.1f °F" % (t * 9.0 / 5.0 + 32.0),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(t_col, 0.75))
		end += 5 + _font.get_string_size("%.1f °F" % (t * 9.0 / 5.0 + 32.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var gx := maxf(x + w * 0.64, end + 8)
	if live_t:  # skin scale: 26-40 °C, marks at the caution / warning edges
		_draw_gauge(Rect2(gx, y + row_h * 0.5 - 3, x + w - gx, 6), 0.0 if no_skin else inverse_lerp(26.0, 40.0, t),
			[37.0, 38.5].map(func(v): return inverse_lerp(26.0, 40.0, v)), t_col)
	else:
		_draw_gauge(Rect2(gx, y + row_h * 0.5 - 3, x + w - gx, 6),
			inverse_lerp(_vitals.normal_temp - 0.3, temp_danger + 0.3, t), [temp_warn, temp_danger].map(
				func(v): return inverse_lerp(_vitals.normal_temp - 0.3, temp_danger + 0.3, v)), t_col)
	y += row_h
	draw_line(Vector2(x, y), Vector2(x + w, y), Color(CYAN, 0.25), 1.0)

	# Suit CO2 (or the ESP32 kit's SCD41 in ppm, like its TFT, while connected)
	if live:
		var has_c := Esp32Link.has_co2()
		var ppm: float = Esp32Link.co2_ppm if has_c else 0.0
		var lc := _level_color(Esp32Link.co2_level(ppm)) if has_c else YELLOW
		draw_string(_font, Vector2(x + 1, y + row_h * 0.5 + 5), "CO", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, lc)
		draw_string(_font, Vector2(x + 18, y + row_h * 0.5 + 9), "2", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, lc)
		_draw_value(Vector2(x + 26, y), row_h, "%d" % roundi(ppm) if has_c else "----", "ppm",
			"CO2 · ESP32" if has_c else "CO2 · WARMING UP", lc)
		_draw_gauge(Rect2(x + w * 0.64, y + row_h * 0.5 - 3, w * 0.36, 6),
			ppm / 3000.0, [1000.0 / 3000.0, 2000.0 / 3000.0], lc)
		return
	var c: float = _vitals.co2
	var c_col := _status_color(c, co2_warn, co2_danger)
	draw_string(_font, Vector2(x + 1, y + row_h * 0.5 + 5), "CO", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, c_col)
	draw_string(_font, Vector2(x + 18, y + row_h * 0.5 + 9), "2", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, c_col)
	_draw_value(Vector2(x + 26, y), row_h, "%.1f" % c, "mmHg", "SUIT CO2", c_col)
	var c_max := _vitals.co2_max
	_draw_gauge(Rect2(x + w * 0.64, y + row_h * 0.5 - 3, w * 0.36, 6),
		c / c_max, [co2_warn / c_max, co2_danger / c_max], c_col)


# ------------------------------------------------------------------ sensor panel (bottom left)

func _draw_sensor_panel() -> void:
	var s := art_scale
	var full := vitals_frame.get_size() * s
	var row_h := (full.y - 12.0) / 3.0
	var size_px := Vector2(full.x, row_h * 2.0 + 12.0)
	var origin := Vector2(margin, size.y - bottom_margin - size_px.y)
	draw_rect(Rect2(origin + Vector2(4, 4), size_px - Vector2(6, 6)), PANEL_BG)
	draw_set_transform(origin, 0.0, Vector2(s, s))  # corners at the same scale as the right panel
	draw_style_box(_panel_box(), Rect2(Vector2.ZERO, size_px / s))
	draw_set_transform(Vector2.ZERO)

	var y := origin.y + 8.0
	var x := origin.x + 12.0
	var w := size_px.x - 24.0

	# Blood oxygen (or the ESP32 kit's MAX30102 while connected)
	var live := Esp32Link.is_live()
	var o := _vitals.spo2
	var o_col := _status_color(-o, -spo2_warn, -spo2_danger)
	var o_txt := "%d" % roundi(o)
	var o_label := "BLOOD OXYGEN"
	if live:
		var has_o := Esp32Link.has_spo2()
		o = Esp32Link.spo2_pct if has_o else 70.0
		o_col = _level_color(Esp32Link.spo2_level(o)) if has_o else YELLOW
		o_txt = "%d" % roundi(o) if has_o else "--"
		o_label = "BLOOD OXYGEN · ESP32" if has_o else "SpO2 · MEASURING"
	draw_string(_font, Vector2(x - 2, y + row_h * 0.5 + 5), "SpO", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, o_col)
	draw_string(_font, Vector2(x + 19, y + row_h * 0.5 + 9), "2", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, o_col)
	_draw_value(Vector2(x + 30, y), row_h, o_txt, "%", o_label, o_col)
	var lo := 70.0
	_draw_gauge(Rect2(x + w * 0.64, y + row_h * 0.5 - 3, w * 0.36, 6),
		inverse_lerp(lo, 100.0, o), [inverse_lerp(lo, 100.0, spo2_danger), inverse_lerp(lo, 100.0, spo2_warn)], o_col)
	y += row_h
	draw_line(Vector2(x, y), Vector2(x + w, y), Color(CYAN, 0.25), 1.0)

	# Suit pressure from the ESP32 kit's BME280 (hPa, like its TFT) while connected
	if live:
		var has_p := Esp32Link.has_pressure()
		var hpa: float = Esp32Link.pressure_hpa if has_p else 900.0
		var lp := _level_color(Esp32Link.pressure_level(hpa)) if has_p else YELLOW
		var f := func(v: float) -> float: return inverse_lerp(900.0, 1100.0, v)
		_draw_dial(Vector2(x + 10, y + row_h * 0.5 + 2), 8.0, f.call(hpa), lp)
		var pend := _draw_value(Vector2(x + 30, y), row_h, "%.1f" % hpa if has_p else "----.-", "hPa",
			"SUIT PRESSURE · ESP32" if has_p else "SUIT PRESSURE · NO DATA", lp)
		var pgx := maxf(x + w * 0.64, pend + 8)
		_draw_gauge(Rect2(pgx, y + row_h * 0.5 - 3, x + w - pgx, 6), f.call(hpa) if has_p else 0.0,
			[f.call(980.0), f.call(1040.0)], lp)
		return

	# Suit pressure
	var p := _vitals.suit_pressure
	var p_col := _status_color(p, pressure_warn, pressure_danger)
	var p_lo := _vitals.nominal_pressure - 0.5
	var p_hi := _vitals.nominal_pressure + _vitals.zone_pressure_rise + 0.3
	_draw_dial(Vector2(x + 10, y + row_h * 0.5 + 2), 8.0, inverse_lerp(p_lo, p_hi, p), p_col)
	var end := _draw_value(Vector2(x + 30, y), row_h, "%.1f" % p, "psi", "SUIT PRESSURE", p_col)
	var kpa := "%.0f kPa" % (p * 6.89476)
	draw_string(_font, Vector2(end + 5, y + row_h * 0.5 + 13), kpa, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(p_col, 0.75))
	end += 5 + _font.get_string_size(kpa, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var gx := maxf(x + w * 0.64, end + 8)
	_draw_gauge(Rect2(gx, y + row_h * 0.5 - 3, x + w - gx, 6), inverse_lerp(p_lo, p_hi, p),
		[inverse_lerp(p_lo, p_hi, pressure_warn), inverse_lerp(p_lo, p_hi, pressure_danger)], p_col)


# ------------------------------------------------------------------ center warnings

func _update_alerts(delta: float) -> void:
	var active := {}
	if _vitals.is_tank_empty():
		active[A_O2_EMPTY] = true
	elif _vitals.oxygen_fraction() < o2_low:
		active[A_O2_LOW] = false
	if _vitals.suit_pressure >= pressure_warn:
		active[A_PRESSURE] = true
	else:
		var cam := get_viewport().get_camera_3d()
		var zone := PressureZone.nearest(get_tree(), cam.global_position) if cam else null
		if zone and zone.distance_to_edge(cam.global_position) < zone.warning_distance:
			active[A_ZONE] = false
	if _vitals.temperature >= temp_danger:
		active[A_HEAT] = true
	if _vitals.radiation > 0.0:
		active[A_RAD] = true
	else:
		var rcam := get_viewport().get_camera_3d()
		var rz := RadiationZone.nearest(get_tree(), rcam.global_position) if rcam else null
		if rz and rz.distance_to_edge(rcam.global_position) < rz.warning_distance:
			active[A_RAD_AHEAD] = false
	if _vitals.co2 >= co2_warn:
		active[A_CO2] = _vitals.co2 >= co2_danger
	if _vitals.spo2 < spo2_warn:
		active[A_SPO2] = _vitals.spo2 < spo2_danger
	# Active ones are refreshed; cleared ones linger for alert_hold, then go.
	for k in active:
		_alerts[k] = [active[k], alert_hold]
	for k in _alerts.keys():
		if not active.has(k):
			_alerts[k][1] -= delta
			if _alerts[k][1] <= 0.0:
				_alerts.erase(k)
	# Superseded pairs: an empty tank replaces "O2 low", being inside replaces "ahead".
	if _alerts.has(A_O2_EMPTY):
		_alerts.erase(A_O2_LOW)
	if _alerts.has(A_PRESSURE):
		_alerts.erase(A_ZONE)
	if _alerts.has(A_RAD):
		_alerts.erase(A_RAD_AHEAD)


func _draw_alerts() -> void:
	if _alerts.is_empty():
		return
	# Slow, smooth blink (fades rather than snapping on/off).
	var blink := 0.5 + 0.5 * cos(_time * TAU / alert_blink_period)
	var a := lerpf(0.25, 1.0, blink)
	var fs := alert_font_size
	var line_h := fs + 18.0
	var y := size.y * alert_y
	var icon_s := fs * 1.35
	for text: String in ALERT_ORDER:
		if not _alerts.has(text):
			continue
		var danger: bool = _alerts[text][0]
		var col := RED if danger else YELLOW
		if text in PURPLE_ALERTS:
			col = PURPLE
		var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var total := icon_s + 12.0 + tw
		var x := (size.x - total) * 0.5
		# Dark band so it reads over bright ground.
		var band := Rect2(x - 16, y - fs * 0.5 - 12, total + 32, fs + 24)
		draw_rect(band, Color(0.0, 0.03, 0.05, 0.45 * lerpf(0.6, 1.0, blink)))
		draw_line(band.position, Vector2(band.end.x, band.position.y), Color(col, 0.6 * a), 1.0)
		draw_line(Vector2(band.position.x, band.end.y), band.end, Color(col, 0.6 * a), 1.0)
		var icon_col := Color(1, 1, 1, a) if not danger else Color(1.0, 0.45, 0.4, a)
		var icon := alert_icon
		if text in PURPLE_ALERTS:
			if _purple_icon == null:
				_purple_icon = _recolor(alert_icon, PURPLE)
			icon = _purple_icon
			icon_col = Color(1, 1, 1, a)
		draw_texture_rect(icon, Rect2(Vector2(x, y - icon_s * 0.5), Vector2(icon_s, icon_s)), false, icon_col)
		var base := Vector2(x + icon_s + 12.0, y + fs * 0.36)
		draw_string_outline(_font, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, Color(0, 0, 0, 0.7 * a))
		draw_string(_font, base, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col, a))
		y += line_h


var _box: StyleBoxTexture
## The vitals frame as a nine-patch, so a shorter panel keeps its corners.
func _panel_box() -> StyleBoxTexture:
	if _box == null:
		_box = StyleBoxTexture.new()
		_box.texture = vitals_frame
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			_box.set_texture_margin(side, 40.0)
		_box.set_expand_margin_all(0)
	return _box


func _draw_dial(c: Vector2, r: float, value: float, col: Color) -> void:
	draw_arc(c, r, PI * 0.75, PI * 2.25, 20, col, 1.5, true)
	var ang := lerpf(PI * 0.75, PI * 2.25, clampf(value, 0.0, 1.0))
	draw_line(c, c + Vector2.from_angle(ang) * (r - 1.5), col, 2.0, true)
	draw_circle(c, 1.8, col)


## Returns the x where the unit text ends.
func _draw_value(pos: Vector2, row_h: float, value: String, unit: String, label: String, col: Color) -> float:
	draw_string(_font, pos + Vector2(0, row_h * 0.5 - 6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(col, 0.7))
	draw_string(_font, pos + Vector2(0, row_h * 0.5 + 13), value, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col)
	var vw := _font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	draw_string(_font, pos + Vector2(vw + 4, row_h * 0.5 + 13), unit, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(col, 0.75))
	return pos.x + vw + 4 + _font.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x


func _draw_trace(r: Rect2, col: Color) -> void:
	var pts := PackedVector2Array()
	var n := _trace.size()
	for i in n:
		pts.append(Vector2(r.position.x + r.size.x * i / float(n - 1),
			r.position.y + r.size.y * (0.6 - _trace[i] * 0.55)))
	draw_polyline(pts, col, 1.5, true)


func _draw_gauge(r: Rect2, value: float, marks: Array, col: Color) -> void:
	draw_rect(r, Color(CYAN, 0.12))
	draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(value, 0.0, 1.0), r.size.y)), col)
	for m in marks:
		var mx: float = r.position.x + r.size.x * clampf(m, 0.0, 1.0)
		draw_line(Vector2(mx, r.position.y - 3), Vector2(mx, r.end.y + 3), Color(CYAN, 0.5), 1.0)


func _draw_heart(c: Vector2, r: float, col: Color, phase: float) -> void:
	var k := 1.0 + (0.18 * (1.0 - phase / 0.15) if phase < 0.15 else 0.0)  # beat
	r *= k
	draw_circle(c + Vector2(-r * 0.45, -r * 0.2), r * 0.52, col)
	draw_circle(c + Vector2(r * 0.45, -r * 0.2), r * 0.52, col)
	draw_colored_polygon(PackedVector2Array([c + Vector2(-r * 0.95, -r * 0.05),
		c + Vector2(r * 0.95, -r * 0.05), c + Vector2(0, r * 0.95)]), col)


func _draw_thermometer(c: Vector2, col: Color) -> void:
	draw_rect(Rect2(c + Vector2(-2.5, -10), Vector2(5, 13)), col, false, 1.5)
	draw_circle(c + Vector2(0, 6), 4.5, col)
	draw_line(c + Vector2(0, -4), c + Vector2(0, 5), col, 2.0)


## Colour for an ESP32 reading's level (0 normal / 1 caution / 2 alert, red blinks).
func _level_color(lvl: int) -> Color:
	return [CYAN, YELLOW, RED if fmod(_time, 0.8) < 0.55 else Color(RED, 0.5)][lvl]


func _status_color(v: float, warn: float, danger: float) -> Color:
	if v >= danger:
		return RED if fmod(_time, 0.8) < 0.55 else Color(RED, 0.5)
	if v >= warn:
		return YELLOW
	return CYAN


func _build_vignette() -> void:
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
uniform float amount = 0.0;
void fragment() {
	vec2 d = (UV - 0.5) * vec2(1.6, 1.0);
	float pulse = 0.85 + 0.15 * sin(TIME * 2.2);
	float v = smoothstep(0.25, 0.85, length(d)) * amount * pulse;
	COLOR = vec4(0.01, 0.0, 0.02, v * 0.9);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_vignette.material = mat
	_vignette.show_behind_parent = true  # under the HUD readouts
	add_child(_vignette)


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
