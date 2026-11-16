extends Node
## Player preferences (autoload "GameSettings"): camera speed and volumes.
## Saved to user://settings.cfg so they survive restarts. Key bindings are fixed.
##
## Audio buses (default_bus_layout.tres): Music (menu music + ambience),
## Voice (for future voice lines), SFX (everything else).

signal changed

const PATH := "user://settings.cfg"
const VOLUME_BUSES := {"music": "Music", "voice": "Voice", "sfx": "SFX"}

var camera_speed := 1.0     ## Multiplier on mouse look (0.25 - 2.5).
var music_volume := 0.8     ## 0..1
var voice_volume := 1.0
var sfx_volume := 1.0
var esp32_mode := false     ## Read vitals from the ESP32 sensor kit instead of the simulation (hardware link not built yet).

## True when the astronaut must not respond to any keys at all (mission complete). Not saved.
var controls_locked := false
## True while the Tab menu is open. The astronaut can still walk, sprint, jump and use
## the flashlight so the biometrics react live; the mouse is free for the menu, so
## looking around needs the right mouse button held, and [E] interact is off. Not saved.
var menu_open := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_settings()
	apply()


## [F11] toggles full screen anywhere (menus, gameplay, debug play, the exe, the browser).
func _input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k and k.pressed and not k.echo and k.physical_keycode == KEY_F11:
		toggle_fullscreen()
		get_viewport().set_input_as_handled()


func toggle_fullscreen() -> void:
	if Engine.is_embedded_in_editor():
		push_warning("F11: full screen doesn't work while the game runs inside the editor's Game tab. "
			+ "In the Game tab's menu, untick 'Embed Game on Next Play', then press Play again.")
		return
	var full := DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN,
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full
		else DisplayServer.WINDOW_MODE_FULLSCREEN)


func set_value(key: String, value: float) -> void:
	set(key, value)
	apply()
	changed.emit()


func apply() -> void:
	_set_bus("Music", music_volume)
	_set_bus("Voice", voice_volume)
	_set_bus("SFX", sfx_volume)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for k in ["camera_speed", "music_volume", "voice_volume", "sfx_volume"]:
		cfg.set_value("settings", k, get(k))
	cfg.set_value("settings", "esp32_mode", esp32_mode)
	cfg.save(PATH)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for k in ["camera_speed", "music_volume", "voice_volume", "sfx_volume"]:
		set(k, float(cfg.get_value("settings", k, get(k))))
	esp32_mode = bool(cfg.get_value("settings", "esp32_mode", false))


func _set_bus(bus_name: String, v: float) -> void:
	var i := AudioServer.get_bus_index(bus_name)
	if i < 0:
		return
	AudioServer.set_bus_mute(i, v <= 0.001)
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(v, 0.001)))
