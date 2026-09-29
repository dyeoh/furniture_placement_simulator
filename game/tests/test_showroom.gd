extends SceneTree

## The showroom end to end through the real viewport: a window taken from the
## catalogue, slid along a wall with the mouse, dropped, picked up again,
## cancelled and deleted; the ceiling switched on; the wall height changed
## with furniture and openings in the room.

var _fails: Array[String] = []


func _init() -> void:
	run.call_deferred()


func check(label: String, cond: bool, detail: String = "") -> void:
	print("  [%s] %s%s" % ["OK  " if cond else "FAIL", label, ("   " + detail) if detail != "" else ""])
	if not cond:
		_fails.append(label)


func frames(n: int) -> void:
	for i in n:
		await process_frame


func mouse(pressed: bool, at: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	get_root().push_input(ev)
	await process_frame


func move(from: Vector2, to: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = to
	ev.global_position = to
	ev.relative = to - from
	get_root().push_input(ev)
	await process_frame


func key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	get_root().push_input(ev)
	await process_frame


func run() -> void:
	await process_frame
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_root().size = Vector2i(1280, 720)
	var scene: Node3D = load("res://scenes/showroom.tscn").instantiate()
	get_root().add_child(scene)
	await frames(5)
	var room: RoomBuilder = scene.room
	var openings: Openings = scene.openings
	var cam: Camera3D = scene._camera
	check("default view keeps the north wall", not room.hidden_walls.has("north"), str(room.hidden_walls))

	# --- a window from the catalogue, slid along the north wall
	scene._spawn_item(scene.catalog.find("window"))
	check("window follows the pointer", openings.dragging != null and openings.dragging.ghost)
	var a := cam.unproject_position(Vector3(-1.0, 1.5, -2.5))
	var b := cam.unproject_position(Vector3(1.2, 1.5, -2.5))
	await mouse(true, a)
	await move(a, b)
	var win := openings.dragging
	check("dragged along the north wall", win != null and win.wall == "north" and absf(win.offset - 1.2) < 0.05,
		"%s %.3f" % [win.wall, win.offset] if win else "none")
	await mouse(false, b)
	check("released: dropped", openings.dragging == null and not win.ghost and room.openings.size() == 1)
	var body: Node3D = room.meshes["north"].get_node("Body")
	check("north wall has its hole", body.get_child_count() == 4, "%d" % body.get_child_count())

	# --- press on it: lifted and selected; Esc puts it back
	var on_win := cam.unproject_position(Vector3(win.offset, 1.5, -2.5))
	await mouse(true, on_win)
	check("press lifts it", openings.dragging == win and scene._selected_opening == win)
	var c := cam.unproject_position(Vector3(-1.5, 1.5, -2.5))
	await move(on_win, c)
	check("lifted window moves", absf(win.offset + 1.5) < 0.05, "%.3f" % win.offset)
	await key(KEY_ESCAPE)
	check("Esc puts it back", openings.dragging == null and absf(win.offset - 1.2) < 0.05, "%.3f" % win.offset)
	await mouse(false, c)

	# --- a second one where the first is: refused, stays on the pointer
	scene._spawn_item(scene.catalog.find("window"))
	await mouse(true, on_win)
	await mouse(false, on_win)
	check("overlapping drop refused", openings.dragging != null and not openings.dragging.valid)
	await key(KEY_DELETE)
	check("Delete discards the ghost", openings.dragging == null and room.openings.size() == 1)

	# --- the ceiling, from the panel
	scene._panel.ceiling_toggled.emit(true)
	await frames(2)
	check("ceiling on", room.has_ceiling and room.ceiling.visible
		and room.ceiling.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	var cut: String = room.hidden_walls[0] if not room.hidden_walls.is_empty() else ""
	var cut_body: Node3D = room.meshes[cut].get_node("Body") if cut != "" else null
	check("a cut wall still casts", cut_body != null and (cut_body.get_child(0) as GeometryInstance3D).cast_shadow
		== GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, cut)
	var any_wall: Node3D = room.meshes["north"]
	check("wall caps in the planner", any_wall.get_node("Trim/Cap").visible)
	scene._set_tool(CatalogPanel.Tool.WALK)
	await frames(2)
	check("no wall caps in the walkthrough", not any_wall.get_node("Trim/Cap").visible)
	scene._set_tool(CatalogPanel.Tool.PLACE)
	await frames(2)
	var data: Dictionary = scene._capture()
	check("layout records the room", data["room"]["ceiling"] == true and data["room"]["openings"].size() == 1)

	# --- wall height: rebuilds, keeps the window, flags a piece too tall
	scene.placer.begin(scene.catalog.find("segu-shelf"), Vector3(0, 0, 0))
	scene.placer.drag_to(Vector3(0, 0, 0))
	scene.placer.drop()
	await frames(10)
	scene._panel.room_size_changed.emit(6.0, 5.0, 2.2)
	await frames(30)
	check("height applied", is_equal_approx(room.wall_height, 2.2))
	check("ceiling kept", room.has_ceiling)
	check("window kept, still fits under 2.2 m", room.openings.size() == 1 and room.openings[0].valid)
	var shelf: PlacedItem = scene.placer.items[0] if not scene.placer.items.is_empty() else null
	check("2.1 m shelf still fits under 2.2 m", shelf != null and shelf.valid)
	var labels: Array[String] = []
	for l in scene._dims.find_children("*", "Label3D", true, false):
		labels.append((l as Label3D).text)
	check("height dimension shown", labels.has("2.20 m"), str(labels))
	# The panel's spin box stops at the minimum; a host asking for less is
	# clamped the same way, in one rebuild.
	scene._panel.room_size_changed.emit(6.0, 5.0, 1.5)
	await frames(30)
	check("height clamped to the minimum", is_equal_approx(room.wall_height, RoomBuilder.MIN_HEIGHT),
		"%.2f" % room.wall_height)

	# --- lamp shadows: only the nearest two lit lamps cast
	var lamps: Array[PlacedItem] = []
	for x in [-2.0, 0.0, 2.0]:
		var l: PlacedItem = scene.placer.begin(scene.catalog.find("floor-lamp"), Vector3(x, 0, 1.5))
		scene.placer.drag_to(Vector3(x, 0, 1.5))
		scene.placer.drop()
		lamps.append(l)
	scene.placer.changed.emit()
	await frames(2)
	var casting := 0
	for l in lamps:
		if l.light_casts_shadow():
			casting += 1
	check("two of three lamps cast shadows", casting == 2, "%d" % casting)

	print("")
	if _fails.is_empty():
		print("ALL PASSED")
		quit(0)
	else:
		print("FAILED: %s" % ", ".join(_fails))
		quit(1)
