class_name Box3DBackend
extends PhysicsBackend

## PhysicsBackend implemented on Box3D via the box3d-godot GDExtension.
##
## This is the primary backend. It is the only one that can offer real mover
## semantics, because Box3D exposes the contact planes directly
## (b3World_CastMover -> b3SolvePlanes -> b3ClipVector) and the upstream
## Box3DCharacterBody node surfaces them to script.
##
## The mover glue used to sit in a Box3DMover node we maintained ourselves.
## Upstream's character node now does everything it did -- swept cast, oriented
## capsule, plane reporting, velocity clipping -- so ours was deleted rather
## than carried alongside it.

# Box3DBody.ShapeType values, which do not line up with PhysicsBackend's
# (Box3D has a CONE we do not expose, so everything after CYLINDER shifts).
const _B3_BOX := 0
const _B3_SPHERE := 1
const _B3_CAPSULE := 2
const _B3_CYLINDER := 3
const _B3_HULL := 5
const _B3_MESH := 6

## A contact plane counts as a wall when its normal is within this cosine of
## perpendicular to up -- i.e. steeper than 70 degrees. Deliberately independent
## of the profile's ground angle; see mover_move() for why sharing one threshold
## breaks surface-relative locomotion.
const WALL_COSINE := 0.342

const _SHAPE_MAP := {
	PhysicsBackend.SHAPE_BOX: _B3_BOX,
	PhysicsBackend.SHAPE_SPHERE: _B3_SPHERE,
	PhysicsBackend.SHAPE_CAPSULE: _B3_CAPSULE,
	PhysicsBackend.SHAPE_CYLINDER: _B3_CYLINDER,
	PhysicsBackend.SHAPE_HULL: _B3_HULL,
	PhysicsBackend.SHAPE_MESH: _B3_MESH,
}

var _host: Node3D
var _world: Node3D            # Box3DWorld
var _movers := {}             # int -> Box3DCharacterBody
var _bodies := {}             # int -> Box3DBody
var _pools := {}              # int -> pool record
var _next_id := 1
## Hit events accumulated from the world's contact_hit signal since the last
## poll. The upstream binding emits per hit rather than offering a batched
## accessor, so the batching happens here -- poll_contact_events() stays the
## same shape for callers either way.
var _hits: Array = []


func _alloc_id() -> int:
	var id := _next_id
	_next_id += 1
	return id


#region Lifecycle

func initialize(host: Node3D) -> void:
	assert(ClassDB.class_exists("Box3DWorld"),
		"Box3D GDExtension is not loaded. Build engine/box3d-godot and make sure "
		+ "bin/box3d.gdextension is present with a macos.editor entry.")
	_host = host
	_world = ClassDB.instantiate("Box3DWorld")
	_world.name = "Box3DWorld"
	# We drive the step ourselves so the game controls ordering: movers must
	# run against a settled world, not race it.
	_world.set_auto_step(false)
	# Leave one core for the main thread and rendering.
	_world.set_worker_count(maxi(1, OS.get_processor_count() - 2))
	# Connecting is what switches hit reporting on: the world gates emission on
	# has_connections("contact_hit"), so an unconnected world costs nothing.
	_world.contact_hit.connect(_on_contact_hit)
	host.add_child(_world)


func _on_contact_hit(hit: Dictionary) -> void:
	_hits.append(hit)


func shutdown() -> void:
	if is_instance_valid(_world):
		_world.queue_free()
	_world = null
	_movers.clear()
	_bodies.clear()
	_pools.clear()


func set_gravity(g: Vector3) -> void:
	_world.set_gravity(g)


func step(dt: float) -> void:
	_world.step(dt)

#endregion


#region Movers

func mover_create(radius: float, height: float, mask: int) -> int:
	var m = ClassDB.instantiate("Box3DCharacterBody")
	m.set("radius", radius)
	m.set("height", height)
	m.set("collision_mask", mask)
	_world.add_child(m)
	var id := _alloc_id()
	_movers[id] = m
	return id


func mover_destroy(id: int) -> void:
	var m = _movers.get(id)
	if m != null and is_instance_valid(m):
		m.queue_free()
	_movers.erase(id)


func mover_set_capsule(id: int, radius: float, height: float, _up: Vector3) -> void:
	# The up vector is not stored on the node: it is passed per-move, because a
	# wall-crawler's up changes every frame as it follows the surface.
	var m = _movers[id]
	m.set("radius", radius)
	m.set("height", height)


