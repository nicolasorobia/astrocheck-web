extends Node3D
## Outpost beacon: a thin mast with a blinking green light on top, so outposts can be
## spotted from far away while exploring. The light is drawn at the same size on screen
## at any distance and shows through hills (so players never lose the outposts), and
## fades out when you're right next to it.

@export var mast_height := 14.0
@export var color := Color(0.35, 1.0, 0.55)
@export var marker: Texture2D = preload("uid://cc6i6jfqhrnrb")  # HUD - map marker (green).png
@export var marker_size := 0.0028        ## Screen size of the far-away marker.
@export var blink_period := 1.6
@export var hide_within := 25.0          ## Marker fades out this close (the outpost itself is obvious).
@export var snap_to_terrain := true

var _light: OmniLight3D
var _bulb: MeshInstance3D
var _sprite: Sprite3D
var _t := 0.0


func _ready() -> void:
	if snap_to_terrain:
		_snap.call_deferred()  # after the outpost has placed itself

	var mast := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.09
	cyl.height = mast_height
	cyl.radial_segments = 8
	mast.mesh = cyl
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.75, 0.76, 0.78)
	metal.metallic = 0.6
	metal.roughness = 0.45
	mast.material_override = metal
	mast.position.y = mast_height * 0.5
	add_child(mast)

	_bulb = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.22
	sph.height = 0.44
	_bulb.mesh = sph
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = color
	_bulb.material_override = glow
	_bulb.position.y = mast_height + 0.2
	add_child(_bulb)

	_light = OmniLight3D.new()
	_light.light_color = color
	_light.omni_range = 14.0
	_light.position.y = mast_height + 0.2
	add_child(_light)

	_sprite = Sprite3D.new()
	_sprite.texture = marker
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.fixed_size = true
	_sprite.pixel_size = marker_size
	_sprite.shaded = false
	_sprite.no_depth_test = true  # visible over hills
	_sprite.render_priority = 10
	_sprite.position.y = mast_height + 0.2
	add_child(_sprite)


func _process(delta: float) -> void:
	_t += delta
	# Quick flash, then a slow fade: reads as a beacon rather than a pulse.
	var p := fposmod(_t, blink_period) / blink_period
	var k := 1.0 - smoothstep(0.0, 0.55, p)
	_light.light_energy = lerpf(0.3, 3.0, k)
	_bulb.visible = k > 0.15
	var near := 1.0
	var cam := get_viewport().get_camera_3d()
	if cam:
		near = smoothstep(hide_within * 0.6, hide_within, cam.global_position.distance_to(global_position))
	_sprite.modulate = Color(1, 1, 1, lerpf(0.35, 1.0, k) * near)


func _snap() -> void:
	var terrain := get_tree().get_first_node_in_group("terrain")
	if terrain and terrain.has_method("get_height"):
		global_position.y = terrain.get_height(global_position.x, global_position.z) - 0.2
