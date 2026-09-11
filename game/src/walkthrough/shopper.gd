class_name Shopper
extends RefCounted

## A person walking through the room.
##
## A kinematic capsule on PhysicsBackend.mover_move(), the same mover contract
## the brawler's creatures use, cut down to what a showroom needs: walk, bump,
## carry. Bumping is done here rather than left to the solver because a mover
## is not a rigid body -- it stops at furniture but imparts nothing -- so the
## shove is a game-side impulse scaled by how hard the shopper is walking into
## the piece. A side table skids; a bed does not.

const RADIUS := 0.3
const HEIGHT := 1.7
const EYE := 1.55
const SPEED := 2.2
const ACCEL := 14.0
const GRAVITY := 9.8
const GROUND_DOT := 0.6428   # cos 50 degrees
const REACH := 1.4
const CARRY_DISTANCE := 0.9
## How close a carried piece is pulled in when something is in the way.
const CARRY_MIN := 0.25
const CARRY_HEIGHT := 0.6

## Steady push, in newtons, applied while walking into a piece. Mass does the
## rest: at 450 N a 32 kg shoe cabinet skids across the floor (friction 0.8)
## and a 70 kg bed stays put. Tunable live from the scene because the right
## number is a feel question, not an arithmetic one.
var shove_force := 450.0

var backend: PhysicsBackend
var placer: Placer
## Capsule *centre*, which is the mover convention on both backends. Feet are
## HEIGHT / 2 below this.
var position := Vector3(0, HEIGHT * 0.5, 1.5)
var velocity := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
var grounded := false
var carrying: PlacedItem

var _id := -1
var _result := MoveResult.new()


## [param spawn_feet] is where the feet go; the capsule centre is derived.
func setup(p_backend: PhysicsBackend, p_placer: Placer, spawn_feet: Vector3) -> void:
	backend = p_backend
	placer = p_placer
	position = spawn_feet + Vector3.UP * (HEIGHT * 0.5 + 0.05)
	velocity = Vector3.ZERO
	carrying = null
	_id = backend.mover_create(RADIUS, HEIGHT, Layers.SOLID)


func release() -> void:
	if carrying != null:
		placer.drop_carried(carrying)
		carrying = null
	if _id >= 0:
		backend.mover_destroy(_id)
		_id = -1


func forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func right() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


func feet() -> Vector3:
	return position - Vector3.UP * HEIGHT * 0.5


func eye() -> Vector3:
	return feet() + Vector3.UP * EYE


func look_dir() -> Vector3:
	return Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * Vector3.FORWARD


func turn(dx: float, dy: float) -> void:
	yaw -= dx
	pitch = clampf(pitch - dy, -1.2, 1.2)


## [param intent] is the desired horizontal direction, camera-relative, |v| <= 1.
func step(intent: Vector3, dt: float) -> void:
	if _id < 0:
		return
	var wish := (forward() * -intent.z + right() * intent.x)
	if wish.length_squared() > 1.0:
		wish = wish.normalized()
	var target := wish * SPEED
	var horiz := Vector3(velocity.x, 0, velocity.z)
	horiz = horiz.move_toward(target, ACCEL * dt)
	velocity.x = horiz.x
	velocity.z = horiz.z
	velocity.y = (-0.5 if grounded else velocity.y - GRAVITY * dt)

	backend.mover_move(_id, position, velocity, dt, Vector3.UP, GROUND_DOT, _result)
	position = _result.position
	velocity = _result.velocity
	grounded = _result.grounded

	_shove(wish, dt)
	if carrying != null:
		_hold()


## Keep the carried piece in front of the shopper but inside the room and
## out of other furniture: it stops at a wall and slides along it, and is
## pulled in closer when it would pass through something. A piece never
## clips a wall, which is what sells the walkthrough.
func _hold() -> void:
	var quarter := int(round(yaw / (PI * 0.5)))
	carrying.yaw = posmod(quarter, 4)
	var half := carrying.rotated_size().z * 0.5
	var d := CARRY_DISTANCE
	var at := Vector3.ZERO
	while true:
		at = placer.clamp_to_room(carrying, feet() + forward() * (d + half))
		if d <= CARRY_MIN or not placer.blocked_at(carrying, at, CARRY_HEIGHT):
			break
		d -= 0.1
	placer.carry_to(carrying, at, quarter, CARRY_HEIGHT)


## Push any piece the capsule is pressed against, in the direction of travel.
func _shove(wish: Vector3, dt: float) -> void:
	if wish.length_squared() < 1e-4:
		return
	var me := AABB(feet() + Vector3(-RADIUS, 0, -RADIUS), Vector3(RADIUS * 2, HEIGHT, RADIUS * 2))
	me = me.grow(0.06)
	for p in placer.items:
		if p.body < 0 or p == carrying:
			continue
		var box := p.aabb(backend)
		if not me.intersects(box):
			continue
		# Only when actually walking into it, not brushing past.
		var to_item := box.get_center() - position
		to_item.y = 0.0
		if to_item.normalized().dot(wish) < 0.3:
			continue
		var contact := Vector3(box.get_center().x, feet().y + 0.9, box.get_center().z) \
			- to_item.normalized() * box.size.length() * 0.25
		backend.body_apply_impulse(p.body, wish * shove_force * dt, contact)


## Toggle carrying: pick up the nearest piece in front of the shopper, or drop
## the one held.
func interact() -> void:
	if carrying != null:
		placer.drop_carried(carrying)
		carrying = null
		return
	var probe := feet() + forward() * REACH * 0.6 + Vector3.UP * 0.5
	var p := placer.nearest(probe, REACH)
	if p != null and placer.carry(p):
		carrying = p
