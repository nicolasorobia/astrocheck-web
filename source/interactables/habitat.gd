extends Interactable
## The habitat (NASA Habitat Demonstration Unit): the astronaut's base.
## Hold [E] to rest for the day: the screen fades to black, stamina and vitals are
## restored, then it fades back in right where the player was standing.
## Can be used any number of times. Shows as a green marker on the compass.
## Also used for the field outposts (outpost.tscn: smaller, `is_main_base` off) -
## rest stations out in the field where the astronaut can refill the O2 tank.
##
## The model is fitted at runtime: scaled so its longest side is `target_length`,
## centered on this node, sat on the terrain, given a matte material (the source
## file's material is fully metallic glass, which renders badly) and a simple
## box collider.

signal rested

@export var target_length := 12.0           ## Longest side of the habitat in meters.
@export var snap_to_terrain := true
@export var sink := 0.15                    ## Pushed into the ground a little so it doesn't float on slopes.
@export var box_fit := 0.92                 ## Collision box size relative to the model's footprint.
@export var is_main_base := true            ## Main habitat ("BASE" on the compass) vs a field outpost.
@export var clear_radius := 9.0             ## Rock scatter keeps this far away.

@export_group("Rest")
@export var fade_out_time := 1.2
@export var black_time := 1.6
@export var fade_in_time := 1.2
@export var rest_text := "Resting in the habitat…"
@export var rest_sound: AudioStream = preload("res://assets/audio/rest.wav")
@export var rest_volume_db := -3.0

var _resting := false


func _enter_tree() -> void:
	super._enter_tree()
	add_to_group("base")       # every rest station (compass, rest logic)
	add_to_group("keep_clear") # no scattered rocks inside it


func _ready() -> void:
	super._ready()
	single_use = false
	if snap_to_terrain:
		var terrain := get_tree().get_first_node_in_group("terrain") as LunarTerrain
		if terrain:
			global_position.y = terrain.get_height(global_position.x, global_position.z)
	_fit_model()


func can_interact() -> bool:
	return not _resting


func _finish(by: Node) -> void:
	super._finish(by)
	_rest()


# ------------------------------------------------------------------ rest sequence

func _rest() -> void:
	_resting = true
	var vitals := get_tree().get_first_node_in_group("vitals") as Vitals

	# Full-screen black overlay that keeps running while the game is paused.
	var layer := CanvasLayer.new()
	layer.layer = 100
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var black := ColorRect.new()
	black.color = Color(0, 0, 0, 0)
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(black)
	var label := Label.new()
	label.text = rest_text
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(0.83, 1.0, 0.99))
	label.modulate.a = 0.0
	layer.add_child(label)
	get_tree().root.add_child(layer)

	if rest_sound:
		var sfx := AudioStreamPlayer.new()
		sfx.stream = rest_sound
		sfx.bus = &"SFX"
		sfx.volume_db = rest_volume_db
		layer.add_child(sfx)  # lives (and keeps playing through the pause) with the overlay
		sfx.play()

	var tw := layer.create_tween()
	tw.tween_property(black, "color:a", 1.0, fade_out_time)
	tw.tween_callback(func():
		get_tree().paused = true  # world freezes while "asleep"
		if vitals:
			vitals.rest()
		_face_away(vitals))
	tw.tween_property(label, "modulate:a", 1.0, 0.4)
	tw.tween_interval(black_time)
	tw.tween_property(label, "modulate:a", 0.0, 0.4)
	tw.tween_callback(func(): get_tree().paused = false)
	tw.tween_property(black, "color:a", 0.0, fade_in_time)
	tw.tween_callback(func():
		layer.queue_free()
		_resting = false
		rested.emit())


## While the screen is black: turn the astronaut to face away from this station, so
## when it fades back in they're looking out at the field and can just walk off.
func _face_away(vitals: Vitals) -> void:
	var player: Node3D = vitals.get_parent() as Node3D if vitals else null
	if player == null:
		return
	var head := player.get_node_or_null("head")
	if head and head.has_method("face_direction"):
		head.face_direction(player.global_position - global_position)


# ------------------------------------------------------------------ model setup

func _fit_model() -> void:
	var model := get_node_or_null("Model") as Node3D
	if model == null:
		return
	var meshes: Array[MeshInstance3D] = []
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			meshes.append(n)
		stack.append_array(n.get_children())
	if meshes.is_empty():
		return

	# Bounds of the model in this node's space, before fitting.
	model.transform = Transform3D.IDENTITY
	var inv := global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for mi in meshes:
		var b: AABB = (inv * mi.global_transform) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false

	var s := target_length / maxf(box.size.x, box.size.z)
	var center := box.get_center()
	model.scale = Vector3.ONE * s
	model.position = Vector3(-center.x * s, -box.position.y * s - sink, -center.z * s)

	for mi in meshes:
		_fix_materials(mi)

	# One solid box around the whole habitat: cheap, and the player can aim at any
	# part of it (stairs and railings included) to rest.
	var shape := BoxShape3D.new()
	shape.size = Vector3(box.size.x * s * box_fit, box.size.y * s, box.size.z * s * box_fit)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0, shape.size.y * 0.5 - sink, 0)
	add_child(cs)


func _fix_materials(mi: MeshInstance3D) -> void:
	for i in mi.mesh.get_surface_count():
		var src := mi.get_active_material(i) as BaseMaterial3D
		if src == null:
			continue
		var m := src.duplicate() as BaseMaterial3D
		m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		m.metallic = 0.25
		m.metallic_texture = null
		m.roughness = 0.75
		m.roughness_texture = null
		m.cull_mode = BaseMaterial3D.CULL_DISABLED  # some panels are single-sided
		mi.set_surface_override_material(i, m)
