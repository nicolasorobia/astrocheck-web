class_name InteractionStep
extends Resource
## One hold-[E] step of a multi-step Interactable (e.g. hammer -> rake -> scoop -> container).

@export var action_name := "Interact"          ## Shown as "Hold [E] to <action_name>".
@export var complete_message := ""             ## Shown briefly when this step finishes.
@export var duration := 3.0                    ## Seconds the key must be held.
@export_enum("none", "wrench", "sample_container", "hammer", "rake", "scoop") var tool: String = "none"
