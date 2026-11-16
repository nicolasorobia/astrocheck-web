class_name Biometrics
extends Node
## Mission Control's view of the astronaut: everything the Vitals node simulates plus
## the slower, longer-term health readings a ground team tracks on a lunar surface stay.
## Runs all the time (also while the Tab menu is open) so the BIOMETRICS page shows the
## same live numbers as the field HUD.
##
## Reference values (NASA / published lunar data, rounded for the game):
## - Radiation: Chang'e-4's lunar lander dosimeter measured ~1.37 mSv/day on the
##   surface (~57 uSv/h), about 2-3x the ISS. A habitat's structure / regolith cover
##   cuts that roughly in half. NASA's career limit (NASA-STD-3001) is 600 mSv.
## - Bone: astronauts on the ISS lose ~1-1.5 % of hip bone mineral density per month.
##   1/6 g on the Moon is expected to slow that; walking and working (bone loading) is
##   the countermeasure, so the projected loss eases as the astronaut stays active.
## - Sleep: NASA studies found astronauts average only ~6 h of sleep per night in flight.
## - Metabolic rate: Apollo moonwalkers averaged ~230-300 W, peaking above 500 W.
## - Suit: ~4.3 psi (29.6 kPa) is the nominal pressure of NASA's EVA suits.

@export var vitals_path: NodePath = ^"../Vitals"

@export_group("Mission timeline")
@export var start_day := 1                    ## Surface day when the mission begins.
@export var seconds_per_day := 240.0          ## Real seconds per 24 h mission day (4 min: 1 real s = 6 mission min).
@export var start_hour := 7.0                 ## Clock time when the mission begins...
@export var woke_at_hour := 6.0               ## ...after waking up at this hour.
@export var wake_hour := 7.0                  ## Sleeping at the habitat lasts until this time next morning.
@export var max_sleep_hours := 9.0            ## Longest real sleep (an early night still only counts this much).
@export var min_sleep_hours := 4.0            ## Going to bed very late: you still sleep at least this long (and wake late).
@export var transit_days := 3.0               ## Earth-Moon transit before landing (microgravity: bone loss starts here).

@export_group("Radiation (uSv/h)")
@export var surface_dose_rate := 57.0         ## Unshielded lunar surface (Chang'e-4 LND).
@export var shielded_factor := 0.5            ## Inside / right next to a habitat or outpost.
@export var shelter_radius := 12.0
@export var prior_mission_dose := 1.5         ## mSv already received during the ~3-day transit.
@export var career_limit := 600.0             ## mSv (NASA-STD-3001).

@export_group("Bone (hip BMD)")
@export var preflight_bmd := 1.020            ## g/cm2, femoral neck.
@export var loss_per_month := 0.55            ## % / month at 1/6 g with no extra loading.
@export var loading_relief := 0.35            ## Up to this much of the loss is offset by staying active.
@export var daily_steps_goal := 6000.0
@export var steps_at_start := 1450.0          ## Steps already logged today (habitat chores, suit-up).
@export var stride := 0.9                     ## m per step in lunar gait.

@export_group("Sleep")
@export var last_sleep_hours := 6.1
@export var debt_start_hours := 16.0          ## Awake longer than this, the sleep score starts dropping...
@export var debt_per_hour := 3.0              ## ...by this many points per extra hour (36 h awake: -60).
@export var fatigue_start_hours := 12.0       ## Awake longer than this: stress starts climbing...
@export var fatigue_full_hours := 20.0        ## ...and is at its worst here.

@export_group("Endurance (sleep + stress -> drain)")
@export var best_drain := 0.82                ## Well rested & calm: stamina / O2 drain at 82 % (lasts ~20 % longer).
@export var worst_drain := 1.5                ## Exhausted & stressed: drain at 150 % (lasts a third less).
@export var best_ventilation := 0.88          ## Well rested & calm: breathing (and O2 use) 12 % below normal.
@export var worst_ventilation := 1.35         ## Exhausted & stressed: breathing 35 % faster (stress hyperventilation).

# Live readings (read by the BIOMETRICS page).
var dose_rate := 57.0         ## uSv/h
var eva_dose := 0.0           ## uSv received this session
var sheltered := false
var steps := 0.0
var total_steps := 0.0       ## Steps walked this whole expedition (for the STATS log).
var bmd := 1.02
var bmd_change := 0.0         ## % vs preflight
var bone_loss_rate := 0.55    ## projected % / month
var sleep_score := 79.0       ## Sleep readiness: last night's quality minus the sleep debt built up since.
var last_sleep_score := 79.0  ## Quality of the last real sleep (habitat only).
var awake_seconds := 0.0
var stress := 25.0            ## 0-100
var hrv := 55.0               ## RMSSD, ms
var resp_rate := 14.0         ## breaths / min
var metabolic := 110.0        ## W
var o2_minutes_left := 0.0    ## at the current breathing rate
var sim_seconds := 0.0        ## mission elapsed time (MET) since the sim started
var clock := 0.0              ## mission clock: seconds since Day 1 00:00
var mission_day := 1          ## Surface day (midnight rolls it over; sleeping skips to the next morning).
var time_scale := 360.0       ## mission seconds per real second (from seconds_per_day)
var stress_trend := 25.0      ## slow average of stress (what wears you down)
var drain_factor := 1.0       ## applied to the Vitals' stamina drain
var ventilation := 1.0        ## breathing-rate multiplier from stress / sleep (drives O2 use)

