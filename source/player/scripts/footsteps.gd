extends Node
## Gravel footsteps synced to the astronaut model's feet.
## Each foot is watched in the animation: when it comes back down to the ground
## after being lifted, one step sound plays. Walking and running both work since
## it follows the actual feet, not a timer.
##
## The sound file is one long recording of steps, so we play single steps cut out
## of it (start times found by analysing the file), picking a random one each time.

@export var stream: AudioStream = preload("res://assets/audio/walking-through-gravel.wav")
@export var body_path: NodePath = ^"../Body"
@export var volume_db := -4.0
@export var run_boost_db := 2.5        ## Running steps hit harder.
@export var step_length := 0.5         ## Seconds of audio per step.
@export var lift_to_arm := 0.09        ## Foot must rise this far (m) above the ground before the next step counts.
@export var plant_margin := 0.03       ## Within this of the ground counts as planted.
@export var min_speed := 0.3           ## Below this horizontal speed, no steps.

# Single steps inside walking-through-gravel.wav: [start seconds, loudness 0..1].
const STEPS := [
	[0.15, 0.35], [0.94, 0.36], [1.85, 0.51], [2.50, 0.37], [3.31, 0.61], [4.06, 1.0],
	[4.94, 0.70], [5.69, 0.34], [6.50, 0.46], [7.32, 0.26], [8.00, 0.90],
]
const FEET := ["foot_l", "foot_r"]

var _player: CharacterBody3D
var _body: Node
var _skeleton: Skeleton3D
var _bones: Array[int] = []
var _ground: Array[float] = []
var _armed: Array[bool] = []
var _players: Array[AudioStreamPlayer] = []
var _fades := {}  # player -> its running fade-out tween
var _next := 0
var _last_step := -1
var _was_on_floor := true


func _ready() -> void:
	_player = get_parent() as CharacterBody3D
	_body = get_node_or_null(body_path)
	for i in 3:  # small pool so overlapping steps don't cut each other off
		var a := AudioStreamPlayer.new()
		a.stream = stream
		a.bus = &"SFX"
		add_child(a)
		_players.append(a)


func _physics_process(_delta: float) -> void:
	if _skeleton == null:
		_find_skeleton()
		return
	var on_floor := _player.is_on_floor()
	var speed := Vector2(_player.velocity.x, _player.velocity.z).length()
	var running := Input.is_action_pressed("sprint") and speed > float(_player.get("walk_speed")) + 0.3

	# Landing from a jump: one heavier step.
	if on_floor and not _was_on_floor:
		_play_step(2.0)
	_was_on_floor = on_floor

	var to_player := _player.global_transform.affine_inverse() * _skeleton.global_transform
	for i in _bones.size():
		var h := (to_player * _skeleton.get_bone_global_pose(_bones[i]).origin).y
		# The ground level under each foot = the lowest it has been (slowly forgotten).
		_ground[i] = minf(_ground[i] + 0.0005, h)
		if h > _ground[i] + lift_to_arm:
			_armed[i] = true
		elif _armed[i] and h < _ground[i] + plant_margin:
			_armed[i] = false
			if on_floor and speed > min_speed:
				_play_step(run_boost_db if running else 0.0)


func _play_step(boost_db: float) -> void:
	if _players.is_empty():
		return
	var pick := randi() % STEPS.size()
	if pick == _last_step:
		pick = (pick + 1) % STEPS.size()
	_last_step = pick
	var start: float = STEPS[pick][0]
	var loud: float = STEPS[pick][1]
	var a := _players[_next]
	_next = (_next + 1) % _players.size()
	# Even out the recording (some steps are much quieter) and vary pitch a little.
	a.volume_db = volume_db + boost_db + linear_to_db(clampf(0.55 / loud, 0.6, 2.2))
	a.pitch_scale = randf_range(0.92, 1.08)
	if _fades.has(a) and _fades[a].is_valid():
		_fades[a].kill()
	a.play(start)
	var tw := a.create_tween()
	_fades[a] = tw
	tw.tween_interval(step_length)
	tw.tween_property(a, "volume_db", -60.0, 0.08)
	tw.tween_callback(a.stop)


func _find_skeleton() -> void:
	if _body == null:
		return
	_skeleton = _body.get("_skeleton") as Skeleton3D
	if _skeleton == null:
		return
	for name in FEET:
		var b := _skeleton.find_bone(name)
		if b >= 0:
			_bones.append(b)
			_ground.append(INF)
			_armed.append(false)
