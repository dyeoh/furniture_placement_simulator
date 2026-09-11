class_name Placer
extends RefCounted

## Drag, snap, validate and commit furniture.
##
## Everything here is backend-agnostic: bodies are created and destroyed through
## the PhysicsBackend seam, picking is a ray-vs-AABB over the (small) placed
## list, and validation is pure box arithmetic. The solver's only job is the
## settle after a drop -- an item is PLACED once its body falls asleep, which is
## what makes a dropped shelf visibly land instead of snapping into place.
##
## Snap modes are switchable live rather than chosen up front: which one feels
## right for a shopper on a phone is a question only trying them answers.

signal changed
signal item_added(placed: PlacedItem)
signal item_removed(placed: PlacedItem)

enum Snap { FREE, GRID, WALL }
const SNAP_NAMES := ["Free", "Grid 25 cm", "Wall magnet"]

const GRID := 0.25
## How close (item edge to wall) before wall-magnet grabs.
const WALL_PULL := 0.4
## Settle grace: a body is not trusted to be asleep before this many seconds.
const SETTLE_GRACE := 0.25
## Give up waiting for sleep after this long; something wedged against a wall
## may jitter forever, and the shopper should still be able to interact with it.
const SETTLE_TIMEOUT := 4.0

var backend: PhysicsBackend
var room: RoomBuilder
var catalog: Catalog
var visual_root: Node3D

var snap_mode := Snap.GRID
var items: Array[PlacedItem] = []
var dragging: PlacedItem


func setup(p_backend: PhysicsBackend, p_room: RoomBuilder, p_catalog: Catalog,
		p_visual_root: Node3D) -> void:
	backend = p_backend
	room = p_room
	catalog = p_catalog
	visual_root = p_visual_root


func cycle_snap() -> void:
	snap_mode = ((snap_mode + 1) % Snap.size()) as Snap


func snap_name() -> String:
	return SNAP_NAMES[snap_mode]


#region Lifecycle

## Spawn a new ghost from the catalogue and start dragging it.
func begin(item: FurnitureItem, at := Vector3.ZERO) -> PlacedItem:
	if dragging != null:
		cancel()
	var p := PlacedItem.new()
	p.item = item
	p.finish = item.finish
	p.position = at
	p.build_visual(visual_root, _color_for(p))
	items.append(p)
	dragging = p
	drag_to(at)
	item_added.emit(p)
	return p


## Pick a placed item back up: destroy its body, it becomes a ghost again.
func lift(p: PlacedItem) -> void:
	if p == null or p.state == PlacedItem.State.CARRIED:
		return
	if dragging != null and dragging != p:
		cancel()
	_release_body(p)
	# Re-derive the intended placement from wherever the solver left it, so
	# lifting an item that was shoved does not snap it back to its old spot.
	p.state = PlacedItem.State.GHOST
	dragging = p
	drag_to(p.position)


## Follow the pointer. [param floor_point] is where the cursor ray meets y = 0.
func drag_to(floor_point: Vector3) -> void:
	if dragging == null:
		return
	var p := floor_point
	p.y = 0.0
	match snap_mode:
		Snap.GRID:
			p.x = snappedf(p.x, GRID)
			p.z = snappedf(p.z, GRID)
		Snap.WALL:
			p = _wall_magnet(dragging, p)
	dragging.position = _clamp_to_room(dragging, p)
	dragging.valid = validate(dragging)
	dragging.sync_visual(null)
	dragging.set_tint(true, dragging.valid)


func rotate(steps := 1) -> void:
	if dragging == null:
		return
	dragging.yaw = posmod(dragging.yaw + steps, 4)
	drag_to(dragging.position)


## Commit the dragged item. Refused (returns false) when the spot is invalid.
func drop() -> bool:
	if dragging == null:
		return false
	if not validate(dragging):
		return false
	_commit(dragging)
	dragging = null
	changed.emit()
	return true


## Abandon the drag. A freshly spawned ghost is deleted; a lifted one goes back
## to where it was.
func cancel() -> void:
	if dragging == null:
		return
	remove(dragging)
	dragging = null


