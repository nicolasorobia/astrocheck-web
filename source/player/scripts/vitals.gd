class_name Vitals
extends Node
## The astronaut's body: heart rate, core temperature, suit CO2 and stamina.
##
## Everything is driven by one number, the current *intensity* (0 = resting,
## 1 = flat-out), taken from what the player is doing:
##   standing still 0 · walking 0.25 · sample work ~0.35 · rover repair ~0.75 · sprinting 1
## (task values come from each Interactable's `exertion`).
##
## - Heart rate chases a target set by intensity, rising faster for harder work.
## - Core temperature follows more slowly (the suit takes time to heat up / cool).
## - Breathing follows heart rate + temperature, and suit CO2 builds up when the
##   astronaut breathes harder than the scrubber can keep up with.
## - Stamina drains with intensity (much faster for hard work), more when overheated.
##   It does not come back on its own: rest at the habitat to refill it.
## - High CO2 makes the astronaut lightheaded (`lightheaded` 0..1), which the
##   camera script turns into shake and sluggish aiming.
## - The oxygen tank is burned by breathing, so it empties faster than stamina when
##   working hard. Only resting at the habitat refills it. On an empty tank CO2 climbs,
##   SpO2 sinks and stamina drains twice as fast.
## - SpO2 (blood oxygen) falls as suit CO2 rises; low SpO2 also makes you dizzy.
## - Suit pressure rises inside PressureZones; above ~5 psi the suit stiffens
##   (`mobility` < 1): no sprinting, slower walking, weaker jumps.
## - Inside a RadiationZone the suit can't shed heat: core temperature climbs fast
##   (no cooling until you get out), dragging heart rate, breathing (O2 use, CO2),
##   dizziness and stamina drain up with it. At `critical_temp` the medical team
##   extracts the astronaut (MedicalRescue).
## (SpO2 / pressure are the values the ESP32 sensor kit will feed in later.)

signal exhausted                     ## Stamina hit zero.

@export var player_path: NodePath = ^".."
@export var interactor_path: NodePath = ^"../head/Camera3D/Interactor"

@export_group("Activity intensity (0-1)")
@export var walk_intensity := 0.25
@export var sprint_intensity := 1.0
@export var jump_intensity := 0.5    ## Brief bump while airborne after a jump.

@export_group("Heart rate (bpm)")
@export var resting_hr := 72.0
@export var max_hr := 168.0
@export var hr_rise_rate := 5.0      ## bpm/s at full intensity (scaled down for lighter work).
@export var hr_recover_rate := 2.5   ## bpm/s back toward the target when easing off.

@export_group("Core temperature (°C)")
@export var normal_temp := 36.8
@export var max_temp := 38.6
@export var temp_rise_time := 150.0   ## Seconds to get most of the way to the target when working.
@export var temp_cool_time := 150.0

@export_group("Radiation heat")
@export var radiation_heat_rate := 0.22  ## °C/s at a zone's core (36.8 -> 43 in ~30 s; ~80 s at the edge).
@export var critical_temp := 43.0        ## Extraction (game over) at this core temperature.
@export var heat_hr_start := 37.5        ## Heat drives the heart: from this temperature...
@export var heat_hr_full := 42.0         ## ...to max heart rate here.

@export_group("Suit CO2 (mmHg)")
@export var co2_baseline := 2.5
@export var co2_max := 17.0          ## Where sustained flat-out work ends up.
@export var co2_rise_time := 70.0
@export var co2_clear_time := 60.0   ## Scrubber catching up when resting.
@export var lightheaded_start := 7.0 ## CO2 where dizziness begins...
@export var lightheaded_full := 13.0 ## ...and where it is at its worst.

@export_group("Stamina (%)")
@export var stamina := 100.0
@export var drain_at_full := 0.55    ## %/s at intensity 1. Walking empties a full bar in ~12 min, sprinting in ~2.5 min.
@export var drain_curve := 1.0       ## > 1: hard work costs disproportionately more than light work.
@export var heat_drain_bonus := 0.6  ## Extra drain per °C above 37.2.

@export_group("Oxygen tank (%)")
@export var oxygen := 100.0
@export var o2_idle_drain := 0.05    ## %/s just standing and breathing (~33 min).
@export var o2_work_drain := 1.1     ## Extra %/s at full breathing. Flat-out sprinting empties a tank in ~1.5-2 min, walking in ~10 min.
@export var o2_drain_curve := 1.6    ## > 1: heavy breathing burns disproportionately more oxygen.
@export var empty_stamina_factor := 2.0  ## Stamina drains this much faster on an empty tank.
@export var empty_tank_time := 200.0   ## On an empty tank, CO2 / SpO2 drift this slowly: ~40 s of clear-headed reserve to get home.

