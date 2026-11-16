@tool
class_name LunarTerrain
extends StaticBody3D
## Lunar terrain built from a heightmap (Apollo 17 landing site).
## - Mesh is split into chunks; each chunk has a full-detail and a low-detail
##   version, swapped by distance, so only the ground near you is high-poly.
## - Collision uses a HeightMapShape3D (cheap, exact).
## - A circle around `flatten_center` is flattened to `flatten_height` so the
##   spawn area, lander and props sit on level ground.
## - Invisible walls stop the player walking off the edge.
## - Runs in the editor too (visual mesh only, not saved), so you can see the
##   ground while placing things in the level.

@export var heightmap: HeightMapShape3D
@export var material: Material
@export var cell_size := 2.0                 ## Meters between height samples (map is ~1 km at 2.0).

@export_group("Level of detail")
@export var chunk_cells := 64
@export var lod_distance := 200.0            ## Beyond this (chunk center distance), use the low-detail mesh.
@export var far_step := 4                    ## Low-detail mesh uses every Nth sample.
@export var skirt_depth := 3.0               ## Hides small cracks between chunks of different detail.

@export_group("Landing zone")
@export var flatten_center := Vector2.ZERO   ## World X/Z.
@export var flatten_radius := 22.0
@export var flatten_blend := 30.0
@export var flatten_height := 0.5            ## World Y of the flat area (top of the old floor).

@export_group("Bounds")
@export var add_boundary_walls := true
@export var wall_height := 400.0

var _w := 0
var _d := 0
var _h := PackedFloat32Array()   # heights in meters, local space


func _enter_tree() -> void:
	add_to_group("terrain")


func _ready() -> void:
	if heightmap == null:
		push_error("terrain: no heightmap assigned.")
		return
	_w = heightmap.map_width
	_d = heightmap.map_depth
	_h = heightmap.map_data.duplicate()
	for i in _h.size():
		_h[i] *= cell_size

	_flatten_landing_zone()
	_build_chunks()
	if Engine.is_editor_hint():
		return  # editor preview: just the visible ground
	_build_collision()
	if add_boundary_walls:
		_build_walls()


## Half the playable size in meters (X, Z), measured from the terrain's center.
func get_half_extent() -> Vector2:
	return Vector2(_w - 1, _d - 1) * cell_size * 0.5


## World-space ground height at x/z (useful for placing things on the terrain).
func get_height(world_x: float, world_z: float) -> float:
	var local := to_local(Vector3(world_x, 0.0, world_z))
	var gx := clampf(local.x / cell_size + (_w - 1) * 0.5, 0.0, _w - 1.001)
	var gz := clampf(local.z / cell_size + (_d - 1) * 0.5, 0.0, _d - 1.001)
	var x0 := int(gx)
	var z0 := int(gz)
	var fx := gx - x0
	var fz := gz - z0
	var a := lerpf(_hat(x0, z0), _hat(x0 + 1, z0), fx)
	var b := lerpf(_hat(x0, z0 + 1), _hat(x0 + 1, z0 + 1), fx)
	return to_global(Vector3(0, lerpf(a, b, fz), 0)).y


# ------------------------------------------------------------------ setup

func _flatten_landing_zone() -> void:
	# Grid coordinates of the flatten center (terrain is centered on this node).
	var cx := (flatten_center.x - position.x) / cell_size + (_w - 1) * 0.5
	var cz := (flatten_center.y - position.z) / cell_size + (_d - 1) * 0.5
	var target := _hat(clampi(roundi(cx), 0, _w - 1), clampi(roundi(cz), 0, _d - 1))
	var r0 := flatten_radius / cell_size
	var r1 := (flatten_radius + flatten_blend) / cell_size
	for z in range(maxi(0, int(cz - r1)), mini(_d, int(cz + r1) + 2)):
		for x in range(maxi(0, int(cx - r1)), mini(_w, int(cx + r1) + 2)):
			var r := Vector2(x - cx, z - cz).length()
			if r >= r1:
				continue
			var t := 0.0 if r <= r0 else smoothstep(0.0, 1.0, (r - r0) / (r1 - r0))
			_h[z * _w + x] = lerpf(target, _h[z * _w + x], t)
	# Move the whole terrain so the flat area sits at flatten_height.
	position.y = flatten_height - target


func _build_collision() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = _w
	shape.map_depth = _d
	var data := _h.duplicate()
	for i in data.size():
		data[i] /= cell_size
	shape.map_data = data
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.scale = Vector3.ONE * cell_size  # uniform scale: spacing and heights
	add_child(cs)


