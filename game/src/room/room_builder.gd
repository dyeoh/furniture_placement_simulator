class_name RoomBuilder
extends RefCounted

## One rectangular room: a floor slab, four walls and an optional ceiling.
##
## Bodies go through the PhysicsBackend seam only, so the same room serves the
## headless tests and the visual scene on either backend. Every box built is
## recorded in [member boxes] -- the bodies are nodeless, so nothing would be
## visible (or paintable) without that record.
##
## The floor's top surface is y = 0 and the interior is centred on the origin,
## which keeps every "is this inside the room" check a plain half-extent compare.
##
## Windows and doors ([member openings]) live in the walls. A wall's body stays
## a solid box -- nobody climbs out of a window at sill height -- but its visual
## is rebuilt from segments around each window so the sun comes in through it.

const SURFACES := ["floor", "north", "east", "south", "west"]
const WALLS := ["north", "east", "south", "west"]
const VISUAL_FLOOR_THICKNESS := 0.08
const SKIRTING_HEIGHT := 0.12
const SKIRTING_DEPTH := 0.015
const CEILING_THICKNESS := 0.12
const MIN_HEIGHT := 2.2
const MAX_HEIGHT := 4.0
## Section-cut grey for the wall tops, as a floor plan draws cut walls.
const CAP_COLOR := Color(0.24, 0.24, 0.26)

## Interior size in metres.
var width := 6.0
var depth := 5.0
var wall_height := 2.7
var wall_thickness := 0.15
## Thick on purpose: a mover that starts a few centimetres inside the floor
## must be pushed *up* by depenetration, and the nearest exit from a thin slab
## can be the underside.
var floor_thickness := 1.0
## A ceiling blocks the sun like a real one, so light only gets in through
## the windows. Off, the room is open to the sky like a dollhouse.
var has_ceiling := false
## Windows and doors, shared with the Openings tool that places them.
var openings: Array[WallOpening] = []

## Recorded boxes: { surface, centre, size, inward } -- inward is the unit
## normal pointing into the room (Vector3.UP for the floor).
var boxes: Array[Dictionary] = []
var body_ids: Array[int] = []

## Visuals, keyed by surface name. Empty until build_visuals() is called. The
## floor is a MeshInstance3D; a wall is a Node3D on the wall's centre with
## local +Z pointing into the room, holding "Body" (the plaster segments),
## "Trim" (skirting, cap, moulding, seam shading) and "Openings".
var meshes: Dictionary = {}
var materials: Dictionary = {}
var ceiling: MeshInstance3D
## Walls the cutaway is currently hiding -- the ones between camera and room.
var hidden_walls: Array[String] = []

var default_wall_color := Color(0.93, 0.91, 0.86)
## The laminate's own colour, so the untouched floor is the photograph.
var default_floor_color := Color(0.61, 0.5, 0.39)
var skirting_color := Color(0.96, 0.95, 0.93)
## The swatch each surface was painted with. The material's albedo_color is
## that swatch normalised against the texture (see SurfaceMaterials.tint), so
## it cannot be read back as the paint colour.
var _paint: Dictionary = {}
var _skirting_mat: StandardMaterial3D
var _cap_mat: StandardMaterial3D
## What update_cutaway last applied, so it only touches nodes on a change:
## wall -> cut, and the ceiling's mode (-1 = not yet applied).
var _cut: Dictionary = {}
var _ceiling_mode := -1
## Wall caps shown (1, planner) or not (0, walkthrough); -1 = not yet applied.
var _caps_on := -1


## Half-extents of the interior in X and Z.
func half_extents() -> Vector2:
	return Vector2(width * 0.5, depth * 0.5)


func contains_aabb(aabb: AABB) -> bool:
	# Epsilon: an item clamped flush to a wall ends exactly on the bound, and
	# half-extent arithmetic lands a float ulp past it.
	const EPS := 1e-4
	var h := half_extents()
	return aabb.position.x >= -h.x - EPS and aabb.end.x <= h.x + EPS \
		and aabb.position.z >= -h.y - EPS and aabb.end.z <= h.y + EPS \
		and aabb.position.y >= -0.001 and aabb.end.y <= wall_height + EPS


