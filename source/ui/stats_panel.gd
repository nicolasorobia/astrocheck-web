class_name StatsPanel
extends Control
## STATS page: one card per completed expedition (from ExpeditionLog), filled from the
## top left, Expedition 1 first. At least 9 slots are shown (empty ones stay dim);
## every run is kept, and once there are more than 9 the grid grows a row at a time
## and scrolls (mouse wheel or the ShockFrame scroll bar).
## Same look as the BIOMETRICS page; drawn in the menu's 1920x1080 design space.

var font: Font

const T_SCROLL := preload("uid://bu0b8x0xe7es4")          # Panels & Dialog/scroll.png
const T_SCROLL_GRAB := preload("uid://dmqstbnt0wy1e")     # Panels & Dialog/scroll - grabber.png

const TEXT := Color(0.86, 0.97, 1.0)
const DIM := Color(0.55, 0.95, 1.0, 0.62)
const CYAN := Color(0.55, 0.95, 1.0)
const GREEN := Color(0.4, 0.95, 0.55)
const YELLOW := Color(1.0, 0.82, 0.3)
const RED := Color(1.0, 0.42, 0.36)
const PURPLE := Color(0.8, 0.5, 1.0)
const CARD_BG := Color(0.01, 0.06, 0.08, 0.86)
const EMPTY_BG := Color(0.01, 0.06, 0.08, 0.4)

const COLS := 3
const MIN_ROWS := 3
const GAP := 14.0
const HEADER_H := 54.0
const BAR_ROOM := 30.0     ## Space kept on the right for the scroll bar.

var _runs: Array = []
var _scroll: ScrollContainer
var _grid: Control
var _card_h := 180.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font == null:
		font = ThemeDB.fallback_font
	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(0, HEADER_H)
	_scroll.size = Vector2(size.x, size.y - HEADER_H)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP  # mouse wheel scrolls the cards
	_style_bar(_scroll.get_v_scroll_bar())
	add_child(_scroll)
	_grid = Control.new()
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.draw.connect(_draw_grid)
	_scroll.add_child(_grid)
	_card_h = (_scroll.size.y - GAP * (MIN_ROWS - 1)) / MIN_ROWS
	refresh()


## Re-reads the saved log (call when the page is shown).
func refresh() -> void:
	_runs = ExpeditionLog.load_all()
	if _grid == null:
		return
	var rows := maxi(MIN_ROWS, ceili(_runs.size() / float(COLS)))
	_grid.custom_minimum_size = Vector2(_scroll.size.x - BAR_ROOM, rows * _card_h + (rows - 1) * GAP)
	_scroll.scroll_vertical = 0
	_grid.queue_redraw()
	queue_redraw()


func _draw() -> void:
	draw_string(font, Vector2(0, 30), "EXPEDITION RECORD", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, TEXT)
	draw_line(Vector2(0, 44), Vector2(size.x, 44), Color(CYAN, 0.3), 2.0)


func _draw_grid() -> void:
	var rows := maxi(MIN_ROWS, ceili(_runs.size() / float(COLS)))
	var cw := (_grid.size.x - GAP * (COLS - 1)) / COLS
	for i in rows * COLS:
		var r := Rect2(Vector2((i % COLS) * (cw + GAP), (i / COLS) * (_card_h + GAP)), Vector2(cw, _card_h))
		if i < _runs.size():
			_draw_run(r, _runs[i])
		else:
			_draw_empty(r)


