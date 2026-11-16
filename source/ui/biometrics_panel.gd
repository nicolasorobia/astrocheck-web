class_name BiometricsPanel
extends Control
## BIOMETRICS page of the in-game (Tab) menu: Mission Control's live view of the
## astronaut. Reads the player's Vitals + Biometrics nodes every frame, so the numbers
## match the field HUD exactly (the sim keeps running while this is open).
## Drawn in the menu's 1920x1080 design space.

var font: Font

const TEXT := Color(0.86, 0.97, 1.0)
const DIM := Color(0.55, 0.95, 1.0, 0.62)
const CYAN := Color(0.55, 0.95, 1.0)
const GREEN := Color(0.4, 0.95, 0.55)
const YELLOW := Color(1.0, 0.82, 0.3)
const RED := Color(1.0, 0.36, 0.3)
const CARD_BG := Color(0.01, 0.06, 0.08, 0.86)

const COLS := 3
const ROWS := 4
const GAP := 14.0
const HEADER_H := 54.0

# Same thresholds as the field HUD (vitals_hud.gd).
const HR_WARN := 135.0
const HR_DANGER := 155.0
const TEMP_WARN := 37.8
const TEMP_DANGER := 38.3
const CO2_WARN := 7.0
const CO2_DANGER := 11.0
const SPO2_WARN := 94.0
const SPO2_DANGER := 90.0
const P_WARN := 5.0
const P_DANGER := 6.5

var _t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font == null:
		font = ThemeDB.fallback_font


func _process(delta: float) -> void:
	_t += delta
	if is_visible_in_tree():
		queue_redraw()


func _draw() -> void:
	var v := get_tree().get_first_node_in_group("vitals") as Vitals
	var b := get_tree().get_first_node_in_group("biometrics") as Biometrics
	if v == null or b == null:
		draw_string(font, Vector2(0, 60), "NO TELEMETRY - simulation not running", HORIZONTAL_ALIGNMENT_LEFT, -1, 32, DIM)
		return

	_draw_header(b)

	var cards := [
		_hr_card(v),
		_spo2_card(v),
		_co2_card(v),
		_pressure_card(v),
		_temp_card(v),
		_card("RESPIRATION", "%d" % roundi(b.resp_rate), "br/min", "%d W  ·  %s" % [roundi(b.metabolic), _vent_text(b)],
			_level(b.resp_rate, 26.0, 32.0)),
		_card("O2 TANK", "%d" % roundi(v.oxygen), "%", _o2_text(v, b),
			2 if v.oxygen <= 0.0 else _level_low(v.oxygen, 40.0, 25.0)),
		_card("STAMINA", "%d" % roundi(v.stamina), "%", "Endurance %d %%  (sleep + stress)" % roundi(b.endurance_percent()),
			_level_low(v.stamina, 40.0, 15.0)),
		_card("RADIATION", _thousands(roundi(b.dose_rate)), "µSv/h",
			"Mission %.1f mSv  ·  %.1f %% of limit" % [b.mission_dose(), b.career_dose_percent()],
			_level(b.dose_rate, 150.0, 1000.0), _rad_tag(b)),
		_card("BONE DENSITY", "%.3f" % b.bmd, "g/cm²",
			"%+.2f %%  ·  %s steps today" % [b.bmd_change, _thousands(roundi(b.steps))],
			_level(-b.bmd_change, 3.0, 6.0)),
		_card("SLEEP SCORE", "%d" % roundi(b.sleep_score), "/100",
			"Last %.1f h  ·  awake %s" % [b.last_sleep_hours, _hm(b.awake_seconds)],
			_level_low(b.sleep_score, 70.0, 55.0)),
		_card("STRESS SCORE", "%d" % roundi(b.stress), "/100", "HRV %d ms" % roundi(b.hrv),
			_level(b.stress, 51.0, 76.0), b.stress_label()),
	]

	var cw := (size.x - GAP * (COLS - 1)) / COLS
	var ch := (size.y - HEADER_H - GAP * (ROWS - 1)) / ROWS
	for i in cards.size():
		var r := Rect2(Vector2((i % COLS) * (cw + GAP), HEADER_H + (i / COLS) * (ch + GAP)), Vector2(cw, ch))
		_draw_card(r, cards[i])


