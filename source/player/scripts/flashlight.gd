extends SpotLight3D
## Helmet flashlight. Press F (the "flashlight" action) to toggle it.
## Lights up the deep black shadows the low Sun casts on the Moon.

@export var start_on := false
@export var toggle_time := 0.08   ## Quick fade so switching doesn't pop.
@export var click_sound: AudioStream = preload("uid://be6g11inr3crq")  # flashlight.wav
@export var click_volume_db := -4.0

var _target_energy := 1.0
var _sfx: AudioStreamPlayer


func _ready() -> void:
	_target_energy = light_energy
	visible = start_on
	light_energy = _target_energy if start_on else 0.0
	_sfx = AudioStreamPlayer.new()
	_sfx.bus = &"SFX"
	_sfx.stream = click_sound
	_sfx.volume_db = click_volume_db
	add_child(_sfx)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("flashlight") and not GameSettings.controls_locked:
		set_on(not is_on())
		if _sfx.stream:
			_sfx.play()


func is_on() -> bool:
	return visible


func set_on(on: bool) -> void:
	var tw := create_tween()
	if on:
		visible = true
		tw.tween_property(self, "light_energy", _target_energy, toggle_time)
	else:
		tw.tween_property(self, "light_energy", 0.0, toggle_time)
		tw.tween_callback(func(): visible = false)
