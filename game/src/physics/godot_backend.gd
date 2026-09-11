class_name GodotPhysicsBackend
extends PhysicsBackend

## PhysicsBackend implemented on Godot's built-in PhysicsServer3D (Jolt).
##
## This is the fallback, and it exists for one reason: Box3D is v0.1.0 and its
## C API is still moving, so the project must be able to keep running if an
## upstream change breaks the extension. It is also useful for A/B-ing feel.
##
## [b]It does not behave identically to Box3DBackend, and cannot.[/b] Box3D's
## mover hands back the real contact planes from a plane solve; here the mover
## is a kinematic body driven through PhysicsServer3D.body_test_motion() --
## the same primitive CharacterBody3D is built on -- in a move-and-slide loop.
## Expect these differences:
##
##   * Contact normals come from the motion test's collisions, so there are
##     only as many as the slide loop encountered, not every touching plane.
##   * Recovery (depenetration) is the server's, with its own margins; a
##     capsule can rest a few millimetres higher or lower than on Box3D.
##   * There is no equivalent of b3ClipVector, so velocity clipping is done by
##     projection here.
##
## Treat it as "the game still runs", not "the game plays the same".

## Slide iterations per move. Four is what CharacterBody3D defaults to.
const MAX_SLIDES := 4
## How far below the capsule the ground probe looks; see mover_move().
const GROUND_PROBE := 0.06

var _host: Node3D
var _space: RID
var _movers := {}
var _bodies := {}
var _pools := {}
var _next_id := 1
var _gravity := Vector3(0, -9.8, 0)


func _alloc_id() -> int:
	var id := _next_id
	_next_id += 1
	return id


#region Lifecycle

func initialize(host: Node3D) -> void:
	_host = host
	_space = host.get_world_3d().space


func shutdown() -> void:
	for id in _bodies:
		# Free the shape too -- a body's shapes are separate RIDs and leak
		# loudly at exit otherwise.
		PhysicsServer3D.free_rid(_bodies[id]["rid"])
		PhysicsServer3D.free_rid(_bodies[id]["shape"])
	for id in _movers:
		PhysicsServer3D.free_rid(_movers[id]["body"])
		PhysicsServer3D.free_rid(_movers[id]["shape"])
	_bodies.clear()
	_movers.clear()
	_pools.clear()


func set_gravity(g: Vector3) -> void:
	# PhysicsServer3D.area_set_param() needs an *area* RID, and a space RID is
	# not one -- there is no public accessor for a space's default area, so the
	# Box3D path's direct b3World_SetGravity has no exact counterpart here.
	#
	# In practice this matters less than it looks: movers carry their own
	# gravity in their LocomotionProfile and never read the world's, so this
	# only governs loose rigid debris. Those pick it up from the project
	# setting when their space is built.
	_gravity = g
	ProjectSettings.set_setting("physics/3d/default_gravity", g.length())
	ProjectSettings.set_setting("physics/3d/default_gravity_vector", g.normalized())


func step(_dt: float) -> void:
	pass  # Godot steps its own space during _physics_process.

#endregion


#region Movers

func mover_create(radius: float, height: float, mask: int) -> int:
	var shape := PhysicsServer3D.capsule_shape_create()
	PhysicsServer3D.shape_set_data(shape, {"radius": radius, "height": height})
	# A kinematic body on layer 0: it collides with whatever `mask` names but
	# nothing collides with it, so the solver never tries to push rigid bodies
	# out of the shopper -- shoves are the game's decision, not the solver's.
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_KINEMATIC)
	PhysicsServer3D.body_set_space(body, _space)
	PhysicsServer3D.body_add_shape(body, shape)
	PhysicsServer3D.body_set_collision_layer(body, 0)
	PhysicsServer3D.body_set_collision_mask(body, mask)
	var id := _alloc_id()
	_movers[id] = {"shape": shape, "body": body, "radius": radius, "height": height, "mask": mask}
	return id


func mover_destroy(id: int) -> void:
	if _movers.has(id):
		PhysicsServer3D.free_rid(_movers[id]["body"])
		PhysicsServer3D.free_rid(_movers[id]["shape"])
		_movers.erase(id)


func mover_set_capsule(id: int, radius: float, height: float, _up: Vector3) -> void:
	var m: Dictionary = _movers[id]
	m["radius"] = radius
	m["height"] = height
	PhysicsServer3D.shape_set_data(m["shape"], {"radius": radius, "height": height})