func mover_move(id: int, position: Vector3, velocity: Vector3, dt: float,
		up: Vector3, ground_dot: float, result: MoveResult) -> void:
	var m = _movers[id]
	m.global_position = position
	# up_direction is set per frame rather than once: an arachnid's up follows
	# the surface normal, so it changes continuously as it walks onto a wall.
	m.set_up_direction(up)
	# ground_dot arrives as a cosine. The node stores RADIANS -- its property
	# hint is radians_as_degrees, so the inspector shows degrees while the
	# setter takes radians, exactly like CharacterBody3D. Passing degrees here
	# silently mangles the classifier rather than erroring: the arachnid's 80
	# became cos(80 rad) = -0.11, so a vertical wall counted as floor,
	# is_on_wall() never fired and it could never attach to climb.
	m.set_floor_max_angle(acos(clampf(ground_dot, -1.0, 1.0)))

	m.move_and_slide(velocity, dt)

	result.reset()
	result.position = m.global_position
	# clip_velocity() rather than deriving from the achieved translation. It
	# discounts planes that only pushed the capsule out of an overlap, so
	# depenetration cannot turn into free speed -- which deriving from the
	# translation would allow.
	result.velocity = m.clip_velocity(velocity)
	result.grounded = m.is_on_floor()
	result.on_ceiling = m.is_on_ceiling()
	# on_wall is classified here rather than taken from is_on_wall(), because
	# upstream derives floor, wall AND ceiling from the single floor_cosine
	# threshold: anything not floor and not ceiling is wall. That is right for a
	# normal character and wrong for surface-relative locomotion.
	#
	# The arachnid needs a wide floor cone (80 degrees) so a wall counts as
	# ground once it has rotated onto it. With one shared threshold, a wall
	# passes into the floor band after only ~10 degrees of tilt, is_on_wall()
	# goes false, and the attach handshake deadlocks half-rotated -- measured
	# stalling at up.y = 0.97. Two independent thresholds fix it: a plane is a
	# wall when it is near-perpendicular to up, regardless of how permissive the
	# floor cone is.

	var fn: Vector3 = m.get_floor_normal()
	result.ground_normal = fn if fn.length_squared() > 1e-6 else up

	var planes: Array = m.get_last_collisions()
	var normals := PackedVector3Array()
	var touched: Array = []
	var best_wall := WALL_COSINE
	for entry in planes:
		var n: Vector3 = entry.get("normal", Vector3.ZERO)
		normals.append(n)
		var body = entry.get("collider")
		if body != null and not touched.has(body):
			touched.append(body)
		# Near-perpendicular to up, in either direction, is a wall. Keep the
		# flattest such plane: that is the face actually being pressed into.
		var d: float = absf(n.dot(up))
		if d <= best_wall:
			best_wall = d
			result.on_wall = true
			result.wall_normal = n
	result.plane_normals = normals
	result.plane_count = normals.size()
	result.touched = touched
	result.touched_count = touched.size()
	# The node does not report the swept-cast fraction, so this is left at 1.0.
	# Nothing in the game reads it; it exists for diagnostics only.
	result.cast_fraction = 1.0


func mover_test_position(id: int, position: Vector3, _up: Vector3) -> bool:
	# Box3DCharacterBody has no free-space overlap test (collide_with_body is
	# per-body), so this is an overlap query instead. That is the more robust
	# primitive anyway: a mover buried deep inside a shape reports no planes at
	# all -- upstream documents that as deliberate -- so a plane-based test
	# answers "clear" for a point well inside solid rock.
	var m = _movers[id]
	var r: float = m.get_radius()
	return _world.overlap_sphere(position, r, m.get_collision_mask()).is_empty()

#endregion


#region Bodies

