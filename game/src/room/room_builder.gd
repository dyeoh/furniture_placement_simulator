class_name RoomBuilder
extends RefCounted

## One rectangular room: a floor slab and four walls.
##
## Bodies go through the PhysicsBackend seam only, so the same room serves the
## headless tests and the visual scene on either backend. Every box built is
## recorded in [member boxes] -- the bodies are nodeless, so nothing would be
## visible (or paintable) without that record.
##
## The floor's top surface is y = 0 and the interior is centred on the origin,
## which keeps every "is this inside the room" check a plain half-extent compare.

const SURFACES := ["floor", "north", "east", "south", "west"]
const VISUAL_FLOOR_THICKNESS := 0.08
const SKIRTING_HEIGHT := 0.12
const SKIRTING_DEPTH := 0.015

## Interior size in metres.
var width := 6.0
var depth := 5.0
var wall_height := 2.7
var wall_thickness := 0.15
## Thick on purpose: a mover that starts a few centimetres inside the floor
## must be pushed *up* by depenetration, and the nearest exit from a thin slab
## can be the underside.
var floor_thickness := 1.0

## Recorded boxes: { surface, centre, size, inward } -- inward is the unit
## normal pointing into the room (Vector3.UP for the floor).
var boxes: Array[Dictionary] = []
var body_ids: Array[int] = []

## Visuals, keyed by surface name. Empty until build_visuals() is called.
var meshes: Dictionary = {}
var materials: Dictionary = {}
## Visual only (no body, nothing to paint): shown with the cutaway off, i.e.
## in the walkthrough, so there is something overhead.
var ceiling: MeshInstance3D

var default_wall_color := Color(0.93, 0.91, 0.86)
## The laminate's own colour, so the untouched floor is the photograph.
var default_floor_color := Color(0.61, 0.5, 0.39)
var skirting_color := Color(0.96, 0.95, 0.93)
## The swatch each surface was painted with. The material's albedo_color is
## that swatch normalised against the texture (see SurfaceMaterials.tint), so
## it cannot be read back as the paint colour.
var _paint: Dictionary = {}


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
		and aabb.position.y >= -0.001


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
	# camera). Each wall spans the full room including the corner overlap.
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


## One MeshInstance3D per surface, each with its own material so painting one
## wall does not repaint the others.
func build_visuals(parent: Node3D) -> void:
	meshes.clear()
	materials.clear()
	_paint.clear()
	for b in boxes:
		var mesh := BoxMesh.new()
		mesh.size = b["size"]
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = b["centre"]
		if b["surface"] == "floor":
			# The slab is a metre thick for the mover's sake (see
			# floor_thickness); drawing all of it puts a big pale block under
			# the room in the planner view. Draw a thin top instead.
			mesh.size = Vector3(b["size"].x, VISUAL_FLOOR_THICKNESS, b["size"].z)
			mi.position = Vector3(b["centre"].x, -VISUAL_FLOOR_THICKNESS * 0.5, b["centre"].z)
		var mat := SurfaceMaterials.floor(default_floor_color) if b["surface"] == "floor" \
			else SurfaceMaterials.plaster(default_wall_color)
		mi.material_override = mat
		mi.name = "Room_" + b["surface"]
		parent.add_child(mi)
		meshes[b["surface"]] = mi
		materials[b["surface"]] = mat
		if b["surface"] != "floor":
			_add_skirting(mi, b)
	_build_ceiling(parent)


## A skirting board along the wall's foot, a child of the wall so the cutaway
## hides both together. Local space: the wall box is centred on its node.
func _add_skirting(wall: MeshInstance3D, b: Dictionary) -> void:
	var size: Vector3 = b["size"]
	var inward: Vector3 = b["inward"]
	var along_x := absf(inward.z) > 0.5   # north/south walls run along X
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size.x, SKIRTING_HEIGHT, SKIRTING_DEPTH) if along_x \
		else Vector3(SKIRTING_DEPTH, SKIRTING_HEIGHT, size.z)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var half_thickness := absf(inward.dot(size)) * 0.5
	mi.position = inward * (half_thickness + SKIRTING_DEPTH * 0.5) \
		+ Vector3.DOWN * (size.y - SKIRTING_HEIGHT) * 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = skirting_color
	mat.roughness = 0.45
	mi.material_override = mat
	mi.name = "Skirting"
	wall.add_child(mi)


func _build_ceiling(parent: Node3D) -> void:
	var wt := wall_thickness
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width + wt * 2, 0.05, depth + wt * 2)
	ceiling = MeshInstance3D.new()
	ceiling.mesh = mesh
	ceiling.position = Vector3(0, wall_height + 0.025, 0)
	ceiling.material_override = SurfaceMaterials.plaster(Color(0.97, 0.96, 0.94))
	ceiling.name = "Room_ceiling"
	ceiling.visible = false
	parent.add_child(ceiling)


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
func update_cutaway(camera_forward: Vector3, enabled: bool) -> void:
	if ceiling != null:
		ceiling.visible = not enabled
	for b in boxes:
		if b["surface"] == "floor":
			continue
		var mi: MeshInstance3D = meshes.get(b["surface"])
		if mi == null:
			continue
		var inward: Vector3 = b["inward"]
		mi.visible = (not enabled) or inward.dot(camera_forward) < 0.05


## Which surface does a ray hit first? Game-side, since the backends return
## different collider handles and a room has only five boxes.
func pick_surface(from: Vector3, dir: Vector3) -> String:
	var best := ""
	var best_t := INF
	for b in boxes:
		var mi: MeshInstance3D = meshes.get(b["surface"])
		if mi != null and not mi.visible:
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
