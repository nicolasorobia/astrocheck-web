class_name Notifications
extends Control
## Side notifications: a blue notification icon, a title line and an optional smaller
## line. Each one slides in, stays a few seconds and fades. Right edge by default (rover
## updates); the left edge is used for the mission clock (new day).
## Use from anywhere:  Notifications.notify(get_tree(), "Title", "detail"[, left])

@export var icon: Texture2D = preload("uid://cf0fh2qk370p7")  # HUD icon - notification.png (recolored blue)
@export var hold_time := 5.0
@export var top := 0.36                ## Where the first notification sits (fraction of screen height).
@export var width := 450.0
@export var left := false              ## Stack on the left edge instead of the right.

const BLUE := Color(0.35, 0.8, 1.0)
const TEXT := Color(0.86, 0.97, 1.0)
const DIM := Color(0.55, 0.95, 1.0, 0.75)

var _items: Array = []   # [title, detail, age]
var _font: Font
var _blue_icon: Texture2D


## Shows a notification, creating the notification layer on first use.
static func notify(tree: SceneTree, title: String, detail := "", on_left := false) -> void:
	var n: Notifications = null
	for c in tree.get_nodes_in_group("notifications"):
		if (c as Notifications).left == on_left:
			n = c
	if n == null:
		var layer := CanvasLayer.new()
		layer.layer = 20
		tree.current_scene.add_child(layer)
		n = Notifications.new()
		n.left = on_left
		layer.add_child(n)
	n.push(title, detail)


func _enter_tree() -> void:
	add_to_group("notifications")


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	_blue_icon = _recolor(icon, BLUE)


func push(title: String, detail := "") -> void:
	_items.append([title, detail, 0.0])
	if _items.size() > 4:
		_items.pop_front()


func _process(delta: float) -> void:
	for it in _items:
		it[2] += delta
	_items = _items.filter(func(it): return it[2] < hold_time + 0.6)
	queue_redraw()


func _draw() -> void:
	var y := size.y * top
	for it in _items:
		var age: float = it[2]
		var slide := 1.0 - pow(1.0 - clampf(age / 0.35, 0.0, 1.0), 3.0)   # ease out
		var a := 1.0 - clampf((age - hold_time) / 0.6, 0.0, 1.0)           # fade out
		var h := 58.0 if it[1] != "" else 42.0
		var x := (16.0 - width * (1.0 - slide)) if left else (size.x - 16.0 - width * slide)
		var r := Rect2(x, y, width, h)
		draw_rect(r, Color(0.01, 0.05, 0.08, 0.72 * a))
		draw_rect(Rect2(r.position, Vector2(3, h)), Color(BLUE, a))       # accent bar
		draw_line(Vector2(r.position.x, r.end.y), r.end, Color(BLUE, 0.4 * a), 1.0)
		var isz := 30.0
		draw_texture_rect(_blue_icon, Rect2(x + 12, y + (h - isz) * 0.5, isz, isz), false, Color(1, 1, 1, a))
		draw_string(_font, Vector2(x + 52, y + 24), it[0], HORIZONTAL_ALIGNMENT_LEFT, width - 60, 15, Color(TEXT, a))
		if it[1] != "":
			draw_string(_font, Vector2(x + 52, y + 44), it[1], HORIZONTAL_ALIGNMENT_LEFT, width - 60, 12, Color(DIM, a))
		y += h + 8.0


## The pack's notification icon is yellow; make a blue copy (keeps the "!" and shading).
func _recolor(t: Texture2D, col: Color) -> Texture2D:
	var img := t.get_image()
	if img == null:
		return t
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	for py in img.get_height():
		for px in img.get_width():
			var c := img.get_pixel(px, py)
			if c.a <= 0.0:
				continue
			var lum := c.get_luminance()
			# Bright yellow body -> blue; the dark "!" stays dark.
			img.set_pixel(px, py, Color(col.r * lum * 1.25, col.g * lum * 1.25, col.b * lum * 1.25, c.a))
	return ImageTexture.create_from_image(img)