func _capsule_basis(up: Vector3) -> Basis:
	# Godot capsules are Y-aligned; rotate so local Y lands on `up`.
	var u := up.normalized()
	if u.is_equal_approx(Vector3.UP):
		return Basis()
	if u.is_equal_approx(Vector3.DOWN):
		return Basis(Vector3.RIGHT, PI)
	var axis := Vector3.UP.cross(u).normalized()
	return Basis(axis, Vector3.UP.angle_to(u))


func mover_move(id: int, position: Vector3, velocity: Vector3, dt: float,
		up: Vector3, ground_dot: float, result: MoveResult) -> void:
	var m: Dictionary = _movers[id]
	var body: RID = m["body"]
	var basis := _capsule_basis(up)

	var params := PhysicsTestMotionParameters3D.new()
	params.max_collisions = 4
	# Report the recovery push as a collision too, or a capsule resting on the
	# floor (no motion into it) would come back with no planes at all.
	params.recovery_as_collision = true
	var tm := PhysicsTestMotionResult3D.new()

	result.reset()
	var pos := position
	var v := velocity
	var remaining := velocity * dt
	var normals := PackedVector3Array()
	var touched: Array = []

	# --- Move and slide.
	for _slide in MAX_SLIDES:
		params.from = Transform3D(basis, pos)
		params.motion = remaining
		var hit := PhysicsServer3D.body_test_motion(body, params, tm)
		pos += tm.get_travel()
		if not hit:
			break
		remaining = tm.get_remainder()
		for i in tm.get_collision_count():
			var n := tm.get_collision_normal(i)
			normals.append(n)
			var c := tm.get_collider(i)
			if c != null and not touched.has(c):
				touched.append(c)
			if v.dot(n) < 0.0:
				v -= n * v.dot(n)
			if remaining.dot(n) < 0.0:
				remaining -= n * remaining.dot(n)
		if remaining.length_squared() < 1e-12:
			break

	# --- Ground probe. The slide loop only reports planes it moved into, so a
	# capsule standing still on a flat floor would otherwise report nothing.
	params.from = Transform3D(basis, pos)
	params.motion = -up * GROUND_PROBE
	if PhysicsServer3D.body_test_motion(body, params, tm):
		for i in tm.get_collision_count():
			var n := tm.get_collision_normal(i)
			if n.dot(up) >= ground_dot:
				normals.append(n)
				var c := tm.get_collider(i)
				if c != null and not touched.has(c):
					touched.append(c)
				# Settle onto it, the way CharacterBody3D's floor snap does.
				pos += tm.get_travel()
				break

	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM,
		Transform3D(basis, pos))

	result.plane_normals = normals
	result.plane_count = normals.size()
	result.touched = touched
	result.touched_count = touched.size()
	result.velocity = v
	result.position = pos
	result.cast_fraction = 1.0

	# --- Classify, same rules as the Box3D path.
	var wall_cos := cos(deg_to_rad(70.0))
	var best_ground := -INF
	var best_wall := INF
	for n in normals:
		var d := n.dot(up)
		if d >= ground_dot:
			result.grounded = true
			if d > best_ground:
				best_ground = d
				result.ground_normal = n
		elif d <= -ground_dot:
			result.on_ceiling = true
		if absf(d) <= wall_cos:
			result.on_wall = true
			if absf(d) < best_wall:
				best_wall = absf(d)
				result.wall_normal = n


func mover_test_position(id: int, position: Vector3, up: Vector3) -> bool:
	var m: Dictionary = _movers[id]
	var state := _host.get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape_rid = m["shape"]
	params.collision_mask = m["mask"]
	params.transform = Transform3D(_capsule_basis(up), position)
	return state.collide_shape(params, 1).is_empty()

#endregion


#region Bodies

func _make_shape(shape: Dictionary) -> RID:
	match int(shape.get("type", PhysicsBackend.SHAPE_BOX)):
		PhysicsBackend.SHAPE_SPHERE:
			var s := PhysicsServer3D.sphere_shape_create()
			PhysicsServer3D.shape_set_data(s, shape.get("radius", 0.5))
			return s
		PhysicsBackend.SHAPE_CAPSULE:
			var s := PhysicsServer3D.capsule_shape_create()
			PhysicsServer3D.shape_set_data(s, {
				"radius": shape.get("radius", 0.5),
				"height": shape.get("height", 2.0)})
			return s
		PhysicsBackend.SHAPE_CYLINDER:
			var s := PhysicsServer3D.cylinder_shape_create()
			PhysicsServer3D.shape_set_data(s, {
				"radius": shape.get("radius", 0.5),
				"height": shape.get("height", 2.0)})
			return s
		PhysicsBackend.SHAPE_HULL:
			var s := PhysicsServer3D.convex_polygon_shape_create()
			PhysicsServer3D.shape_set_data(s, shape.get("points", PackedVector3Array()))
			return s
		_:
			var s := PhysicsServer3D.box_shape_create()
			PhysicsServer3D.shape_set_data(s, shape.get("size", Vector3.ONE) * 0.5)
			return s


