class_name Catalog
extends RefCounted

## The list of things that can be placed.
##
## Loaded from res://data/catalog.json by default. The host page (the Shopify
## section) can replace it wholesale at runtime with the live collection, and
## uploaded models are appended. Either way callers only ever see [member items].
##
## Fixtures -- the floor lamp, windows and a door -- are not products. They
## are appended to every catalogue so the Light tool can always place a lamp
## and every room can have windows; they never reach the cart (variant 0).
## The lamp is hidden from the product list; the openings get their own
## "Architecture" heading. Opening sizes are W x depth x H like the rest,
## depth being ignored (an opening is as deep as its wall).

signal changed

const DEFAULT_PATH := "res://data/catalog.json"
const FIXTURES := [
	{"id": "floor-lamp", "name": "Floor lamp", "size_mm": [420, 420, 1600], "mass": 6,
		"wall_snap": false, "variant_id": 0, "shape": "lamp", "color": "#e8e0d0"},
	{"id": "window", "name": "Window", "size_mm": [1200, 150, 1200], "sill_mm": 900,
		"variant_id": 0, "shape": "window", "color": "#f4f2ee"},
	{"id": "tall-window", "name": "Tall window", "size_mm": [900, 150, 2000], "sill_mm": 100,
		"variant_id": 0, "shape": "window", "color": "#f4f2ee"},
	{"id": "wide-window", "name": "Wide window", "size_mm": [2400, 150, 1400], "sill_mm": 700,
		"variant_id": 0, "shape": "window", "color": "#f4f2ee"},
	{"id": "door", "name": "Door", "size_mm": [900, 150, 2100], "sill_mm": 0,
		"variant_id": 0, "shape": "door", "color": "#f4f2ee"},
]

var items: Array[FurnitureItem] = []
var finishes: Dictionary = {}


func load_default() -> void:
	var f := FileAccess.open(DEFAULT_PATH, FileAccess.READ)
	if f == null:
		push_error("Catalog: cannot open %s" % DEFAULT_PATH)
		return
	var data = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		load_dict(data)


func load_dict(data: Dictionary) -> void:
	if data.has("finishes"):
		finishes = data["finishes"]
	items.clear()
	for d in data.get("items", []):
		if d is Dictionary:
			items.append(FurnitureItem.from_dict(d, finishes))
	for f in FIXTURES:
		items.append(FurnitureItem.from_dict(f, finishes))
	changed.emit()


func add(item: FurnitureItem) -> void:
	items.append(item)
	changed.emit()


func find(id: String) -> FurnitureItem:
	for it in items:
		if it.id == id:
			return it
	return null


func finish_color(key: String) -> Color:
	if finishes.has(key):
		return Color(str(finishes[key].get("color", "#c0a080")))
	return Color(0.75, 0.63, 0.5)