@export_group("Blood oxygen SpO2 (%)")
@export var spo2_normal := 98.0
@export var spo2_per_co2 := 0.55     ## SpO2 points lost per mmHg of CO2 above baseline.
@export var spo2_empty_tank := 72.0  ## Where SpO2 sinks on an empty tank.
@export var spo2_time := 20.0
@export var hypoxia_start := 93.0    ## SpO2 where low oxygen starts making you dizzy...
@export var hypoxia_full := 82.0     ## ...and where it is at its worst.

@export_group("Suit pressure (psi)")
@export var nominal_pressure := 4.3  ## Normal EVA suit pressure.
@export var zone_pressure_rise := 3.7  ## Extra psi at the heart of a pressure zone.
@export var pressure_time := 2.5     ## How quickly the reading follows.
@export var mobility_loss_start := 5.0  ## psi where the suit starts to stiffen...
@export var mobility_loss_full := 8.0   ## ...and where movement is at its slowest.
@export var min_mobility := 0.15
@export var pressure_effort := 0.45   ## Extra intensity when walking with the suit fully stiff.

var heart_rate := 72.0
var temperature := 36.8
var co2 := 2.5
var spo2 := 98.0
var suit_pressure := 4.3
var mobility := 1.0                  ## 1 = free; lower = stiff suit (player speed and jump scale with it).
var intensity := 0.0
var breathing := 0.0
var lightheaded := 0.0
var radiation := 0.0                 ## 0..1 radiation zone exposure right now.
var drain_factor := 1.0              ## Set by Biometrics from sleep + stress: stamina drain (< 1 lasts longer, > 1 drains faster).
var ventilation := 1.0               ## Set by Biometrics: stress / sleep loss make you breathe faster, which burns O2 faster.

var _player: CharacterBody3D
var _interactor: Interactor
var _jump_boost := 0.0
var _was_on_floor := true


func _ready() -> void:
	_player = get_node_or_null(player_path) as CharacterBody3D
	_interactor = get_node_or_null(interactor_path) as Interactor
	heart_rate = resting_hr
	temperature = normal_temp
	co2 = co2_baseline
	spo2 = spo2_normal
	suit_pressure = nominal_pressure


