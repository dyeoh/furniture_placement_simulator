class_name Catalog
extends RefCounted

## The list of things that can be placed.
##
## Loaded from res://data/catalog.json by default. The host page (the Shopify
## section) can replace it wholesale at runtime with the live collection, and
## uploaded models are appended. Either way callers only ever see [member items].

signal changed

const DEFAULT_PATH := "res://data/catalog.json"

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
