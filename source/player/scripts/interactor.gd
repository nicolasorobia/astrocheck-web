class_name Interactor
extends RayCast3D
## Hold-to-interact. Lives on a RayCast3D under the player's Camera3D.
## Aim at an Interactable, hold "interact" (E) and a progress bar fills.
## Letting go, looking away or walking out of reach cancels it, unless the
## Interactable has keep_progress on (long repairs), in which case it just pauses.
## The Interactable's tool is shown in front of the camera while working.

@export var reach := 3.0
@export var tool_scenes := {
	"wrench": preload("res://tools/wrench.tscn"),
	"sample_container": preload("res://tools/sample_container.tscn"),
	"hammer": preload("res://tools/hammer.tscn"),
	"rake": preload("res://tools/rake.tscn"),
	"scoop": preload("res://tools/scoop.tscn"),
}
@export var tool_offset := Vector3(0.2, -0.09, -0.45)  ## Where the tool sits, in camera space (+Y = higher).
@export var tool_scale := 1.6                          ## Extra size on top of each tool scene's own scale.
@export var message_time := 1.8

@export_group("Sounds")
## Looped while working with each tool (no entry = silent).
@export var tool_sounds := {
	"hammer": preload("res://assets/audio/rock-hits-with-hammer.wav"),
	"rake": preload("res://assets/audio/raking-gravel.wav"),
	"scoop": preload("res://assets/audio/collecting-soil.wav"),
	"wrench": preload("res://assets/audio/ratchet-wrench.wav"),
	"sample_container": preload("uid://qdd1og2edat1"),  # sealing-samples.wav: last step, before confirm.wav
}
@export var tool_volume_db := 5.0
## Played once when a step with this tool is finished (as its message appears).
@export var complete_sounds := {
	"sample_container": preload("uid://d1pv0nfw0s2v7"),  # done.wav: sample fully processed
}
@export var complete_volume_db := -4.0

var _target: Interactable
var _progress := 0.0
var _working := false
var _needs_release := false
var _tool_holder: Node3D
var _tool_audio: AudioStreamPlayer
var _tool_fade: Tween
var _sfx: AudioStreamPlayer
var _tool: Node3D
var _work_time := 0.0
var _message_left := 0.0

var _prompt: Label
var _bar: ProgressBar
var _message: Label


func _ready() -> void:
	add_to_group("interactor")
	target_position = Vector3(0, 0, -reach)
	# Don't hit our own capsule.
	var n := get_parent()
	while n and not (n is CollisionObject3D):
		n = n.get_parent()
	if n:
		add_exception(n)

	_tool_holder = Node3D.new()
	_tool_holder.name = "ToolHolder"
	get_parent().add_child.call_deferred(_tool_holder)
	_tool_holder.position = tool_offset
	_tool_holder.scale = Vector3.ONE * tool_scale
	_build_hud()

	_tool_audio = AudioStreamPlayer.new()
	_tool_audio.name = "ToolAudio"
	_tool_audio.bus = &"SFX"
	add_child(_tool_audio)
	_sfx = AudioStreamPlayer.new()
	_sfx.name = "CompleteAudio"
	_sfx.bus = &"SFX"
	add_child(_sfx)
	_tool_audio.finished.connect(func():
		if _working:  # keep looping while the player is still holding E
			_tool_audio.play())


func _process(delta: float) -> void:
	var target := _get_target()
	if target != _target:
		_stop()
		_target = target

	if _message_left > 0.0:
		_message_left -= delta
		_message.visible = _message_left > 0.0

	var locked := GameSettings.controls_locked or GameSettings.menu_open
	if locked or not Input.is_action_pressed("interact"):
		_needs_release = false

	if _target == null or GameSettings.menu_open:  # Tab menu: no prompts showing through it
		_prompt.visible = false
		_bar.visible = false
		_stop()
		return
	if not _working:
		_bar.visible = false

	_prompt.visible = not _working
	var steps := _target.step_count()
	var paused := _target.keep_progress and _target.progress > 0.0
	var verb := "continue: " if paused else ""
	var instant := _target.current_duration() <= 0.0  # no progress bar: a single press does it
	var key := "Press [E]" if instant else "Hold [E]"
	if steps > 1:
		_prompt.text = "Step %d/%d  ·  %s to %s%s" % [_target.step_index + 1, steps, key, verb, _target.current_action_name()]
	else:
		_prompt.text = "%s to %s%s" % [key, verb, _target.current_action_name()]

	if instant:
		if not locked and Input.is_action_just_pressed("interact") and not _needs_release:
			_finish()
		return

	if not locked and Input.is_action_pressed("interact") and not _needs_release:
		if not _working:
			_start()
		_progress += delta
		_work_time += delta
		if _target.keep_progress:
			_target.progress = _progress
		_bar.value = _progress / maxf(_target.current_duration(), 0.01)
		_animate_tool()
		if _progress >= _target.current_duration():
			_finish()
	elif _working:
		_stop()
	elif paused:
		# Aiming at a paused long task: show where it stands.
		_bar.value = _target.progress / maxf(_target.current_duration(), 0.01)
		_bar.visible = true


