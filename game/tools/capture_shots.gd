extends SceneTree

## Renders screenshots of the showroom into shots/ (project root). Must run
## WITHOUT --headless: the headless server has no rendering device.
##
##   godot --path game --script res://tools/capture_shots.gd
##
## Places a few catalogue items, windows and a door, paints a wall, and shoots
## the planner view open and under a ceiling, the walkthrough view, and an
## evening scene with the lamps on.

func _init() -> void:
	run.call_deferred()


## Wait for the frame to finish drawing, then save it: grabbing the texture
## straight after process_frame can hand back an earlier frame.
func _save(shot: String) -> void:
	await RenderingServer.frame_post_draw
	get_root().get_viewport().get_texture().get_image().save_png("res://../shots/%s.png" % shot)
	print("saved shots/%s.png" % shot)


func run() -> void:
	await process_frame
	var scene: Node3D = load("res://scenes/showroom.tscn").instantiate()
	get_root().add_child(scene)
	for i in 5:
		await process_frame
	var placer: Placer = scene.placer
	var catalog: Catalog = scene.catalog
	var room: RoomBuilder = scene.room
	placer.snap_mode = Placer.Snap.WALL
	var layout := [
		["segu-shelf", Vector3(-1.0, 0, -2.4)],
		["hikari-drinks-cabinet", Vector3(1.6, 0, -2.4)],
		["naka-bed", Vector3(-1.9, 0, 0.6)],
		["lutra-bedside-table", Vector3(-2.75, 0, -0.9)],
		["logos-tv-unit", Vector3(2.75, 0, 0.2)],
		["moto-coffee-table", Vector3(1.0, 0, 0.9)],
		["se-side-table", Vector3(1.9, 0, 1.9)],
	]
	for e in layout:
		placer.begin(catalog.find(e[0]), e[1])
		placer.drag_to(e[1])
		if not placer.drop():
			placer.cancel()
	room.paint("north", Color("#7f9a7a"))
	room.paint("east", Color("#e3d9c6"))
	var openings: Openings = scene.openings
	openings.place(catalog.find("window"), "west", -1.7)
	openings.place(catalog.find("tall-window"), "east", -1.5)
	openings.place(catalog.find("wide-window"), "south", 0.6)
	openings.place(catalog.find("door"), "south", -2.2)
	for i in 90:
		await process_frame
	DirAccess.make_dir_recursive_absolute("res://../shots")
	await _save("planner")

	# Under a ceiling the sun only gets in through the windows.
	room.set_ceiling(true)
	scene._panel.set_room_size(room.width, room.depth, room.wall_height, true)
	for i in 30:
		await process_frame
	await _save("ceiling")

	scene._set_tool(CatalogPanel.Tool.PAINT)
	scene.painter.set_hover("west")
	for i in 5:
		await process_frame
	await _save("paint")

	scene._set_tool(CatalogPanel.Tool.WALK)
	scene.shopper.yaw = 0.5
	scene.shopper.pitch = -0.1
	for i in 30:
		await process_frame
	await _save("walk")

	# Close up into the north-east corner, up toward the ceiling: the seam
	# shading, with and without a ceiling.
	scene.shopper.position = Vector3(1.9, scene.shopper.position.y, -1.2)
	scene.shopper.yaw = atan2(-1.1, 1.3)
	scene.shopper.pitch = 0.3
	for i in 20:
		await process_frame
	await _save("corner")
	room.set_ceiling(false)
	scene._sync_light_sources()
	for i in 10:
		await process_frame
	await _save("corner_open")
	room.set_ceiling(true)
	scene._sync_light_sources()

	# Evening: sun low and warm, ceiling light on, a floor lamp by the bed.
	scene._set_tool(CatalogPanel.Tool.LIGHT)
	placer.snap_mode = Placer.Snap.FREE
	var lamp := placer.begin(catalog.find("floor-lamp"), Vector3(-0.6, 0, -1.6))
	placer.drag_to(Vector3(-0.6, 0, -1.6))
	lamp.set_light(true, 0.8, 0.8)
	placer.drop()
	var lighting: Lighting = scene.lighting
	lighting.from_dict({"sun": {"elevation": 14.0, "azimuth": 250.0, "energy": 0.25, "warmth": 0.9},
		"ambient": {"energy": 0.25}, "ceiling": {"on": true, "energy": 0.6, "warmth": 0.6}})
	scene._panel.set_lighting(lighting.to_dict())
	for i in 60:
		await process_frame
	await _save("light")

	# Night under a ceiling: no sun, ceiling light off, just the floor lamp.
	lighting.from_dict({"sun": {"energy": 0.0}, "ceiling": {"on": false}})
	scene._panel.set_lighting(lighting.to_dict())
	for i in 30:
		await process_frame
	await _save("night")
	lamp.set_light(false, 0.8, 0.8)
	placer.changed.emit()
	for i in 10:
		await process_frame
	await _save("dark")

	# Up close at dusk: the lamp beside the shelf against the north wall, as
	# a shopper standing in the room would see it.
	lighting.from_dict({"sun": {"elevation": 12.0, "azimuth": 250.0, "energy": 0.15, "warmth": 0.9}})
	placer.lift(lamp)
	placer.drag_to(Vector3(0.05, 0, -2.2))
	placer.drop()
	lamp.set_light(true, 0.8, 0.75)
	placer.changed.emit()
	scene._set_tool(CatalogPanel.Tool.WALK)
	scene.shopper.position = Vector3(-0.2, scene.shopper.position.y, -0.5)
	scene.shopper.yaw = atan2(0.25, 1.7)
	scene.shopper.pitch = -0.2
	for i in 60:
		await process_frame
	await _save("lamp")
	# Looking up into the shade from below it: lower than a standing eye,
	# so the camera is placed by hand with the showroom's own update paused.
	scene.set_process(false)
	var cam: Camera3D = scene._camera
	var bulb: Vector3 = lamp.node.global_position + Vector3.UP * FurnitureShapes.bulb_height(lamp.item.size)
	cam.global_position = bulb + Vector3(0.2, -0.85, 0.4)
	cam.look_at(bulb + Vector3(0, 0.05, 0))
	for i in 10:
		await process_frame
	await _save("lamp_under")
	scene.set_process(true)
	quit()
