class_name Openings
extends RefCounted

## Places windows and doors: drag one from the catalogue along the walls, drop
## it where it fits. The Placer's counterpart for things that live in a wall.
##
## The list itself is the room's ([member RoomBuilder.openings]), because the
## room is what builds walls around it and what outlives a backend swap. This
## only drags, validates and serialises.

signal changed

## Clearance kept from a corner and between two openings on one wall.
const GAP := 0.1
## Keep a window's head this far under the ceiling.
const HEAD_ROOM := 0.05

var room: RoomBuilder
var catalog: Catalog
var dragging: WallOpening
## Where a lifted opening was, to put it back on cancel; empty for a new one.
var _lifted_from: Dictionary = {}


func setup(p_room: RoomBuilder, p_catalog: Catalog) -> void:
	room = p_room
	catalog = p_catalog
	for op in room.openings:
		op.offset = clamp_offset(op, op.wall, op.offset)
	for op in room.openings:
		op.valid = validate(op)
		_build(op)


## Start dragging a new opening, on the first wall the camera can see.
func begin(item: FurnitureItem) -> WallOpening:
	if dragging != null:
		cancel()
	var op := WallOpening.new()
	op.item = item
	op.ghost = true
	op.wall = "north"
	for w in RoomBuilder.WALLS:
		if not room.hidden_walls.has(w):
			op.wall = w
			break
	op.offset = clamp_offset(op, op.wall, 0.0)
	room.openings.append(op)
	dragging = op
	_lifted_from = {}
	_refresh(op, "")
	return op


## Put an opening straight onto a wall, for scripts and tests. It may not fit;
## check [member WallOpening.valid].
func place(item: FurnitureItem, wall: String, offset: float) -> WallOpening:
	var op := WallOpening.new()
	op.item = item
	op.wall = wall
	op.offset = clamp_offset(op, wall, offset)
	room.openings.append(op)
	_refresh(op, "")
	changed.emit()
	return op


func lift(op: WallOpening) -> void:
	if dragging != null:
		cancel()
	_lifted_from = {"wall": op.wall, "offset": op.offset}
	op.ghost = true
	dragging = op
	op.set_tint(true, op.valid)


## Move the dragged opening to where a pointer ray meets a visible wall, or
## -- over the floor -- to the nearest visible wall.
func drag_ray(from: Vector3, dir: Vector3) -> void:
	if dragging == null:
		return
	var hit := wall_hit(from, dir)
	if hit.is_empty():
		return
	var old := dragging.wall
	dragging.wall = hit["wall"]
	dragging.offset = clamp_offset(dragging, dragging.wall, float(hit["offset"]))
	_refresh(dragging, old)


func drop() -> bool:
	if dragging == null:
		return false
	if not dragging.valid:
		return false
	dragging.ghost = false
	dragging.set_tint(false, true)
	dragging = null
	_lifted_from = {}
	changed.emit()
	return true


func cancel() -> void:
	if dragging == null:
		return
	var op := dragging
	dragging = null
	if _lifted_from.is_empty():
		_remove(op)
		return
	var old := op.wall
	op.wall = _lifted_from["wall"]
	op.offset = _lifted_from["offset"]
	op.ghost = false
	_lifted_from = {}
	_refresh(op, old)
	op.set_tint(not op.valid, op.valid)


func remove(op: WallOpening) -> void:
	if op == dragging:
		dragging = null
		_lifted_from = {}
	_remove(op)
	changed.emit()


func _remove(op: WallOpening) -> void:
	room.openings.erase(op)
	op.free_visual()
	room.rebuild_wall(op.wall)


func clear() -> void:
	dragging = null
	_lifted_from = {}
	var walls := {}
	for op in room.openings:
		walls[op.wall] = true
		op.free_visual()
	room.openings.clear()
	for w in walls:
		room.rebuild_wall(w)


## Rebuild the walls an opening touches and move its node into place.
func _refresh(op: WallOpening, old_wall: String) -> void:
	for o in room.openings:
		o.valid = validate(o)
	if old_wall != "" and old_wall != op.wall:
		room.rebuild_wall(old_wall)
	room.rebuild_wall(op.wall)
	_build(op)
	# Neighbours on either wall may have gone valid or invalid.
	for o in room.openings:
		if o != op and (o.wall == op.wall or o.wall == old_wall):
			o.set_tint(not o.valid, o.valid)


func _build(op: WallOpening) -> void:
	var wall: Node3D = room.meshes.get(op.wall)
	if wall == null:
		return   # headless: no visuals
	var parent := wall.get_node("Openings")
	if op.node == null or not is_instance_valid(op.node):
		op.build_visual(parent, room.wall_thickness)
	elif op.node.get_parent() != parent:
		op.node.reparent(parent, false)
	op.node.position = room.opening_local_position(op)
	op.set_cut(room.is_cut(op.wall))


