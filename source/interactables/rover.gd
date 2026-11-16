extends Interactable
## Broken Perseverance rover. Hold [E] with the wrench for a long time to repair it.
## When repaired: the blue marker ring turns off and one of the rover's own
## animations plays (by default the robotic arm) so the player sees it come alive.
## rover-moving.wav plays from the rover each time the arm starts a movement.
## Movement starts are found by measuring how fast the animated parts move
## (the clip also has a slow background creep, which is ignored). The clip is
## started right at its first real movement, so the arm swings the moment the
## repair finishes.
##
## Reward: once repaired, Perseverance goes autonomous. After showing off its arm it
## drives out to the nearest sample the player isn't busy with, swings its arm to
## collect it (the sample counts as collected, just like doing it yourself), pauses
## to analyse it, and moves on - with a side notification each time.

@export var repaired_animation := "armAction"   ## Name (or part of a name) of a clip in the rover model.
@export var snap_to_terrain := true
@export var moving_sound: AudioStream = preload("uid://bdwohfgxjh270")  # rover-moving.wav (arm servos)
@export var driving_sound: AudioStream = preload("uid://b3fxts1lxof4x")  # rover-driving.wav (wheels, loops while driving)
@export var moving_volume_db := 0.0
@export var sound_range := 40.0                 ## Meters until the sound fades out.

@export_group("Autonomous sampling (after repair)")
@export var autonomous := true
@export var startup_delay := 10.0               ## Seconds of arm show-off before it sets off.
@export var drive_speed := 1.6                  ## m/s. Kept slow so the player still does most of the work.
@export var turn_speed := 50.0                  ## Degrees per second.
@export var stop_distance := 3.2                ## How close it parks to a sample.
@export var collect_time := 6.0                 ## Arm-swinging at the sample before it's collected.
@export var analyse_time := 20.0                ## Pause after each sample before driving to the next.
@export var avoid_player_radius := 40.0         ## Leaves samples this close to the player for the player.
@export var drive_volume_db := 10.0             ## Wheel sound boost (the recording itself is quiet).
@export var drive_sound_range := 70.0           ## Meters the wheel sound carries (it keeps ~40 m from the player).

var _anim: AnimationPlayer
var _clip := ""
var _move_starts: Array[float] = []   # times in the clip where the arm starts moving
var _last_pos := -1.0
var _sfx: AudioStreamPlayer3D
var _drive_sfx: AudioStreamPlayer3D

enum State { BROKEN, STARTUP, DRIVE, COLLECT, ANALYSE, IDLE }
var _state := State.BROKEN
var _timer := 0.0
var _target: Interactable
var _terrain: LunarTerrain
var _collected := 0
var _yaw := 0.0


func _enter_tree() -> void:
	super._enter_tree()
	add_to_group("rover")  # yellow compass marker


func _ready() -> void:
	super._ready()
	if snap_to_terrain:
		var terrain := get_tree().get_first_node_in_group("terrain") as LunarTerrain
		if terrain:
			global_position.y = terrain.get_height(global_position.x, global_position.z)
	_anim = _find_anim_player(self)
	if _anim:
		_anim.stop()  # stays still (broken) until repaired
	_sfx = AudioStreamPlayer3D.new()
	_sfx.bus = &"SFX"
	_sfx.stream = moving_sound
	_sfx.volume_db = moving_volume_db
	_sfx.max_distance = sound_range
	_sfx.unit_size = 6.0
	_sfx.position = Vector3(0, 1.0, 0)
	add_child(_sfx)
	_drive_sfx = _sfx.duplicate() as AudioStreamPlayer3D
	_drive_sfx.stream = driving_sound
	_drive_sfx.volume_db = drive_volume_db
	_drive_sfx.max_db = maxf(drive_volume_db, 3.0)  # 3D players cap at +3 dB by default
	_drive_sfx.max_distance = drive_sound_range
	_drive_sfx.unit_size = 12.0
	_drive_sfx.finished.connect(func():
		if _state == State.DRIVE:
			_drive_sfx.play())
	add_child(_drive_sfx)
	_terrain = get_tree().get_first_node_in_group("terrain") as LunarTerrain
	var fwd := -global_basis.z  # the model faces -Z (camera mast at the front)
	_yaw = atan2(fwd.x, fwd.z)


func _process(delta: float) -> void:
	if autonomous and _state != State.BROKEN:
		_autonomy(delta)
	if _clip == "" or not _anim.is_playing():
		return
	var pos := _anim.current_animation_position
	if pos < _last_pos:
		_last_pos = -0.001  # looped back to the start
	for t in _move_starts:
		if t > _last_pos and t <= pos:
			_sfx.play()
			break
	_last_pos = pos


func _finish(by: Node) -> void:
	super._finish(by)
	if autonomous:
		_state = State.STARTUP
		_timer = startup_delay
		Notifications.notify(get_tree(), "Perseverance is planning a route to the samples",
			"It will set off on its own shortly")
	if _anim == null:
		return
	for clip in _anim.get_animation_list():
		if repaired_animation.to_lower() in clip.to_lower():
			var a := _anim.get_animation(clip)
			a.loop_mode = Animation.LOOP_LINEAR
			_move_starts = _movement_starts(a)
			_clip = clip
			_anim.play(clip)
			# Skip the idle lead-in: begin right as the first swing starts.
			var first: float = _move_starts[0] if not _move_starts.is_empty() else 0.0
			_anim.seek(first, true)
			_last_pos = first - 0.001
			break


