extends SceneTree

## Placement logic end to end, on the primary backend: snapping, validation,
## settle-to-sleep, carry/drop, layout round-trip, and model import.

var _fails: Array[String] = []


func _init() -> void:
	run.call_deferred()


func check(label: String, cond: bool, detail: String = "") -> void:
	print("  [%s] %s%s" % ["OK  " if cond else "FAIL", label, ("   " + detail) if detail != "" else ""])
	if not cond:
		_fails.append(label)


func settle(backend: PhysicsBackend, placer: Placer, frames := 300) -> int:
	for i in frames:
		backend.step(1.0 / 60.0)
		placer.update(1.0 / 60.0)
		await process_frame
		if not placer.any_settling():
			return i
	return -1


func run() -> void:
	await process_frame
	var host := Node3D.new()
	get_root().add_child(host)
	await process_frame

	for which in [PhysicsFactory.Backend.BOX3D, PhysicsFactory.Backend.GODOT]:
		var backend := PhysicsFactory.create(which)
		print("\n=== backend: %s ===" % PhysicsFactory.backend_name(backend))
		var stage := Node3D.new()
		host.add_child(stage)
		await process_frame
		backend.initialize(stage)
		backend.set_gravity(Vector3(0, -9.8, 0))
		await process_frame

		var catalog := Catalog.new()
		catalog.load_default()
		check("catalogue loaded", catalog.items.size() >= 10, "%d items" % catalog.items.size())
		var shelf := catalog.find("segu-shelf")
		check("mm -> m conversion (W,H,D)", shelf != null and shelf.size.is_equal_approx(Vector3(1.35, 2.1, 0.3)),
			str(shelf.size) if shelf else "missing")
		check("variant per finish", shelf.variant_for("blackwood") == 47737160925425
			and shelf.variant_for("american_oak") == 47737160859889)
		check("unknown finish falls back to default variant", shelf.variant_for("velvet") == shelf.variant_id)
		var single := FurnitureItem.from_dict({"id": "one", "variant_id": 7, "finish": "sage"}, catalog.finishes)
		check("single-variant item offers every finish", single.finish_choices(catalog.finishes).size() == 5
			and single.variant_for("blackwood") == 7)
		var partial := FurnitureItem.from_dict({"id": "two", "finish": "japanese_black",
			"variants": {"eucalyptus": 11, "blackwood": 12}}, catalog.finishes)
		check("default finish must be purchasable", partial.finish == "eucalyptus", partial.finish)
		check("picker limited to sold finishes", partial.finish_choices(catalog.finishes) == ["eucalyptus", "blackwood"])
		# Every product gets a model or generated shape; the lamp fixture is a light.
		var unresolved := []
		for it in catalog.items:
			if it.model == "" and it.shape_kind == "":
				unresolved.append(it.id)
		check("every item has a model or shape", unresolved.is_empty(), str(unresolved))
		check("model inferred from a store title", FurnitureItem.from_dict({"id": "x", "name": "Strata Buffet"}, catalog.finishes).model == "modern_wooden_cabinet")
		check("bed inferred, not bedside", FurnitureItem.from_dict({"id": "y", "name": "Naka Bed"}, catalog.finishes).shape_kind == "bed"
			and FurnitureItem.from_dict({"id": "z", "name": "Lutra Bedside Table"}, catalog.finishes).shape_kind == "")
		var lamp := catalog.find("floor-lamp")
		check("floor lamp fixture present", lamp != null and lamp.is_light() and lamp.variant_id == 0)

		var room := RoomBuilder.new()
		room.width = 6.0
		room.depth = 5.0
		room.build(backend)
		room.build_visuals(stage)
		var placer := Placer.new()
		placer.setup(backend, room, catalog, stage)

		# --- grid snap
		placer.snap_mode = Placer.Snap.GRID
		var table := placer.begin(catalog.find("se-side-table"))
		placer.drag_to(Vector3(0.61, 0, -0.36))
		check("grid snap", table.position.is_equal_approx(Vector3(0.5, 0, -0.25)), str(table.position))
		check("valid inside room", table.valid)

		# --- clamped to the room, never outside
		placer.drag_to(Vector3(40, 0, 40))
		check("clamped inside", room.contains_aabb(table.aabb(null)), str(table.position))
		placer.drag_to(Vector3(0.5, 0, -0.25))
		check("drop accepted", placer.drop())
		check("body created", table.body >= 0 and table.state == PlacedItem.State.SETTLING)
		# The visual is a fitted model, the collider is still the catalogue box.
		var model_node := table.node.get_node_or_null("Model_side_table_01")
		check("model visual fitted", model_node != null)
		check("aabb is the catalogue box", table.aabb(backend).size.is_equal_approx(table.item.size), str(table.aabb(backend).size))

		# --- overlap is refused
		var second := placer.begin(catalog.find("se-side-table"))
		placer.drag_to(Vector3(0.5, 0, -0.25))
		check("overlap invalid", not second.valid)
		check("overlap drop refused", not placer.drop())
		placer.drag_to(Vector3(-1.5, 0, 1.0))
		check("moved away is valid", second.valid)
		check("second drop accepted", placer.drop())

		# --- wall magnet: a shelf near the north wall turns to face the room
		placer.snap_mode = Placer.Snap.WALL
		var s := placer.begin(shelf)
		placer.drag_to(Vector3(1.0, 0, -2.3))
		check("wall magnet flush to north", is_equal_approx(s.position.z, -2.5 + 0.15) and s.yaw == 0,
			"z=%.3f yaw=%d" % [s.position.z, s.yaw])
		placer.drag_to(Vector3(2.8, 0, 0.5))
		check("wall magnet flush to east", is_equal_approx(s.position.x, 3.0 - 0.15) and s.yaw == 3,
			"x=%.3f yaw=%d" % [s.position.x, s.yaw])
		check("rotated footprint", s.rotated_size().is_equal_approx(Vector3(0.3, 2.1, 1.35)))
		check("shelf drop accepted", placer.drop())

		# --- everything settles and sleeps
		var settled_at := await settle(backend, placer)
		check("all items settle", settled_at >= 0, "after %d frames" % settled_at)
		var all_placed := true
		var all_valid := true
		for p in placer.items:
			all_placed = all_placed and p.state == PlacedItem.State.PLACED
			all_valid = all_valid and p.valid
			var y := backend.body_get_transform(p.body).origin.y
			if absf(y - p.item.size.y * 0.5) > 0.03:
				check("rests on floor: " + p.item.name, false, "y=%.3f" % y)
		check("all PLACED", all_placed)
		check("all valid after settle", all_valid)

		# --- rotate while dragging, lift/re-drop keeps identity
		placer.snap_mode = Placer.Snap.FREE
		placer.lift(table)
		check("lift destroys body", table.body < 0 and placer.dragging == table)
		placer.rotate()
		check("rotate", table.yaw == 1)
		placer.drag_to(Vector3(1.8, 0, 1.5))
		check("re-drop", placer.drop())
		await settle(backend, placer)

		# --- cart: the finish decides the variant
		placer.set_finish(table, "blackwood")
		var lines := placer.cart_lines()
		var by_vid := {}
		for l in lines:
			by_vid[l["variant_id"]] = l["quantity"]
		check("cart lines split by finish", by_vid.get(48060316516593, 0) == 1
			and by_vid.get(48060316483825, 0) == 1 and by_vid.get(47737160859889, 0) == 1, str(lines))

		# --- a lamp: placed like furniture, dimmable, never for sale
		var lamp_p := placer.begin(catalog.find("floor-lamp"))
		placer.drag_to(Vector3(2.0, 0, -1.5))
		lamp_p.set_light(false, 0.25, 0.9)
		check("lamp drop", placer.drop())
		check("lamp has a light node", lamp_p.node.get_child_count() > 0 and lamp_p.node.find_children("*", "OmniLight3D", true, false).size() == 1)
		check("lamp not in cart", placer.cart_lines().size() == 3)
		await settle(backend, placer)

		# --- layout round-trip, lighting included
		room.paint("north", Color("#b3624a"))
		var lighting := Lighting.new()
		lighting.setup(stage, room.wall_height)
		lighting.set_sun("azimuth", 123.0)
		lighting.set_ceiling("on", true)
		var data := Layout.capture(placer, room, lighting)
		check("capture has 4 items", data["items"].size() == 4)
		check("capture has paint", data["paint"]["north"] == "#b3624a")
		check("capture has lighting", data["lighting"]["sun"]["azimuth"] == 123.0 and data["lighting"]["ceiling"]["on"] == true)
		var json := Layout.to_json(data)
		placer.clear()
		room.paint("north", Color.WHITE)
		lighting.set_sun("azimuth", 0.0)
		lighting.set_ceiling("on", false)
		check("clear", placer.items.is_empty())
		Layout.restore(Layout.from_json(json), placer, room, lighting)
		check("restore count", placer.items.size() == 4)
		check("restore paint", room.paint_color("north").is_equal_approx(Color("#b3624a")))
		check("restore lighting", lighting.settings["sun"]["azimuth"] == 123.0 and lighting.settings["ceiling"]["on"] == true
			and lighting.ceiling_light.visible)
		var restored_lamp: PlacedItem = null
		for p in placer.items:
			if p.item.is_light():
				restored_lamp = p
		check("restore lamp state", restored_lamp != null and restored_lamp.light["on"] == false
			and is_equal_approx(float(restored_lamp.light["energy"]), 0.25), str(restored_lamp.light if restored_lamp else null))
		var restored_ok := true
		for p in placer.items:
			var orig = null
			for d in data["items"]:
				if d["id"] == p.item.id and absf(d["x"] - p.position.x) < 1e-3 and absf(d["z"] - p.position.z) < 1e-3 and d["yaw"] == p.yaw:
					orig = d
			restored_ok = restored_ok and orig != null
		check("restore positions/yaw", restored_ok)
		check("restored items settle", (await settle(backend, placer)) >= 0)
		placer.remove(restored_lamp)

		# --- walkthrough carry & drop
		var shopper := Shopper.new()
		shopper.setup(backend, placer, Vector3(0, 0, 2.0))
		for i in 30:
			shopper.step(Vector3.ZERO, 1.0 / 60.0)
			backend.step(1.0 / 60.0)
			placer.update(1.0 / 60.0)
			await process_frame
		check("shopper grounded", shopper.grounded, "y=%.3f" % shopper.position.y)
		var target := placer.nearest(shopper.feet() + Vector3(0, 0.3, 0), 6.0)
		# Walk to it, pick it up.
		for i in 240:
			var to := target.aabb(backend).get_center() - shopper.feet()
			to.y = 0
			if to.length() < 1.0:
				break
			shopper.yaw = atan2(-to.x, -to.z)
			shopper.step(Vector3(0, 0, -1), 1.0 / 60.0)
			backend.step(1.0 / 60.0)
			placer.update(1.0 / 60.0)
			await process_frame
		shopper.interact()
		check("picked up", shopper.carrying == target and target.state == PlacedItem.State.CARRIED)
		for i in 10:
			shopper.step(Vector3.ZERO, 1.0 / 60.0)
			backend.step(1.0 / 60.0)
			placer.update(1.0 / 60.0)
			await process_frame
		check("carried item lifted", target.lift_y > 0.3 and target.body < 0)
		shopper.interact()
		check("dropped", shopper.carrying == null and target.state == PlacedItem.State.SETTLING and target.body >= 0)
		check("dropped item settles", (await settle(backend, placer)) >= 0)
		var dy := backend.body_get_transform(target.body).origin.y
		check("dropped item on floor", dy < target.item.size.y * 0.5 + 0.05, "y=%.3f" % dy)
		shopper.release()

		# --- model import: a generated GLB in millimetres
		if which == PhysicsFactory.Backend.BOX3D:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(1200, 800, 400)   # mm
			mi.mesh = bm
			mi.position = Vector3(0, 400, 0)   # pivot at the base, like most exports
			var scene_root := Node3D.new()
			scene_root.add_child(mi)
			mi.owner = scene_root
			var doc := GLTFDocument.new()
			var st := GLTFState.new()
			check("glb export", doc.append_from_scene(scene_root, st) == OK)
			var bytes := doc.generate_buffer(st)
			check("glb bytes", bytes.size() > 100, "%d bytes" % bytes.size())
			var up := ModelLoader.from_bytes(bytes, "Test Cabinet.glb")
			check("model imported", up != null)
			if up != null:
				check("mm auto-scaled", up.size.is_equal_approx(Vector3(1.2, 0.8, 0.4)), str(up.size))
				check("upload id", up.id == "upload-test-cabinet")
				catalog.add(up)
				var u := placer.begin(up)
				placer.drag_to(Vector3(-2.0, 0, -1.5))
				check("upload placeable", u.valid and placer.drop())
				check("upload settles", (await settle(backend, placer)) >= 0)
				var uy := backend.body_get_transform(u.body).origin.y
				check("upload rests on floor", absf(uy - 0.4) < 0.03, "y=%.3f" % uy)
				var hull := ModelLoader.from_bytes(bytes, "Hull.glb", true)
				check("hull shape", hull != null and hull.shape["type"] == PhysicsBackend.SHAPE_HULL
					and hull.shape["points"].size() >= 8)
				var h := placer.begin(hull)
				placer.drag_to(Vector3(0.0, 0, -2.0))
				check("hull placeable", h.valid and placer.drop())
				check("hull settles", (await settle(backend, placer)) >= 0)
			scene_root.queue_free()

		placer.clear()
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
