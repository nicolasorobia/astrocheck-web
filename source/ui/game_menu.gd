class_name GameMenu
extends Control
## Main menu / in-game menu in the ShockFrame style (laid out after the pack's
## "03 - SETTINGS" mock-up): title top-left, section buttons on the left, a big
## panel with the selected section, and two buttons along the bottom.
##
## Sections: MISSION (briefing), SETTINGS (camera speed + volumes), CONTROLS (fixed keys),
## CREDITS (team + asset sources, links open in the browser).
## MAIN mode: full-screen background, menu music, START MISSION / QUIT.
## PAUSE mode: dims the game, RESUME / MAIN MENU (opened with Tab, see pause_menu.gd).
##
## Everything is laid out in 1920x1080 "design" pixels (the art's native size) on a
## stage that is scaled to fit the window.

signal resume_requested
signal main_menu_requested

enum Mode { MAIN, PAUSE }

@export var mode := Mode.MAIN
@export var title_text := "BIOBEACON"
@export var game_scene := "res://levels/main.tscn"
@export var ui_font: Font                   ## Optional: drop in Oxanium (the pack's font) here.
@export var menu_music: AudioStream = preload("uid://b483tulwyxoy1")  # main-menu.wav
@export var music_volume_db := -4.0
@export var confirm_sound: AudioStream = preload("uid://bpvp3snhvqjaj")  # confirm.wav
@export var cancel_sound: AudioStream = preload("uid://b3v3bn877sbtf")   # cancel.wav

# ShockFrame art (res://assets/HUD/sci-fi - ShockFrame/PNG/1080p/), loaded by UID.
const T_BG := preload("uid://cwqal6f1v1c7h")          # Panels & Dialog/BG.png
const T_PANEL := preload("uid://cjlolgafdfa4w")       # Panels & Dialog/panel.png (1366x834)
const T_BTN := preload("uid://byidglunp2u4s")         # Input/Btn.png
const T_BTN_HOVER := preload("uid://d4bfrjs34nfmu")   # Input/Btn - hovered.png
const T_BTN2 := preload("uid://b5f1pfypjrqwx")        # Input/Btn 2 (medium size).png
const T_BTN2_HOVER := preload("uid://cn3citnnby0qy")  # Input/Btn 2 - hovered (medium size).png
const T_DECOR := preload("uid://bft7twecaq6nt")       # Decor/decor - title.png
const T_SLIDER_BG := preload("uid://4bstudov1fv")     # Input/slider - BG.png
const T_SLIDER_FG := preload("uid://bhcnokigrrmid")   # Input/slider - FG.png
const T_GRABBER := preload("uid://dkvt7mbv5pfsl")     # Input/slider - grabber.png
const T_LOGO := preload("uid://ceua6we0s54pc")        # Space Apps logo
const T_TOGGLE_ON := preload("uid://brum3afg0ljqx")   # Input/Btn - toggle_ON.png
const T_TOGGLE_OFF := preload("uid://b1wwduyckgqrx")  # Input/Btn - toggle_OFF.png

const DESIGN := Vector2(1920, 1080)
const PANEL_POS := Vector2(490, 98)
const TEXT := Color(0.86, 0.97, 1.0)
const CYAN := Color(0.55, 0.95, 1.0)
const DIM := Color(0.55, 0.95, 1.0, 0.6)
const DARK := Color(0.02, 0.09, 0.12)

var _stage: Control
var _font: Font
var _section_buttons := {}   # name -> Button
var _pages := {}             # name -> Control
var _current := ""
var _tab_title: Label
var _sfx: AudioStreamPlayer
var _music: AudioStreamPlayer
var _sliders := {}           # settings key -> [HSlider, value Label]
var _stats_panel: StatsPanel
var _esp32_btn: TextureButton
var _esp32_state: Label
var _esp32_status: Label
var _loading: Label
var _starting := false
var _start_time := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = ui_font if ui_font else ThemeDB.fallback_font

	_sfx = AudioStreamPlayer.new()
	_sfx.bus = &"SFX"
	_sfx.volume_db = -4.0
	add_child(_sfx)

	if mode == Mode.MAIN:
		var bg := TextureRect.new()
		bg.texture = T_BG
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bg)
		if menu_music:
			_music = AudioStreamPlayer.new()
			_music.set_script(preload("res://audio/ambient_loop.gd"))  # seamless loop on the Music bus
			_music.stream = menu_music
			_music.volume_db = music_volume_db
			add_child(_music)
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		var dim := ColorRect.new()
		dim.color = Color(0.0, 0.02, 0.04, 0.3)  # light: the astronaut can keep walking behind it
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(dim)

	_stage = Control.new()
	_stage.size = DESIGN
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stage)
	resized.connect(_fit)
	_fit()
	_build()
	_select(_first_section(), false)


