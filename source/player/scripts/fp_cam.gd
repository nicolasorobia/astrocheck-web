extends Node3D
## First-person mouse look on the "head" pivot (pitch here, yaw on the player).
## When the astronaut is lightheaded from high suit CO2 (Vitals.lightheaded 0..1)
## they get vertigo:
##   - the view pans around on its own (swinging left/right, nodding up/down),
##     so the player has to keep fighting it with the mouse,
##   - the camera trembles and rolls like the world is tilting,
##   - aiming gets sluggish (mouse input lags and is weaker).

@export var sensitivity := 0.2
@export var vitals_path: NodePath = ^"../Vitals"
@export var camera_path: NodePath = ^"Camera3D"

@export_group("Vertigo")
@export var pan_degrees_per_sec := 55.0   ## How fast the view swings by itself at full effect.
@export var pitch_pan_ratio := 0.35       ## Up/down swing compared to left/right.
@export var pan_speed := 0.35             ## How often the swing changes direction (higher = more erratic).
@export var shake_degrees := 3.5          ## Fast tremor at full effect.
@export var roll_degrees := 14.0          ## Slow world-tilting roll at full effect.
@export var nod_degrees := 6.0            ## Slow up/down bob of the camera at full effect.
@export var min_look_response := 2.5      ## How fast the view catches up with the mouse at full effect (lower = laggier).
@export var sensitivity_loss := 0.55      ## Fraction of mouse sensitivity lost at full effect.

var _vitals: Vitals
var _camera: Node3D
var _time := 0.0
var _pending := Vector2.ZERO    # mouse look not yet applied (yaw, pitch) in degrees
var _noise := FastNoiseLite.new()


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_vitals = get_node_or_null(vitals_path) as Vitals
	_camera = get_node_or_null(camera_path) as Node3D
	_noise.frequency = 0.6


## True while the astronaut is being played normally: the mouse must be captured
## (hidden and locked). Menus, dialogs, resting and the end screen all pause the game
## or set a flag, so the cursor is only free while one of those is up.
func _wants_capture() -> bool:
	return not GameSettings.menu_open and not GameSettings.controls_locked and not get_tree().paused


func _input(event: InputEvent) -> void:
	if GameSettings.controls_locked:
		return
	# Cursor should be locked but isn't (e.g. the browser released it on Esc):
	# a click is a user gesture, so the browser lets us lock it again.
	if event is InputEventMouseButton and event.pressed and _wants_capture() \
			and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		get_viewport().set_input_as_handled()
		return
	# Tab menu open: the cursor is for the menu; hold right mouse to look around.
	if GameSettings.menu_open and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return
	# Never steer the camera with a free cursor during play: that's what made the
	# view drift towards wherever the visible pointer was.
	if not GameSettings.menu_open and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var s := sensitivity * GameSettings.camera_speed * (1.0 - sensitivity_loss * _amount())
		_pending += Vector2(-event.relative.x, -event.relative.y) * s
		if _amount() <= 0.0:
			_apply_look(_pending)  # clear-headed: instant, exactly as before
			_pending = Vector2.ZERO


func _process(delta: float) -> void:
	_time += delta
	_keep_captured(delta)
	var a := _amount()

	# Sluggish look: feed the stored mouse movement in gradually.
	if _pending != Vector2.ZERO:
		var response := lerpf(60.0, min_look_response, a)
		var step := _pending * (1.0 - exp(-response * delta))
		_apply_look(step)
		_pending -= step

	if a > 0.0:
		# Vertigo pan: the view swings by itself. Noise is ~±0.6, so scale it up to ~±1.
		var t := _time * pan_speed
		var yaw := clampf(_n(t, 11.0) * 1.7, -1.0, 1.0)
		var pitch := clampf(_n(t * 1.3, 57.0) * 1.7, -1.0, 1.0) * pitch_pan_ratio
		# Keep the up/down swing from parking the view in the sky or the ground.
		pitch -= rad_to_deg(rotation.x) / 60.0
		_apply_look(Vector2(yaw, pitch) * pan_degrees_per_sec * a * delta)

	# Tremor + rolling tilt on the camera itself.
	if _camera:
		var shake := Vector3(_n(_time * 9.0, 3.0), _n(_time * 9.0, 29.0), _n(_time * 9.0, 71.0)) * 1.6 * shake_degrees
		var roll := sin(_time * 0.7) * 0.6 + _n(_time * 0.4, 91.0)
		var sway := Vector3(sin(_time * 1.1 + 0.5) * nod_degrees, 0.0, roll * roll_degrees)
		_camera.rotation_degrees = (shake + sway) * a


var _was_wanting := false
var _recapture_t := 0.0

## Re-locks the mouse whenever play resumes (menu closed, dialog closed, rest over,
## window refocused). In the browser, locking only works right after a key press or
## click, so there it tries once when play resumes and then waits for a click.
func _keep_captured(delta: float) -> void:
	var want := _wants_capture()
	if want and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		_recapture_t -= delta
		if not _was_wanting or (_recapture_t <= 0.0 and not OS.has_feature("web")):
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			_recapture_t = 0.25
	_was_wanting = want


## Turns the astronaut to look along `dir` (flattened), eyes level. Used after resting
## so they wake up facing out into the field instead of at the habitat wall.
func face_direction(dir: Vector3) -> void:
	dir.y = 0.0
	if dir.length() < 0.01:
		return
	_pending = Vector2.ZERO
	get_parent().rotation.y = atan2(-dir.x, -dir.z)
	rotation.x = 0.0


func _apply_look(deg: Vector2) -> void:
	get_parent().rotate_y(deg_to_rad(deg.x))
	rotate_x(deg_to_rad(deg.y))
	# prevent head from looking up or down 360 degrees
	rotation.x = clamp(rotation.x, deg_to_rad(-90), deg_to_rad(90))


func _n(x: float, y: float) -> float:
	return _noise.get_noise_2d(x, y)


func _amount() -> float:
	return _vitals.lightheaded if _vitals else 0.0