func body_create(shape: Dictionary, xform: Transform3D, type: int,
		layer: int, mask: int) -> int:
	var rid := PhysicsServer3D.body_create()
	var mode := PhysicsServer3D.BODY_MODE_RIGID
	if type == PhysicsBackend.BODY_STATIC:
		mode = PhysicsServer3D.BODY_MODE_STATIC
	elif type == PhysicsBackend.BODY_KINEMATIC:
		mode = PhysicsServer3D.BODY_MODE_KINEMATIC
	PhysicsServer3D.body_set_mode(rid, mode)
	PhysicsServer3D.body_set_space(rid, _space)
	var srid := _make_shape(shape)
	PhysicsServer3D.body_add_shape(rid, srid)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	PhysicsServer3D.body_set_collision_layer(rid, layer)
	PhysicsServer3D.body_set_collision_mask(rid, mask)
	var id := _alloc_id()
	_bodies[id] = {"rid": rid, "shape": srid}
	return id


func body_destroy(id: int) -> void:
	if _bodies.has(id):
		PhysicsServer3D.free_rid(_bodies[id]["rid"])
		PhysicsServer3D.free_rid(_bodies[id]["shape"])
		_bodies.erase(id)


func body_get_transform(id: int) -> Transform3D:
	return PhysicsServer3D.body_get_state(_bodies[id]["rid"], PhysicsServer3D.BODY_STATE_TRANSFORM)


func body_set_transform(id: int, xform: Transform3D) -> void:
	PhysicsServer3D.body_set_state(_bodies[id]["rid"], PhysicsServer3D.BODY_STATE_TRANSFORM, xform)


func body_apply_impulse(id: int, impulse: Vector3, point: Vector3) -> void:
	var rid: RID = _bodies[id]["rid"]
	var t: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
	PhysicsServer3D.body_apply_impulse(rid, impulse, point - t.origin)


func body_is_sleeping(id: int) -> bool:
	# PhysicsServer3D has no body_is_sleeping(); sleep is a body *state*.
	return bool(PhysicsServer3D.body_get_state(_bodies[id]["rid"],
		PhysicsServer3D.BODY_STATE_SLEEPING))


func body_set_velocity(id: int, linear: Vector3, angular: Vector3) -> void:
	var rid: RID = _bodies[id]["rid"]
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, linear)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, angular)

#endregion


#region Bulk pools

func pool_create(shape: Dictionary, capacity: int, layer: int, mask: int) -> int:
	var id := _alloc_id()
	_pools[id] = {
		"shape": shape, "capacity": capacity, "layer": layer, "mask": mask,
		"ids": [], "free": [], "live": [], "buffer": PackedFloat32Array(),
	}
	return id


func pool_spawn(pool: int, xform: Transform3D, velocity: Vector3) -> int:
	var p: Dictionary = _pools[pool]
	var slot := -1
	if not (p["free"] as Array).is_empty():
		slot = (p["free"] as Array).pop_back()
	elif (p["ids"] as Array).size() < p["capacity"]:
		var bid := body_create(p["shape"], xform, PhysicsBackend.BODY_DYNAMIC, p["layer"], p["mask"])
		(p["ids"] as Array).append(bid)
		slot = (p["ids"] as Array).size() - 1
	else:
		return -1
	var body_id: int = (p["ids"] as Array)[slot]
	body_set_transform(body_id, xform)
	PhysicsServer3D.body_set_state(_bodies[body_id]["rid"],
		PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, velocity)
	(p["live"] as Array).append(slot)
	return slot


func pool_despawn(pool: int, slot: int) -> void:
	var p: Dictionary = _pools[pool]
	var body_id: int = (p["ids"] as Array)[slot]
	body_set_transform(body_id, Transform3D(Basis(), Vector3(0, -10000, 0)))
	(p["live"] as Array).erase(slot)
	(p["free"] as Array).append(slot)