func _fit() -> void:
	if _stage == null:
		return
	var k := minf(size.x / DESIGN.x, size.y / DESIGN.y)
	_stage.scale = Vector2(k, k)
	_stage.position = (size - DESIGN * k) * 0.5


func _process(_delta: float) -> void:
	if _esp32_status and _esp32_status.is_visible_in_tree():
		_show_esp32_status()
	if not _starting:
		return
	# Wait for the level to finish loading in the background and the music to fade.
	var status := ResourceLoader.load_threaded_get_status(game_scene)
	var waited := Time.get_ticks_msec() / 1000.0 - _start_time
	_loading.modulate.a = 0.55 + 0.45 * cos(waited * TAU / 1.6)
	if status == ResourceLoader.THREAD_LOAD_LOADED and waited > 1.2:
		var packed := ResourceLoader.load_threaded_get(game_scene) as PackedScene
		_starting = false
		get_tree().change_scene_to_packed(packed)
	elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		_starting = false
		get_tree().change_scene_to_file(game_scene)  # fall back to a normal load


# ------------------------------------------------------------------ actions

func _start_game() -> void:
	if _starting:
		return
	_play(confirm_sound)
	_starting = true
	_start_time = Time.get_ticks_msec() / 1000.0
	_loading.visible = true
	for b in _stage.find_children("*", "Button", true, false):
		(b as Button).disabled = true
	if _music:
		create_tween().tween_property(_music, "volume_db", -60.0, 1.2)
	ResourceLoader.load_threaded_request(game_scene)


func _quit() -> void:
	_play(cancel_sound)
	get_tree().quit()


## Pause mode: called by the pause layer when the menu opens.
func reset_to_first_section() -> void:
	_select(_first_section(), false)


## BIOMETRICS only exists once the sim is running (the Tab menu in-game).
func _first_section() -> String:
	return "BIOMETRICS" if mode == Mode.PAUSE else "MISSION"


func play_cancel() -> void:
	_play(cancel_sound)


func _play(s: AudioStream) -> void:
	if s:
		_sfx.stream = s
		_sfx.play()


func _select(section: String, sound := true) -> void:
	if sound and section != _current:
		_play(confirm_sound)
	_current = section
	for n in _pages:
		(_pages[n] as Control).visible = n == section
	for n in _section_buttons:
		_style_section_button(_section_buttons[n], n == section)
	_tab_title.text = section
	if section == "STATS" and _stats_panel:
		_stats_panel.refresh()  # pick up runs finished since the menu was built
	for rt in _scrollers:
		rt.scroll_to_line(0)


# ------------------------------------------------------------------ layout