func _draw_header(b: Biometrics) -> void:
	var y := 30.0
	var pulse := 0.5 + 0.5 * cos(_t * TAU / 1.2)
	draw_circle(Vector2(10, y - 8), 8.0, Color(RED, lerpf(0.35, 1.0, pulse)))
	draw_string(font, Vector2(28, y), "LIVE", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, RED)
	draw_string(font, Vector2(100, y), "EVA CREW MEMBER 1  ·  TELEMETRY", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, TEXT)
	var right := "SURFACE DAY %d   %s   ·   AWAKE %s" % [b.mission_day, b.time_text(), _hm(b.awake_seconds)]
	var w := font.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
	draw_string(font, Vector2(size.x - w, y), right, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, CYAN)
	draw_line(Vector2(0, y + 14), Vector2(size.x, y + 14), Color(CYAN, 0.3), 2.0)


# While the ESP32 kit is connected (ESP32 SENSOR MODE), each sensor card shows the
# kit's reading in the same units, rounding and thresholds as the kit's TFT page, so the
# two can be compared side by side. "--" = the kit's TFT shows dashes too (no result yet).

func _esp_tag(lvl: int) -> String:
	return "ESP32 · " + ["NOMINAL", "CAUTION", "WARNING"][lvl]


## HEART RATE: the kit's MAX30102 (TFT page 1), else the sim.
func _hr_card(v: Vitals) -> Array:
	if Esp32Link.is_live():
		if not Esp32Link.has_hr():
			return _card("HEART RATE", "--", "bpm", "Finger on the sensor  ·  ~1 min", 1, "MEASURING")
		var lvl := Esp32Link.hr_level(Esp32Link.hr_bpm)
		return _card("HEART RATE", "%d" % roundi(Esp32Link.hr_bpm), "bpm", "ESP32 MAX30102  ·  resting 60-100", lvl, _esp_tag(lvl))
	return _card("HEART RATE", "%d" % roundi(v.heart_rate), "bpm", "Resting range 60-100",
		_level(v.heart_rate, HR_WARN, HR_DANGER))


## BLOOD OXYGEN: the kit's MAX30102 (TFT page 1), else the sim.
func _spo2_card(v: Vitals) -> Array:
	if Esp32Link.is_live():
		if not Esp32Link.has_spo2():
			return _card("BLOOD OXYGEN", "--", "%", "Finger on the sensor  ·  ~1 min", 1, "MEASURING")
		var lvl := Esp32Link.spo2_level(Esp32Link.spo2_pct)
		return _card("BLOOD OXYGEN", "%d" % roundi(Esp32Link.spo2_pct), "%", "ESP32 MAX30102  ·  nominal 95 % +", lvl, _esp_tag(lvl))
	return _card("BLOOD OXYGEN  SpO2", "%d" % roundi(v.spo2), "%", "Nominal 95 % or higher",
		_level_low(v.spo2, SPO2_WARN, SPO2_DANGER))


## CO2: the kit's SCD41 (TFT page 5, in ppm like the TFT), else the simulated suit CO2.
func _co2_card(v: Vitals) -> Array:
	if Esp32Link.is_live():
		if not Esp32Link.has_co2():
			return _card("CO2", "----", "ppm", "SCD41 warming up  ·  ~5 s", 1, "ESP32 · WARMING UP")
		var ppm: float = Esp32Link.co2_ppm
		var lvl := Esp32Link.co2_level(ppm)
		return _card("CO2", "%d" % roundi(ppm), "ppm", "%.3f mmHg  ·  ESP32 SCD41" % Esp32Link.co2_mmhg, lvl, _esp_tag(lvl))
	return _card("SUIT CO2", "%.1f" % v.co2, "mmHg", "Caution above %.0f mmHg" % CO2_WARN,
		_level(v.co2, CO2_WARN, CO2_DANGER))


## SUIT PRESSURE: the kit's BME280 pressure (TFT page 4, in hPa), else the simulated suit pressure.
func _pressure_card(v: Vitals) -> Array:
	if Esp32Link.is_live():
		if not Esp32Link.has_pressure():
			return _card("SUIT PRESSURE", "----.-", "hPa", "BME280  ·  no data yet", 1, "ESP32 · NO DATA")
		var p: float = Esp32Link.pressure_hpa
		var lvl := Esp32Link.pressure_level(p)
		return _card("SUIT PRESSURE", "%.1f" % p, "hPa", "%.1f psi  ·  %d %% of Earth  ·  ESP32 BME280" % [p * 0.0145038, roundi(p / 10.1325)],
			lvl, _esp_tag(lvl))
	return _card("SUIT PRESSURE", "%.1f" % v.suit_pressure, "psi", "%d kPa  ·  nominal 4.3 psi" % roundi(v.suit_pressure * 6.895),
		_level(v.suit_pressure, P_WARN, P_DANGER))


