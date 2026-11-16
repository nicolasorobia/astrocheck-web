extends Interactable
## A moon rock the player turns into a sealed sample:
##   1. hammer  - break the rock   (rock -> a few fragments)
##   2. rake    - sift pebbles     (fragments -> scattered pebbles)
##   3. scoop   - scoop the sample (most pebbles picked up)
##   4. container - seal it        (rock site removed)
## The steps themselves (names, durations, tools) live in `steps` on the scene.
## The rock model is picked from `rock_scenes` (same moon rocks as the scatter)
## and gets a pulsing blue rim so it stands out from ordinary rocks.
## It snaps itself onto the terrain, so only X/Z matter when placing it.

@export var rock_scenes: Array[PackedScene] = []
@export var rock_size := 0.75                   ## Longest side of the rock in meters.
@export var highlight: Material                 ## Overlay material (blue rim glow).
@export var snap_to_terrain := true

var _rock: MeshInstance3D
var _fragments: Array[MeshInstance3D] = []
var _pebbles: Array[MeshInstance3D] = []
var _shape: CollisionShape3D


func _enter_tree() -> void:
	super._enter_tree()
	add_to_group("sample_rock")


func _ready() -> void:
	super._ready()
	if steps.is_empty():
		# Safety net: if a level instance ends up with an empty `steps` override
		# (the editor can save one), fall back to the standard sampling sequence.
		push_warning("%s: no steps set, using the default hammer/rake/scoop/container sequence." % name)
		steps = _default_steps()
	if display_name == "Objective":
		display_name = "Sample rock"
	if snap_to_terrain:
		var terrain := get_tree().get_first_node_in_group("terrain") as LunarTerrain
		if terrain:
			global_position.y = terrain.get_height(global_position.x, global_position.z)

	var mesh := _pick_mesh()
	if mesh == null:
		push_error("sample_rock: no rock mesh available (check rock_scenes).")
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(roundi(global_position.x), roundi(global_position.z)))

	_rock = _make_piece(mesh, rock_size, Vector3.ZERO, rng.randf() * TAU, 0.2)
	add_child(_rock)

	# Collision box matching the rock.
	var aabb := _rock.transform * mesh.get_aabb()
	var box := BoxShape3D.new()
	box.size = aabb.size * Vector3(0.9, 1.0, 0.9)
	_shape = CollisionShape3D.new()
	_shape.shape = box
	_shape.position = aabb.get_center()
	add_child(_shape)

	# Pre-build the later stages (hidden until their step is done).
	for i in 4:
		var a := TAU * i / 4.0 + rng.randf() * 0.6
		var p := _make_piece(mesh, rock_size * rng.randf_range(0.3, 0.42),
			Vector3(cos(a), 0, sin(a)) * rock_size * 0.32, rng.randf() * TAU, 0.15)
		p.visible = false
		add_child(p)
		_fragments.append(p)
	for i in 12:
		var a := rng.randf() * TAU
		var r := sqrt(rng.randf()) * rock_size * 0.75
		var p := _make_piece(mesh, rock_size * rng.randf_range(0.07, 0.14),
			Vector3(cos(a), 0, sin(a)) * r, rng.randf() * TAU, 0.3)
		p.visible = false
		add_child(p)
		_pebbles.append(p)


func _on_step_completed(index: int) -> void:
	match index:
		0:  # hammer: rock breaks into fragments
			_rock.visible = false
			for f in _fragments:
				f.visible = true
			_shrink_collision(0.35)
		1:  # rake: fragments sifted into pebbles
			for f in _fragments:
				f.visible = false
			for p in _pebbles:
				p.visible = true
			_shrink_collision(0.2)
		2:  # scoop: most pebbles scooped up
			for i in _pebbles.size():
				_pebbles[i].visible = i < 3


func _finish(by: Node) -> void:
	remove_on_complete = true
	super._finish(by)


# ------------------------------------------------------------------ helpers

func _default_steps() -> Array[InteractionStep]:
	var out: Array[InteractionStep] = []
	for d in [
		["break the rock with the hammer", "Rock broken", 2.5, "hammer"],
		["rake the pebbles from the soil", "Pebbles separated", 3.0, "rake"],
		["scoop up the sample", "Sample scooped", 2.5, "scoop"],
		["seal the sample in the container", "Sample sealed", 2.0, "sample_container"],
	]:
		var s := InteractionStep.new()
		s.action_name = d[0]
		s.complete_message = d[1]
		s.duration = d[2]
		s.tool = d[3]
		out.append(s)
	return out


func _make_piece(mesh: Mesh, size: float, offset: Vector3, yaw: float, sink: float) -> MeshInstance3D:
	var aabb := mesh.get_aabb()
	var s := size / maxf(aabb.size[aabb.get_longest_axis_index()], 0.001)
	var b := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var center := b * aabb.get_center()
	var bottom := aabb.position.y * s
	mi.transform = Transform3D(b, Vector3(offset.x - center.x, -bottom - aabb.size.y * s * sink, offset.z - center.z))
	mi.material_overlay = highlight
	return mi


## Lowers the collision box so the aim target matches the smaller pile.
func _shrink_collision(height: float) -> void:
	if _shape == null:
		return
	var box := _shape.shape as BoxShape3D
	box.size = Vector3(maxf(box.size.x, rock_size * 1.2), rock_size * height, maxf(box.size.z, rock_size * 1.2))
	_shape.position = Vector3(0, box.size.y * 0.5, 0)


func _pick_mesh() -> Mesh:
	if rock_scenes.is_empty():
		return null
	var i := absi(hash(Vector2i(roundi(global_position.x), roundi(global_position.z)))) % rock_scenes.size()
	var inst := rock_scenes[i].instantiate()
	var found: MeshInstance3D = null
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		# Prefer the highest-detail node when the file ships several LODs.
		if n is MeshInstance3D and (found == null or "LOD0" in String(n.name)):
			found = n
		stack.append_array(n.get_children())
	var mesh: Mesh = found.mesh if found else null
	inst.free()
	return mesh