func build(backend: PhysicsBackend) -> void:
	boxes.clear()
	body_ids.clear()
	var h := half_extents()
	var wt := wall_thickness
	var wh := wall_height
	var wy := wh * 0.5
	# Floor: top face at y = 0. Slightly larger than the interior so the walls
	# sit on it rather than hang off its edge.
	_box(backend, "floor", Vector3(0, -floor_thickness * 0.5, 0),
		Vector3(width + wt * 2, floor_thickness, depth + wt * 2), Vector3.UP)
	# Walls, named by compass direction; "north" is -Z (away from the default
	# camera). North and south span the full room including the corners.
	_box(backend, "north", Vector3(0, wy, -h.y - wt * 0.5),
		Vector3(width + wt * 2, wh, wt), Vector3.BACK)
	_box(backend, "south", Vector3(0, wy, h.y + wt * 0.5),
		Vector3(width + wt * 2, wh, wt), Vector3.FORWARD)
	_box(backend, "east", Vector3(h.x + wt * 0.5, wy, 0),
		Vector3(wt, wh, depth), Vector3.LEFT)
	_box(backend, "west", Vector3(-h.x - wt * 0.5, wy, 0),
		Vector3(wt, wh, depth), Vector3.RIGHT)


func _box(backend: PhysicsBackend, surface: String, centre: Vector3, size: Vector3,
		inward: Vector3) -> void:
	boxes.append({"surface": surface, "centre": centre, "size": size, "inward": inward})
	var id := backend.body_create(
		{"type": PhysicsBackend.SHAPE_BOX, "size": size, "friction": 0.9},
		Transform3D(Basis(), centre), PhysicsBackend.BODY_STATIC, Layers.ROOM, Layers.ALL)
	body_ids.append(id)


func wall_box(surface: String) -> Dictionary:
	for b in boxes:
		if b["surface"] == surface:
			return b
	return {}


#region Wall geometry

## World axis a wall runs along: 0 (X) for north/south, 2 (Z) for east/west.
static func run_axis(surface: String) -> int:
	return 0 if surface == "north" or surface == "south" else 2


## Interior half-length of a wall's run (corner to corner, inside).
func run_half(surface: String) -> float:
	var h := half_extents()
	return h.x if run_axis(surface) == 0 else h.y


## Wall frame: origin on the wall's centre, local X along the run, local +Z
## into the room.
func wall_transform(surface: String) -> Transform3D:
	var b := wall_box(surface)
	var inward: Vector3 = b["inward"]
	return Transform3D(Basis(Vector3.UP, atan2(inward.x, inward.z)), b["centre"])


## Along-wall world coordinate to the wall's local X.
func _local_x(surface: String, offset: float) -> float:
	return offset * wall_transform(surface).basis.x[run_axis(surface)]


## Where an opening's node sits, in its wall's local frame.
func opening_local_position(op: WallOpening) -> Vector3:
	return Vector3(_local_x(op.wall, op.offset), op.sill() + op.height() * 0.5 - wall_height * 0.5, 0)

#endregion


#region Visuals