func pool_transforms(pool: int) -> PackedFloat32Array:
	var p: Dictionary = _pools[pool]
	var live: Array = p["live"]
	var buf: PackedFloat32Array = p["buffer"]
	buf.resize(live.size() * 12)
	var ids: Array = p["ids"]
	var o := 0
	for slot in live:
		var t := body_get_transform(ids[slot])
		var b := t.basis
		buf[o + 0] = b.x.x; buf[o + 1] = b.y.x; buf[o + 2] = b.z.x; buf[o + 3] = t.origin.x
		buf[o + 4] = b.x.y; buf[o + 5] = b.y.y; buf[o + 6] = b.z.y; buf[o + 7] = t.origin.y
		buf[o + 8] = b.x.z; buf[o + 9] = b.y.z; buf[o + 10] = b.z.z; buf[o + 11] = t.origin.z
		o += 12
	p["buffer"] = buf
	return buf


func pool_live_count(pool: int) -> int:
	return (_pools[pool]["live"] as Array).size()


func pool_apply_impulse(pool: int, slot: int, impulse: Vector3, point: Vector3) -> void:
	body_apply_impulse((_pools[pool]["ids"] as Array)[slot], impulse, point)


func pool_is_sleeping(pool: int, slot: int) -> bool:
	return body_is_sleeping((_pools[pool]["ids"] as Array)[slot])


func pool_set_transform(pool: int, slot: int, xform: Transform3D) -> void:
	body_set_transform((_pools[pool]["ids"] as Array)[slot], xform)


func pool_set_velocity(pool: int, slot: int, velocity: Vector3) -> void:
	var bid: int = (_pools[pool]["ids"] as Array)[slot]
	PhysicsServer3D.body_set_state(_bodies[bid]["rid"],
		PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, velocity)

#endregion


#region Queries

func query_sphere(center: Vector3, radius: float, mask: int) -> Array:
	var state := _host.get_world_3d().direct_space_state
	var sphere := PhysicsServer3D.sphere_shape_create()
	PhysicsServer3D.shape_set_data(sphere, radius)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape_rid = sphere
	params.transform = Transform3D(Basis(), center)
	params.collision_mask = mask
	var hits := state.intersect_shape(params, 64)
	PhysicsServer3D.free_rid(sphere)
	var out: Array = []
	for h in hits:
		out.append(h.get("collider"))
	return out


func cast_ray(from: Vector3, to: Vector3, mask: int) -> Dictionary:
	var state := _host.get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = mask
	var hit := state.intersect_ray(params)
	if hit.is_empty():
		return {"hit": false}
	return {
		"hit": true,
		"position": hit["position"],
		"normal": hit["normal"],
		"fraction": (hit["position"] - from).length() / maxf(0.0001, (to - from).length()),
		"collider": hit.get("collider"),
	}


func cast_sphere(from: Vector3, to: Vector3, radius: float, mask: int) -> Dictionary:
	var state := _host.get_world_3d().direct_space_state
	var sphere := PhysicsServer3D.sphere_shape_create()
	PhysicsServer3D.shape_set_data(sphere, radius)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape_rid = sphere
	params.transform = Transform3D(Basis(), from)
	params.motion = to - from
	params.collision_mask = mask
	var cast: PackedFloat32Array = state.cast_motion(params)
	PhysicsServer3D.free_rid(sphere)
	if cast.size() != 2 or cast[0] >= 1.0:
		return {"hit": false}
	return {"hit": true, "fraction": cast[0], "position": from + (to - from) * cast[0]}


func explode(center: Vector3, radius: float, impulse: float,
		falloff: float, mask: int) -> void:
	# Emulated. Box3D does this natively across overlapping shapes; here we
	# have to walk the overlap set ourselves, which is measurably slower for
	# the large blast radii a monster brawler throws around.
	var hit_ids := _sphere_body_ids(center, radius, mask)
	for entry in hit_ids:
		var rid: RID = entry["rid"]
		var t: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		var d := t.origin - center
		var dist := maxf(0.001, d.length())
		var atten := 1.0 - clampf(dist / maxf(0.001, radius), 0.0, 1.0) * falloff
		PhysicsServer3D.body_apply_impulse(rid, d.normalized() * impulse * atten, Vector3.ZERO)


func _sphere_body_ids(center: Vector3, radius: float, mask: int) -> Array:
	var out: Array = []
	for id in _bodies:
		var rid: RID = _bodies[id]["rid"]
		var t: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
		if t.origin.distance_to(center) <= radius:
			out.append({"id": id, "rid": rid})
	return out

#endregion


#region Events

func poll_contact_events() -> Array:
	# Godot does not expose a batched hit-event stream comparable to Box3D's.
	# Contact monitoring is per-body and signal-driven, so destruction damage
	# on this backend has to be fed from body signals instead. Returning empty
	# rather than faking it keeps the difference visible.
	return []

#endregion
