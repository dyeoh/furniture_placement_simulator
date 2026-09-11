class_name FurnitureShapes
extends RefCounted

## Generated furniture for the pieces no generic model suits: a bed, a
## hanging rack, a floor lamp, and the plain slab everything else falls back
## to. Parts are boxes and cylinders inside the item's box, so the collider
## (still the box) is honest. Every timber part shares the one material
## passed in, which is what lets a finish change retint the whole piece.

const LEG := 0.05


static func build(shape: String, size: Vector3, wood: StandardMaterial3D) -> Node3D:
	var root := Node3D.new()
	root.name = "Shape_" + shape
	match shape:
		"bed": _bed(root, size, wood)
		"rack": _rack(root, size, wood)
		"lamp": _lamp(root, size)
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


## Weighted base, slim pole, fabric drum shade. The light itself is added by
## PlacedItem, since it is state (on/off, warmth) rather than geometry.
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
	var fabric := StandardMaterial3D.new()
	fabric.albedo_color = Color(0.96, 0.93, 0.86)
	fabric.roughness = 1.0
	fabric.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := _cyl(root, shade, Vector3(0, half.y - shade_h * 0.5, 0), fabric)
	mi.name = "Shade"


static func _box(root: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.material_override = mat
	root.add_child(mi)
	return mi


static func _cyl(root: Node3D, mesh: CylinderMesh, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.material_override = mat
	root.add_child(mi)
	return mi
