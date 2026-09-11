extends SceneTree

## Renders screenshots of the showroom into shots/ (project root). Must run
## WITHOUT --headless: the headless server has no rendering device.
##
##   godot --path game --script res://tools/capture_shots.gd
##
## Places a few catalogue items, paints a wall, and shoots the planner view,
## then the walkthrough view.

func _init() -> void:
	run.call_deferred()


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
	room.paint("floor", Color("#cfcac2"))
	for i in 90:
		await process_frame
	DirAccess.make_dir_recursive_absolute("res://../shots")
	get_root().get_viewport().get_texture().get_image().save_png("res://../shots/planner.png")
	print("saved shots/planner.png")

	scene._set_tool(CatalogPanel.Tool.PAINT)
	scene.painter.set_hover("west")
	for i in 5:
		await process_frame
	get_root().get_viewport().get_texture().get_image().save_png("res://../shots/paint.png")
	print("saved shots/paint.png")

	scene._set_tool(CatalogPanel.Tool.WALK)
	scene.shopper.yaw = 0.5
	scene.shopper.pitch = -0.1
	for i in 30:
		await process_frame
	get_root().get_viewport().get_texture().get_image().save_png("res://../shots/walk.png")
	print("saved shots/walk.png")
	quit()