#region Validation

## Centre offset kept inside the wall's run, clear of the corners.
func clamp_offset(op: WallOpening, wall: String, offset: float) -> float:
	var lim := room.run_half(wall) - op.width() * 0.5 - GAP
	if lim < 0.0:
		return 0.0
	return clampf(offset, -lim, lim)


func validate(op: WallOpening) -> bool:
	var half := room.run_half(op.wall)
	var s := op.span()
	if s.x < -half + GAP - 1e-4 or s.y > half - GAP + 1e-4:
		return false
	if op.head() > room.wall_height - HEAD_ROOM + 1e-4:
		return false
	for o in room.openings:
		if o == op or o.wall != op.wall:
			continue
		var t := o.span()
		if s.x < t.y + GAP - 1e-4 and t.x < s.y + GAP - 1e-4:
			return false
	return true

#endregion


#region Picking

## The wall a pointer ray points at: {wall, offset} on a visible wall it
## hits, else the visible wall nearest where it meets the floor.
func wall_hit(from: Vector3, dir: Vector3) -> Dictionary:
	var best := ""
	var best_t := INF
	for w in RoomBuilder.WALLS:
		if room.hidden_walls.has(w):
			continue
		var b := room.wall_box(w)
		var t := RoomBuilder.ray_aabb(from, dir, AABB(b["centre"] - b["size"] * 0.5, b["size"]))
		if t >= 0.0 and t < best_t:
			best_t = t
			best = w
	if best != "":
		var p := from + dir * best_t
		return {"wall": best, "offset": p[RoomBuilder.run_axis(best)]}
	var f = Placer.floor_hit(from, dir)
	if f == null:
		return {}
	var h := room.half_extents()
	var dist := {"north": f.z + h.y, "south": h.y - f.z, "east": h.x - f.x, "west": f.x + h.x}
	var best_d := INF
	for w in RoomBuilder.WALLS:
		if room.hidden_walls.has(w):
			continue
		if dist[w] < best_d:
			best_d = dist[w]
			best = w
	if best == "":
		return {}
	return {"wall": best, "offset": f[RoomBuilder.run_axis(best)]}


## The opening a ray hits, with its distance: [opening, t], or [null, INF].
func pick(from: Vector3, dir: Vector3) -> Array:
	var best: WallOpening = null
	var best_t := INF
	for op in room.openings:
		if room.hidden_walls.has(op.wall) or op == dragging:
			continue
		var t := RoomBuilder.ray_aabb(from, dir, world_aabb(op))
		if t >= 0.0 and t < best_t:
			best_t = t
			best = op
	return [best, best_t]


## The opening's box in world space, a little proud of both wall faces.
func world_aabb(op: WallOpening) -> AABB:
	var b := room.wall_box(op.wall)
	var c: Vector3 = b["centre"]
	var axis := RoomBuilder.run_axis(op.wall)
	var size := Vector3.ZERO
	size[axis] = op.width()
	size[2 - axis] = room.wall_thickness + 0.1
	size.y = op.height()
	c[axis] = op.offset
	c.y = op.sill() + op.height() * 0.5
	return AABB(c - size * 0.5, size)

#endregion


#region Serialisation

func to_array() -> Array:
	# One being dragged counts where it came from; a new one not at all.
	var out := []
	for op in room.openings:
		if op != dragging:
			out.append(op.to_dict())
		elif not _lifted_from.is_empty():
			out.append({"id": op.item.id, "wall": _lifted_from["wall"],
				"offset": snappedf(_lifted_from["offset"], 0.001)})
	return out


## Replace every opening with [param data] (to_array() output). Unknown ids
## and walls are skipped; a shrunk wall clamps them and flags any overlap.
func restore(data: Array) -> void:
	clear()
	for d in data:
		if not (d is Dictionary):
			continue
		var item := catalog.find(str(d.get("id", "")))
		var wall := str(d.get("wall", ""))
		if item == null or not item.is_opening() or not RoomBuilder.WALLS.has(wall):
			push_warning("Layout: opening '%s' on '%s' skipped" % [d.get("id", ""), wall])
			continue
		var op := WallOpening.new()
		op.item = item
		op.wall = wall
		op.offset = clamp_offset(op, wall, float(d.get("offset", 0.0)))
		room.openings.append(op)
	var walls := {}
	for op in room.openings:
		op.valid = validate(op)
		walls[op.wall] = true
	for w in walls:
		room.rebuild_wall(w)
	for op in room.openings:
		_build(op)

#endregion