func _build() -> void:
	# Title + decor line (top left).
	var title := _label(title_text if mode == Mode.MAIN else "MISSION CONTROL", 58, TEXT)
	title.position = Vector2(76, 22)
	_stage.add_child(title)
	var decor := TextureRect.new()
	decor.texture = T_DECOR
	decor.position = Vector2(56, 92)
	decor.size = Vector2(540, 33)
	decor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(decor)

	# Section buttons (left column).
	var y := 195.0
	var sections := ["MISSION", "STATS", "SETTINGS", "CONTROLS", "CREDITS"]
	if mode == Mode.PAUSE:
		sections.push_front("BIOMETRICS")
	for section: String in sections:
		var b := Button.new()
		b.text = section
		b.position = Vector2(70, y)
		b.size = Vector2(390, 70)
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.add_theme_font_override("font", _font)
		b.add_theme_font_size_override("font_size", 30)
		b.pressed.connect(_select.bind(section))
		if mode == Mode.PAUSE:
			b.modulate.a = 0.8
		_stage.add_child(b)
		_section_buttons[section] = b
		y += 68.0

	# Big panel with its title tab and close button.
	var panel := TextureRect.new()
	panel.texture = T_PANEL
	panel.position = PANEL_POS
	panel.size = T_PANEL.get_size()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if mode == Mode.PAUSE:
		panel.modulate.a = 0.6  # see-through frame; the cards on it stay solid
	_stage.add_child(panel)
	_tab_title = _label("", 32, TEXT)
	_tab_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tab_title.position = PANEL_POS + Vector2(530, 12)
	_tab_title.size = Vector2(306, 44)
	_stage.add_child(_tab_title)
	var close := Button.new()
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	close.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close.position = PANEL_POS + Vector2(1316, 10)
	close.size = Vector2(44, 44)
	close.pressed.connect(_on_close)
	_stage.add_child(close)

	var content := Control.new()
	content.position = PANEL_POS + Vector2(150, 125)
	content.size = Vector2(1066, 640)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(content)
	if mode == Mode.PAUSE:
		_pages["BIOMETRICS"] = _build_biometrics(content)
	_pages["MISSION"] = _build_mission(content)
	_pages["STATS"] = _build_stats(content)
	_pages["SETTINGS"] = _build_settings(content)
	_pages["CONTROLS"] = _build_controls(content)
	_pages["CREDITS"] = _build_credits(content)

	# Bottom buttons.
	var left_text := "START MISSION" if mode == Mode.MAIN else "RESUME"
	var right_text := "QUIT" if mode == Mode.MAIN else "MAIN MENU"
	var b1 := _big_button(left_text, Vector2(920, 966))
	var b2 := _big_button(right_text, Vector2(1402, 966))
	if mode == Mode.MAIN:
		b1.pressed.connect(_start_game)
		b2.pressed.connect(_quit)
	else:
		b1.pressed.connect(func(): resume_requested.emit())
		b2.pressed.connect(func():
			_play(confirm_sound)
			main_menu_requested.emit())

	if mode == Mode.MAIN:
		var logo := TextureRect.new()
		logo.texture = T_LOGO
		logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		logo.position = Vector2(70, 900)
		logo.size = Vector2(300, 140)
		logo.modulate = Color(1, 1, 1, 0.85)
		logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_stage.add_child(logo)
	else:
		var hint := _label("[TAB]  RESUME     [WASD]  WALK     [HOLD RIGHT MOUSE]  LOOK", 24, DIM)
		hint.position = Vector2(76, 990)
		_stage.add_child(hint)

	_loading = _label("LOADING MISSION...", 30, CYAN)
	_loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading.position = Vector2(490, 900)
	_loading.size = Vector2(1366, 50)
	_loading.visible = false
	_stage.add_child(_loading)


func _on_close() -> void:
	if mode == Mode.PAUSE:
		resume_requested.emit()
	elif _current != _first_section():
		_play(cancel_sound)
		_select(_first_section(), false)


# ------------------------------------------------------------------ pages

func _build_biometrics(parent: Control) -> Control:
	var page := _page(parent)
	var panel := BiometricsPanel.new()
	panel.font = _font
	# Use the panel's spare side margins: 12 cards need the room.
	panel.position = Vector2(-95, -12)
	panel.size = parent.size + Vector2(190, 12)
	page.add_child(panel)
	return page


func _build_mission(parent: Control) -> Control:
	var page := _page(parent)
	_reading_text(page, MISSION_TEXT)
	return page