## Ignore the interact key until it is let go (e.g. after closing a pop-up with E).
func block_until_release() -> void:
	_needs_release = true
	_stop()


## Used by Vitals to know how hard the player is working.
func is_working() -> bool:
	return _working


func current_target() -> Interactable:
	return _target if is_instance_valid(_target) else null


func _get_target() -> Interactable:
	if not is_colliding():
		return null
	var collider := get_collider()
	if not is_instance_valid(collider):  # e.g. a rock that was just collected
		return null
	var hit := collider as Interactable
	if hit and hit.can_interact():
		return hit
	return null


func _start() -> void:
	_working = true
	_progress = _target.progress if _target.keep_progress else 0.0
	_work_time = 0.0
	_bar.value = _progress / maxf(_target.current_duration(), 0.01)
	_bar.visible = true
	_show_tool(_target.current_tool())
	_start_tool_sound(_target.current_tool())


func _stop() -> void:
	_working = false
	_progress = 0.0
	if _bar:
		_bar.visible = false
	_show_tool("none")
	_stop_tool_sound()


func _finish() -> void:
	var t := _target
	_stop()
	_needs_release = true  # don't instantly start on the next thing
	var done_sound: AudioStream = complete_sounds.get(t.current_tool())
	if done_sound:
		_sfx.stream = done_sound
		_sfx.volume_db = complete_volume_db
		_sfx.play()
	var msg := t.current_message()
	if msg != "":
		_message.text = msg
		_message.visible = true
		_message_left = message_time
	t.complete(get_parent())
	_target = null


func _start_tool_sound(tool_name: String) -> void:
	var s: AudioStream = tool_sounds.get(tool_name)
	if s == null or _tool_audio == null:
		return
	if _tool_fade and _tool_fade.is_valid():
		_tool_fade.kill()
	_tool_audio.stream = s
	_tool_audio.volume_db = tool_volume_db
	# Long recordings start somewhere random so repeats don't sound identical.
	var length := s.get_length()
	_tool_audio.play(randf() * maxf(length - 4.0, 0.0) if length > 8.0 else 0.0)


func _stop_tool_sound() -> void:
	if _tool_audio == null or not _tool_audio.playing:
		return
	if _tool_fade and _tool_fade.is_valid():
		return  # already fading out
	_tool_fade = create_tween()
	_tool_fade.tween_property(_tool_audio, "volume_db", -50.0, 0.15)
	_tool_fade.tween_callback(_tool_audio.stop)


func _show_tool(tool_name: String) -> void:
	if _tool:
		_tool.queue_free()
		_tool = null
	if tool_name == "none" or not tool_scenes.has(tool_name):
		return
	_tool = (tool_scenes[tool_name] as PackedScene).instantiate() as Node3D
	_tool_holder.add_child(_tool)


func _animate_tool() -> void:
	# Simple "working" wiggle instead of a real animation.
	if _tool:
		_tool.rotation = Vector3(sin(_work_time * 9.0) * 0.18, 0.0, sin(_work_time * 4.5) * 0.08)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var dot := ColorRect.new()  # crosshair
	dot.color = Color(1, 1, 1, 0.8)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center(dot, Rect2(-2, -2, 4, 4))
	root.add_child(dot)

	_prompt = _make_label(root, 66.0)  # below the progress bar (bar sits at +44..+58)
	_message = _make_label(root, -70.0)
	_message.add_theme_color_override("font_color", Color(0.67, 0.79, 0.96))

	_bar = ProgressBar.new()
	_bar.max_value = 1.0
	_bar.show_percentage = false
	_center(_bar, Rect2(-130, 44, 260, 14))
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.55)
	bg.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.92, 0.93, 0.94)
	fill.set_corner_radius_all(4)
	_bar.add_theme_stylebox_override("background", bg)
	_bar.add_theme_stylebox_override("fill", fill)
	_bar.visible = false
	root.add_child(_bar)


func _make_label(root: Control, y: float) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center(l, Rect2(-250, y, 500, 30))
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_constant_override("outline_size", 4)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.visible = false
	root.add_child(l)
	return l


## Places a control relative to the screen center (rect is an offset from the center).
func _center(c: Control, rect: Rect2) -> void:
	c.anchor_left = 0.5
	c.anchor_right = 0.5
	c.anchor_top = 0.5
	c.anchor_bottom = 0.5
	c.offset_left = rect.position.x
	c.offset_top = rect.position.y
	c.offset_right = rect.end.x
	c.offset_bottom = rect.end.y
