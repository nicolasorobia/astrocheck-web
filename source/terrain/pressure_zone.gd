@tool
class_name PressureZone
extends Node3D
## A patch of ground with bad pressure readings. Walking into it raises the suit
## pressure (see Vitals), which stiffens the suit until the astronaut can barely move.
## The HUD warns when one is near, and the compass shows nearby zones in red.
##
## Pressure starts rising at `radius` and is at its worst inside `core_radius`.
## In the editor a red disc shows the zone so it can be moved around; in game it is
## invisible: the player only has their sensors.

@export var radius := 30.0:
	set(v):
		radius = v
		_update_gizmo()
@export var core_radius := 12.0:
	set(v):
		core_radius = v
		_update_gizmo()
@export var warning_distance := 25.0  ## "Zone ahead" warning this far outside the edge.
@export var strength := 1.0           ## 1 = full rise at the core.
@export var show_on_compass := true

var _gizmo: MeshInstance3D


func _enter_tree() -> void:
	add_to_group("pressure_zone")


func _ready() -> void:
	if Engine.is_editor_hint():
		_update_gizmo()


## 0 outside, rising to `strength` at the core.
func influence(pos: Vector3) -> float:
	var d := Vector2(pos.x - global_position.x, pos.z - global_position.z).length()
	return (1.0 - smoothstep(core_radius, radius, d)) * strength


## Meters from `pos` to the zone's edge (negative = inside).
func distance_to_edge(pos: Vector3) -> float:
	return Vector2(pos.x - global_position.x, pos.z - global_position.z).length() - radius


## Strongest influence of any zone at `pos`.
static func influence_at(tree: SceneTree, pos: Vector3) -> float:
	var best := 0.0
	if tree == null:
		return best
	for n in tree.get_nodes_in_group("pressure_zone"):
		var z := n as PressureZone
		if z and z.is_inside_tree():
			best = maxf(best, z.influence(pos))
	return best


## Closest zone (by distance to its edge), or null.
static func nearest(tree: SceneTree, pos: Vector3) -> PressureZone:
	var best: PressureZone = null
	var best_d := INF
	for n in tree.get_nodes_in_group("pressure_zone"):
		var z := n as PressureZone
		if z and z.is_inside_tree():
			var d := z.distance_to_edge(pos)
			if d < best_d:
				best_d = d
				best = z
	return best


func _update_gizmo() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _gizmo == null:
		_gizmo = MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1, 0.2, 0.15, 0.25)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_gizmo.material_override = mat
		add_child(_gizmo)  # not owned: never saved into the scene
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = 6.0
	m.radial_segments = 48
	m.cap_top = false
	m.cap_bottom = false
	_gizmo.mesh = m
	_gizmo.position.y = 2.0
	# Snap to the ground so it's visible against the terrain.
	var t := get_tree().get_first_node_in_group("terrain")
	if t and t.has_method("get_height"):
		_gizmo.global_position.y = t.get_height(global_position.x, global_position.z) + 2.0
