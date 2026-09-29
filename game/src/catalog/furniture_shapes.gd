class_name FurnitureShapes
extends RefCounted

## Generated furniture for the pieces no generic model suits: a bed, a
## hanging rack, a floor lamp, and the plain slab everything else falls back
## to -- plus the windows and doors that go in the walls. Parts are boxes and cylinders inside the item's box, so the collider
## (still the box) is honest. Every timber part shares the one material
## passed in, which is what lets a finish change retint the whole piece.

const LEG := 0.05
## How much light a lampshade's fabric lets through (backlight colour).
const FABRIC_TRANSLUCENCY := Color(0.26, 0.23, 0.19)


static func build(shape: String, size: Vector3, wood: StandardMaterial3D) -> Node3D:
	var root := Node3D.new()
	root.name = "Shape_" + shape
	match shape:
		"bed": _bed(root, size, wood)
		"rack": _rack(root, size, wood)
		"lamp": _lamp(root, size)
		"window": _window(root, size)
		"door": _door(root, size)
		_: _slab(root, size, wood)
	return root


static func _slab(root: Node3D, size: Vector3, wood: StandardMaterial3D) -> void:
	_box(root, size, Vector3.ZERO, wood)


## Low platform on legs, mattress inset on top, headboard on -Z (the "back",
## which is what wall-magnet snaps to a wall).
static func _bed(root: Node3D, size: Vector3, wood: StandardMaterial3D) -> void:
	var half := size * 0.5
	var head_t := minf(0.05, size.z * 0.05)
	var head_h := size.y
	var frame_h := minf(0.12, size.y * 0.35)
	var leg_h := minf(0.15, size.y * 0.3)
	var mattress_h := maxf(size.y - leg_h - frame_h, 0.05)
	var body_z := size.z - head_t
	# Legs
	for sx: int in [-1, 1]:
		for sz: int in [-1, 1]:
			_box(root, Vector3(LEG, leg_h, LEG),
				Vector3(sx * (half.x - LEG * 0.5 - 0.02), -half.y + leg_h * 0.5,
					sz * (body_z * 0.5 - LEG * 0.5 - 0.02) + head_t * 0.5), wood)
	# Frame
	_box(root, Vector3(size.x, frame_h, body_z),
		Vector3(0, -half.y + leg_h + frame_h * 0.5, head_t * 0.5), wood)
	# Headboard
	_box(root, Vector3(size.x, head_h, head_t), Vector3(0, 0, -half.z + head_t * 0.5), wood)
	# Mattress: separate fabric material, slightly inset
	var fabric := StandardMaterial3D.new()
	fabric.albedo_color = Color(0.93, 0.92, 0.89)
	fabric.roughness = 1.0
	_box(root, Vector3(size.x - 0.06, mattress_h, body_z - 0.06),
		Vector3(0, -half.y + leg_h + frame_h + mattress_h * 0.5, head_t * 0.5), fabric)


## Two A-frames and a rail.
static func _rack(root: Node3D, size: Vector3, wood: StandardMaterial3D) -> void:
	var half := size * 0.5
	var bar := 0.035
	for sx: int in [-1, 1]:
		var x := sx * (half.x - bar * 0.5)
		var leg_len := sqrt(size.y * size.y + half.z * half.z)
		for sz: int in [-1, 1]:
			var leg := _box(root, Vector3(bar, leg_len, bar), Vector3(x, 0, sz * half.z * 0.5), wood)
			leg.rotation.x = -sz * atan2(half.z, size.y)
		_box(root, Vector3(bar, bar, size.z), Vector3(x, -half.y + bar * 0.5, 0), wood)
	var rail := CylinderMesh.new()
	rail.top_radius = 0.015
	rail.bottom_radius = 0.015
	rail.height = size.x
	var mi := MeshInstance3D.new()
	mi.mesh = rail
	mi.rotation.z = PI * 0.5
	mi.position = Vector3(0, half.y - 0.03, 0)
	mi.material_override = wood
	root.add_child(mi)