func _configure_shape(b: Object, shape: Dictionary) -> void:
	var t: int = shape.get("type", PhysicsBackend.SHAPE_BOX)
	b.set("shape_type", _SHAPE_MAP[t])
	match t:
		PhysicsBackend.SHAPE_BOX:
			b.set("box_size", shape.get("size", Vector3.ONE))
		PhysicsBackend.SHAPE_SPHERE:
			b.set("sphere_radius", shape.get("radius", 0.5))
		PhysicsBackend.SHAPE_CAPSULE:
			b.set("capsule_radius", shape.get("radius", 0.5))
			b.set("capsule_height", shape.get("height", 2.0))
		PhysicsBackend.SHAPE_CYLINDER:
			b.set("capsule_radius", shape.get("radius", 0.5))
			b.set("capsule_height", shape.get("height", 2.0))
		PhysicsBackend.SHAPE_HULL, PhysicsBackend.SHAPE_MESH:
			if shape.has("mesh"):
				b.set("collision_mesh", shape["mesh"])
			elif shape.has("points"):
				# Box3DBody hulls from a Mesh's vertices; the Godot backend takes
				# raw points. Accept the raw form here too so callers (uploaded
				# models) describe a hull the same way on both backends. A
				# point-cloud primitive is enough -- only the vertices are read.
				var arrays := []
				arrays.resize(Mesh.ARRAY_MAX)
				arrays[Mesh.ARRAY_VERTEX] = shape["points"]
				var cloud := ArrayMesh.new()
				cloud.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
				b.set("collision_mesh", cloud)
	if shape.has("density"):
		b.set("density", shape["density"])
	if shape.has("friction"):
		b.set("friction", shape["friction"])
	if shape.has("restitution"):
		b.set("restitution", shape["restitution"])


func body_create(shape: Dictionary, xform: Transform3D, type: int,
		layer: int, mask: int) -> int:
	var b = ClassDB.instantiate("Box3DBody")
	b.set("body_type", type)          # our constants match Box3DBody's
	_configure_shape(b, shape)
	b.set("collision_layer", layer)
	b.set("collision_mask", mask)
	# The transform MUST be set before entering the tree. Box3DBody creates its
	# b3 body on _enter_tree from whatever transform it has then; assigning
	# global_transform afterwards moves the Godot node but leaves a static
	# body's physics proxy behind at the origin, so it silently collides
	# somewhere else entirely.
	b.transform = xform
	_world.add_child(b)
	b.teleport(xform)
	var id := _alloc_id()
	_bodies[id] = b
	return id


func body_destroy(id: int) -> void:
	var b = _bodies.get(id)
	if b != null and is_instance_valid(b):
		# Detach first. queue_free() alone is deferred to the end of the frame,
		# so the physics body outlives the call -- and destruction spawns a
		# dynamic chunk at the exact position of the static one it replaces,
		# which then starts life pinned inside an immovable collider and never
		# moves. remove_child() runs _exit_tree now and frees the b3 body with it.
		var parent: Node = b.get_parent()
		if parent != null:
			parent.remove_child(b)
		b.queue_free()
	_bodies.erase(id)


func body_get_transform(id: int) -> Transform3D:
	return (_bodies[id] as Node3D).global_transform


func body_set_transform(id: int, xform: Transform3D) -> void:
	_bodies[id].teleport(xform)


func body_apply_impulse(id: int, impulse: Vector3, point: Vector3) -> void:
	# Off-centre by default: a punch or blast that lands away from the centre
	# of mass has to impart spin, or debris looks weightless.
	_bodies[id].apply_impulse_at_point(impulse, point)


func body_is_sleeping(id: int) -> bool:
	return not _bodies[id].is_awake()


func body_set_velocity(id: int, linear: Vector3, angular: Vector3) -> void:
	var b = _bodies[id]
	b.set_linear_velocity(linear)
	b.set_angular_velocity(angular)

#endregion


#region Bulk pools
##
## NOTE: currently pooled Box3DBody nodes. The interface is already the bulk
## one the destruction system wants, but the *implementation* is not yet the
## data-oriented path -- there is still a Node per chunk. Phase 3 replaces the
## internals with a nodeless C++ SoA pool; nothing above this seam changes,
## which is the point of having the seam.

func pool_create(shape: Dictionary, capacity: int, layer: int, mask: int) -> int:
	var id := _alloc_id()
	_pools[id] = {
		"shape": shape, "capacity": capacity, "layer": layer, "mask": mask,
		"bodies": [], "free": [], "live": [],
		"buffer": PackedFloat32Array(),
	}
	return id


