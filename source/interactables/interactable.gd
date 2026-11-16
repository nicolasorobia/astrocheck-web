class_name Interactable
extends StaticBody3D
## Something the player can aim at and hold the interact key on.
## While held, a progress bar fills over the step's duration; when it's full the
## step is done. With `steps` filled in, the player works through them in order
## (one tool per step); otherwise the single action below is used.
## Drop this on any StaticBody3D with a CollisionShape3D.

signal step_completed(index: int, by: Node)
signal completed(by: Node)

@export var display_name := "Objective"              ## Used by the HUD/compass.
@export var show_on_compass := true

@export_group("Single action")
@export var action_name := "Interact"                ## Shown as "Hold [E] to <action_name>".
@export var complete_message := ""                   ## Shown briefly when finished (optional).
@export var duration := 3.0                          ## Seconds the key must be held.
@export_enum("none", "wrench", "sample_container", "hammer", "rake", "scoop") var tool: String = "none"  ## Shown in hand while working.

@export_group("Multi-step")
@export var steps: Array[InteractionStep] = []       ## If set, overrides the single action above.

@export_group("Long tasks")
@export var keep_progress := false                   ## Letting go of [E] pauses instead of resetting.

@export_group("Effort")
@export_range(0.0, 1.0) var exertion := 0.35         ## How hard this is on the body (0 rest, 0.25 walking, 1 sprinting).

@export_group("On complete")
@export var single_use := true
@export var remove_on_complete := false              ## Delete this node when finished (e.g. a collected rock).
@export var reveal_on_complete: NodePath             ## Hidden at start, shown when finished.
@export var hide_on_complete: NodePath               ## Visible at start, hidden when finished.

var done := false
var step_index := 0
var progress := 0.0   ## Seconds worked on the current step (kept between holds when keep_progress is on).


func _enter_tree() -> void:
	add_to_group("interactable")


func _ready() -> void:
	var reveal := get_node_or_null(reveal_on_complete) as Node3D
	if reveal:
		reveal.visible = false


func can_interact() -> bool:
	return not (single_use and done)


# --- what the current step asks for (used by the interactor) ---

func step_count() -> int:
	return maxi(steps.size(), 1)


func current_action_name() -> String:
	return steps[step_index].action_name if _has_steps() else action_name


func current_duration() -> float:
	return steps[step_index].duration if _has_steps() else duration


func current_tool() -> String:
	return steps[step_index].tool if _has_steps() else tool


func current_message() -> String:
	return steps[step_index].complete_message if _has_steps() else complete_message


## Called by the interactor when the progress bar fills.
func complete(by: Node) -> void:
	progress = 0.0
	if _has_steps():
		var i := step_index
		_on_step_completed(i)
		step_completed.emit(i, by)
		step_index += 1
		if step_index < steps.size():
			return
	_finish(by)


## Override in subclasses to change visuals between steps.
func _on_step_completed(_index: int) -> void:
	pass


func _finish(by: Node) -> void:
	done = true
	var reveal := get_node_or_null(reveal_on_complete) as Node3D
	if reveal:
		reveal.visible = true
	var hidden := get_node_or_null(hide_on_complete) as Node3D
	if hidden:
		hidden.visible = false
	completed.emit(by)
	if remove_on_complete:
		queue_free()


func _has_steps() -> bool:
	return not steps.is_empty() and step_index < steps.size()
