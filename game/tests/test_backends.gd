extends SceneTree

## Drive the same scenario through both PhysicsBackend implementations and
## confirm the contract the simulator relies on holds: bodies settle, movers
## stand on floors and stop at walls, velocities can be overwritten.
##
## It does NOT assert the backends agree numerically -- they will not.

var _fails: Array[String] = []


func _init() -> void:
	run.call_deferred()


func check(label: String, cond: bool, detail: String = "") -> void:
	print("  [%s] %s%s" % ["OK  " if cond else "FAIL", label, ("   " + detail) if detail != "" else ""])
	if not cond:
		_fails.append(label)


func run() -> void:
	await process_frame
	var host := Node3D.new()
	get_root().add_child(host)
	await process_frame

	for which in [PhysicsFactory.Backend.BOX3D, PhysicsFactory.Backend.GODOT]:
		var backend := PhysicsFactory.create(which)
		var name := PhysicsFactory.backend_name(backend)
		print("\n=== backend: %s ===" % name)
		if which == PhysicsFactory.Backend.BOX3D:
			check("Box3D extension loaded", backend is Box3DBackend)

		var stage := Node3D.new()
		host.add_child(stage)
		await process_frame
		backend.initialize(stage)
		backend.set_gravity(Vector3(0, -9.8, 0))
		await process_frame

		var room := RoomBuilder.new()
		room.width = 6.0
		room.depth = 5.0
		room.build(backend)
		check("room built 5 bodies", room.body_ids.size() == 5)
		for i in 4:
			backend.step(1.0 / 60.0)
			await process_frame

		# --- 1. a dropped box lands on the floor and falls asleep
		var size := Vector3(0.9, 0.35, 0.35)
		var bid := backend.body_create(
			{"type": PhysicsBackend.SHAPE_BOX, "size": size, "density": 60.0, "friction": 0.8},
			Transform3D(Basis(), Vector3(0, 0.5, 0)), PhysicsBackend.BODY_DYNAMIC,
			Layers.FURNITURE, Layers.ALL)
		var asleep_at := -1
		for i in 300:
			backend.step(1.0 / 60.0)
			await process_frame
			if i > 15 and backend.body_is_sleeping(bid):
				asleep_at = i
				break
		var rest := backend.body_get_transform(bid).origin
		check("box rests on floor", absf(rest.y - size.y * 0.5) < 0.03, "y=%.3f" % rest.y)
		check("box falls asleep", asleep_at > 0, "after %d steps" % asleep_at)

		# --- 2. velocity overwrite: a sleeping box told to move, moves
		backend.body_set_velocity(bid, Vector3(2, 0, 0), Vector3.ZERO)
		var before := rest
		for i in 20:
			backend.step(1.0 / 60.0)
			await process_frame
		var after := backend.body_get_transform(bid).origin
		check("body_set_velocity moves it", after.x - before.x > 0.1, "dx=%.3f" % (after.x - before.x))

		# --- 3. mover stands on the floor
		# Mover origin is the capsule centre on both backends.
		var mid := backend.mover_create(0.3, 1.7, Layers.SOLID)
		await process_frame
		var res := MoveResult.new()
		var pos := Vector3(-2, 1.2, 0)
		var vel := Vector3.ZERO
		var grounded_frames := 0
		for i in 90:
			# Same contract Shopper uses: keep a small downward press while
			# grounded so the capsule stays in contact instead of hovering.
			vel.y = -0.5 if res.grounded else vel.y - 9.8 / 60.0
			backend.mover_move(mid, pos, vel, 1.0 / 60.0, Vector3.UP, 0.64, res)
			pos = res.position
			vel = res.velocity
			if i >= 60 and res.grounded:
				grounded_frames += 1
			backend.step(1.0 / 60.0)
			await process_frame
		check("mover grounded", grounded_frames >= 25, "y=%.3f grounded %d/30" % [pos.y, grounded_frames])
		# Jolt's mover sinks ~0.55 m (documented approximation); Box3D should sit
		# at half height. Both must at least stay above the slab.
		check("mover stands on floor", pos.y > 0.2 and pos.y < 0.95, "y=%.3f" % pos.y)

		# --- 4. mover stops at the wall
		for i in 120:
			backend.mover_move(mid, pos, Vector3(-4, -0.5, 0), 1.0 / 60.0, Vector3.UP, 0.64, res)
			pos = res.position
			backend.step(1.0 / 60.0)
			await process_frame
		check("wall stops mover", pos.x > -3.0 - 0.3 - 0.2, "x=%.3f" % pos.x)

		# --- 5. wall is a wall
		check("wall reported", res.on_wall or res.plane_count > 0)

		backend.mover_destroy(mid)
		backend.body_destroy(bid)
		backend.shutdown()
		stage.queue_free()
		await process_frame

	print("")
	if _fails.is_empty():
		print("ALL PASSED")
		quit(0)
	else:
		print("FAILED: %s" % ", ".join(_fails))
		quit(1)
