class_name FurnitureItem
extends RefCounted

## One catalogue entry: what a piece of furniture *is*, independent of any
## placed instance of it.
##
## Sizes are stored in metres, X = width, Y = height, Z = depth -- i.e. Godot's
## axes, not the store's W x D x H order. The conversion happens once, here,
## rather than at every call site.

var id := ""
var name := ""
## Full extents in metres (width, height, depth).
var size := Vector3(1, 1, 1)
var mass := 10.0
## Pull flush to the nearest wall in wall-magnet snap mode. True for anything
## that lives against a wall (shelves, cabinets, beds), false for tables.
var wall_snap := false
## Shopify variant to add to cart. 0 when the product has no purchasable variant.
var variant_id := 0
## Key into Catalog.finishes; drives the tint.
var finish := ""
var color := Color(0.8, 0.7, 0.55)
## Dimensions were guessed rather than read from the product page.
var estimated := false
## Optional mesh for the visual (uploaded or fetched model). Null = box.
var mesh_scene: PackedScene
## Collider description for PhysicsBackend.body_create(). Defaults to a box of
## [member size]; uploaded models may swap in a hull.
var shape: Dictionary = {}
## Offset from the collider centre to the visual's origin, for meshes whose
## origin is not at their bounding-box centre.
var mesh_offset := Vector3.ZERO


static func from_dict(d: Dictionary, finishes: Dictionary) -> FurnitureItem:
	var it := FurnitureItem.new()
	it.id = str(d.get("id", ""))
	it.name = str(d.get("name", it.id))
	if d.has("size_mm"):
		var mm: Array = d["size_mm"]
		it.size = Vector3(float(mm[0]), float(mm[2]), float(mm[1])) * 0.001
	elif d.has("size"):
		var m: Array = d["size"]
		it.size = Vector3(float(m[0]), float(m[1]), float(m[2]))
	it.mass = float(d.get("mass", 10.0))
	it.wall_snap = bool(d.get("wall_snap", false))
	it.variant_id = int(d.get("variant_id", 0))
	it.estimated = bool(d.get("estimated", false))
	it.finish = str(d.get("finish", ""))
	if finishes.has(it.finish):
		it.color = Color(str(finishes[it.finish].get("color", "#c0a080")))
	elif d.has("color"):
		it.color = Color(str(d["color"]))
	it.shape = {"type": PhysicsBackend.SHAPE_BOX, "size": it.size}
	return it


func to_dict() -> Dictionary:
	return {
		"id": id, "name": name,
		"size": [size.x, size.y, size.z],
		"mass": mass, "wall_snap": wall_snap, "variant_id": variant_id,
		"finish": finish, "color": "#" + color.to_html(false), "estimated": estimated,
	}


func volume() -> float:
	return maxf(size.x * size.y * size.z, 1e-4)


## Collider spec with density derived from the catalogue mass, so a 70 kg bed
## and an 8 kg side table settle and get shoved differently.
func body_shape() -> Dictionary:
	var s := shape.duplicate()
	s["density"] = mass / volume()
	s["friction"] = 0.8
	return s
