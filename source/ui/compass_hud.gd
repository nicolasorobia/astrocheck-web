extends Control
## Top-of-screen compass (ShockFrame HUD art).
## - The ruler scrolls with the camera's heading; N/E/S/W and 45° marks are labeled.
## - A blue map marker sits at the bearing of the nearest few objectives (and a green
##   one at the base and the nearest outpost), with its
##   distance in meters above it. Targets outside the compass are pinned to the
##   nearest edge so the player always knows which way to turn.
## - Shows how many sample rocks have been collected.
## North is -Z, East is +X.

# ShockFrame art (res://assets/HUD/sci-fi - ShockFrame/PNG/1080p/HUD/In-game/), loaded by UID
# so moving the folder in the editor doesn't break it.
@export var ruler: Texture2D = preload("uid://c2k4wb46pqnfu")    # HUD - compass ruler.png
@export var pointer: Texture2D = preload("uid://128m571og4os")   # HUD - compass pointer.png
@export var marker: Texture2D = preload("uid://62ea5fqy6fqg")    # HUD - map marker (blue).png
@export var base_marker: Texture2D = preload("uid://cc6i6jfqhrnrb")  # HUD - map marker (green).png, for the habitat
@export var rover_marker: Texture2D = preload("uid://bttty5b4m8nwo")   # HUD - map marker (yellow).png, for the rover
@export var hazard_marker: Texture2D = preload("uid://cqam4wqlkgwxg")  # HUD - map marker (red).png, for pressure zones

@export var width := 620.0              ## On-screen width of the compass strip.
@export var top_margin := 14.0
@export var degrees_per_ruler_period := 90.0  ## The ruler art has a big tick every 404 px = 90°.
@export var ruler_period_px := 404.0
@export var max_marker_distance := 2000.0     ## Hide markers farther than this.
@export var max_objective_markers := 3          ## Only the nearest few objectives are shown (the base is always shown).
@export var hazard_distance := 250.0            ## Pressure zones closer than this (to their edge) get a red marker.
@export var max_hazard_markers := 2
@export var max_outpost_markers := 0          ## Outposts shown on the compass (0: their beacons are enough).

const CYAN := Color(0.83, 1.0, 0.99)
const BLUE := Color(0.2, 0.82, 1.0)
const GREEN := Color(0.35, 0.95, 0.5)
const RED := Color(1.0, 0.35, 0.3)
const YELLOW := Color(1.0, 0.84, 0.25)
const PURPLE := Color(0.78, 0.45, 1.0)
const LABELS := {0: "N", 45: "45", 90: "E", 135: "135", 180: "S", 225: "225", 270: "W", 315: "315"}

var _font: Font
var _rad_marker: Texture2D   # purple copy of the red hazard marker
var _samples_total := 0
var _samples_done := 0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	_rad_marker = _recolor(hazard_marker, PURPLE)
	# Count sample rocks once the level has finished loading.
	_count_samples.call_deferred()