## One material per surface, so painting one wall does not repaint the others.
func build_visuals(parent: Node3D) -> void:
	meshes.clear()
	materials.clear()
	_paint.clear()
	_cut.clear()
	_ceiling_mode = -1
	_caps_on = -1
	hidden_walls.clear()
	_skirting_mat = StandardMaterial3D.new()
	_skirting_mat.albedo_color = skirting_color
	_skirting_mat.roughness = 0.45
	_cap_mat = StandardMaterial3D.new()
	_cap_mat.albedo_color = CAP_COLOR
	_cap_mat.roughness = 1.0
	for b in boxes:
		var surface: String = b["surface"]
		if surface == "floor":
			# The slab is a metre thick for the mover's sake (see
			# floor_thickness); drawing all of it puts a big pale block under
			# the room in the planner view. Draw a thin top instead.
			var full := Vector2(b["size"].x, b["size"].z)
			var mi := MeshInstance3D.new()
			mi.mesh = _box_with_uv2(Vector3(full.x, VISUAL_FLOOR_THICKNESS, full.y), Vector3.ZERO,
				func(p: Vector3) -> Vector2: return Vector2(p.x / full.x + 0.5, p.z / full.y + 0.5))
			mi.position = Vector3(b["centre"].x, -VISUAL_FLOOR_THICKNESS * 0.5, b["centre"].z)
			var fmat := SurfaceMaterials.floor(default_floor_color)
			SurfaceMaterials.set_ao(fmat, Occlusion.floor_ao(full, half_extents()))
			mi.material_override = fmat
			mi.name = "Room_floor"
			parent.add_child(mi)
			meshes[surface] = mi
			materials[surface] = fmat
			continue
		var wall := Node3D.new()
		wall.name = "Room_" + surface
		wall.transform = wall_transform(surface)
		parent.add_child(wall)
		for part in ["Body", "Trim", "Openings"]:
			var n := Node3D.new()
			n.name = part
			wall.add_child(n)
		meshes[surface] = wall
		materials[surface] = SurfaceMaterials.plaster(default_wall_color, true)
		rebuild_wall(surface)
	_build_ceiling(parent)


## Plaster segments and trim for one wall, around its openings. Called on
## every opening move, so it touches only this wall's nodes.
func rebuild_wall(surface: String) -> void:
	var wall: Node3D = meshes.get(surface)
	if wall == null:
		return
	var body := wall.get_node("Body")
	var trim := wall.get_node("Trim")
	for c in body.get_children() + trim.get_children():
		c.free()
	var b := wall_box(surface)
	var size: Vector3 = b["size"]
	var run := size.x if run_axis(surface) == 0 else size.z
	var t := wall_thickness
	var wh := wall_height
	var mat: StandardMaterial3D = materials[surface]

	# Holes (windows) and gaps in the skirting (anything reaching the floor),
	# in local X.
	var holes: Array[Vector4] = []   # x0, x1, y0, y1
	var gaps: Array[Vector2] = []
	for op in openings:
		if op.wall != surface:
			continue
		var lx := _local_x(surface, op.offset)
		var x0 := lx - op.width() * 0.5
		var x1 := lx + op.width() * 0.5
		if op.cuts_wall():
			holes.append(Vector4(x0, x1, op.sill(), op.head()))
		if op.sill() < SKIRTING_HEIGHT + 0.01:
			gaps.append(Vector2(x0, x1))

	var inner := run_half(surface)
	_set_wall_ao(surface)
	# UV2 is the point's place on the whole wall, so every segment around a
	# window samples one continuous AO map.
	var wall_uv2 := func(p: Vector3) -> Vector2:
		return Vector2(p.x / run + 0.5, 0.5 - p.y / wh)
	for seg in _wall_segments(run, wh, holes):
		var at := Vector3(seg.get_center().x, seg.get_center().y - wh * 0.5, 0)
		var mi := MeshInstance3D.new()
		mi.mesh = _box_with_uv2(Vector3(seg.size.x, seg.size.y, t), at, wall_uv2)
		mi.position = at
		mi.material_override = mat
		body.add_child(mi)

	var face := t * 0.5
	# Skirting along the foot, broken at doors and floor-length windows.
	for span in _subtract_spans(Vector2(-run * 0.5, run * 0.5), gaps):
		_trim_box(trim, Vector3(span.y - span.x, SKIRTING_HEIGHT, SKIRTING_DEPTH),
			Vector3((span.x + span.y) * 0.5, SKIRTING_HEIGHT * 0.5 - wh * 0.5, face + SKIRTING_DEPTH * 0.5),
			_skirting_mat)
	# The cut top, dark like a plan's section fill: it reads the wall height.
	# Planner only (see update_cutaway), and no wider than the wall, so it
	# never shows as a line from inside.
	var cap := _trim_box(trim, Vector3(run, 0.012, t), Vector3(0, wh * 0.5 + 0.006, 0), _cap_mat)
	cap.name = "Cap"
	cap.visible = _caps_on == 1
	# Crown moulding: a stepped two-box profile, only under a ceiling.
	var crown := Node3D.new()
	crown.name = "Crown"
	crown.visible = has_ceiling
	trim.add_child(crown)
	_trim_box(crown, Vector3(inner * 2.0, 0.09, 0.018), Vector3(0, wh * 0.5 - 0.045, face + 0.009), _skirting_mat)
	_trim_box(crown, Vector3(inner * 2.0, 0.035, 0.04), Vector3(0, wh * 0.5 - 0.0175, face + 0.02), _skirting_mat)

	if _cut.has(surface):
		_apply_cut(surface, bool(_cut[surface]))


