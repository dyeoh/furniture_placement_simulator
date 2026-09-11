class_name Layout
extends RefCounted

## The room as data: which items, where, and what colour the walls are.
##
## This is the contract with the outside world. The host page receives it on
## every change, a backend swap rebuilds from it so the A/B compares the same
## room, and the tests round-trip it. Uploaded models serialise by id like
## anything else; restoring one needs the upload to still be in the catalogue.

const VERSION := 1


static func capture(placer: Placer, room: RoomBuilder, lighting: Lighting = null) -> Dictionary:
	var items := []
	for p in placer.items:
		if p.state == PlacedItem.State.GHOST:
			continue
		items.append(p.to_dict())
	var paint := {}
	for s in RoomBuilder.SURFACES:
		paint[s] = "#" + room.paint_color(s).to_html(false)
	var data := {
		"version": VERSION,
		"room": {"width": room.width, "depth": room.depth},
		"items": items,
		"paint": paint,
	}
	if lighting != null:
		data["lighting"] = lighting.to_dict()
	return data


## Rebuild from a capture. Items are committed straight to bodies -- they drop
## the couple of centimetres and settle, which is also what proves the layout
## was physically stable.
static func restore(data: Dictionary, placer: Placer, room: RoomBuilder, lighting: Lighting = null) -> void:
	placer.clear()
	for d in data.get("items", []):
		if not (d is Dictionary):
			continue
		var item := placer.catalog.find(str(d.get("id", "")))
		if item == null:
			push_warning("Layout: unknown item '%s' skipped" % d.get("id", ""))
			continue
		var p := placer.begin(item, Vector3(float(d.get("x", 0.0)), 0.0, float(d.get("z", 0.0))))
		p.yaw = int(d.get("yaw", 0)) % 4
		p.finish = str(d.get("finish", item.finish))
		placer.set_finish(p, p.finish)
		# Bypass snapping: the stored position is already exact.
		p.position = Vector3(float(d.get("x", 0.0)), 0.0, float(d.get("z", 0.0)))
		p.valid = placer.validate(p)
		if d.get("light") is Dictionary and item.is_light():
			var l: Dictionary = d["light"]
			p.set_light(bool(l.get("on", true)), float(l.get("energy", 0.6)), float(l.get("warmth", 0.7)))
		placer.dragging = null
		placer._commit(p)
	var paint: Dictionary = data.get("paint", {})
	for s in paint:
		room.paint(str(s), Color(str(paint[s])))
	if lighting != null and data.get("lighting") is Dictionary:
		lighting.from_dict(data["lighting"])
	placer.changed.emit()


static func to_json(data: Dictionary) -> String:
	return JSON.stringify(data)


static func from_json(text: String) -> Dictionary:
	var v = JSON.parse_string(text)
	return v if v is Dictionary else {}