var _vitals: Vitals
var _player: Node3D
var _last_pos := Vector3.ZERO
var _noise := FastNoiseLite.new()
var _o2_rate := 0.05
var _last_o2 := 100.0


func _enter_tree() -> void:
	add_to_group("biometrics")


func _ready() -> void:
	_vitals = get_node_or_null(vitals_path) as Vitals
	_player = get_parent() as Node3D
	_last_pos = _player.global_position
	steps = steps_at_start
	time_scale = 86400.0 / maxf(seconds_per_day, 1.0)
	clock = (start_day - 1) * 86400.0 + start_hour * 3600.0
	mission_day = _day_of(clock)
	awake_seconds = (start_hour - woke_at_hour) * 3600.0
	last_sleep_score = _score_for(last_sleep_hours)
	sleep_score = last_sleep_score
	_noise.frequency = 0.15
	_hook_rest_stations.call_deferred()
	_announce_start.call_deferred()


func _announce_start() -> void:
	Notifications.notify(get_tree(), "SURFACE DAY %d  -  %s" % [mission_day, time_text()],
		"Mission start. Sleep at the habitat each night.", true)


func _hook_rest_stations() -> void:
	for b in get_tree().get_nodes_in_group("base"):
		if b.has_signal("rested"):
			b.rested.connect(_on_rested.bind(b))


func _process(delta: float) -> void:
	if _vitals == null:
		return
	var body_dt := delta * time_scale  # mission / body-clock time
	sim_seconds += body_dt
	awake_seconds += body_dt
	clock += body_dt
	if _day_of(clock) != mission_day:  # midnight out in the field
		mission_day = _day_of(clock)
		Notifications.notify(get_tree(), "SURFACE DAY %d  -  00:00" % mission_day,
			"Midnight. Awake %d h: get back to the habitat to sleep." % int(awake_seconds / 3600.0), true)
	var v := _vitals

	# Radiation: steady galactic cosmic ray background, halved near shelter.
	sheltered = false
	for b in get_tree().get_nodes_in_group("base"):
		if (b as Node3D).global_position.distance_to(_player.global_position) < shelter_radius:
			sheltered = true
			break
	var target_rate := surface_dose_rate * (shielded_factor if sheltered else 1.0)
	target_rate += RadiationZone.dose_at(get_tree(), _player.global_position)
	target_rate *= 1.0 + 0.06 * _noise.get_noise_1d(sim_seconds * 2.0)  # counting noise
	dose_rate = lerpf(dose_rate, target_rate, 1.0 - exp(-delta * 1.5))
	eva_dose += dose_rate / 3600.0 * body_dt

	# Bone loading: count steps from distance walked on the ground.
	var p := _player.global_position
	var moved := Vector2(p.x - _last_pos.x, p.z - _last_pos.z).length()
	_last_pos = p
	if moved < 2.0:  # ignore teleports (rescue)
		steps += moved / stride
		total_steps += moved / stride
	var activity := clampf(steps / daily_steps_goal, 0.0, 1.0)
	bone_loss_rate = loss_per_month * (1.0 - loading_relief * activity)
	var days := transit_days + sim_seconds / 86400.0
	bmd_change = -bone_loss_rate * days / 30.0
	bmd = preflight_bmd * (1.0 + bmd_change / 100.0)

	# Breathing / metabolism.
	resp_rate = lerpf(resp_rate, lerpf(13.0, 34.0, v.breathing) * v.ventilation, 1.0 - exp(-delta * 1.2))
	var hr_load := clampf((v.heart_rate - v.resting_hr) / (v.max_hr - v.resting_hr), 0.0, 1.0)
	metabolic = lerpf(metabolic, lerpf(105.0, 560.0, maxf(v.intensity, hr_load)), 1.0 - exp(-delta * 0.8))
	var rate := v.o2_use_rate()
	if v.oxygen > _last_o2 + 1.0:
		_o2_rate = rate  # tank just refilled (rest): don't carry the old breathing rate over
	_last_o2 = v.oxygen
	_o2_rate = lerpf(_o2_rate, rate, 1.0 - exp(-delta * 1.5))
	o2_minutes_left = v.oxygen / maxf(_o2_rate, 0.001) / 60.0

	# Stress: physiological load + the things a crew member would be worried about.
	var hr_n := clampf((v.heart_rate - v.resting_hr) / (v.max_hr - v.resting_hr), 0.0, 1.0)
	var co2_n := smoothstep(5.0, 12.0, v.co2)
	var hyp := 1.0 - smoothstep(86.0, 95.0, v.spo2)
	var press := smoothstep(4.6, 7.0, v.suit_pressure)
	var tank := 1.0 - smoothstep(0.1, 0.35, v.oxygen_fraction())
	var tired := 1.0 - v.stamina_fraction()
	var sleep_debt := clampf((85.0 - sleep_score) / 40.0, 0.0, 1.0)
	# Long hours away from a real night's sleep wear on you.
	var awake_h := awake_seconds / 3600.0
	# Sleep readiness: outpost rests don't count, so the debt keeps growing until the habitat.
	sleep_score = clampf(last_sleep_score - maxf(awake_h - debt_start_hours, 0.0) * debt_per_hour, 10.0, 98.0)
	var fatigue := smoothstep(fatigue_start_hours, fatigue_full_hours, awake_h)
	var heat := smoothstep(37.8, 42.5, v.temperature)  # overheating is frightening
	var s_target := 15.0 + 25.0 * heat + 10.0 * v.radiation + 28.0 * hr_n + 12.0 * co2_n + 15.0 * hyp + 10.0 * press + 14.0 * tank 		+ 6.0 * tired + 12.0 * sleep_debt + 35.0 * fatigue
	# Acute danger (heat / radiation) spikes stress quickly; otherwise it drifts.
	var s_speed := 1.2 if heat > 0.2 or v.radiation > 0.0 else 0.25
	stress = lerpf(stress, clampf(s_target, 0.0, 100.0), 1.0 - exp(-delta * s_speed))
	stress_trend = lerpf(stress_trend, stress, 1.0 - exp(-delta / 45.0))
	hrv = lerpf(68.0, 18.0, stress / 100.0)

	# Endurance: good sleep and low stress make stamina and O2 last longer.
	# Endurance: good sleep and low stress make stamina last longer, and keep breathing
	# (so O2 use) calm. Poor sleep / high stress: faster breathing burns the tank faster.
	var bad := condition_badness()
	drain_factor = lerpf(best_drain, worst_drain, bad)
	ventilation = lerpf(best_ventilation, worst_ventilation, bad)
	v.drain_factor = drain_factor
	v.ventilation = ventilation


