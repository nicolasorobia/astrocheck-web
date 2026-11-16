@tool
class_name RadiationZone
extends Node3D
## A radiation hotspot: the most dangerous place on the map. Inside it, the dose rate
## spikes and the suit can't shed the heat, so the astronaut's core temperature climbs
## fast (see Vitals). At 43 °C Mission Control pulls them out (MedicalRescue).
##
## Heating starts at `radius` and is at its worst inside `core_radius`.
## The compass shows nearby zones in purple, and a faint purple glow wall marks the
## edge in the game world (a red-free disc in the editor shows it while placing).

@export var radius := 24.0:
	set(v):
		radius = v
		_build_visual()
@export var core_radius := 9.0:
	set(v):
		core_radius = v
		_build_visual()
@export var warning_distance := 25.0      ## "Radiation ahead" warning this far outside the edge.
@export var peak_dose_rate := 20000.0     ## uSv/h at the core (a solar-storm level hotspot).
@export var strength := 1.0
@export var show_on_compass := true
@export var show_in_game := true          ## Faint glow wall at the edge.

const PURPLE := Color(0.72, 0.35, 1.0)

var _wall: MeshInstance3D
var _t := 0.0


func _enter_tree() -> void:
	add_to_group("radiation_zone")


func _ready() -> void:
	_build_visual()


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _wall == null:
		return
	# Slow pulse so the wall reads as "active", not scenery.
	_t += delta
	var mat := _wall.material_override as StandardMaterial3D
	mat.albedo_color.a = 0.10 + 0.06 * (0.5 + 0.5 * sin(_t * TAU / 2.4))


## 0 outside; anywhere inside is dangerous (0.35 at the edge) rising to `strength` at the core.
func influence(pos: Vector3) -> float:
	var d := Vector2(pos.x - global_position.x, pos.z - global_position.z).length()
	if d >= radius:
		return 0.0
	return lerpf(0.35, 1.0, 1.0 - smoothstep(core_radius, radius, d)) * strength


## Meters from `pos` to the zone's edge (negative = inside).
func distance_to_edge(pos: Vector3) -> float:
	return Vector2(pos.x - global_position.x, pos.z - global_position.z).length() - radius


## Strongest influence of any zone at `pos`.
static func influence_at(tree: SceneTree, pos: Vector3) -> float:
	var best := 0.0
	if tree == null:
		return best
	for n in tree.get_nodes_in_group("radiation_zone"):
		var z := n as RadiationZone
		if z and z.is_inside_tree():
			best = maxf(best, z.influence(pos))
	return best


## Extra dose rate (uSv/h) from zones at `pos`.
static func dose_at(tree: SceneTree, pos: Vector3) -> float:
	var best := 0.0
	if tree == null:
		return best
	for n in tree.get_nodes_in_group("radiation_zone"):
		var z := n as RadiationZone
		if z and z.is_inside_tree():
			best = maxf(best, z.influence(pos) * z.peak_dose_rate)
	return best


## Closest zone (by distance to its edge), or null.
static func nearest(tree: SceneTree, pos: Vector3) -> RadiationZone:
	var best: RadiationZone = null
	var best_d := INF
	for n in tree.get_nodes_in_group("radiation_zone"):
		var z := n as RadiationZone
		if z and z.is_inside_tree():
			var d := z.distance_to_edge(pos)
			if d < best_d:
				best_d = d
				best = z
	return best


func _build_visual() -> void:
	if not is_inside_tree():
		return
	if not Engine.is_editor_hint() and not show_in_game:
		return
	if _wall == null:
		_wall = MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_color = Color(PURPLE, 0.25 if Engine.is_editor_hint() else 0.12)
		mat.albedo_texture = _fade_texture()
		_wall.material_override = mat
		_wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_wall)  # not owned: never saved into the scene
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = 5.0
	m.radial_segments = 64
	m.cap_top = false
	m.cap_bottom = false
	_wall.mesh = m
	_snap.call_deferred()


func _snap() -> void:
	if _wall == null or not is_inside_tree():
		return
	var t := get_tree().get_first_node_in_group("terrain")
	var ground := global_position.y
	if t and t.has_method("get_height"):
		ground = t.get_height(global_position.x, global_position.z)
	_wall.global_position = Vector3(global_position.x, ground + 1.5, global_position.z)


## Vertical gradient: bright at the ground, fading out towards the top of the wall.
func _fade_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0))
	g.set_color(1, Color(1, 1, 1, 1))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 64
	return gt
