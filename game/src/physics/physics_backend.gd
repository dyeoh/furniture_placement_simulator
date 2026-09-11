class_name PhysicsBackend
extends RefCounted

## The one seam between game code and a physics engine.
##
## Nothing in src/placement, src/walkthrough or src/room may call Box3D (or
## Godot physics) directly -- everything goes through this contract. Two
## implementations exist: [Box3DBackend] (primary) and [GodotPhysicsBackend]
## (Jolt fallback).
##
## [b]What this abstraction buys, honestly:[/b] swappability, not identical
## feel. The two backends will not handle the same, because Box3D's mover
## exposes real contact planes and Godot's PhysicsServer3D cannot express that
## concept at all -- the Jolt path reconstructs an approximation from shape
## casts. The point is insurance: Box3D is v0.1.0 and its C API is still
## churning, so the project must survive a breaking upstream change. The
## secondary benefit is being able to A/B game feel between solvers.
##
## Ids returned by this interface are opaque ints. Do not assume they are
## indices, pointers, or stable across a reload.

const BODY_STATIC := 0
const BODY_KINEMATIC := 1
const BODY_DYNAMIC := 2

const SHAPE_BOX := 0
const SHAPE_SPHERE := 1
const SHAPE_CAPSULE := 2
const SHAPE_CYLINDER := 3
const SHAPE_HULL := 4
const SHAPE_MESH := 5


func _unimplemented(method: String) -> void:
	push_error("%s does not implement %s()" % [get_script().resource_path.get_file(), method])


#region Lifecycle

## Called once with the node the backend may parent its internals under.
func initialize(_host: Node3D) -> void:
	_unimplemented("initialize")


func shutdown() -> void:
	_unimplemented("shutdown")


func set_gravity(_g: Vector3) -> void:
	_unimplemented("set_gravity")


## Advance the simulation. May be a no-op when the backend auto-steps.
func step(_dt: float) -> void:
	_unimplemented("step")

#endregion


#region Movers (kinematic characters)

## Create a capsule mover. Movers are NOT rigid bodies -- they live outside the
## solver and are driven entirely by game code, which is what makes them
## responsive enough for a first-person walkthrough.
func mover_create(_radius: float, _height: float, _mask: int) -> int:
	_unimplemented("mover_create")
	return -1


func mover_destroy(_id: int) -> void:
	_unimplemented("mover_destroy")


## Re-orient / resize the capsule. [param up] is the capsule's local axis in
## world space -- arachnid mode rotates it to the surface normal, so this cannot
## be hardcoded to world Y.
func mover_set_capsule(_id: int, _radius: float, _height: float, _up: Vector3) -> void:
	_unimplemented("mover_set_capsule")


## Sweep, depenetrate and clip in one call; fills [param result] in place.
##
## [param up] is the mode's up vector (world up when walking, surface normal
## when wall-crawling, arbitrary when flying). [param ground_dot] is the
## dot(normal, up) threshold above which a plane counts as ground.
func mover_move(_id: int, _position: Vector3, _velocity: Vector3, _dt: float,
		_up: Vector3, _ground_dot: float, _result: MoveResult) -> void:
	_unimplemented("mover_move")


## Is the capsule clear at this position? Overlap test only, no movement.
##
## Burrowing needs this: a mover deliberately inside terrain cannot rely on the
## solver to push it out (see the limitation documented in box3d_mover.h), so it
## must confirm a clear exit before surfacing.
func mover_test_position(_id: int, _position: Vector3, _up: Vector3) -> bool:
	_unimplemented("mover_test_position")
	return true

#endregion


#region Bodies

## [param shape] describes geometry, e.g.
## { type = SHAPE_BOX, size = Vector3(1,1,1) }
## { type = SHAPE_CAPSULE, radius = 0.5, height = 2.0 }
## { type = SHAPE_HULL, points = PackedVector3Array(...) }
func body_create(_shape: Dictionary, _xform: Transform3D, _type: int,
		_layer: int, _mask: int) -> int:
	_unimplemented("body_create")
	return -1


func body_destroy(_id: int) -> void:
	_unimplemented("body_destroy")