func pool_spawn(pool: int, xform: Transform3D, velocity: Vector3) -> int:
	var p: Dictionary = _pools[pool]
	var slot := -1
	if not (p["free"] as Array).is_empty():
		slot = (p["free"] as Array).pop_back()
	elif (p["bodies"] as Array).size() < p["capacity"]:
		var b = ClassDB.instantiate("Box3DBody")
		b.set("body_type", PhysicsBackend.BODY_DYNAMIC)
		_configure_shape(b, p["shape"])
		b.set("collision_layer", p["layer"])
		b.set("collision_mask", p["mask"])
		b.transform = xform    # before add_child; see body_create()
		_world.add_child(b)
		(p["bodies"] as Array).append(b)
		slot = (p["bodies"] as Array).size() - 1
	else:
		return -1     # caller recycles; never grow mid-frame
	var body = (p["bodies"] as Array)[slot]
	body.teleport(xform)
	body.set_linear_velocity(velocity)
	body.set("sync_node_transform", true)
	body.visible = true
	(p["live"] as Array).append(slot)
	return slot


func pool_despawn(pool: int, slot: int) -> void:
	var p: Dictionary = _pools[pool]
	var body = (p["bodies"] as Array)[slot]
	body.visible = false
	body.set_linear_velocity(Vector3.ZERO)
	body.teleport(Transform3D(Basis(), Vector3(0, -10000, 0)))
	(p["live"] as Array).erase(slot)
	(p["free"] as Array).append(slot)


func pool_transforms(pool: int) -> PackedFloat32Array:
	var p: Dictionary = _pools[pool]
	var live: Array = p["live"]
	var buf: PackedFloat32Array = p["buffer"]
	buf.resize(live.size() * 12)
	var bodies: Array = p["bodies"]
	var o := 0
	for slot in live:
		var t: Transform3D = (bodies[slot] as Node3D).global_transform
		var b := t.basis
		# MultiMesh TRANSFORM_3D is row-major 3x4.
		buf[o + 0] = b.x.x; buf[o + 1] = b.y.x; buf[o + 2] = b.z.x; buf[o + 3] = t.origin.x
		buf[o + 4] = b.x.y; buf[o + 5] = b.y.y; buf[o + 6] = b.z.y; buf[o + 7] = t.origin.y
		buf[o + 8] = b.x.z; buf[o + 9] = b.y.z; buf[o + 10] = b.z.z; buf[o + 11] = t.origin.z
		o += 12
	p["buffer"] = buf
	return buf


func pool_live_count(pool: int) -> int:
	return (_pools[pool]["live"] as Array).size()


func pool_apply_impulse(pool: int, slot: int, impulse: Vector3, point: Vector3) -> void:
	((_pools[pool]["bodies"] as Array)[slot]).apply_impulse_at_point(impulse, point)


func pool_is_sleeping(pool: int, slot: int) -> bool:
	return not ((_pools[pool]["bodies"] as Array)[slot]).is_awake()


func pool_set_transform(pool: int, slot: int, xform: Transform3D) -> void:
	((_pools[pool]["bodies"] as Array)[slot]).teleport(xform)


func pool_set_velocity(pool: int, slot: int, velocity: Vector3) -> void:
	((_pools[pool]["bodies"] as Array)[slot]).set_linear_velocity(velocity)

#endregion


#region Queries

func query_sphere(center: Vector3, radius: float, mask: int) -> Array:
	return _world.overlap_sphere(center, radius, mask)


func cast_ray(from: Vector3, to: Vector3, mask: int) -> Dictionary:
	return _world.raycast(from, to, mask)


func cast_sphere(from: Vector3, to: Vector3, radius: float, mask: int) -> Dictionary:
	return _world.shape_cast_sphere(from, to, radius, mask)


func explode(center: Vector3, radius: float, impulse: float,
		falloff: float, mask: int) -> void:
	# Native in Box3D -- it applies the radial impulse across overlapping
	# shapes internally, which is far cheaper than doing it body-by-body here.
	_world.explode(center, radius, impulse, falloff, mask)

#endregion


#region Events

func poll_contact_events() -> Array:
	var out: Array = []
	out.resize(_hits.size())
	for i in _hits.size():
		var e: Dictionary = _hits[i]
		out[i] = {
			"a": e.get("body_a"),
			"b": e.get("body_b"),
			"position": e.get("point", Vector3.ZERO),
			"normal": e.get("normal", Vector3.ZERO),
			"impulse": e.get("approach_speed", 0.0),
		}
	_hits.clear()
	return out

#endregion