## Rectangles (local X, height above the floor) covering a wall of [param run]
## by [param height] minus the [param holes]. Columns are cut at every hole
## edge; within a column the solid parts are what the covering holes leave.
## Overlapping holes (a ghost dragged over another window) merge.
static func _wall_segments(run: float, height: float, holes: Array[Vector4]) -> Array[Rect2]:
	var xs: Array[float] = [-run * 0.5, run * 0.5]
	for h in holes:
		xs.append(clampf(h.x, -run * 0.5, run * 0.5))
		xs.append(clampf(h.y, -run * 0.5, run * 0.5))
	xs.sort()
	var out: Array[Rect2] = []
	for i in xs.size() - 1:
		var a := xs[i]
		var b := xs[i + 1]
		if b - a < 1e-4:
			continue
		var mid := (a + b) * 0.5
		var cover: Array[Vector2] = []
		for h in holes:
			if mid > h.x and mid < h.y:
				cover.append(Vector2(clampf(h.z, 0.0, height), clampf(h.w, 0.0, height)))
		for span in _subtract_spans(Vector2(0.0, height), cover):
			out.append(Rect2(a, span.x, b - a, span.y - span.x))
	return out


## [param whole] minus the union of [param cuts], as sorted spans.
static func _subtract_spans(whole: Vector2, cuts: Array[Vector2]) -> Array[Vector2]:
	var sorted := cuts.duplicate()
	sorted.sort_custom(func(p: Vector2, q: Vector2): return p.x < q.x)
	var out: Array[Vector2] = []
	var at := whole.x
	for c in sorted:
		if c.x > at + 1e-4:
			out.append(Vector2(at, minf(c.x, whole.y)))
		at = maxf(at, c.y)
		if at >= whole.y:
			break
	if whole.y - at > 1e-4:
		out.append(Vector2(at, whole.y))
	return out


## The wall's seam AO: its corners, the floor, and the ceiling if there is one.
func _set_wall_ao(surface: String) -> void:
	var size: Vector3 = wall_box(surface)["size"]
	var run := size.x if run_axis(surface) == 0 else size.z
	SurfaceMaterials.set_ao(materials[surface],
		Occlusion.wall_ao(run, wall_height, run_half(surface), has_ceiling))


## A box mesh like BoxMesh, plus UV2 from [param uv2_of] called with each
## vertex in the parent's frame ([param at] is the box's position there).
static func _box_with_uv2(size: Vector3, at: Vector3, uv2_of: Callable) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = size
	var arrays := box.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv2 := PackedVector2Array()
	uv2.resize(verts.size())
	for i in verts.size():
		uv2[i] = uv2_of.call(verts[i] + at)
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _trim_box(parent: Node3D, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _build_ceiling(parent: Node3D) -> void:
	# A little past the outside of the walls, so no sunlight slips in along
	# the top of a wall at a grazing angle.
	var over := wall_thickness * 2 + 0.2
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width + over, CEILING_THICKNESS, depth + over)
	ceiling = MeshInstance3D.new()
	ceiling.mesh = mesh
	ceiling.position = Vector3(0, wall_height + CEILING_THICKNESS * 0.5, 0)
	ceiling.material_override = SurfaceMaterials.plaster(Color(0.97, 0.96, 0.94))
	ceiling.name = "Room_ceiling"
	ceiling.visible = false
	parent.add_child(ceiling)