const MISSION_TEXT := """[b][color=#8cf2ff]WELCOME TO BIOBEACON[/color][/b]
You volunteered to field-test NASA's newest astronaut health-monitoring system, built for long-duration expeditions. While you work on the lunar surface, Mission Control will follow your heart rate, core temperature, blood oxygen, suit CO2 and suit pressure in real time.

What we learn from you will shape how we keep explorers healthy the longer they are away from home. Pace yourself, manage your resources and rest when your body tells you to. We'll be watching closely to keep you safe.

[b][color=#8cf2ff]OBJECTIVE[/color][/b]
Collect all [color=#8cf2ff]lunar rock samples[/color].

Repair the [color=#8cf2ff]Perseverance rover[/color] parked beside the lander. We also need data to see how it will perform for its Mars expedition it was originally built for. It will collect samples for you and make your job easier.

[b][color=#8cf2ff]STAY ALIVE OUT THERE[/color][/b]
•  Your [color=#5dd97a]STAMINA[/color] and [color=#6fd6ff]O2 TANK[/color] (top left) drain as you work. Sprinting burns both fast.

•  Rest at the [color=#5dd97a]HABITAT[/color] or any [color=#5dd97a]OUTPOST[/color] (green beacons) to refill both.

•  Only the [color=#5dd97a]HABITAT[/color] (home base) gives you a real night's sleep. Outposts refill you but don't let you sleep. The longer you stay awake, the higher your [color=#8cf2ff]STRESS[/color]. Good sleep and low stress make your stamina and O2 last longer; poor sleep and high stress drain them faster.

•  High CO2 or low SpO2 makes you dizzy. Slow down and catch your breath.

•  Press [color=#8cf2ff]TAB[/color] any time during the mission to see what Mission Control sees: your live [color=#8cf2ff]BIOMETRICS[/color]. The simulation keeps running while you look.

•  Red [color=#ff6a5c]PRESSURE[/color] markers on the compass are hazard zones: your suit stiffens and you can barely move. Go around them.

•  Purple [color=#c77dff]RADIATION[/color] zones (a faint purple glow on the ground) are the deadliest places on the Moon. Your suit can't shed the heat: your core temperature, heart rate and breathing climb fast, and at 43 °C you'll be extracted. Never cut through one."""


func _build_stats(parent: Control) -> Control:
	var page := _page(parent)
	_stats_panel = StatsPanel.new()
	_stats_panel.font = _font
	# Same wide card area as the BIOMETRICS page.
	_stats_panel.position = Vector2(-95, -12)
	_stats_panel.size = parent.size + Vector2(190, 12)
	page.add_child(_stats_panel)
	return page


func _build_settings(parent: Control) -> Control:
	var page := _page(parent)
	var rows := [
		["camera_speed", "CAMERA SPEED", 0.25, 2.5, Vector2(0, 30)],
		["music_volume", "MUSIC", 0.0, 1.0, Vector2(580, 30)],
		["sfx_volume", "SOUND EFFECTS", 0.0, 1.0, Vector2(0, 190)],
	]
	for r in rows:
		_slider_row(page, r[0], r[1], r[2], r[3], r[4])

	# DEFAULT sits where a fourth slider would be, level with the SOUND EFFECTS slider.
	var reset := _big_button("DEFAULT", Vector2(580, 222), page, Vector2(340, 58))
	reset.pressed.connect(_reset_settings)

	# ESP32 sensor mode (ShockFrame toggle switch), one row lower on the same 160 px rhythm.
	var esp := _label("ESP32 SENSOR MODE", 30, TEXT)
	esp.position = Vector2(0, 360)
	page.add_child(esp)
	_esp32_btn = TextureButton.new()
	_esp32_btn.toggle_mode = true
	_esp32_btn.texture_normal = T_TOGGLE_OFF
	_esp32_btn.texture_pressed = T_TOGGLE_ON
	_esp32_btn.ignore_texture_size = true
	_esp32_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	_esp32_btn.position = Vector2(580, 352)
	_esp32_btn.size = Vector2(210, 54)
	_esp32_btn.focus_mode = Control.FOCUS_NONE
	_esp32_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_esp32_btn.button_pressed = GameSettings.esp32_mode
	_esp32_btn.toggled.connect(func(on: bool):
		GameSettings.esp32_mode = on
		GameSettings.save_settings()
		_play(confirm_sound if on else cancel_sound)
		_show_esp32())
	page.add_child(_esp32_btn)
	_esp32_state = _label("", 26, TEXT)
	_esp32_state.position = Vector2(808, 362)
	page.add_child(_esp32_state)
	_esp32_status = _label("", 22, Color(1.0, 0.82, 0.3))
	_esp32_status.position = Vector2(580, 418)
	page.add_child(_esp32_status)
	var lines := ["Live readings from the BioBeacon ESP32 kit. Keys",
		"1-5 or the arrow keys switch the kit's screen page."]
	for i in lines.size():
		var esp_note := _label(lines[i], 22, DIM)
		esp_note.position = Vector2(0, 418 + i * 32)
		page.add_child(esp_note)
	# The browser can't reach USB ports, so the web build (what the judges play) can't use the kit.
	var esp_warn := _label("WARNING: ESP32 mode only works in the Windows .exe version, not in the browser.",
		22, Color(1.0, 0.82, 0.3))
	esp_warn.position = Vector2(0, 490)
	page.add_child(esp_warn)
	_show_esp32()

	var note := _label("Settings are saved automatically.", 22, DIM)
	note.position = Vector2(0, 540)
	page.add_child(note)
	return page


