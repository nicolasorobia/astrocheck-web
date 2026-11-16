extends Interactable
## Team flag planted by the habitat. Press [E] on it (instant, no progress bar) to open the crew panel
## (names + group photo). Not shown on the compass, usable any number of times.

@export var credits_scene: PackedScene = preload("res://ui/team_credits.tscn")
@export var snap_to_terrain := true
@export var sink := 0.25            ## How deep the pole is planted.

var _credits: ShockFrameDialog


func _ready() -> void:
	super._ready()
	single_use = false
	show_on_compass = false
	if snap_to_terrain:
		var terrain := get_tree().get_first_node_in_group("terrain") as LunarTerrain
		if terrain:
			global_position.y = terrain.get_height(global_position.x, global_position.z) - sink


func _finish(by: Node) -> void:
	super._finish(by)
	if _credits == null and credits_scene:
		var layer := CanvasLayer.new()
		layer.layer = 50
		layer.process_mode = Node.PROCESS_MODE_ALWAYS
		get_tree().current_scene.add_child(layer)
		_credits = credits_scene.instantiate() as ShockFrameDialog
		layer.add_child(_credits)
	if _credits:
		_credits.open()
