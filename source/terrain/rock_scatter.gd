extends Node3D
## Scatters moon rocks over the terrain when the level starts.
## Three size classes, each with its own count, size range and draw distance:
##   pebbles  - small, only around the landing zone, no collision, no shadows
##   rocks    - knee-to-waist high, across the whole map, no collision
##   boulders - big, across the map, solid (simple sphere collision), cast shadows
## Placement uses a fixed seed, so the layout is the same every run.
## Each rock is its own MeshInstance3D so Godot's automatic mesh LODs kick in
## per rock (distant rocks render with a few hundred triangles), and
## visibility ranges hide small rocks that are far away.

@export var terrain_path: NodePath = ^"../Terrain"
@export var rock_scenes: Array[PackedScene] = []
@export var seed := 17

@export_group("Pebbles (landing zone)")
@export var pebble_count := 350
@export var pebble_area_radius := 70.0
@export var pebble_size := Vector2(0.08, 0.45)       ## Min/max size in meters.
@export var pebble_draw_distance := 45.0

@export_group("Rocks")
@export var rock_count := 1800
@export var rock_size := Vector2(0.4, 1.4)
@export var rock_draw_distance := 140.0

@export_group("Boulders")
@export var boulder_count := 350
@export var boulder_size := Vector2(1.8, 6.0)
@export var boulder_draw_distance := 700.0

@export_group("Placement")
@export var keep_clear_radius := 24.0   ## No rocks/boulders this close to the landing zone center.
@export var interactable_clearance := 4.0  ## No scatter this close to sample rocks / other interactables.
@export var clustering := 0.6           ## 0 = even spread, 1 = rocks gather in patches.
@export var sink := 0.25                ## Fraction of each rock's height pushed into the ground.

var _rng := RandomNumberGenerator.new()
var _noise := FastNoiseLite.new()
var _terrain: LunarTerrain
var _meshes: Array[Mesh] = []
var _half_extent := Vector2.ZERO
var _center := Vector2.ZERO
var _clear_points: Array[Vector3] = []  # x, z, radius


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path) as LunarTerrain
	if _terrain == null:
		push_error("rock_scatter: terrain not found at %s" % terrain_path)
		return
	_collect_meshes()
	if _meshes.is_empty():
		push_error("rock_scatter: no rock meshes found in rock_scenes.")
		return

	_rng.seed = seed
	_noise.seed = seed
	_noise.frequency = 0.012
	_half_extent = _terrain.get_half_extent() - Vector2(4, 4)
	_center = _terrain.flatten_center

	for n in get_tree().get_nodes_in_group("interactable"):
		var p3 := (n as Node3D).global_position
		_clear_points.append(Vector3(p3.x, p3.z, interactable_clearance))
	# Big props (e.g. the comms dish) keep a wider area clear.
	for n in get_tree().get_nodes_in_group("keep_clear"):
		var p3 := (n as Node3D).global_position
		_clear_points.append(Vector3(p3.x, p3.z, float(n.get("clear_radius"))))

	var body := StaticBody3D.new()  # one body holds all boulder colliders
	body.name = "BoulderCollision"
	add_child(body)

	_scatter(pebble_count, pebble_size, pebble_draw_distance, false, body, pebble_area_radius)
	_scatter(rock_count, rock_size, rock_draw_distance, false, body)
	_scatter(boulder_count, boulder_size, boulder_draw_distance, true, body)


func _scatter(count: int, size_range: Vector2, draw_distance: float, solid: bool,
		body: StaticBody3D, area_radius := -1.0) -> void:
	var placed := 0
	var attempts := 0
	while placed < count and attempts < count * 6:
		attempts += 1
		var p := _random_point(area_radius)
		if area_radius < 0.0 and p.distance_to(_center) < keep_clear_radius:
			continue
		if _near_interactable(p):
			continue
		# Clustering: reject points where the noise says "empty patch".
		var n := (_noise.get_noise_2d(p.x, p.y) + 1.0) * 0.5
		if _rng.randf() > lerpf(1.0, n * n * 2.0, clustering):
			continue

		var mesh := _meshes[_rng.randi() % _meshes.size()]
		# Skew sizes toward the small end so big ones stay special.
		var size := lerpf(size_range.x, size_range.y, pow(_rng.randf(), 2.0))
		_place(mesh, p, size, draw_distance, solid, body)
		placed += 1


func _near_interactable(p: Vector2) -> bool:
	for c in _clear_points:
		if p.distance_squared_to(Vector2(c.x, c.y)) < c.z * c.z:
			return true
	return false


func _random_point(area_radius: float) -> Vector2:
	if area_radius > 0.0:
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * area_radius
		return _center + Vector2(cos(a), sin(a)) * r
	return Vector2(_rng.randf_range(-_half_extent.x, _half_extent.x),
		_rng.randf_range(-_half_extent.y, _half_extent.y))


func _place(mesh: Mesh, p: Vector2, size: float, draw_distance: float, solid: bool, body: StaticBody3D) -> void:
	var aabb := mesh.get_aabb()
	var longest := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var s := size / maxf(longest, 0.001)
	# Random shape variety: slightly squash/stretch, random yaw, small tilt.
	var stretch := Vector3(_rng.randf_range(0.85, 1.15), _rng.randf_range(0.7, 1.1), _rng.randf_range(0.85, 1.15)) * s
	var yaw := Basis(Vector3.UP, _rng.randf() * TAU)
	var b := yaw \
		* Basis(Vector3.RIGHT, _rng.randf_range(-0.15, 0.15)) \
		* Basis.from_scale(stretch)

	var ground := _terrain.get_height(p.x, p.y)
	var bottom := aabb.position.y * stretch.y
	var height := aabb.size.y * stretch.y
	var y := ground - bottom - height * sink

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = Transform3D(b, Vector3(p.x, y, p.y) - b * Vector3(aabb.get_center().x, 0, aabb.get_center().z))
	mi.visibility_range_end = draw_distance
	mi.visibility_range_end_margin = draw_distance * 0.1
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if size > 0.8 \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	if solid:
		# A box a bit smaller than the rock, turned the same way (no scale on shapes).
		var box := BoxShape3D.new()
		box.size = aabb.size * stretch * Vector3(0.8, 1.0, 0.8)
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.transform = Transform3D(yaw, Vector3(p.x, y + bottom + height * 0.5, p.y))
		body.add_child(cs)


func _collect_meshes() -> void:
	for scene in rock_scenes:
		if scene == null:
			continue
		var inst := scene.instantiate()
		var mi := _find_mesh(inst)
		if mi and mi.mesh:
			var mesh: Mesh = mi.mesh
			# Bake the glTF's material into the mesh so we can share it directly.
			if mi.get_surface_override_material(0) != null:
				mesh = mesh.duplicate() as Mesh
				mesh.surface_set_material(0, mi.get_surface_override_material(0))
			_meshes.append(mesh)
		inst.free()


## Prefer the highest-detail node (named *LOD0) when a file ships several LODs.
func _find_mesh(root: Node) -> MeshInstance3D:
	var first: MeshInstance3D = null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			if "LOD0" in String(n.name):
				return n
			if first == null:
				first = n
		stack.append_array(n.get_children())
	return first