func _slider_row(page: Control, key: String, text: String, lo: float, hi: float, pos: Vector2) -> void:
	var l := _label(text, 30, TEXT)
	l.position = pos
	page.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.01
	s.position = pos + Vector2(0, 62)
	s.size = Vector2(430, 24)
	s.focus_mode = Control.FOCUS_NONE
	s.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_style_slider(s)
	page.add_child(s)
	var v := _label("", 24, DIM)
	v.position = pos + Vector2(450, 56)
	page.add_child(v)
	_sliders[key] = [s, v]
	s.value = float(GameSettings.get(key))
	_show_value(key)
	s.value_changed.connect(func(val: float):
		GameSettings.set_value(key, val)
		_show_value(key))
	s.drag_ended.connect(func(_changed: bool):
		GameSettings.save_settings()
		if key == "sfx_volume":
			_play(confirm_sound))  # preview the new effects volume


func _show_esp32() -> void:
	var on := GameSettings.esp32_mode
	_esp32_btn.set_pressed_no_signal(on)
	_esp32_state.text = "ON" if on else "OFF"
	_esp32_state.add_theme_color_override("font_color", Color(0.4, 0.95, 0.55) if on else DIM)
	_show_esp32_status()


## Live connection line under the ESP32 toggle (searching / connected on COMx / port busy).
func _show_esp32_status() -> void:
	if not GameSettings.esp32_mode:
		_esp32_status.text = ""
		return
	var t := Esp32Link.status_text()
	_esp32_status.text = t if t != "" else "SEARCHING FOR DEVICE..."
	_esp32_status.add_theme_color_override("font_color",
		Color(0.4, 0.95, 0.55) if Esp32Link.status_ok() else Color(1.0, 0.82, 0.3))


func _show_value(key: String) -> void:
	var s: HSlider = _sliders[key][0]
	var v: Label = _sliders[key][1]
	v.text = ("%.2fx" % s.value) if key == "camera_speed" else str(roundi(s.value * 100.0))


func _reset_settings() -> void:
	_play(confirm_sound)
	var defaults := {"camera_speed": 1.0, "music_volume": 0.8, "sfx_volume": 1.0}
	for k in defaults:
		(_sliders[k][0] as HSlider).value = defaults[k]  # triggers set_value
	GameSettings.save_settings()


func _build_controls(parent: Control) -> Control:
	var page := _page(parent)
	var rows := [
		[["W", "A", "S", "D"], "MOVE", ""],
		[["MOUSE"], "LOOK AROUND", ""],
		[["SHIFT"], "SPRINT", "fast, but burns O2 and stamina"],
		[["SPACE"], "JUMP", ""],
		[["E"], "INTERACT", "hold to collect samples, repair and rest"],
		[["F"], "FLASHLIGHT", ""],
		[["TAB"], "MISSION CONTROL", "live biometrics, stats & settings"],
		[["F11"], "FULL SCREEN", "on / off"],
	]
	var y := 0.0
	for r in rows:
		var x := 0.0
		for key: String in r[0]:
			var cap := _keycap(key)
			cap.position = Vector2(x, y)
			page.add_child(cap)
			x += cap.size.x + 10.0
		var a := _label(r[1], 28, TEXT)
		a.position = Vector2(330, y + 6)
		page.add_child(a)
		if r[2] != "":
			var d := _label(r[2], 22, DIM)
			d.position = Vector2(330 + a.get_minimum_size().x + 18, y + 12)
			page.add_child(d)
		y += 76.0
	var note := _label("Key bindings are fixed for this demo.", 22, DIM)
	note.position = Vector2(0, y + 10)
	page.add_child(note)
	return page