func set_ceiling(on: bool) -> void:
	has_ceiling = on
	_ceiling_mode = -1
	for surface in WALLS:
		var wall: Node3D = meshes.get(surface)
		if wall == null:
			continue
		wall.get_node("Trim/Crown").visible = on
		_set_wall_ao(surface)


func paint(surface: String, color: Color) -> void:
	if not materials.has(surface):
		return
	_paint[surface] = color
	SurfaceMaterials.tint(materials[surface],
		"laminate_floor_02" if surface == "floor" else "plaster_grey_04", color)


func paint_color(surface: String) -> Color:
	if _paint.has(surface):
		return _paint[surface]
	return default_floor_color if surface == "floor" else default_wall_color


## Sims-style cutaway: hide the walls between the camera and the room so the
## planner view is never blocked. The far wall's inward normal points back
## toward the camera (against the view direction), so it stays; a wall whose
## inward normal points along the view direction is in front of the room and
## goes.
##
## A cut wall still casts its shadow, and a ceiling in the planner view is
## shadow only: the room is lit as the covered room it is, sun through the
## windows and all, while the view stays open.
func update_cutaway(camera_forward: Vector3, enabled: bool) -> void:
	hidden_walls.clear()
	for b in boxes:
		var surface: String = b["surface"]
		if surface == "floor" or not meshes.has(surface):
			continue
		var inward: Vector3 = b["inward"]
		var cut := enabled and inward.dot(camera_forward) >= 0.05
		if cut:
			hidden_walls.append(surface)
		if _cut.get(surface) != cut:
			_cut[surface] = cut
			_apply_cut(surface, cut)
	var caps := 1 if enabled else 0
	if caps != _caps_on:
		_caps_on = caps
		for surface in WALLS:
			if meshes.has(surface):
				meshes[surface].get_node("Trim/Cap").visible = enabled
	if ceiling == null:
		return
	# 0 none, 1 shadow only (planner), 2 solid (walkthrough).
	var mode := 0 if not has_ceiling else (1 if enabled else 2)
	if mode != _ceiling_mode:
		_ceiling_mode = mode
		ceiling.visible = mode != 0
		ceiling.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if mode == 1 \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _apply_cut(surface: String, cut: bool) -> void:
	var wall: Node3D = meshes[surface]
	for c in wall.get_node("Body").get_children():
		(c as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY \
			if cut else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	wall.get_node("Trim").visible = not cut
	for op in openings:
		if op.wall == surface:
			op.set_cut(cut)


func is_cut(surface: String) -> bool:
	return bool(_cut.get(surface, false))

#endregion


## Which surface does a ray hit first? Game-side, since the backends return
## different collider handles and a room has only five boxes. Cut-away walls
## are not there to hit.
func pick_surface(from: Vector3, dir: Vector3) -> String:
	var best := ""
	var best_t := INF
	for b in boxes:
		if hidden_walls.has(b["surface"]):
			continue
		var aabb := AABB(b["centre"] - b["size"] * 0.5, b["size"])
		var t := ray_aabb(from, dir, aabb)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = b["surface"]
	return best


## Slab test. Returns the entry distance along [param dir], or -1 for a miss.
static func ray_aabb(from: Vector3, dir: Vector3, aabb: AABB) -> float:
	var tmin := -INF
	var tmax := INF
	for i in 3:
		var d := dir[i]
		var lo := aabb.position[i]
		var hi := aabb.end[i]
		if absf(d) < 1e-8:
			if from[i] < lo or from[i] > hi:
				return -1.0
			continue
		var t1 := (lo - from[i]) / d
		var t2 := (hi - from[i]) / d
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return -1.0
	if tmax < 0.0:
		return -1.0
	return maxf(tmin, 0.0)
