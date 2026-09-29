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
		# Quality watchdog: slow frames after the grace period drop to low, once.
		var q := Quality.new()
		var drops := [0]   # an array, so the lambda's copy shares it
		q.changed.connect(func(_l: bool): drops[0] += 1)
		for i in 59:
			q.watch(0.1)   # 10 fps through the grace period: must not trigger
		check("no drop during grace", not q.low and drops[0] == 0)
		for i in 100:
			q.watch(0.05)  # 20 fps for 5 s
		check("watchdog drops to low", q.low and drops[0] == 1, "drops %d" % drops[0])
		for i in 100:
			q.watch(0.05)
		check("watchdog drops only once", drops[0] == 1)
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
		var shade_mi := lamp_p.node.find_child("Shade", true, false) as MeshInstance3D
		check("shade lets the lamp's light through (casts nothing)",
			shade_mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		lamp_p.set_light_shadow(true)
		check("lamp casts shadows when allowed", lamp_p.light_casts_shadow())
		PlacedItem.shadows_allowed = false
		lamp_p.set_light_shadow(true)
		check("no lamp shadows on low spec", not lamp_p.light_casts_shadow())
		PlacedItem.shadows_allowed = true
		lamp_p.set_light_shadow(false)
		check("lamp drop", placer.drop())
		check("lamp has a light node", lamp_p.node.get_child_count() > 0 and lamp_p.node.find_children("*", "OmniLight3D", true, false).size() == 1)
		var drum := (lamp_p.node.find_child("Shade", true, false) as MeshInstance3D).mesh as CylinderMesh
		var bulb_mi := lamp_p.node.find_child("Bulb", true, false) as MeshInstance3D
		var lamp_omni := lamp_p.node.find_children("*", "OmniLight3D", true, false)[0] as OmniLight3D
		check("hollow shade with a bulb at the light", not drum.cap_top and not drum.cap_bottom and bulb_mi != null
			and bulb_mi.global_position.is_equal_approx(lamp_omni.global_position))
		var bulb_glass := bulb_mi.material_override as StandardMaterial3D
		var fabric_mat := (lamp_p.node.find_child("Shade", true, false) as MeshInstance3D).material_override as StandardMaterial3D
		check("shade fabric is translucent", fabric_mat.backlight_enabled
			and fabric_mat.backlight == FurnitureShapes.FABRIC_TRANSLUCENCY)
		check("off bulb and shade are dark", not bulb_glass.emission_enabled and not fabric_mat.emission_enabled)
		lamp_p.set_light(true, 0.5, 0.9)
		check("lit bulb glows, shade faintly", bulb_glass.emission_enabled and fabric_mat.emission_enabled
			and is_equal_approx(fabric_mat.emission_energy_multiplier, 0.5 * PlacedItem.SHADE_GLOW))
		lamp_p.set_light(false, 0.25, 0.9)
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
		# --- ambient is bounce from the light that is actually there
		lighting.from_dict({"sun": {"energy": 0.5}, "ambient": {"energy": 0.3}, "ceiling": {"on": false}})
		lighting.set_room(false, 0.0, 30.0)
		lighting.set_lamps(0.0, 0.7)
		# Energies are the bounce model's, times the calibration gain (Lighting.GAINS).
		check("open room, sun 0.5: the old ambient", is_equal_approx(lighting.env.ambient_light_energy, 0.3 * Lighting.gain("ambient")),
			"%.3f" % lighting.env.ambient_light_energy)
		lighting.set_room(true, 0.0, 30.0)
		check("covered, no windows: dark", is_equal_approx(lighting.env.ambient_light_energy, Lighting.AMBIENT_FLOOR * Lighting.gain("ambient"))
			and is_equal_approx(lighting.fill.light_energy, 0.0), "%.3f" % lighting.env.ambient_light_energy)
		lighting.set_room(true, 3.0, 30.0)
		var windowed := lighting.env.ambient_light_energy
		check("a window lets daylight in", windowed > Lighting.AMBIENT_FLOOR * 2.0 * Lighting.gain("ambient") and windowed < 0.3 * Lighting.gain("ambient"), "%.3f" % windowed)
		lighting.set_sun("energy", 0.0)
		lighting.set_room(true, 3.0, 30.0)
		check("no sun, no lamps: dark", is_equal_approx(lighting.env.ambient_light_energy, Lighting.AMBIENT_FLOOR * Lighting.gain("ambient")))
		lighting.set_lamps(0.8, 0.9)
		var col := lighting.env.ambient_light_color
		check("a lamp brings warm bounce", lighting.env.ambient_light_energy > Lighting.AMBIENT_FLOOR * Lighting.gain("ambient")
			and col.r > col.b + 0.2, "%.3f %s" % [lighting.env.ambient_light_energy, col])
		lighting.set_lamps(0.0, 0.7)
		lighting.set_room(false, 0.0, 30.0)
		lighting.from_dict(Layout.from_json(json)["lighting"])

		# --- models carry their baked AO (the ARM texture's red channel)
		var model_mat: StandardMaterial3D = null
		for p in placer.items:
			if p.item.model == "" or p.node == null:
				continue
			for n in p.node.find_children("*", "MeshInstance3D", true, false):
				var m := (n as MeshInstance3D).get_active_material(0) as StandardMaterial3D
				if m != null and m.roughness_texture != null:
					model_mat = m
		check("model AO from its ARM texture", model_mat != null and model_mat.ao_enabled
			and model_mat.ao_texture == model_mat.roughness_texture and model_mat.ao_light_affect == 0.0)

		# --- room surfaces carry seam AO on UV2; nothing painted over them
		var north_mat: StandardMaterial3D = room.materials["north"]
		var floor_mat: StandardMaterial3D = room.materials["floor"]
		check("walls and floor have seam AO", north_mat.ao_enabled and north_mat.ao_on_uv2
			and north_mat.ao_texture != null and floor_mat.ao_texture != null and floor_mat.ao_light_affect == 0.0)
		var ao_img := (north_mat.ao_texture as ImageTexture).get_image()
		var mid_x := ao_img.get_width() / 2
		check("wall AO: dark at the floor, clear mid-wall",
			ao_img.get_pixel(mid_x, ao_img.get_height() - 1).r < 0.6 and ao_img.get_pixel(mid_x, ao_img.get_height() / 2).r > 0.95)
		check("no overlay strips left", room.meshes["north"].find_children("Seam", "", true, false).is_empty())

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

		# --- a piece against a wall shades it; lifted, it does not
		var against: PlacedItem = null
		for p in placer.items:
			if p.item.id == "segu-shelf":
				against = p
		placer.update(1.0 / 60.0)
		check("shelf against the wall shades it", against != null and against.has_wall_contact())
		placer.lift(against)
		placer.update(1.0 / 60.0)
		check("lifted shelf does not", not against.has_wall_contact())
		placer.drop()
		await settle(backend, placer)

		placer.remove(restored_lamp)

		# --- dimension lines follow the cutaway
		var dims := DimensionLines.new()
		stage.add_child(dims)
		dims.build(room)
		var labels: Array[String] = []
		for l in dims.find_children("*", "Label3D", true, false):
			labels.append((l as Label3D).text)
		labels.sort()
		check("dimension labels", labels == ["2.70 m", "5.00 m", "6.00 m"], str(labels))
		dims.update(["south", "east"])
		check("lines on the camera side", dims._width_line.position.z > 2.5 and dims._depth_line.position.x > 3.0)
		dims.update(["north", "west"])
		check("lines flip with the cutaway", dims._width_line.position.z < -2.5 and dims._depth_line.position.x < -3.0)
		# Upright at the far end of the width line, beside the standing wall.
		check("height line beside the standing wall", dims._height_line.position.x > 3.0
			and dims._height_line.position.z < -2.5
			and is_equal_approx(dims._height_line.position.y, room.wall_height * 0.5), str(dims._height_line.position))
		dims.queue_free()

		# --- wall height: a piece taller than the room does not fit
		var tall_box := AABB(Vector3(-0.5, 0, -0.5), Vector3(1.0, 2.1, 1.0))
		check("2.1 m fits under 2.7 m", room.contains_aabb(tall_box))
		room.wall_height = 2.0
		check("2.1 m refused under 2.0 m", not room.contains_aabb(tall_box))
		room.wall_height = 2.7

		# --- wall segments around windows
		var run := 6.3
		check("plain wall is one segment", RoomBuilder._wall_segments(run, 2.7, []).size() == 1)
		var one: Array[Vector4] = [Vector4(-0.6, 0.6, 0.9, 2.1)]
		check("one window: 4 segments", RoomBuilder._wall_segments(run, 2.7, one).size() == 4)
		var two: Array[Vector4] = [Vector4(-0.6, 0.6, 0.9, 2.1), Vector4(1.5, 2.5, 0.9, 2.1)]
		check("two windows: 7 segments", RoomBuilder._wall_segments(run, 2.7, two).size() == 7)
		var overlapping: Array[Vector4] = [Vector4(-0.6, 0.6, 0.9, 2.1), Vector4(0.0, 1.2, 0.5, 2.1)]
		var area := 0.0
		for r in RoomBuilder._wall_segments(run, 2.7, overlapping):
			area += r.get_area()
		# Union of the holes: 1.2 x 1.2 plus the second's 0.6 x 1.6 beyond x = 0.6
		# and its 0.6 x 0.4 below the first between x = 0 and 0.6.
		var holes_area := 1.2 * 1.2 + 0.6 * 1.6 + 0.6 * 0.4
		check("overlapping holes merge", is_equal_approx(area, run * 2.7 - holes_area),
			"%.4f vs %.4f" % [area, run * 2.7 - holes_area])

		# --- windows and doors
		var ops := Openings.new()
		ops.setup(room, catalog)
		var win_item := catalog.find("window")
		check("window fixture", win_item != null and win_item.is_opening() and win_item.variant_id == 0
			and is_equal_approx(win_item.sill, 0.9) and win_item.size.is_equal_approx(Vector3(1.2, 1.2, 0.15)))
		var w1 := ops.begin(win_item)
		ops.drag_ray(Vector3(1.0, 1.5, 0.0), Vector3(0, 0, -1))
		check("window slides along the north wall", w1.wall == "north" and is_equal_approx(w1.offset, 1.0),
			"%s %.3f" % [w1.wall, w1.offset])
		check("window drop", ops.drop() and not w1.ghost)
		var north_body: Node3D = room.meshes["north"].get_node("Body")
		check("north wall cut around it", north_body.get_child_count() == 4, "%d" % north_body.get_child_count())
		var w2 := ops.begin(win_item)
		ops.drag_ray(Vector3(1.5, 1.5, 0.0), Vector3(0, 0, -1))
		check("overlapping window invalid", not w2.valid)
		check("overlapping drop refused", not ops.drop())
		ops.drag_ray(Vector3(2.9, 1.5, 0.0), Vector3(0, 0, -1))
		check("window clamped clear of the corner", is_equal_approx(w2.offset, 3.0 - 0.6 - Openings.GAP) and w2.valid,
			"%.3f" % w2.offset)
		ops.drag_ray(Vector3(0, 5, 0), Vector3(2.9, -5, 0.3).normalized())
		check("over the floor: nearest wall", w2.wall == "east", w2.wall)
		check("north wall whole again but for w1", north_body.get_child_count() == 4)
		check("second window drop", ops.drop())
		var door := ops.begin(catalog.find("door"))
		ops.drag_ray(Vector3(0, 1.0, 0), Vector3(0, 0, 1))
		check("door on the south wall", door.wall == "south" and not door.cuts_wall())
		check("door drop", ops.drop())
		var south_body: Node3D = room.meshes["south"].get_node("Body")
		check("a door cuts nothing", south_body.get_child_count() == 1)
		room.wall_height = 2.0
		check("window head above a 2.0 m wall refused", not ops.validate(w1))
		room.wall_height = 2.7
		var cancelled := ops.begin(win_item)
		ops.cancel()
		check("cancel drops a new one", not room.openings.has(cancelled) and room.openings.size() == 3)
		ops.lift(w1)
		ops.drag_ray(Vector3(-1.0, 1.5, 0.0), Vector3(0, 0, -1))
		check("lifted opening serialises where it was", is_equal_approx(float(ops.to_array()[0]["offset"]), 1.0))
		ops.cancel()
		check("cancelled lift goes back", is_equal_approx(w1.offset, 1.0) and not w1.ghost)

		# --- room layout: height, ceiling and openings round-trip
		room.set_ceiling(true)
		var room_data := Layout.capture(placer, room, null, ops)
		check("capture has height and ceiling", is_equal_approx(float(room_data["room"]["height"]), 2.7)
			and room_data["room"]["ceiling"] == true)
		check("capture has openings, not as items", room_data["room"]["openings"].size() == 3
			and room_data["items"].size() == 3)
		room.set_ceiling(false)
		ops.clear()
		check("openings cleared", room.openings.is_empty() and north_body.get_child_count() == 1)
		# A layout from before any of this still loads, and leaves the room be.
		Layout.restore({"version": 1, "room": {"width": 6.0, "depth": 5.0}, "items": [], "paint": {}},
			placer, room, null, ops)
		check("old layout restores", not room.has_ceiling and room.openings.is_empty())
		Layout.restore(Layout.from_json(Layout.to_json(room_data)), placer, room, null, ops)
		check("restore ceiling", room.has_ceiling)
		check("restore openings", room.openings.size() == 3 and north_body.get_child_count() == 4)
		check("restore items", placer.items.size() == 3)
		var restored_walls := []
		for op in room.openings:
			restored_walls.append(op.wall)
		restored_walls.sort()
		check("restore opening walls", restored_walls == ["east", "north", "south"], str(restored_walls))
		# A narrower room pulls openings in from the corners.
		room.width = 1.8
		ops.setup(room, catalog)
		var inside_walls := true
		for op in room.openings:
			var half := room.run_half(op.wall)
			inside_walls = inside_walls and op.span().x >= -half and op.span().y <= half
		check("shrunk wall keeps openings inside", room.openings.size() == 3 and inside_walls)
		room.width = 6.0
		ops.clear()
		room.set_ceiling(false)
		await settle(backend, placer)

		# --- restoring into a narrower room keeps every piece inside the walls.
		# The walls' bodies are not rebuilt here: clamping and validation are
		# arithmetic on the room's extents, which is what is under test.
		var wide := Layout.capture(placer, room)
		var far_x := 0.0
		for p in placer.items:
			far_x = maxf(far_x, absf(p.position.x))
		check("something sits past x=1.0 in the 6 m room", far_x > 1.0, "%.2f" % far_x)
		placer.clear()
		room.width = 2.0
		room.depth = 2.0
		Layout.restore(wide, placer, room)
		var inside := true
		var flagged := 0
		for p in placer.items:
			inside = inside and room.contains_aabb(p.aabb(null))
			if not p.valid:
				flagged += 1
		check("shrunk room: all inside", inside)
		check("shrunk room: overlaps flagged", flagged > 0, "%d flagged" % flagged)
		placer.clear()
		room.width = 6.0
		room.depth = 5.0
		Layout.restore(wide, placer, room)
		var clean := true
		for p in placer.items:
			clean = clean and p.valid
		check("back at 6 m: all valid", clean)
		await settle(backend, placer)

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
		# Walk at the nearest wall with it: it must stay inside the room.
		shopper.yaw = 0.0   # facing -Z, the north wall
		var clipped := false
		for i in 240:
			shopper.step(Vector3(0, 0, -1), 1.0 / 60.0)
			backend.step(1.0 / 60.0)
			placer.update(1.0 / 60.0)
			await process_frame
			if not room.contains_aabb(target.aabb(null)):
				clipped = true
		check("carried item never clips the wall", not clipped, str(target.position))
		check("shopper reached the wall", shopper.feet().z < -1.5, "z=%.2f" % shopper.feet().z)
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