func _draw_run(r: Rect2, e: Dictionary) -> void:
	var g := _grid
	var rescues := int(e.get("rescues", 0))
	var heat := int(e.get("heat_rescues", 0))
	var o2 := maxi(rescues - heat, 0)
	var accent := GREEN if rescues == 0 else (PURPLE if heat > 0 else RED)
	g.draw_rect(r, CARD_BG)
	g.draw_rect(r, Color(CYAN, 0.28), false, 2.0)
	g.draw_rect(Rect2(r.position, Vector2(6, r.size.y)), accent)
	var x := r.position.x + 24.0
	var y := r.position.y
	var right := r.end.x - 16.0

	# Title + date.
	g.draw_string(font, Vector2(x, y + 32), "EXPEDITION %d" % int(e.get("number", 0)), HORIZONTAL_ALIGNMENT_LEFT, -1, 26, CYAN)
	var date := str(e.get("date", ""))
	var dw := font.get_string_size(date, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x
	g.draw_string(font, Vector2(right - dw, y + 30), date, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, DIM)

	# Big number: surface days.
	var days := int(e.get("days", 0))
	g.draw_string(font, Vector2(x, y + 84), str(days), HORIZONTAL_ALIGNMENT_LEFT, -1, 50, TEXT)
	var vw := font.get_string_size(str(days), HORIZONTAL_ALIGNMENT_LEFT, -1, 50).x
	g.draw_string(font, Vector2(x + vw + 10, y + 84), "day" if days == 1 else "days", HORIZONTAL_ALIGNMENT_LEFT, -1, 26, DIM)
	# Real-world time the expedition took, right of the days.
	if e.has("play_seconds"):
		var gt := _real_time(float(e["play_seconds"]))
		var gw := font.get_string_size(gt, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
		g.draw_string(font, Vector2(right - gw, y + 82), gt, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, TEXT)
		var lw := font.get_string_size("DURATION", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		g.draw_string(font, Vector2(right - lw, y + 56), "DURATION", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, DIM)
	if bool(e.get("playtest", false)):
		var pw := font.get_string_size("PLAYTEST", HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		g.draw_string(font, Vector2(right - pw, y + 145), "PLAYTEST", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, YELLOW)

	# Details.
	var rover := int(e.get("rover_samples", 0))
	var you := int(e.get("player_samples", int(e.get("samples", 0)) - rover))
	var maxw := r.size.x - 40.0
	g.draw_string(font, Vector2(x, y + 116), "Samples:  you %d  ·  rover %d" % [you, rover], HORIZONTAL_ALIGNMENT_LEFT, maxw, 22, Color(TEXT, 0.85))
	var steps := "Steps:  %s" % _thousands(int(e["steps"])) if e.has("steps") else "Steps:  not logged"
	g.draw_string(font, Vector2(x, y + 145), steps, HORIZONTAL_ALIGNMENT_LEFT, maxw, 22, Color(TEXT, 0.85))
	if rescues == 0:
		g.draw_string(font, Vector2(x, y + 174), "No medical rescues", HORIZONTAL_ALIGNMENT_LEFT, maxw, 22, GREEN)
	else:
		var a := "Rescues:  heat %d" % heat
		g.draw_string(font, Vector2(x, y + 174), a, HORIZONTAL_ALIGNMENT_LEFT, maxw, 22, PURPLE if heat > 0 else Color(TEXT, 0.6))
		var aw := font.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		g.draw_string(font, Vector2(x + aw, y + 174), "  ·  O2/stamina %d" % o2, HORIZONTAL_ALIGNMENT_LEFT, maxw - aw, 22, RED if o2 > 0 else Color(TEXT, 0.6))


func _draw_empty(r: Rect2) -> void:
	var g := _grid
	g.draw_rect(r, EMPTY_BG)
	g.draw_rect(r, Color(CYAN, 0.12), false, 2.0)
	var t := "EMPTY SLOT"
	var w := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	g.draw_string(font, Vector2(r.position.x + (r.size.x - w) * 0.5, r.position.y + r.size.y * 0.5 + 8), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(CYAN, 0.25))


func _style_bar(bar: VScrollBar) -> void:
	bar.custom_minimum_size.x = 16
	var track := StyleBoxTexture.new()
	track.texture = T_SCROLL
	track.content_margin_left = 7
	track.content_margin_right = 7
	var grab := StyleBoxTexture.new()
	grab.texture = T_SCROLL_GRAB
	grab.content_margin_left = 4
	grab.content_margin_right = 4
	for k in ["scroll", "scroll_focus"]:
		bar.add_theme_stylebox_override(k, track)
	for k in ["grabber", "grabber_highlight", "grabber_pressed"]:
		bar.add_theme_stylebox_override(k, grab)


## Real-world duration as "1h 05m 12s" / "12m 40s" / "18s".
func _real_time(s: float) -> String:
	var t := int(s)
	var h := t / 3600
	var m := (t / 60) % 60
	var sec := t % 60
	if h > 0:
		return "%dh %02dm %02ds" % [h, m, sec]
	if m > 0:
		return "%dm %02ds" % [m, sec]
	return "%ds" % sec


func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out