func remove(p: PlacedItem) -> void:
	if p == dragging:
		dragging = null
	_release_body(p)
	p.free_visual()
	items.erase(p)
	item_removed.emit(p)
	changed.emit()


func clear() -> void:
	if dragging != null:
		dragging = null
	for p in items.duplicate():
		remove(p)


## Walkthrough carry. The body is destroyed and the item follows the shopper
## as a ghost, for the same reason dragging is a ghost: a rigid body driven
## kinematically at chest height would block the very mover carrying it.
func carry(p: PlacedItem) -> bool:
	if p == null or p.state == PlacedItem.State.GHOST or p.state == PlacedItem.State.CARRIED:
		return false
	_release_body(p)
	p.state = PlacedItem.State.CARRIED
	p.set_tint(false, true)
	return true


func carry_to(p: PlacedItem, floor_point: Vector3, yaw: int, height: float) -> void:
	p.position = Vector3(floor_point.x, 0.0, floor_point.z)
	p.yaw = posmod(yaw, 4)
	p.lift_y = height
	p.sync_visual(null)


## Let go: the body is created where the item is held and falls from there.
func drop_carried(p: PlacedItem) -> void:
	if p == null or p.state != PlacedItem.State.CARRIED:
		return
	p.position = _clamp_to_room(p, p.position)
	_commit(p)
	changed.emit()


## What the room comes to at the till: one line per distinct variant, so a
## shelf in oak and the same shelf in blackwood are two lines.
func cart_lines() -> Array:
	var counts := {}
	for p in items:
		if p.state == PlacedItem.State.GHOST:
			continue
		var vid := p.item.variant_for(p.finish)
		if vid == 0:
			continue
		counts[vid] = counts.get(vid, 0) + 1
	var lines := []
	for vid in counts:
		lines.append({"variant_id": vid, "quantity": counts[vid]})
	return lines


func set_finish(p: PlacedItem, key: String) -> void:
	p.finish = key
	p.set_color(_color_for(p))
	changed.emit()


func _color_for(p: PlacedItem) -> Color:
	if p.finish != "" and catalog != null and catalog.finishes.has(p.finish):
		return catalog.finish_color(p.finish)
	return p.item.color


func _commit(p: PlacedItem) -> void:
	# A hair above the floor: a body created exactly touching the ground can
	# start life penetrating it by a solver epsilon and pop upward.
	var xf := p.intended_transform()
	xf.origin.y += 0.02
	p.lift_y = 0.0
	p.body = backend.body_create(p.item.body_shape(), xf,
		PhysicsBackend.BODY_DYNAMIC, Layers.FURNITURE, Layers.ALL)
	p.state = PlacedItem.State.SETTLING
	p.settle_time = 0.0
	p.set_tint(false, true)
	p.sync_visual(backend)


func _release_body(p: PlacedItem) -> void:
	if p.body >= 0:
		# Where the solver left it is the new intended placement.
		var xf := backend.body_get_transform(p.body)
		p.position = Vector3(xf.origin.x, 0.0, xf.origin.z)
		p.yaw = _nearest_quarter(xf.basis)
		backend.body_destroy(p.body)
		p.body = -1


static func _nearest_quarter(b: Basis) -> int:
	var fwd := b.z
	var a := atan2(fwd.x, fwd.z)   # 0 when facing +Z
	return posmod(int(round(a / (PI * 0.5))), 4)

#endregion


#region Per-frame

func update(dt: float) -> void:
	for p in items:
		match p.state:
			PlacedItem.State.SETTLING:
				p.settle_time += dt
				p.sync_visual(backend)
				if p.settle_time >= SETTLE_GRACE and (backend.body_is_sleeping(p.body)
						or p.settle_time > SETTLE_TIMEOUT):
					p.state = PlacedItem.State.PLACED
					var xf := backend.body_get_transform(p.body)
					p.position = Vector3(xf.origin.x, 0.0, xf.origin.z)
					p.valid = validate(p)
					changed.emit()
			PlacedItem.State.PLACED, PlacedItem.State.CARRIED:
				p.sync_visual(backend)


