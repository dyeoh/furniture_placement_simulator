class_name Occlusion
extends RefCounted

## Faked ambient occlusion. The Compatibility renderer has no SSAO, so the
## cues that sell "this is in a room" are supplied by hand: darkening into the
## room's seams, and on the wall behind a piece standing against it.
##
## The seams are AO maps on the wall and floor materials (ambient_light only,
## via UV2), so a sun patch that crosses a corner stays bright, as it would in
## a real room. The wall shading is an unshaded black quad whose alpha is the
## occlusion. (Alpha rather than blend_mul: the Compatibility renderer draws a
## blend_mul quad as a no-op.)

## Soft rounded rectangle: fully dark over the footprint, fading out over
## [code]margin[/code] metres around it. Sized in metres so a bed and a side
## table get the same falloff.
const BLOB_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec2 inner_half = vec2(0.5);
uniform float margin = 0.18;
uniform float strength : hint_range(0.0, 1.0) = 0.6;

void fragment() {
	vec2 p = (UV - 0.5) * (inner_half + margin) * 2.0;
	float r = 0.06;
	vec2 q = abs(p) - inner_half + r;
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
	float a = 1.0 - smoothstep(-0.06, margin, d);
	ALBEDO = vec3(0.0);
	ALPHA = strength * a;
}
"""

const BLOB_MARGIN := 0.18
const BLOB_LIFT := 0.004
## Seam occlusion: 1 - SEAM_DEPTH * exp(-d / SEAM_FALLOFF), d metres from the
## seam. Tight and exponential like the real thing -- a band that fades
## linearly over a hand's width reads as paint.
const SEAM_DEPTH := 0.5
const SEAM_FALLOFF := 0.12
const WALL_AO_SIZE := Vector2i(256, 128)
const FLOOR_AO_SIZE := Vector2i(256, 256)

static var _blob_shader: Shader
## Maps by their parameters: a wall's map does not change as windows move.
static var _ao_cache: Dictionary = {}


## A soft-edged quad for an outline of [param footprint] metres (PlaneMesh:
## X and Z span it, Y is its normal). Its own material, so each use sets its
## own strength (PlacedItem.set_wall_contact).
static func blob(footprint: Vector2) -> MeshInstance3D:
	if _blob_shader == null:
		_blob_shader = Shader.new()
		_blob_shader.code = BLOB_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _blob_shader
	mat.set_shader_parameter("inner_half", footprint * 0.5)
	mat.set_shader_parameter("margin", BLOB_MARGIN)
	var mesh := PlaneMesh.new()
	mesh.size = footprint + Vector2.ONE * BLOB_MARGIN * 2.0
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "ContactShadow"
	return mi


static func set_blob_strength(mi: MeshInstance3D, strength: float) -> void:
	(mi.material_override as ShaderMaterial).set_shader_parameter("strength", strength)


static func seam(d: float) -> float:
	return 1.0 - SEAM_DEPTH * exp(-maxf(d, 0.0) / SEAM_FALLOFF)


## AO for one wall's inside face, spanning its whole [param run] (corners
## included) by [param height]: UV2 (0, 0) is the top of the -X end. Darkens
## into both inside corners at +/-[param inner], the floor, and the ceiling
## when there is one.
static func wall_ao(run: float, height: float, inner: float, with_ceiling: bool) -> ImageTexture:
	var key := "w%.3f/%.3f/%.3f/%s" % [run, height, inner, with_ceiling]
	if _ao_cache.has(key):
		return _ao_cache[key]
	var sz := WALL_AO_SIZE
	var across := PackedFloat32Array()
	for i in sz.x:
		var x := ((i + 0.5) / sz.x - 0.5) * run
		across.append(seam(inner - absf(x)))
	var down := PackedFloat32Array()
	for j in sz.y:
		var y := (1.0 - (j + 0.5) / sz.y) * height
		down.append(seam(y) * (seam(height - y) if with_ceiling else 1.0))
	var tex := _separable(across, down)
	_ao_cache[key] = tex
	return tex


## AO for the floor, spanning [param full] (walls included) and darkening
## toward the inside faces at [param half] -- the interior half-extents.
static func floor_ao(full: Vector2, half: Vector2) -> ImageTexture:
	var key := "f%.3f/%.3f/%.3f/%.3f" % [full.x, full.y, half.x, half.y]
	if _ao_cache.has(key):
		return _ao_cache[key]
	var sz := FLOOR_AO_SIZE
	var across := PackedFloat32Array()
	for i in sz.x:
		across.append(seam(half.x - absf(((i + 0.5) / sz.x - 0.5) * full.x)))
	var down := PackedFloat32Array()
	for j in sz.y:
		down.append(seam(half.y - absf(((j + 0.5) / sz.y - 0.5) * full.y)))
	var tex := _separable(across, down)
	_ao_cache[key] = tex
	return tex


## Greyscale image whose texel (i, j) is across[i] * down[j].
static func _separable(across: PackedFloat32Array, down: PackedFloat32Array) -> ImageTexture:
	var data := PackedByteArray()
	data.resize(across.size() * down.size())
	var k := 0
	for j in down.size():
		for i in across.size():
			data[k] = int(clampf(across[i] * down[j], 0.0, 1.0) * 255.0 + 0.5)
			k += 1
	var img := Image.create_from_data(across.size(), down.size(), false, Image.FORMAT_L8, data)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