## Times in the clip where a real movement begins: the combined speed of all
## animated parts rises well above its usual (resting/creeping) level.
func _movement_starts(a: Animation) -> Array[float]:
	var dt := 1.0 / 30.0
	var speeds: Array[float] = []
	var prev := {}
	var t := 0.0
	while t <= a.length:
		var speed := 0.0
		for tr in a.get_track_count():
			var v: Variant
			match a.track_get_type(tr):
				Animation.TYPE_ROTATION_3D:
					v = a.rotation_track_interpolate(tr, t)
					if prev.has(tr):
						speed += rad_to_deg((prev[tr] as Quaternion).angle_to(v)) / dt  # degrees/s
				Animation.TYPE_POSITION_3D:
					v = a.position_track_interpolate(tr, t)
					if prev.has(tr):
						speed += ((v as Vector3) - prev[tr]).length() * 100.0 / dt  # cm/s
				_:
					continue
			prev[tr] = v
		speeds.append(speed)
		t += dt
	var sorted := speeds.duplicate()
	sorted.sort()
	var usual: float = sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0
	var threshold := maxf(usual * 2.5, 10.0)
	var starts: Array[float] = []
	var moving := false
	for i in speeds.size():
		if not moving and speeds[i] > threshold:
			moving = true
			starts.append(maxf(i * dt - 0.1, 0.0))  # a hair early: motors spin up before the arm visibly moves
		elif moving and speeds[i] < threshold * 0.6:
			moving = false
	return starts


# ------------------------------------------------------------------ autonomy

func _autonomy(delta: float) -> void:
	_timer -= delta
	match _state:
		State.STARTUP, State.ANALYSE:
			if _timer <= 0.0:
				_set_arm(false)
				_next_target()
		State.DRIVE:
			if not _valid(_target):
				_next_target()
				return
			var to := _target.global_position - global_position
			to.y = 0.0
			if to.length() <= stop_distance:
				_state = State.COLLECT
				_timer = collect_time
				_drive_sfx.stop()
				_set_arm(true)
				return
			_drive_toward(to, delta)
		State.COLLECT:
			if not _valid(_target):
				_set_arm(false)
				_next_target()
			elif _timer <= 0.0:
				_collect(_target)
				_set_arm(false)
				_state = State.ANALYSE
				_timer = analyse_time
		State.IDLE:
			if _timer <= 0.0:
				_timer = 5.0
				_next_target()  # in case new work turned up


func _next_target() -> void:
	_target = _pick_sample()
	if _target:
		_state = State.DRIVE
		if not _drive_sfx.playing:
			_drive_sfx.play()
	else:
		_state = State.IDLE
		_timer = 5.0
		_drive_sfx.stop()


## Nearest sample that is untouched and not right next to the player.
func _pick_sample() -> Interactable:
	var player := get_tree().get_first_node_in_group("interactor") as Node3D
	var best: Interactable = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("sample_rock"):
		var s := n as Interactable
		if not _valid(s) or s.step_index > 0:
			continue
		if player and s.global_position.distance_to(player.global_position) < avoid_player_radius:
			continue
		var d := s.global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best = s
	return best


func _valid(s: Interactable) -> bool:
	if s == null or not is_instance_valid(s) or not s.is_inside_tree() or s.done:
		return false
	# The player started working on it: leave it to them.
	var interactor := get_tree().get_first_node_in_group("interactor")
	if interactor and interactor.has_method("current_target") and interactor.current_target() == s 			and interactor.is_working():
		return false
	return s.step_index == 0 or _state == State.COLLECT


func _drive_toward(to: Vector3, delta: float) -> void:
	# Heading = direction of travel; the model's front is its -Z side.
	var want := atan2(to.x, to.z)
	var diff := wrapf(want - _yaw, -PI, PI)
	var step := deg_to_rad(turn_speed) * delta
	_yaw += clampf(diff, -step, step)
	var forward := Vector3(sin(_yaw), 0, cos(_yaw))
	var speed := drive_speed * clampf(1.0 - absf(diff) / PI * 1.5, 0.25, 1.0)  # slow down for sharp turns
	var p := global_position + forward * speed * delta
	if _terrain:
		p.y = _terrain.get_height(p.x, p.z)
	# Sit on the slope: tilt to the ground under the wheels.
	var up := Vector3.UP
	if _terrain:
		var e := 1.4
		var hx := _terrain.get_height(p.x + e, p.z) - _terrain.get_height(p.x - e, p.z)
		var hz := _terrain.get_height(p.x, p.z + e) - _terrain.get_height(p.x, p.z - e)
		up = Vector3(-hx, 2.0 * e, -hz).normalized()
	var z := -(forward - up * forward.dot(up)).normalized()
	var x := up.cross(z).normalized()
	global_transform = Transform3D(Basis(x, up, z), p)


## Runs every remaining step of the sample, exactly as if the player had done it
## (so it counts toward SAMPLES and disappears), then notifies the player.
func _collect(s: Interactable) -> void:
	if not _valid(s):
		return
	while not s.done:
		s.complete(self)
	_collected += 1
	Notifications.notify(get_tree(), "Perseverance has collected a sample for you",
		"Rover samples: %d" % _collected)


func _set_arm(on: bool) -> void:
	if _anim == null or _clip == "":
		return
	if on:
		_anim.play(_clip)
		var first: float = _move_starts[0] if not _move_starts.is_empty() else 0.0
		_anim.seek(first, true)
		_last_pos = first - 0.001
	else:
		_anim.pause()


func _find_anim_player(root: Node) -> AnimationPlayer:
	for c in root.get_children():
		if c is AnimationPlayer:
			return c
		var found := _find_anim_player(c)
		if found:
			return found
	return null