## Is a settle still in progress anywhere? The HUD uses this.
func any_settling() -> bool:
	for p in items:
		if p.state == PlacedItem.State.SETTLING:
			return true
	return false

#endregion


#region Validation and snapping

func validate(p: PlacedItem) -> bool:
	var box := p.aabb(backend if p.body >= 0 else null)
	if not room.contains_aabb(box):
		return false
	# Shrink a touch so two items snapped flush on the grid do not count as
	# overlapping through their shared face.
	var mine := box.grow(-0.005)
	for o in items:
		if o == p or o.state == PlacedItem.State.CARRIED:
			continue
		if mine.intersects(o.aabb(backend if o.body >= 0 else null)):
			return false
	return true


func _clamp_to_room(p: PlacedItem, pos: Vector3) -> Vector3:
	var h := room.half_extents()
	var rs := p.rotated_size()
	pos.x = clampf(pos.x, -h.x + rs.x * 0.5, h.x - rs.x * 0.5)
	pos.z = clampf(pos.z, -h.y + rs.z * 0.5, h.y - rs.z * 0.5)
	return pos


## Wall magnet: within WALL_PULL of a wall, pull flush and turn the item's back
## (local -Z) to it. Items that do not live against walls (tables) just get
## grid-snapped so the mode still feels deliberate for them.
func _wall_magnet(p: PlacedItem, pos: Vector3) -> Vector3:
	if not p.item.wall_snap:
		pos.x = snappedf(pos.x, GRID)
		pos.z = snappedf(pos.z, GRID)
		return pos
	var h := room.half_extents()
	var s := p.item.size
	# Distance from the item's centre to each wall, minus the depth it would
	# have when turned to face that wall. Local -Z is the back, so the extent
	# toward a north/south wall is size.z and toward east/west it is size.z too
	# once rotated -- the rotation is what makes that true.
	var d_north := (pos.z + h.y) - s.z * 0.5
	var d_south := (h.y - pos.z) - s.z * 0.5
	var d_east := (h.x - pos.x) - s.z * 0.5
	var d_west := (pos.x + h.x) - s.z * 0.5
	var best := minf(minf(d_north, d_south), minf(d_east, d_west))
	if best > WALL_PULL:
		pos.x = snappedf(pos.x, GRID)
		pos.z = snappedf(pos.z, GRID)
		return pos
	if best == d_north:
		p.yaw = 0
		pos.z = -h.y + s.z * 0.5
		pos.x = snappedf(pos.x, GRID)
	elif best == d_south:
		p.yaw = 2
		pos.z = h.y - s.z * 0.5
		pos.x = snappedf(pos.x, GRID)
	elif best == d_east:
		p.yaw = 3
		pos.x = h.x - s.z * 0.5
		pos.z = snappedf(pos.z, GRID)
	else:
		p.yaw = 1
		pos.x = -h.x + s.z * 0.5
		pos.z = snappedf(pos.z, GRID)
	return pos

#endregion


#region Picking

## Nearest item along a ray, or null.
func pick(from: Vector3, dir: Vector3) -> PlacedItem:
	var best: PlacedItem = null
	var best_t := INF
	for p in items:
		var t := RoomBuilder.ray_aabb(from, dir, p.aabb(backend if p.body >= 0 else null))
		if t >= 0.0 and t < best_t:
			best_t = t
			best = p
	return best


## Nearest item to a point within [param radius], for the walkthrough's grab.
func nearest(point: Vector3, radius: float) -> PlacedItem:
	var best: PlacedItem = null
	var best_d := radius * radius
	for p in items:
		if p.state == PlacedItem.State.GHOST:
			continue
		var d := p.aabb(backend).get_center().distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = p
	return best


## Where a pointer ray meets the floor plane, or null if it never does.
static func floor_hit(from: Vector3, dir: Vector3) -> Variant:
	if absf(dir.y) < 1e-6:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	return from + dir * t

#endregion