func _count_samples() -> void:
	for n in get_tree().get_nodes_in_group("sample_rock"):
		_samples_total += 1
		(n as Interactable).completed.connect(func(_by): _samples_done += 1)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var px_per_deg := ruler_period_px / degrees_per_ruler_period
	var fwd := -cam.global_basis.z
	var heading := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)

	var cx := size.x * 0.5
	var x0 := cx - width * 0.5
	var y_text := top_margin
	var y_marker := top_margin + 12.0
	var y_ruler := top_margin + 56.0
	var y_labels := y_ruler + 32.0

	# Ruler: the art repeats every 90°, so scroll within one period.
	var src_x := fposmod(heading * px_per_deg - width * 0.5, ruler_period_px)
	draw_texture_rect_region(ruler, Rect2(x0, y_ruler, width, ruler.get_height()),
		Rect2(src_x, 0, width, ruler.get_height()))

	# Cardinal / 45° labels under the ruler.
	for deg: int in LABELS:
		var rel := wrapf(deg - heading, -180.0, 180.0)
		var x := cx + rel * px_per_deg
		if absf(x - cx) > width * 0.5 - 8.0:
			continue
		var text: String = LABELS[deg]
		var fs := 20 if text.length() == 1 else 15
		var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var a := 1.0 - smoothstep(width * 0.35, width * 0.5, absf(x - cx))  # fade at the edges
		draw_string(_font, Vector2(x - tw * 0.5, y_labels), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(CYAN, a))

	# Objective markers.
	var targets := []
	for n in get_tree().get_nodes_in_group("interactable"):
		var it := n as Interactable
		if it == null or not it.show_on_compass or not it.can_interact() or not it.is_inside_tree():
			continue
		if it.is_in_group("rover"):
			continue  # tracked separately below (yellow, also after it's repaired)
		var to := it.global_position - cam.global_position
		var dist := to.length()
		if dist > max_marker_distance:
			continue
		targets.append([dist, it, to])
	# Decide which markers get a distance label: nearest first, skipping labels
	# that would overlap one already placed (and only the nearest at each edge).
	targets.sort_custom(func(a, b): return a[0] < b[0])
	# Declutter: keep the base plus only the nearest few objectives.
	# Rest stations: the main base always, plus the nearest few outposts.
	var kept := []
	var objectives := 0
	var outposts := 0
	for t in targets:
		if (t[1] as Node).is_in_group("base"):
			if _is_main_base(t[1]):
				kept.append(t)
			elif outposts < max_outpost_markers:
				kept.append(t)
				outposts += 1
		elif objectives < max_objective_markers:
			kept.append(t)
			objectives += 1
	targets = kept
	# The rover (yellow): always shown, before repair and while it roams afterwards.
	for n in get_tree().get_nodes_in_group("rover"):
		var r := n as Node3D
		if r and r.is_inside_tree():
			var to := r.global_position - cam.global_position
			targets.append([to.length(), r, to])
	# Nearby pressure zones (red), distance measured to the zone's edge.
	var hazards := []
	for n in get_tree().get_nodes_in_group("pressure_zone"):
		var z := n as PressureZone
		if z == null or not z.show_on_compass:
			continue
		var edge := z.distance_to_edge(cam.global_position)
		if edge < hazard_distance:
			hazards.append([maxf(edge, 0.0), z, z.global_position - cam.global_position])
	hazards.sort_custom(func(a, b): return a[0] < b[0])
	targets.append_array(hazards.slice(0, max_hazard_markers))
	# Nearby radiation zones (purple), always worth knowing about.
	var rads := []
	for n in get_tree().get_nodes_in_group("radiation_zone"):
		var rz := n as RadiationZone
		if rz == null or not rz.show_on_compass:
			continue
		var redge := rz.distance_to_edge(cam.global_position)
		if redge < hazard_distance:
			rads.append([maxf(redge, 0.0), rz, rz.global_position - cam.global_position])
	rads.sort_custom(func(a, b): return a[0] < b[0])
	targets.append_array(rads.slice(0, max_hazard_markers))
	targets.sort_custom(func(a, b): return a[0] < b[0])
	var placed: Array[Vector2] = []  # (x, half label width)
	# The rover's label claims its spot first so it never hides behind a sample's.
	var label_order := targets.filter(func(t): return (t[1] as Node).is_in_group("rover"))
	label_order.append_array(targets.filter(func(t): return not (t[1] as Node).is_in_group("rover")))
	for t in label_order:
		var to: Vector3 = t[2]
		var rel := wrapf(rad_to_deg(atan2(to.x, -to.z)) - heading, -180.0, 180.0)
		var x := cx + clampf(rel * px_per_deg, -width * 0.5, width * 0.5)
		# Rough label width so long labels ("PRESSURE 120 m") don't overlap others.
		var half := 28.0
		if t[1] is PressureZone or t[1] is RadiationZone or (t[1] as Node).is_in_group("base") or (t[1] as Node).is_in_group("rover"):
			half = 60.0
		var free := true
		for pl in placed:
			if absf(pl.x - x) < pl.y + half + 4.0:
				free = false
				break
		if free:
			placed.append(Vector2(x, half))
		t.append_array([rel, x, free])

	# Draw far-to-near so the nearest marker is on top.
	for i in range(targets.size() - 1, -1, -1):
		var t: Array = targets[i]
		var dist: float = t[0]
		var rel: float = t[3]
		var x: float = t[4]
		var show_label: bool = t[5]
		var off_edge := absf(rel * px_per_deg) > width * 0.5
		var nearest := i == 0
		var a := 1.0 if nearest else 0.6
		var is_base := (t[1] as Node).is_in_group("base")
		var is_hazard := t[1] is PressureZone
		var is_rad := t[1] is RadiationZone
		var is_rover := (t[1] as Node).is_in_group("rover")
		var tex := _rad_marker if is_rad else hazard_marker if is_hazard else (base_marker if is_base else (rover_marker if is_rover else marker))
		var ms := tex.get_size() * (1.0 if nearest else 0.8)
		draw_texture_rect(tex, Rect2(Vector2(x, y_marker + 14.0) - ms * 0.5, ms), false, Color(1, 1, 1, a))
		if not show_label:
			continue
		var label := ("BASE %d m" if is_base else ("PRESSURE %d m" if is_hazard else "%d m")) % roundi(dist)
		if is_base and not _is_main_base(t[1]):
			label = "OUTPOST %d m" % roundi(dist)
		if is_hazard and dist <= 0.0:
			label = "IN PRESSURE ZONE"
		if is_rover:
			label = "ROVER %d m" % roundi(dist)
		if is_rad:
			label = "IN RADIATION ZONE" if dist <= 0.0 else "RADIATION %d m" % roundi(dist)
		if off_edge:
			label = ("< " + label) if rel < 0 else (label + " >")
		var fs := 15 if nearest else 12
		var tw := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(_font, Vector2(x - tw * 0.5, y_text + 8.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(PURPLE if is_rad else (GREEN if is_base else (RED if is_hazard else (YELLOW if is_rover else BLUE))), a))

	# Center pointer (drawn last so it sits over everything).
	var ps := pointer.get_size()
	draw_texture_rect(pointer, Rect2(Vector2(cx - ps.x * 0.5, y_ruler - ps.y - 2.0), ps), false)

	# Sample counter at the right end of the compass.
	if _samples_total > 0:
		var s := "SAMPLES %d/%d" % [_samples_done, _samples_total]
		draw_string(_font, Vector2(x0 + width + 18.0, y_ruler + 13.0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, CYAN)


func _is_main_base(n: Node) -> bool:
	var v = n.get("is_main_base")
	return v == null or bool(v)


## The pack has no purple marker: tint a copy of the red one.
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
			if c.a > 0.0:
				var lum := maxf(c.r, maxf(c.g, c.b))
				img.set_pixel(px, py, Color(col.r * lum, col.g * lum, col.b * lum, c.a))
	return ImageTexture.create_from_image(img)