const CREDITS_TEXT := """[b][color=#8cf2ff]MISSION CREW[/color][/b]
Nico Orobia
Vir Padhya
Minnoli Shukla
Clarissa Suryapranata
Reda Mourtada

[b][color=#8cf2ff]ITCH.IO[/color][/b]
[url=https://ultra-knight.itch.io/sci-fi-game-ui-asset-pack-shockframe][color=#8cf2ff]ShockFrame Sci-Fi Game UI[/color][/url]  by Ultra-Knight
[color=#9fc7cf]Menus and HUD: bars, compass, panels, buttons, icons[/color]

[url=https://agor2012.itch.io/astronaut-modular-low-poly-stylized][color=#8cf2ff]Astronaut Modular Low Poly Stylized[/color][/url]  by agor2012
[color=#9fc7cf]The player's astronaut and its animations[/color]

[b][color=#8cf2ff]POLY HAVEN[/color][/b]
[url=https://polyhaven.com/models/nature/rocks-stone][color=#8cf2ff]Moon Rocks 01, 04, 05, 07[/color][/url]
[color=#9fc7cf]Rock samples and scattered rocks[/color]

[b][color=#8cf2ff]NASA 3D RESOURCES[/color][/b]
[url=https://science.nasa.gov/3d-resources/][color=#8cf2ff]Apollo Lunar Module[/color][/url]
[color=#9fc7cf]The lander at the landing site[/color]

[url=https://science.nasa.gov/3d-resources/][color=#8cf2ff]70 Meter Dish[/color][/url]
[color=#9fc7cf]Comms dish beside the lander[/color]

[url=https://science.nasa.gov/3d-resources/][color=#8cf2ff]Habitat Demonstration Unit (part 1)[/color][/url]
[color=#9fc7cf]The base habitat and the outposts[/color]

[url=https://science.nasa.gov/3d-resources/][color=#8cf2ff]Perseverance Rover[/color][/url]
[color=#9fc7cf]The rover you repair[/color]

[url=https://science.nasa.gov/3d-resources/][color=#8cf2ff]Apollo 17 Landing Site[/color][/url]
[color=#9fc7cf]Terrain heightmap and ground level[/color]

[url=https://science.nasa.gov/3d-resources/][color=#8cf2ff]Apollo Hammer, Rake and Scoop[/color][/url]
[color=#9fc7cf]Sample-collection tools[/color]

[url=https://science.nasa.gov/3d-resources/][color=#8cf2ff]Sample Container[/color][/url]
[color=#9fc7cf]Sealing samples[/color]

[url=https://science.nasa.gov/3d-resources/][color=#8cf2ff]Wrench[/color][/url]
[color=#9fc7cf]Rover repair[/color]

[b][color=#8cf2ff]AUDIO[/color][/b]
[url=https://freesound.org/][color=#8cf2ff]Freesound[/color][/url]
[color=#9fc7cf]Footsteps, tools, rover, ambience, music and UI sounds[/color]"""


func _build_credits(parent: Control) -> Control:
	var page := _page(parent)
	var rt := _reading_text(page, CREDITS_TEXT)
	rt.meta_clicked.connect(func(meta): OS.shell_open(str(meta)))
	return page


const T_SCROLL := preload("uid://bu0b8x0xe7es4")          # Panels & Dialog/scroll.png
const T_SCROLL_GRAB := preload("uid://dmqstbnt0wy1e")     # Panels & Dialog/scroll - grabber.png
const READ_FONT := 36        ## Body text size on the reading pages (design px).
const READ_HEADING := 44

