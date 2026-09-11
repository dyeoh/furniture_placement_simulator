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
## Shopify variant to add to cart when [member variants] has no entry for the
## chosen finish. 0 when the product has no purchasable variant.
var variant_id := 0
## Shopify variant per finish key. The store sells every piece in its five
## timbers as one "Timber" option, so a shelf in blackwood is a different
## variant from the same shelf in oak; this is what makes the finish picker
## put the right one in the cart. Empty for single-variant products.
var variants: Dictionary = {}
## Key into Catalog.finishes; drives the tint.
var finish := ""
var color := Color(0.8, 0.7, 0.55)
## Dimensions were guessed rather than read from the product page.
var estimated := false
## Optional mesh for the visual (uploaded or fetched model). Null = box.
var mesh_scene: PackedScene
## Generic CC0 model standing in for the product (ModelLibrary key), fitted
## to [member size]. Empty = use [member shape_kind].
var model := ""
## Generated geometry (FurnitureShapes key: bed, rack, lamp) when no generic
## model suits; empty = plain slab. "lamp" also makes the item a light.
var shape_kind := ""
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
	for key in d.get("variants", {}):
		it.variants[str(key)] = int(d["variants"][key])
	it.estimated = bool(d.get("estimated", false))
	it.finish = str(d.get("finish", ""))
	# A default finish the product cannot be bought in would put the wrong
	# variant in the cart, so fall back to the first one it comes in.
	if not it.variants.is_empty() and not it.variants.has(it.finish):
		it.finish = str(it.variants.keys()[0])
	if finishes.has(it.finish):
		it.color = Color(str(finishes[it.finish].get("color", "#c0a080")))
	elif d.has("color"):
		it.color = Color(str(d["color"]))
	it.shape = {"type": PhysicsBackend.SHAPE_BOX, "size": it.size}
	it.model = str(d.get("model", ""))
	it.shape_kind = str(d.get("shape", ""))
	if it.model == "" and it.shape_kind == "":
		it.shape_kind = shape_for_name(it.name)
		if it.shape_kind == "":
			it.model = ModelLibrary.for_name(it.name)
	return it


## Pieces that get generated geometry rather than a generic model.
static func shape_for_name(item_name: String) -> String:
	var n := item_name.to_lower()
	if n.contains("lamp"):
		return "lamp"
	if n.contains("rack"):
		return "rack"
	if n.contains("bed") and not n.contains("bedside"):
		return "bed"
	return ""


func is_light() -> bool:
	return shape_kind == "lamp"


func to_dict() -> Dictionary:
	return {
		"id": id, "name": name,
		"size": [size.x, size.y, size.z],
		"mass": mass, "wall_snap": wall_snap, "variant_id": variant_id, "variants": variants,
		"finish": finish, "color": "#" + color.to_html(false), "estimated": estimated,
		"model": model, "shape": shape_kind,
	}


## The variant to buy for a finish: the mapped one, else the product default.
func variant_for(finish_key: String) -> int:
	return int(variants.get(finish_key, variant_id))


## Finish keys the picker should offer: only the ones the store sells this
## piece in, or every catalogue finish when the product carries no mapping.
func finish_choices(all_finishes: Dictionary) -> Array:
	if variants.is_empty():
		return all_finishes.keys()
	var keys := []
	for key in all_finishes:
		if variants.has(key):
			keys.append(key)
	return keys


func volume() -> float:
	return maxf(size.x * size.y * size.z, 1e-4)


## Collider spec with density derived from the catalogue mass, so a 70 kg bed
## and an 8 kg side table settle and get shoved differently.
func body_shape() -> Dictionary:
	var s := shape.duplicate()
	s["density"] = mass / volume()
	s["friction"] = 0.8
	return s