## Weighted base, slim pole, an open fabric drum with a bulb on the pole's tip
## in the middle of it. The light itself is added by PlacedItem, at the bulb
## (bulb_height), since it is state (on/off, warmth) rather than geometry.
static func _lamp(root: Node3D, size: Vector3) -> void:
	var half := size * 0.5
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.15, 0.15, 0.16)
	metal.metallic = 0.8
	metal.roughness = 0.35
	var base := CylinderMesh.new()
	base.top_radius = minf(half.x, half.z) * 0.6
	base.bottom_radius = base.top_radius
	base.height = 0.02
	_cyl(root, base, Vector3(0, -half.y + 0.01, 0), metal)
	var shade_h := size.y * 0.28
	var pole := CylinderMesh.new()
	pole.top_radius = 0.012
	pole.bottom_radius = 0.012
	pole.height = size.y - shade_h * 0.5 - 0.02
	_cyl(root, pole, Vector3(0, -half.y + 0.02 + pole.height * 0.5, 0), metal)
	var shade := CylinderMesh.new()
	shade.top_radius = minf(half.x, half.z) * 0.85
	shade.bottom_radius = minf(half.x, half.z)
	shade.height = shade_h
	# Hollow: open top and bottom, so you look up into it at the bulb.
	shade.cap_top = false
	shade.cap_bottom = false
	var fabric := StandardMaterial3D.new()
	fabric.albedo_color = Color(0.96, 0.93, 0.86)
	fabric.roughness = 1.0
	# Light diffusing through the fabric. The Compatibility renderer has no
	# subsurface scattering (Forward+ only); backlight is its translucency
	# term: light reaching the inside face shows through on the outside, so
	# the bulb makes the drum glow, brightest nearest it, in its colour, and
	# not at all when it is off. PlacedItem adds a faint emission on top.
	fabric.backlight_enabled = true
	fabric.backlight = FABRIC_TRANSLUCENCY
	var mi := _cyl(root, shade, Vector3(0, half.y - shade_h * 0.5, 0), fabric)
	mi.name = "Shade"
	# The shade does not cast: a real fabric shade passes most of its light,
	# and a solid one would throw hard bands up and down the wall. The lamp's
	# shadows come from everything else -- pole, base, furniture.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The lining: the same drum turned inside out, darker, so the inside --
	# a hand's width from the bulb -- shows its falloff instead of burning to
	# a flat white disc.
	var inner := shade.duplicate() as CylinderMesh
	inner.flip_faces = true
	var lining := StandardMaterial3D.new()
	lining.albedo_color = Color(0.5, 0.47, 0.42)
	lining.roughness = 1.0
	var li := _cyl(root, inner, mi.position, lining)
	li.name = "Lining"
	li.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bulb := SphereMesh.new()
	bulb.radius = 0.035
	bulb.height = 0.08
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(1.0, 0.98, 0.94)
	var b := _cyl(root, bulb, Vector3(0, bulb_height(size), 0), glass)
	b.name = "Bulb"
	b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Where a lamp's bulb sits above its centre: the pole's tip, mid-shade.
static func bulb_height(size: Vector3) -> float:
	return size.y * 0.5 - size.y * 0.28 * 0.5


## A white casement: frame, inside sill, a mullion when it is wide, and glass.
## [param size] is (width, height, wall thickness), centred on the wall's
## middle plane with +Z into the room. The frame is tagged "caster": on a
## cut-away wall it keeps its shadow, so the sun patch on the floor has bars.
static func _window(root: Node3D, size: Vector3) -> void:
	var half := size * 0.5
	var f := 0.06
	var d := size.z + 0.04
	var paint := _trim_material()
	for s: int in [-1, 1]:
		_box(root, Vector3(size.x, f, d), Vector3(0, s * (half.y - f * 0.5), 0), paint).set_meta("caster", true)
		_box(root, Vector3(f, size.y - f * 2, d), Vector3(s * (half.x - f * 0.5), 0, 0), paint).set_meta("caster", true)
	if size.x > 1.5:
		_box(root, Vector3(f * 0.6, size.y - f * 2, d * 0.6), Vector3.ZERO, paint).set_meta("caster", true)
	# Transom bar on tall windows, a third of the way down.
	if size.y > 1.6:
		_box(root, Vector3(size.x - f * 2, f * 0.6, d * 0.6), Vector3(0, half.y - size.y / 3.0, 0), paint).set_meta("caster", true)
	var board := _box(root, Vector3(size.x + 0.08, 0.03, 0.14),
		Vector3(0, -half.y - 0.015, half.z + 0.05), paint)
	board.set_meta("caster", true)
	board.name = "Sill"
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.82, 0.9, 0.95, 0.12)
	glass.roughness = 0.05
	glass.metallic_specular = 0.9
	var pane := _box(root, Vector3(size.x - f * 2, size.y - f * 2, 0.012), Vector3.ZERO, glass)
	pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pane.name = "Glass"


## A closed door on the room side of the wall: architrave, a leaf with two
## raised panels, a lever handle. Cuts nothing -- where it leads is not part
## of the room.
static func _door(root: Node3D, size: Vector3) -> void:
	var half := size * 0.5
	var f := 0.07
	var face := half.z
	var paint := _trim_material()
	# Architrave: two jambs and a head, 3 cm proud of the wall.
	for s: int in [-1, 1]:
		_box(root, Vector3(f, size.y, 0.03), Vector3(s * (half.x - f * 0.5), 0, face + 0.015), paint)
	_box(root, Vector3(size.x, f, 0.03), Vector3(0, half.y - f * 0.5, face + 0.015), paint)
	var leaf_w := size.x - f * 2
	var leaf_h := size.y - f
	var leaf_y := -f * 0.5
	_box(root, Vector3(leaf_w, leaf_h, 0.02), Vector3(0, leaf_y, face + 0.01), paint).name = "Leaf"
	var panel_w := leaf_w - 0.2
	var panel_h := (leaf_h - 0.3) * 0.5
	for s: int in [-1, 1]:
		_box(root, Vector3(panel_w, panel_h, 0.008),
			Vector3(0, leaf_y + s * (panel_h * 0.5 + 0.05), face + 0.024), paint)
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.2, 0.2, 0.21)
	metal.metallic = 0.8
	metal.roughness = 0.3
	var hx := leaf_w * 0.5 - 0.08
	var hy := 1.0 - half.y
	_box(root, Vector3(0.05, 0.12, 0.012), Vector3(hx, hy, face + 0.026), metal)
	_box(root, Vector3(0.12, 0.02, 0.02), Vector3(hx - 0.05, hy + 0.02, face + 0.05), metal)


static func _trim_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.95, 0.94, 0.91)
	m.roughness = 0.5
	return m


static func _box(root: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.material_override = mat
	root.add_child(mi)
	return mi


static func _cyl(root: Node3D, mesh: PrimitiveMesh, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.material_override = mat
	root.add_child(mi)
	return mi
