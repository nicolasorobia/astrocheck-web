extends CharacterBody3D

## Moon movement: low gravity, slow heavy steps, little air control.

@export var walk_speed := 2.0
@export var run_speed := 4.0
@export var jump_velocity := 2.6        ## ~2 m high, ~3 s in the air at moon gravity.
@export var gravity_scale := 0.165      ## Moon gravity is about 1/6 of Earth's.
@export var ground_accel := 6.0         ## m/s² — low values make the suit feel heavy.
@export var ground_decel := 5.0
@export var air_accel := 1.0            ## Barely any steering mid-jump.
@export var exhausted_speed := 1.2      ## Walk speed once stamina is gone (no sprinting).
@export var stumble_strength := 0.8     ## How much vertigo (high CO2) pushes you off course while moving.

var _stumble_noise := FastNoiseLite.new()
var _time := 0.0

@onready var vitals: Vitals = get_node_or_null("Vitals")


func _ready() -> void:
	# Safety net: retrieves the astronaut to base if they collapse out in the field.
	var rescue := MedicalRescue.new()
	rescue.name = "MedicalRescue"
	add_child(rescue)
	# Mission Control's long-term health readings (shown on the Tab menu's BIOMETRICS page).
	var bio := Biometrics.new()
	bio.name = "Biometrics"
	add_child(bio)
	# End screen once every sample is collected.
	var done := MissionComplete.new()
	done.name = "MissionComplete"
	add_child(done)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * gravity_scale * delta

	var locked := GameSettings.controls_locked  # mission over: the astronaut stands still (the Tab menu doesn't lock movement)
	if not locked and Input.is_action_just_pressed("jump") and is_on_floor() and not (vitals and vitals.is_exhausted()):
		# A stiff, over-pressurised suit can barely push off.
		velocity.y = jump_velocity * (sqrt(vitals.mobility) if vitals else 1.0)

	_time += delta
	var input_dir := Vector2.ZERO if locked else Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	if vitals and vitals.lightheaded > 0.0 and input_dir != Vector2.ZERO:
		# Vertigo: legs don't go where you tell them; you veer and stagger.
		var t := _time * 0.5
		var veer := Vector2(_stumble_noise.get_noise_2d(t, 5.0), _stumble_noise.get_noise_2d(t, 77.0) * 0.5) * 1.7
		input_dir = (input_dir + veer * stumble_strength * vitals.lightheaded).limit_length(1.0)
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var sprint := not locked and Input.is_action_pressed("sprint") and not (vitals and not vitals.can_sprint())
	var speed := run_speed if sprint else walk_speed
	if vitals and vitals.is_exhausted():
		speed = exhausted_speed
	if vitals:
		speed *= vitals.mobility  # high suit pressure: every step is a fight
	var target := direction * speed

	var accel := ground_accel if direction else ground_decel
	if not is_on_floor():
		accel = air_accel

	var flat := Vector2(velocity.x, velocity.z).move_toward(Vector2(target.x, target.z), accel * delta)
	velocity.x = flat.x
	velocity.z = flat.y

	move_and_slide()