## CORE TEMP, or SKIN TEMP from the kit's MLX90614 infrared sensor. Skin normally reads
## a few degrees below core, so it gets its own normal range (about 32-36 °C).
func _temp_card(v: Vitals) -> Array:
	if Esp32Link.skin_live() and not Esp32Link.has_skin_temp():
		# Kit connected, MLX90614 still on its first settle + measure cycle (~20 s).
		return _card("SKIN TEMP", "--.-", "°C", "MLX90614 measuring  ·  hold still", 1, "MEASURING")
	if Esp32Link.has_skin_temp() and not Esp32Link.skin_detected():
		# Sensor sees the room, not a person: don't call that the astronaut's temperature.
		return _card("SKIN TEMP", "--.-", "°C", "Sensor reads %.1f °C (room)  ·  aim at skin" % Esp32Link.skin_temp_c,
			1, "ESP32 · NO SKIN")
	if Esp32Link.has_skin_temp():
		var t: float = Esp32Link.skin_temp_c
		var lvl := skin_level(t)
		return _card("SKIN TEMP", "%.1f" % t, "°C", "%.1f °F  ·  ESP32 MLX90614 sensor" % (t * 1.8 + 32.0),
			lvl, _esp_tag(lvl))
	return _card("CORE TEMP", "%.1f" % v.temperature, "°C", "%.1f °F  ·  nominal 36.5-37.5" % (v.temperature * 1.8 + 32.0),
		_level(v.temperature, TEMP_WARN, TEMP_DANGER))


## 0 normal / 1 caution / 2 warning for a skin temperature reading.
static func skin_level(t: float) -> int:
	if t < 28.0 or t > 38.5:
		return 2
	if t < 31.0 or t > 37.0:
		return 1
	return 0


## [title, value, unit, detail, level 0/1/2, tag]
func _card(title: String, value: String, unit: String, detail: String, level: int, tag := "") -> Array:
	if tag == "":
		tag = ["NOMINAL", "CAUTION", "WARNING"][level]
	return [title, value, unit, detail, level, tag]


func _draw_card(r: Rect2, c: Array) -> void:
	var level: int = c[4]
	var col: Color = [GREEN, YELLOW, RED][level]
	var a := 1.0
	if level == 2:
		a = lerpf(0.55, 1.0, 0.5 + 0.5 * cos(_t * TAU / 1.4))  # warnings pulse slowly
	draw_rect(r, CARD_BG)
	draw_rect(r, Color(CYAN, 0.28), false, 2.0)
	draw_rect(Rect2(r.position, Vector2(6, r.size.y)), Color(col, a))
	var x := r.position.x + 24.0
	var y := r.position.y
	draw_string(font, Vector2(x, y + 36), c[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 24, DIM)
	var tag: String = c[5]
	var tw := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
	draw_string(font, Vector2(r.end.x - 16 - tw, y + 34), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(col, a))
	var vcol := TEXT if level == 0 else Color(col, a)
	draw_string(font, Vector2(x, y + 96), c[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 54, vcol)
	var vw := font.get_string_size(c[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 54).x
	draw_string(font, Vector2(x + vw + 10, y + 96), c[2], HORIZONTAL_ALIGNMENT_LEFT, -1, 26, DIM)
	draw_string(font, Vector2(x, y + 132), c[3], HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 40, 22, Color(TEXT, 0.78))


## How much stress / sleep is speeding up (or calming) breathing.
func _vent_text(b: Biometrics) -> String:
	var pct := roundi((b.ventilation - 1.0) * 100.0)
	if pct > 0:
		return "+%d %% from stress / sleep" % pct
	if pct < 0:
		return "%d %% well rested" % pct
	return "normal breathing"


func _rad_tag(b: Biometrics) -> String:
	if b.dose_rate >= 1000.0:
		return "RADIATION ZONE"
	if b.dose_rate >= 150.0:
		return "ELEVATED"
	return "SHIELDED" if b.sheltered else "NOMINAL"


func _o2_text(v: Vitals, b: Biometrics) -> String:
	if v.oxygen <= 0.0:
		return "EMPTY - return to a station now"
	return "About %d min left at this pace" % maxi(roundi(b.o2_minutes_left), 1)


func _level(x: float, warn: float, danger: float) -> int:
	return 2 if x >= danger else (1 if x >= warn else 0)


func _level_low(x: float, warn: float, danger: float) -> int:
	return 2 if x < danger else (1 if x < warn else 0)


func _hms(s: float) -> String:
	var t := int(s)
	return "%02d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]


func _hm(s: float) -> String:
	var t := int(s)
	return "%dh %02dm" % [t / 3600, (t / 60) % 60]


func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out
