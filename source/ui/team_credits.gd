extends ShockFrameDialog
## The crew panel opened from the flag: team names, "were here.", and a group photo.
## The photo is res://assets/team-picture.jpg (or set Team Photo in the Inspector).

@export var names: PackedStringArray = [
	"Nico Orobia",
	"Vir Padhya",
	"Minnoli Shukla",
	"Clarissa Suryapranata",
	"Reda Mourtada",
]
@export var tagline := "were here."
@export var name_size := 15      ## Names stay small...
@export var tagline_size := 21   ## ...so "were here." at the bottom stands out.
@export var team_photo: Texture2D
## Fraction of the photo cut off the top (empty wall above the team) so the people
## fill the frame. 0 = show the whole photo.
@export_range(0.0, 0.6) var photo_crop_top := 0.25
## Shows the photo in black and white, like an old NASA crew portrait.
@export var photo_black_and_white := true
@export var underline: Texture2D = preload("uid://brj0kwc3uft1u")  # Decor/decor - underline.png

const TEXT := Color(0.83, 1.0, 0.99)
const DIM := Color(0.55, 0.95, 1.0, 0.7)
const FALLBACK_PHOTOS := ["res://assets/team-picture.jpg", "res://ui/team_photo.png", "res://ui/team_photo.jpg", "res://ui/team_photo.jpeg"]


func _ready() -> void:
	if get_node_or_null("Content") == null:
		var c := Control.new()
		c.name = "Content"
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(c)
	super._ready()
	if team_photo == null:
		for p in FALLBACK_PHOTOS:
			if ResourceLoader.exists(p):
				team_photo = load(p)
				break
	_build()


func _build() -> void:
	var content := get_node("Content") as Control
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 24
	box.offset_right = -24
	box.offset_top = 14
	box.offset_bottom = -18
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(box)

	var names_label := _label("\n".join(names), name_size, DIM)
	names_label.add_theme_constant_override("line_spacing", 1)
	box.add_child(names_label)

	box.add_child(_label(tagline, tagline_size, TEXT))

	if underline:
		var u := TextureRect.new()
		u.texture = underline
		u.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		u.stretch_mode = TextureRect.STRETCH_SCALE
		u.custom_minimum_size = Vector2(0, 2)
		u.modulate = Color(1, 1, 1, 0.6)
		box.add_child(u)

	# Photo area: framed box that takes the rest of the height.
	var frame_box := PanelContainer.new()
	frame_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.06, 0.09, 0.6)
	sb.border_color = Color(0.55, 0.95, 1.0, 0.45)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(6)
	frame_box.add_theme_stylebox_override("panel", sb)
	box.add_child(frame_box)

	if team_photo:
		var tex: Texture2D = team_photo
		if photo_crop_top > 0.0:
			var sz := team_photo.get_size()
			var cropped := AtlasTexture.new()
			cropped.atlas = team_photo
			cropped.region = Rect2(0, sz.y * photo_crop_top, sz.x, sz.y * (1.0 - photo_crop_top))
			tex = cropped
		var photo := TextureRect.new()
		photo.texture = tex
		if photo_black_and_white:
			var mat := ShaderMaterial.new()
			mat.shader = _vintage_shader()
			var crop := photo_crop_top if tex != team_photo else 0.0
			mat.set_shader_parameter("uv_rect", Vector4(0.0, crop, 1.0, 1.0 - crop))
			photo.material = mat
		photo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		photo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		frame_box.add_child(photo)
	else:
		frame_box.add_child(_label("[ team photo ]", 15, DIM))


## Old-film look: black and white, a bit more contrast, slightly faded blacks,
## fine grain and darker corners.
func _vintage_shader() -> Shader:
	var s := Shader.new()
	s.code = """
shader_type canvas_item;

uniform vec4 uv_rect = vec4(0.0, 0.0, 1.0, 1.0);  // visible part of the photo (after the crop)

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float g = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	g = clamp((g - 0.5) * 1.2 + 0.5, 0.0, 1.0);      // contrast
	g = mix(0.06, 0.95, g);                           // faded blacks / whites
	g += (hash(floor(UV * 900.0)) - 0.5) * 0.06;      // film grain
	vec2 d = (UV - uv_rect.xy) / uv_rect.zw - 0.5;
	g *= 1.0 - dot(d, d) * 0.9;                       // vignette
	COLOR = vec4(vec3(g), c.a);
}
"""
	return s


func _label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l