func _build_chunks() -> void:
	for cz in range(0, _d - 1, chunk_cells):
		for cx in range(0, _w - 1, chunk_cells):
			var x1 := mini(cx + chunk_cells, _w - 1)
			var z1 := mini(cz + chunk_cells, _d - 1)
			var near := _make_chunk(cx, cz, x1, z1, 1)
			near.visibility_range_end = lod_distance
			var far := _make_chunk(cx, cz, x1, z1, far_step)
			far.visibility_range_begin = lod_distance
			far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _make_chunk(x0: int, z0: int, x1: int, z1: int, step: int) -> MeshInstance3D:
	var xs := _samples(x0, x1, step)
	var zs := _samples(z0, z1, step)
	var nx := xs.size()
	var nz := zs.size()
	var center := Vector3(_gx((x0 + x1) * 0.5), 0.0, _gz((z0 + z1) * 0.5))

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	verts.resize(nx * nz)
	normals.resize(nx * nz)
	for j in nz:
		for i in nx:
			var k := j * nx + i
			verts[k] = Vector3(_gx(xs[i]), _hat(xs[i], zs[j]), _gz(zs[j])) - center
			normals[k] = _normal(xs[i], zs[j])
	for j in nz - 1:
		for i in nx - 1:
			var a := j * nx + i
			indices.append_array([a, a + 1, a + nx, a + 1, a + nx + 1, a + nx])

	# Skirts: a vertical strip hanging down from each edge.
	var edges := [
		_edge_indices(nx, nz, 0, 0, 1, 0, nx),          # north edge (z0), left->right
		_edge_indices(nx, nz, nx - 1, 0, 0, 1, nz),     # east edge
		_edge_indices(nx, nz, nx - 1, nz - 1, -1, 0, nx),  # south edge
		_edge_indices(nx, nz, 0, nz - 1, 0, -1, nz),    # west edge
	]
	for edge: PackedInt32Array in edges:
		var base := verts.size()
		for idx in edge:
			verts.append(verts[idx] - Vector3(0, skirt_depth, 0))
			normals.append(normals[idx])
		for e in edge.size() - 1:
			var top_a := edge[e]
			var top_b := edge[e + 1]
			var bot_a := base + e
			var bot_b := base + e + 1
			# Both windings so the skirt is visible from either side.
			indices.append_array([top_a, bot_a, top_b, top_b, bot_a, bot_b])
			indices.append_array([top_a, top_b, bot_a, top_b, bot_b, bot_a])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material:
		mesh.surface_set_material(0, material)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = center
	add_child(mi)
	return mi


# ------------------------------------------------------------------ helpers

func _samples(a: int, b: int, step: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var v := a
	while v < b:
		out.append(v)
		v += step
	out.append(b)
	return out


func _edge_indices(nx: int, nz: int, sx: int, sz: int, dx: int, dz: int, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for n in count:
		out.append((sz + dz * n) * nx + (sx + dx * n))
	return out


func _hat(x: int, z: int) -> float:
	return _h[clampi(z, 0, _d - 1) * _w + clampi(x, 0, _w - 1)]


## Local X/Z for a (possibly fractional) grid index. Matches HeightMapShape3D,
## which is centered on its node.
func _gx(index: float) -> float:
	return (index - (_w - 1) * 0.5) * cell_size


func _gz(index: float) -> float:
	return (index - (_d - 1) * 0.5) * cell_size


func _normal(x: int, z: int) -> Vector3:
	var l := _hat(x - 1, z)
	var r := _hat(x + 1, z)
	var u := _hat(x, z - 1)
	var dn := _hat(x, z + 1)
	return Vector3(l - r, 2.0 * cell_size, u - dn).normalized()


func _build_walls() -> void:
	var half_x := (_w - 1) * cell_size * 0.5
	var half_z := (_d - 1) * cell_size * 0.5
	var t := 2.0
	for wall: Array in [
		[Vector3(0, 0, -half_z - t * 0.5), Vector3(half_x * 2 + t * 2, wall_height, t)],
		[Vector3(0, 0, half_z + t * 0.5), Vector3(half_x * 2 + t * 2, wall_height, t)],
		[Vector3(-half_x - t * 0.5, 0, 0), Vector3(t, wall_height, half_z * 2)],
		[Vector3(half_x + t * 0.5, 0, 0), Vector3(t, wall_height, half_z * 2)],
	]:
		var box := BoxShape3D.new()
		box.size = wall[1]
		var cs := CollisionShape3D.new()
		cs.shape = box
		cs.position = wall[0]
		add_child(cs)
