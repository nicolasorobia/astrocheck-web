extends Node3D
## First-person astronaut body.
## - Auto-fits the imported model (scale, facing, feet on the capsule bottom).
## - Hides head/helmet meshes from the player's camera (they still cast shadows).
## - Picks idle / walk / run / jump animations from the player's movement.
## - Moves the camera pivot ("head" node) to the head bone so walking bobs the view.

## Camera render layer that the player camera does NOT draw (camera cull_mask excludes layer 2).
const HIDDEN_LAYER := 2

@export var model_path: NodePath = ^"Model"
@export var camera_pivot_path: NodePath = ^"../head"

@export_group("Fit")
@export var target_height := 1.85          ## Model height in meters (capsule is 2 m tall).
@export var feet_y := -1.0                 ## Capsule bottom, in player space.

@export_group("First person")
## Mesh names containing any of these words are hidden from the player camera.
@export var hidden_mesh_keywords: PackedStringArray = ["helmet", "head", "hair", "beard", "glasses", "headphone"]
## From the head bone, in player space. The Camera3D already sits ~0.11 m forward of its pivot.
@export var eye_offset := Vector3(0.0, 0.08, 0.0)
@export var head_follow_smoothing := 12.0          ## Higher = camera follows head bob more tightly.

@export_group("Suit colors")
## Palette texture recolored to the Mark III suit's whites/greys. Applied to every mesh
## except the ones matching skin_mesh_keywords (face, hair, beard keep the original palette).
@export var suit_palette: Texture2D = preload("res://assets/Astronaut/FAB/Main_colors_mark3.png")
@export var skin_mesh_keywords: PackedStringArray = ["head", "hair", "beard"]

@export_group("Animations")
## Matched case-insensitively as substrings of the imported animation names.
@export var idle_anim := "idle"
@export var walk_anim := "walking_1"
@export var run_anim := "runing"           ## (sic) the pack spells it "Runing".
@export var jump_anim := "jumping"
@export var walk_reference_speed := 2.0    ## Player speed at which the walk plays at walk_anim_speed.
@export var run_reference_speed := 4.0
@export var walk_anim_speed := 0.75        ## < 1 for slow, heavy moon steps.
@export var run_anim_speed := 0.8
@export var blend_time := 0.25

var _player: CharacterBody3D
var _model: Node3D
var _skeleton: Skeleton3D
var _anim: AnimationPlayer
var _pivot: Node3D
var _head_bone := -1
var _anims := {}            # role -> animation name
var _current := ""
var _was_on_floor := true


func _ready() -> void:
	process_priority = 100  # run after the player and animation updates
	_player = get_parent() as CharacterBody3D
	_model = get_node(model_path) as Node3D
	_pivot = get_node_or_null(camera_pivot_path) as Node3D
	_skeleton = _find_first(_model, "Skeleton3D") as Skeleton3D
	_anim = _find_first(_model, "AnimationPlayer") as AnimationPlayer

	if _skeleton == null:
		push_error("astronaut_body: no Skeleton3D found in the model.")
		return

	_head_bone = _skeleton.find_bone("head")
	_fit_model()
	_setup_mesh_layers()
	_apply_suit_palette()
	_setup_animations()


func _process(delta: float) -> void:
	if _skeleton == null:
		return
	_update_animation()
	_follow_head(delta)


# ---------------------------------------------------------------- fitting

func _fit_model() -> void:
	_model.transform = Transform3D.IDENTITY
	var to_model := _model.global_transform.affine_inverse() * _skeleton.global_transform

	# Combined mesh bounds in model space.
	var aabb := AABB()
	var first := true
	for mi in _meshes():
		var box: AABB = (_model.global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
		aabb = box if first else aabb.merge(box)
		first = false
	if first or aabb.size.y <= 0.001:
		push_warning("astronaut_body: could not measure model; leaving transform as is.")
		return

	# Facing: from ankle to toe bones = the direction the model looks.
	var forward := Vector3.ZERO
	for side in ["l", "r"]:
		var foot := _skeleton.find_bone("foot_" + side)
		var ball := _skeleton.find_bone("ball_" + side)
		if foot >= 0 and ball >= 0:
			forward += (to_model * _skeleton.get_bone_global_rest(ball).origin) \
				- (to_model * _skeleton.get_bone_global_rest(foot).origin)
	forward.y = 0.0
	var yaw := 0.0
	if forward.length() > 0.0001:
		yaw = PI - atan2(forward.x, forward.z)  # rotate model forward onto -Z (player forward)

	var s := target_height / aabb.size.y
	var fit_basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s)

	# Center horizontally on the pelvis, feet on the capsule bottom.
	var center := aabb.get_center()
	var pelvis := _skeleton.find_bone("pelvis")
	if pelvis >= 0:
		center = to_model * _skeleton.get_bone_global_rest(pelvis).origin
	var origin := -(fit_basis * center)
	origin.y = feet_y - s * aabb.position.y
	_model.transform = Transform3D(fit_basis, origin)