var _scrollers: Array[RichTextLabel] = []


## Large, scrollable text block (mouse wheel or drag the ShockFrame scroll bar).
func _reading_text(page: Control, bbcode: String) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.scroll_active = true
	rt.scroll_following = false
	rt.position = Vector2(-40, -20)
	rt.size = Vector2(1130, 660)
	rt.mouse_filter = Control.MOUSE_FILTER_STOP  # needed for wheel scrolling
	rt.meta_underlined = false  # links are shown in cyan instead
	rt.add_theme_font_override("normal_font", _font)
	rt.add_theme_font_override("bold_font", _font)
	rt.add_theme_font_size_override("normal_font_size", READ_FONT)
	rt.add_theme_font_size_override("bold_font_size", READ_HEADING)
	rt.add_theme_color_override("default_color", Color(TEXT, 0.95))
	rt.add_theme_constant_override("line_separation", 6)
	rt.text = bbcode
	var bar := rt.get_v_scroll_bar()
	bar.custom_minimum_size.x = 16
	var track := _tex_box(T_SCROLL)
	track.content_margin_left = 7
	track.content_margin_right = 7
	var grab := _tex_box(T_SCROLL_GRAB)
	grab.content_margin_left = 4
	grab.content_margin_right = 4
	bar.add_theme_stylebox_override("scroll", track)
	bar.add_theme_stylebox_override("scroll_focus", track)
	bar.add_theme_stylebox_override("grabber", grab)
	bar.add_theme_stylebox_override("grabber_highlight", grab)
	bar.add_theme_stylebox_override("grabber_pressed", grab)
	page.add_child(rt)
	_scrollers.append(rt)
	return rt


# ------------------------------------------------------------------ widgets

func _page(parent: Control) -> Control:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(c)
	return c


func _label(text: String, font_size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col)
	return l


func _tex_box(t: Texture2D) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = t
	return sb


func _style_section_button(b: Button, selected: bool) -> void:
	var normal := _tex_box(T_BTN_HOVER if selected else T_BTN)
	var hover := _tex_box(T_BTN_HOVER)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("disabled", normal)
	b.add_theme_color_override("font_color", DARK if selected else TEXT)
	b.add_theme_color_override("font_hover_color", DARK)
	b.add_theme_color_override("font_pressed_color", DARK)
	# The highlighted art is a little wider (glow): grow it out to the left like the mock-up.
	b.position.x = 55.0 if selected else 70.0
	b.size.x = 405.0 if selected else 390.0


func _big_button(text: String, pos: Vector2, parent: Control = null, sz := Vector2(392, 64)) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = sz
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", 28)
	var normal := _tex_box(T_BTN2)
	var hover := _tex_box(T_BTN2_HOVER)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("disabled", normal)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", DARK)
	b.add_theme_color_override("font_pressed_color", DARK)
	(parent if parent else _stage).add_child(b)
	return b


func _style_slider(s: HSlider) -> void:
	var track := _tex_box(T_SLIDER_BG)
	track.content_margin_top = 1
	track.content_margin_bottom = 1
	var fill := _tex_box(T_SLIDER_FG)
	fill.content_margin_top = 4
	fill.content_margin_bottom = 4
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	var g := _scaled_grabber()
	s.add_theme_icon_override("grabber", g)
	s.add_theme_icon_override("grabber_highlight", g)


var _grabber_tex: Texture2D
func _scaled_grabber() -> Texture2D:
	# The grabber art is tiny at 13x19; show it a bit larger.
	if _grabber_tex == null:
		var img := T_GRABBER.get_image()
		if img:
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			img.resize(20, 30, Image.INTERPOLATE_LANCZOS)
			_grabber_tex = ImageTexture.create_from_image(img)
		else:
			_grabber_tex = T_GRABBER
	return _grabber_tex


func _keycap(text: String) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.1, 0.13, 0.95)
	sb.border_color = Color(CYAN, 0.8)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _label(text, 26, CYAN)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	p.custom_minimum_size = Vector2(56, 52)
	p.size = p.get_combined_minimum_size()
	return p
