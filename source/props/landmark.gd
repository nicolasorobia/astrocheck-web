extends StaticBody3D
## A static set piece (e.g. the communications dish), optionally resized.
## - Sits itself on the terrain: its base goes to the lowest ground under its
##   footprint (so it never floats on a slope) and is sunk in slightly.
## - Gets exact collision built from its mesh.
## - Keeps the rock scatter clear of its footprint (group "keep_clear").

@export var target_height := 0.0    ## > 0: scale the "Model" child so the whole thing is this tall (meters).
@export var snap_to_terrain := true
@export var sink := 0.15            ## Meters pushed into the ground.
@export var clear_radius := 48.0    ## Rock scatter stays this far from the center.
@export var collision := true


func _enter_tree() -> void:
	add_to_group("keep_clear")


func _ready() -> void:
	var meshes: Array[MeshInstance3D] = []
	var stack: Array[Node] = [self]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			meshes.append(n)
		stack.append_array(n.get_children())
	if meshes.is_empty():
		return

	var model := get_node_or_null("Model") as Node3D
	if model and target_height > 0.0:
		var h := _bounds(meshes).size.y
		if h > 0.0:
			model.scale *= target_height / h

	# Bottom of the model in this node's space.
	var bottom := _bounds(meshes).position.y

	if snap_to_terrain:
		var terrain := get_tree().get_first_node_in_group("terrain") as LunarTerrain
		if terrain:
			# Find where the model actually touches down (its lowest vertices, e.g. the
			# feet of the mount) and put the lowest ground under them at that level,
			# so no foot floats; feet on higher ground just sink into the soil.
			var inv := global_transform.affine_inverse()
			var height := _bounds(meshes).size.y
			var low := INF
			for mi in meshes:
				var to_body := inv * mi.global_transform
				for v in mi.mesh.get_faces():
					var bv := to_body * v
					if bv.y <= bottom + height * 0.04:
						var g := global_transform * bv
						low = minf(low, terrain.get_height(g.x, g.z))
			if low == INF:
				low = terrain.get_height(global_position.x, global_position.z)
			global_position.y = low - bottom - sink

	if collision:
		var inv := global_transform.affine_inverse()
		for mi in meshes:
			var to_body := inv * mi.global_transform
			var faces := mi.mesh.get_faces()
			for i in faces.size():
				faces[i] = to_body * faces[i]
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(faces)
			shape.backface_collision = true
			var cs := CollisionShape3D.new()
			cs.shape = shape
			add_child(cs)


## Bounds of all meshes in this node's space.
func _bounds(meshes: Array[MeshInstance3D]) -> AABB:
	var inv := global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for mi in meshes:
		var b: AABB = (inv * mi.global_transform) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box