func body_get_transform(_id: int) -> Transform3D:
	_unimplemented("body_get_transform")
	return Transform3D()


func body_set_transform(_id: int, _xform: Transform3D) -> void:
	_unimplemented("body_set_transform")


func body_apply_impulse(_id: int, _impulse: Vector3, _point: Vector3) -> void:
	_unimplemented("body_apply_impulse")


func body_is_sleeping(_id: int) -> bool:
	_unimplemented("body_is_sleeping")
	return false


## Overwrite a body's motion. A carried item is driven with body_set_transform()
## every frame; without zeroing its velocity on release it would keep whatever
## the solver accumulated while being teleported and fly off when dropped.
func body_set_velocity(_id: int, _linear: Vector3, _angular: Vector3) -> void:
	_unimplemented("body_set_velocity")

#endregion


#region Bulk pools -- the data-oriented path
##
## Debris is the only system here with an N large enough to justify SoA. A pool
## owns many bodies sharing one shape, keeps their transforms contiguous, and
## hands them out as a single buffer that goes straight into a MultiMesh. No
## Node, no per-chunk script, one draw call.

func pool_create(_shape: Dictionary, _capacity: int, _layer: int, _mask: int) -> int:
	_unimplemented("pool_create")
	return -1


## Returns a slot index within the pool, or -1 when the pool is full. Callers
## are expected to handle -1 by recycling, never by growing mid-frame.
func pool_spawn(_pool: int, _xform: Transform3D, _velocity: Vector3) -> int:
	_unimplemented("pool_spawn")
	return -1


func pool_despawn(_pool: int, _slot: int) -> void:
	_unimplemented("pool_despawn")


## 12 floats per live instance, in Godot's MultiMesh TRANSFORM_3D layout, ready
## for multimesh_set_buffer() with no per-instance scripting.
func pool_transforms(_pool: int) -> PackedFloat32Array:
	_unimplemented("pool_transforms")
	return PackedFloat32Array()


func pool_live_count(_pool: int) -> int:
	_unimplemented("pool_live_count")
	return 0


## Off-centre impulse on one pooled body. Destruction depends on this being
## positional rather than central: debris that gains no spin reads as weightless.
func pool_apply_impulse(_pool: int, _slot: int, _impulse: Vector3, _point: Vector3) -> void:
	_unimplemented("pool_apply_impulse")


## Has this chunk come to rest? Used to pick recycling victims -- removing
## settled rubble is far less visible than removing something still tumbling.
func pool_is_sleeping(_pool: int, _slot: int) -> bool:
	_unimplemented("pool_is_sleeping")
	return false


## Drive a pooled body to a transform. Used to carry a grabbed chunk, which is
## done kinematically rather than with a joint so the debris follows the
## creature instead of dragging it around.
func pool_set_transform(_pool: int, _slot: int, _xform: Transform3D) -> void:
	_unimplemented("pool_set_transform")


func pool_set_velocity(_pool: int, _slot: int, _velocity: Vector3) -> void:
	_unimplemented("pool_set_velocity")

#endregion


#region Queries

func query_sphere(_center: Vector3, _radius: float, _mask: int) -> Array:
	_unimplemented("query_sphere")
	return []


## { hit: bool, position: Vector3, normal: Vector3, fraction: float, body: int }
func cast_ray(_from: Vector3, _to: Vector3, _mask: int) -> Dictionary:
	_unimplemented("cast_ray")
	return {}


func cast_sphere(_from: Vector3, _to: Vector3, _radius: float, _mask: int) -> Dictionary:
	_unimplemented("cast_sphere")
	return {}


## Radial impulse. Box3D implements this natively; the Jolt path emulates it.
func explode(_center: Vector3, _radius: float, _impulse: float,
		_falloff: float, _mask: int) -> void:
	_unimplemented("explode")

#endregion


#region Events

## Contacts since the last poll. Each entry:
## { a: int, b: int, position: Vector3, normal: Vector3, impulse: float }
## Impulse is what destruction uses to decide whether a chunk breaks loose.
func poll_contact_events() -> Array:
	_unimplemented("poll_contact_events")
	return []

#endregion