func _physics_process(delta: float) -> void:
	intensity = _current_intensity(delta)

	# Heart rate: quick to rise (faster the harder the work), slower to settle.
	var hr_target := lerpf(resting_hr, max_hr, intensity)
	# Overheating pushes the heart hard even standing still.
	var heat_load := smoothstep(heat_hr_start, heat_hr_full, temperature)
	hr_target = maxf(hr_target, lerpf(resting_hr, max_hr, heat_load))
	var rate := hr_rise_rate * (0.4 + maxf(intensity, heat_load)) if hr_target > heart_rate else hr_recover_rate
	heart_rate = move_toward(heart_rate, hr_target, rate * delta)

	# Core temperature: slow, follows effort.
	var t_target := lerpf(normal_temp, max_temp, intensity)
	var t_time := temp_rise_time / (0.5 + intensity) if t_target > temperature else temp_cool_time
	radiation = RadiationZone.influence_at(get_tree(), _player.global_position if _player else Vector3.ZERO)
	if radiation > 0.0:
		# Radiation zone: the suit can't shed heat, so no cooling, only heating.
		temperature = maxf(temperature, lerpf(temperature, t_target, 1.0 - exp(-delta * 3.0 / t_time)))
		temperature += radiation_heat_rate * radiation * delta
	else:
		temperature = lerpf(temperature, t_target, 1.0 - exp(-delta * 3.0 / t_time))

	# Breathing load from heart rate + heat -> CO2 build-up in the suit.
	var hr_n := clampf((heart_rate - resting_hr) / (max_hr - resting_hr), 0.0, 1.0)
	var t_n := clampf((temperature - normal_temp) / (max_temp - normal_temp), 0.0, 1.0)
	breathing = 0.7 * hr_n + 0.3 * t_n
	# Hyperthermia: fast, shallow breathing (burns O2, builds CO2).
	breathing = maxf(breathing, smoothstep(37.8, 42.5, temperature))
	var tank_empty := oxygen <= 0.0
	var c_target := lerpf(co2_baseline, co2_max, breathing * breathing)
	if tank_empty:
		c_target = co2_max  # no fresh gas: you rebreathe your own CO2
	var c_time := co2_rise_time if c_target > co2 else co2_clear_time
	if tank_empty:
		c_time = maxf(c_time, empty_tank_time)
	co2 = lerpf(co2, c_target, 1.0 - exp(-delta * 3.0 / c_time))

	# Oxygen tank: burned by breathing, so it tracks effort directly.
	oxygen = maxf(oxygen - o2_use_rate() * delta, 0.0)

	# Blood oxygen: falls as CO2 builds up (and sinks fast on an empty tank).
	var s_target := spo2_normal - spo2_per_co2 * maxf(co2 - co2_baseline, 0.0)
	if tank_empty:
		s_target = spo2_empty_tank
	spo2 = lerpf(spo2, s_target, 1.0 - exp(-delta * 3.0 / (empty_tank_time if tank_empty else spo2_time)))

	lightheaded = maxf(maxf(smoothstep(lightheaded_start, lightheaded_full, co2),
		1.0 - smoothstep(hypoxia_full, hypoxia_start, spo2)),
		smoothstep(39.5, 42.5, temperature))  # heat stroke dizziness

	# Suit pressure: rises inside pressure zones and stiffens the suit.
	var p_target := nominal_pressure + zone_pressure_rise * PressureZone.influence_at(get_tree(), _player.global_position if _player else Vector3.ZERO)
	suit_pressure = lerpf(suit_pressure, p_target, 1.0 - exp(-delta * 3.0 / pressure_time))
	mobility = lerpf(1.0, min_mobility, smoothstep(mobility_loss_start, mobility_loss_full, suit_pressure))

	# Stamina.
	if stamina > 0.0:
		var heat := 1.0 + maxf(temperature - 37.2, 0.0) * heat_drain_bonus
		var empty := empty_stamina_factor if tank_empty else 1.0
		stamina = maxf(stamina - drain_at_full * pow(intensity, drain_curve) * heat * empty * drain_factor * delta, 0.0)
		if stamina == 0.0:
			exhausted.emit()


func _enter_tree() -> void:
	add_to_group("vitals")


## A night's rest: stamina refilled and the body back to resting values.
func rest() -> void:
	stamina = 100.0
	oxygen = 100.0  # tank refilled at the habitat
	heart_rate = resting_hr
	temperature = normal_temp
	co2 = co2_baseline
	spo2 = spo2_normal
	lightheaded = 0.0
	intensity = 0.0
	breathing = 0.0


## O2 burned per second (%/s): effort-driven breathing, scaled by stress / sleep (ventilation).
func o2_use_rate() -> float:
	return (o2_idle_drain + o2_work_drain * pow(breathing, o2_drain_curve)) * ventilation


## Core temperature at the extraction limit.
func is_overheated() -> bool:
	return temperature >= critical_temp


func is_exhausted() -> bool:
	return stamina <= 0.0


func is_tank_empty() -> bool:
	return oxygen <= 0.0


## Suit too stiff to sprint (inside a pressure zone).
func can_sprint() -> bool:
	return suit_pressure < mobility_loss_start and not is_exhausted()


## 0..1 fraction for the HUD bar.
func stamina_fraction() -> float:
	return stamina / 100.0


func oxygen_fraction() -> float:
	return oxygen / 100.0


func _current_intensity(delta: float) -> float:
	var move := 0.0
	if _player:
		var on_floor := _player.is_on_floor()
		if _was_on_floor and not on_floor and _player.velocity.y > 0.5:
			_jump_boost = 1.0  # just jumped
		_was_on_floor = on_floor
		_jump_boost = maxf(_jump_boost - delta, 0.0)
		var speed := Vector2(_player.velocity.x, _player.velocity.z).length()
		if speed > 0.3 * mobility:
			var sprinting := not GameSettings.controls_locked and Input.is_action_pressed("sprint") and speed > float(_player.get("walk_speed")) + 0.3
			move = sprint_intensity if sprinting else walk_intensity
			# Pushing through a stiff, over-pressurised suit is hard work.
			move = minf(move + (1.0 - mobility) * pressure_effort, 1.0)
		move = maxf(move, jump_intensity * _jump_boost)
	var task := 0.0
	if _interactor and _interactor.is_working():
		var t: Interactable = _interactor.current_target()
		if t:
			task = t.exertion
	return maxf(move, task)