func _setup_mesh_layers() -> void:
	for mi in _meshes():
		var n := String(mi.name).to_lower()
		var hidden := false
		for word in hidden_mesh_keywords:
			if word.to_lower() in n:
				hidden = true
				break
		# Hidden meshes keep casting shadows (the light still sees layer 2).
		mi.layers = (1 << (HIDDEN_LAYER - 1)) if hidden else 1


func _apply_suit_palette() -> void:
	if suit_palette == null:
		return
	for mi in _meshes():
		var n := String(mi.name).to_lower()
		var is_skin := false
		for word in skin_mesh_keywords:
			if word.to_lower() in n:
				is_skin = true
				break
		if is_skin or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var base := mi.get_active_material(i) as BaseMaterial3D
			if base == null:
				continue
			var mat := base.duplicate() as BaseMaterial3D
			mat.albedo_texture = suit_palette
			# Each face samples a single palette pixel; nearest filtering stops
			# neighbouring (orange) pixels from bleeding into the white suit.
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			mi.set_surface_override_material(i, mat)


# ---------------------------------------------------------------- animation

func _setup_animations() -> void:
	if _anim == null:
		push_warning("astronaut_body: no AnimationPlayer found in the model.")
		return
	var names := _anim.get_animation_list()
	var wanted := {"idle": idle_anim, "walk": walk_anim, "run": run_anim, "jump": jump_anim}
	for role: String in wanted:
		var found := _match_anim(names, wanted[role])
		if found == "":
			push_warning("astronaut_body: no animation matching '%s'. Available: %s" % [wanted[role], names])
			continue
		_anims[role] = found
		var a := _anim.get_animation(found)
		a.loop_mode = Animation.LOOP_NONE if role == "jump" else Animation.LOOP_LINEAR

	# Keep the character in place if the clips move the root bone forward.
	var root_track := _find_root_track()
	if root_track != NodePath():
		_anim.root_motion_track = root_track

	_play("idle", 1.0, 0.0)


func _update_animation() -> void:
	if _anim == null or _player == null:
		return
	var on_floor := _player.is_on_floor()
	var flat := Vector3(_player.velocity.x, 0.0, _player.velocity.z)
	var speed := flat.length()
	# Walking backwards plays the clip in reverse.
	var forward := -_player.global_transform.basis.z
	var dir_sign := -1.0 if flat.dot(forward) < -0.1 * speed else 1.0

	if not on_floor:
		if _was_on_floor:
			_play("jump", 1.0)
	elif speed < 0.15:
		_play("idle", 1.0)
	elif speed > (walk_reference_speed + run_reference_speed) * 0.5 and _anims.has("run"):
		_play("run", dir_sign * run_anim_speed * speed / run_reference_speed)
	else:
		_play("walk", dir_sign * walk_anim_speed * speed / walk_reference_speed)
	_was_on_floor = on_floor


func _play(role: String, speed: float, blend := -1.0) -> void:
	if not _anims.has(role):
		return
	var anim_name: String = _anims[role]
	# A negative speed_scale plays the clip in reverse (used for walking backwards).
	_anim.speed_scale = speed
	if _current == anim_name:
		return
	_current = anim_name
	_anim.play(anim_name, blend_time if blend < 0.0 else blend)


# ---------------------------------------------------------------- camera

func _follow_head(delta: float) -> void:
	if _pivot == null or _head_bone < 0:
		return
	var head_global := _skeleton.global_transform * _skeleton.get_bone_global_pose(_head_bone).origin
	var target := _player.to_local(head_global) + eye_offset
	var t := 1.0 - exp(-head_follow_smoothing * delta)
	_pivot.position = _pivot.position.lerp(target, t)


# ---------------------------------------------------------------- helpers

func _meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array[Node] = [_model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		stack.append_array(n.get_children())
	return out


func _find_first(root: Node, type_name: String) -> Node:
	if root.is_class(type_name):
		return root
	for c in root.get_children():
		var f := _find_first(c, type_name)
		if f:
			return f
	return null


func _match_anim(names: PackedStringArray, key: String) -> String:
	key = key.to_lower()
	for n in names:
		if key in n.to_lower():
			return n
	return ""


func _find_root_track() -> NodePath:
	if not _anims.has("walk"):
		return NodePath()
	var a := _anim.get_animation(_anims["walk"])
	for i in a.get_track_count():
		if a.track_get_type(i) != Animation.TYPE_POSITION_3D:
			continue
		var p := a.track_get_path(i)
		if p.get_subname_count() > 0 and p.get_concatenated_subnames() == "root":
			return p
	return NodePath()
