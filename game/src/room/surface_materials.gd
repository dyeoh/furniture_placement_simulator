class_name SurfaceMaterials
extends RefCounted

## PBR materials for the room and for generated furniture parts.
##
## Three CC0 texture sets from Poly Haven (albedo, normal, roughness), mapped
## triplanar so a box of any size gets grain at real-world scale with no UV
## work. Painting and finishes keep working by setting albedo_color: it is a
## tint *over* the texture, so every set records the mean colour of its
## albedo and [method tint] divides by it -- a wall painted Sage comes out
## Sage, not Sage times plaster-grey.

const DIR := "res://assets/textures/"

## set -> { size: real-world edge in metres, mean: linear mean albedo }
## Means measured once from the 1K albedo maps (tools: 64x64 box average).
const SETS := {
	"plaster_grey_04": {"size": 1.5, "mean": Color(0.294, 0.273, 0.217)},
	"laminate_floor_02": {"size": 1.7, "mean": Color(0.330, 0.218, 0.126)},
	"oak_veneer_01": {"size": 1.83, "mean": Color(0.355, 0.207, 0.095)},
}

static var _textures: Dictionary = {}


## Painted plaster: the paint *is* the colour, so no albedo texture -- the
## photographed plaster is stained in a way a showroom wall is not -- just
## its relief, matte.
static func plaster(color: Color) -> StandardMaterial3D:
	var m := _make("plaster_grey_04", true, false)
	m.normal_scale = 0.5
	m.roughness = 0.92
	m.albedo_color = color
	return m


## Laminate planks. Matte-ish on purpose: the photographed roughness is
## semi-gloss, and a glossy floor under a low sun becomes one big highlight
## in the planner view.
static func floor(color: Color) -> StandardMaterial3D:
	var m := _make("laminate_floor_02", true, true)
	m.normal_scale = 0.8
	m.roughness = 0.72
	m.metallic_specular = 0.3
	tint(m, "laminate_floor_02", color)
	return m


static func wood(color: Color) -> StandardMaterial3D:
	# Object-space triplanar: the grain follows the piece when it is rotated
	# or carried, rather than sliding through it.
	var m := _make("oak_veneer_01", false, true)
	m.normal_scale = 0.7
	m.roughness_texture = _tex("oak_veneer_01", "rough")
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	tint(m, "oak_veneer_01", color)
	return m


## Colour that, multiplied with the set's albedo, averages to [param color].
## Done in linear space because that is where the shader multiplies.
static func tint(m: StandardMaterial3D, set_name: String, color: Color) -> void:
	if m.albedo_texture == null:
		m.albedo_color = color
		return
	m.albedo_color = normalised(color, SETS[set_name]["mean"])


static func normalised(color: Color, mean_linear: Color) -> Color:
	var lin := color.srgb_to_linear()
	var t := Color(lin.r / maxf(mean_linear.r, 0.01), lin.g / maxf(mean_linear.g, 0.01),
		lin.b / maxf(mean_linear.b, 0.01), color.a)
	return t.linear_to_srgb()


static func _make(set_name: String, world_space: bool, with_albedo: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if with_albedo:
		m.albedo_texture = _tex(set_name, "diff")
	m.normal_enabled = true
	m.normal_texture = _tex(set_name, "nor_gl")
	m.uv1_triplanar = true
	m.uv1_world_triplanar = world_space
	# Triplanar UV = position * scale, so one texture repeat per real edge.
	m.uv1_scale = Vector3.ONE / float(SETS[set_name]["size"])
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m


static func _tex(set_name: String, map: String) -> Texture2D:
	var key := set_name + "/" + map
	if not _textures.has(key):
		_textures[key] = load("%s%s/%s_%s_1k.jpg" % [DIR, set_name, set_name, map])
	return _textures[key]