## Only the home base gives a real night's sleep. Outposts just refill O2 and energy:
## they don't touch the sleep score or the hours awake.
func _on_rested(station: Node) -> void:
	var main: Variant = station.get("is_main_base")
	if main == null or bool(main):
		# Sleep until the next morning. Getting in late means a short night.
		var morning := floorf(clock / 86400.0) * 86400.0 + wake_hour * 3600.0
		if morning <= clock:
			morning += 86400.0
		var until_morning := (morning - clock) / 3600.0
		last_sleep_hours = clampf(until_morning, min_sleep_hours, max_sleep_hours)
		var passed := maxf(until_morning, last_sleep_hours) * 3600.0
		clock += passed
		sim_seconds += passed
		eva_dose += surface_dose_rate * shielded_factor * passed / 3600.0  # inside the habitat
		mission_day = _day_of(clock)
		last_sleep_score = _score_for(last_sleep_hours)
		sleep_score = last_sleep_score
		awake_seconds = 0.0
		steps = 0.0  # new day, new step count
		Notifications.notify(get_tree(), "SURFACE DAY %d  -  %s" % [mission_day, time_text()],
			"Good morning. Slept %.1f h, sleep score %d." % [last_sleep_hours, roundi(sleep_score)], true)
		stress = minf(stress, 20.0)
		stress_trend = minf(stress_trend, 20.0)


## 0 = peak (sleep ~95, stress ~20 or less) .. 1 = poor (sleep ~55, stress ~65+).
func condition_badness() -> float:
	var sleep_bad := clampf((95.0 - sleep_score) / 40.0, 0.0, 1.0)
	var stress_bad := clampf((stress_trend - 20.0) / 45.0, 0.0, 1.0)
	return 0.5 * sleep_bad + 0.5 * stress_bad


## How long stamina / O2 last compared with normal (100 %).
func endurance_percent() -> float:
	return 100.0 / drain_factor


func _score_for(hours: float) -> float:
	return clampf(100.0 - 10.0 * maxf(8.0 - hours, 0.0) - 2.0, 30.0, 98.0)


func _day_of(t: float) -> int:
	return int(floorf(t / 86400.0)) + 1


## Mission clock time of day, "HH:MM".
func time_text() -> String:
	var s := int(fposmod(clock, 86400.0))
	return "%02d:%02d" % [s / 3600, (s / 60) % 60]


func career_dose_percent() -> float:
	return (prior_mission_dose + eva_dose / 1000.0) / career_limit * 100.0


func mission_dose() -> float:
	return prior_mission_dose + eva_dose / 1000.0


func stress_label() -> String:
	if stress < 26.0:
		return "RESTING"
	if stress < 51.0:
		return "LOW"
	if stress < 76.0:
		return "MEDIUM"
	return "HIGH"
