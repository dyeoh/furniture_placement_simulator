extends Node3D

## The showroom: one room, a catalogue, three tools.
##
##   Place  drag furniture in from the catalogue, rotate, drop; it settles.
##   Paint  pick a swatch, tap a wall or the floor.
##   Walk   first person: WASD, mouse look, E to carry / drop, bump into things.
##   Light  swing the sun, dim the ambient and ceiling light, add floor lamps.
##
## Keys (desktop)
##   1 / 2 / 3 / 4 Place / Paint / Walk / Light  Tab   cycle tools
##   R             rotate the dragged item     S     cycle snap mode (Place)
##   Delete        remove the dragged item     Esc   cancel drag / release mouse
##   B             swap physics backend (Box3D <-> Jolt), same layout
##   [ ]           shove force down / up (Walk), live
##   RMB drag      orbit    Wheel  zoom
##
## On a touchscreen Walk gets on-screen controls instead (TouchControls): a
## stick on the left, drag-to-look on the right, a carry button. The side
## panel steps aside while walking so a phone gets the whole room.
##
## Everything physical goes through the PhysicsBackend seam; this file owns
## cameras, input and wiring only.

const ROOM_W := 6.0
const ROOM_D := 5.0

var backend: PhysicsBackend
var room := RoomBuilder.new()
var catalog := Catalog.new()
var placer := Placer.new()
var painter := Painter.new()
var shopper := Shopper.new()
var bridge := HostBridge.new()
var lighting := Lighting.new()

var _world_root: Node3D
var _visual_root: Node3D
var _cam_pivot: Node3D
var _camera: Camera3D
var _panel: CatalogPanel
var _hud: Label
var _touch: TouchControls
var _file_dialog: FileDialog

var _tool := CatalogPanel.Tool.PLACE
var _backend_choice := PhysicsFactory.Backend.BOX3D
var _yaw := 0.35
var _pitch := -0.95
var _dist := 9.0
var _orbiting := false
var _press_drag := false
var _last_pointer := Vector2.ZERO
var _selected: PlacedItem
var _pending_layout: Dictionary = {}


func _ready() -> void:
	catalog.load_default()
	_build_environment()
	_build_ui()
	bridge.catalog_received.connect(_on_host_catalog)
	bridge.layout_received.connect(_restore_layout)
	bridge.clear_requested.connect(func(): placer.clear())
	bridge.model_received.connect(_on_model_bytes)
	bridge.setup()
	_start_backend()


#region Setup

func _build_environment() -> void:
	lighting.setup(self, room.wall_height)
	lighting.changed.connect(_on_layout_changed)

	_cam_pivot = Node3D.new()
	add_child(_cam_pivot)
	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 55
	_cam_pivot.add_child(_camera)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_panel = CatalogPanel.new()
	_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_panel.offset_left = 8
	_panel.offset_top = 8
	_panel.offset_bottom = -8
	_panel.build(catalog, HostBridge.is_web())
	layer.add_child(_panel)
	_panel.tool_selected.connect(_set_tool)
	_panel.item_chosen.connect(_spawn_item)
	_panel.snap_cycled.connect(func():
		placer.cycle_snap()
		_panel.set_snap_name(placer.snap_name())
		if placer.dragging != null:
			placer.drag_to(placer.dragging.position))
	_panel.rotate_pressed.connect(func(): placer.rotate())
	_panel.delete_pressed.connect(_delete_selected)
	_panel.finish_chosen.connect(func(key):
		var p := placer.dragging if placer.dragging != null else _selected
		if p != null:
			placer.set_finish(p, key))
	_panel.swatch_chosen.connect(func(c): painter.color = c)
	_panel.paint_all_pressed.connect(func(): painter.apply_all_walls())
	_panel.upload_pressed.connect(_on_upload)
	_panel.clear_pressed.connect(func(): placer.clear())
	_panel.cart_pressed.connect(_add_to_cart)
	_panel.export_pressed.connect(func(): print(Layout.to_json(Layout.capture(placer, room, lighting))))
	_panel.light_changed.connect(_on_light_changed)
	_panel.lamp_changed.connect(_on_lamp_changed)
	_panel.add_lamp_pressed.connect(func(): _spawn_item(catalog.find("floor-lamp")))
	_panel.set_lighting(lighting.to_dict())

	var hud_panel := PanelContainer.new()
	hud_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	hud_panel.offset_left = -330
	hud_panel.offset_right = -8
	hud_panel.offset_top = 8
	hud_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	layer.add_child(hud_panel)
	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 13)
	_hud.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud_panel.add_child(_hud)

	if TouchControls.wanted():
		_touch = TouchControls.new()
		_touch.visible = false
		layer.add_child(_touch)
		_touch.look.connect(func(rel: Vector2): shopper.turn(rel.x * 0.005, rel.y * 0.005))
		_touch.interact_pressed.connect(func(): shopper.interact())
		_touch.exit_pressed.connect(func(): _set_tool(CatalogPanel.Tool.PLACE))

	if not HostBridge.is_web():
		_file_dialog = FileDialog.new()
		_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.filters = PackedStringArray(["*.glb, *.gltf ; glTF models"])
		_file_dialog.use_native_dialog = true
		_file_dialog.file_selected.connect(func(path: String):
			_on_model_bytes(FileAccess.get_file_as_bytes(path), path.get_file()))
		add_child(_file_dialog)


func _start_backend() -> void:
	if backend != null:
		_pending_layout = Layout.capture(placer, room, lighting)
		shopper.release()
		placer.clear()
		backend.shutdown()
	if is_instance_valid(_world_root):
		_world_root.queue_free()
	if is_instance_valid(_visual_root):
		_visual_root.queue_free()
	_world_root = Node3D.new()
	add_child(_world_root)
	_visual_root = Node3D.new()
	add_child(_visual_root)

	backend = PhysicsFactory.create(_backend_choice)
	backend.initialize(_world_root)
	backend.set_gravity(Vector3(0, -9.8, 0))

	room.width = ROOM_W
	room.depth = ROOM_D
	room.build(backend)
	room.build_visuals(_visual_root)
	placer.setup(backend, room, catalog, _visual_root)
	painter.setup(room)
	if not placer.changed.is_connected(_on_layout_changed):
		placer.changed.connect(_on_layout_changed)
	shopper.setup(backend, placer, Vector3(0, 0.0, ROOM_D * 0.5 - 1.0))
	if not _pending_layout.is_empty():
		_restore_layout(_pending_layout)
		_pending_layout = {}
	_set_tool(_tool)


func _restore_layout(data: Dictionary) -> void:
	Layout.restore(data, placer, room, lighting)
	_panel.set_lighting(lighting.to_dict())

#endregion


#region Tools

func _set_tool(tool: int) -> void:
	if _tool == CatalogPanel.Tool.WALK and tool != CatalogPanel.Tool.WALK:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if shopper.carrying != null:
			shopper.interact()
	_tool = tool as CatalogPanel.Tool
	_panel.set_tool(tool)
	if _touch != null:
		_touch.visible = (tool == CatalogPanel.Tool.WALK)
		_panel.visible = not _touch.visible
	painter.clear_hover()
	if tool != CatalogPanel.Tool.PLACE and placer.dragging != null:
		placer.cancel()
	_select(null)


func _spawn_item(item: FurnitureItem) -> void:
	if item == null:
		return
	# A lamp added from the Light tool is dragged in right there; anything
	# else is a Place job.
	if _tool != CatalogPanel.Tool.LIGHT or not item.is_light():
		_set_tool(CatalogPanel.Tool.PLACE)
	placer.begin(item, Vector3.ZERO)
	_press_drag = false
	_select(placer.dragging)


func _select(p: PlacedItem) -> void:
	if _selected != null and _selected != p:
		_selected.set_highlight(false)
	_selected = p
	if _selected != null and _selected.state != PlacedItem.State.GHOST:
		_selected.set_highlight(true)
	_panel.show_selected(p)


func _delete_selected() -> void:
	if placer.dragging != null:
		placer.remove(placer.dragging)
	elif _selected != null:
		placer.remove(_selected)
	_select(null)


func _on_light_changed(group: String, key: String, value: Variant) -> void:
	match group:
		"sun": lighting.set_sun(key, float(value))
		"ambient": lighting.set_ambient(float(value))
		"ceiling": lighting.set_ceiling(key, value)


func _on_lamp_changed(key: String, value: Variant) -> void:
	var p := placer.dragging if placer.dragging != null else _selected
	if p == null or not p.item.is_light():
		return
	var l := p.light.duplicate()
	l[key] = value
	p.set_light(bool(l["on"]), float(l["energy"]), float(l["warmth"]))
	placer.changed.emit()

#endregion


#region Input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_key(event as InputEventKey)
		return
	match _tool:
		CatalogPanel.Tool.PLACE:
			_input_place(event)
		CatalogPanel.Tool.PAINT:
			_input_paint(event)
		CatalogPanel.Tool.WALK:
			_input_walk(event)
		CatalogPanel.Tool.LIGHT:
			_input_light(event)


func _key(k: InputEventKey) -> void:
	match k.keycode:
		KEY_1: _set_tool(CatalogPanel.Tool.PLACE)
		KEY_2: _set_tool(CatalogPanel.Tool.PAINT)
		KEY_3: _set_tool(CatalogPanel.Tool.WALK)
		KEY_4: _set_tool(CatalogPanel.Tool.LIGHT)
		KEY_TAB: _set_tool((_tool + 1) % CatalogPanel.TOOL_NAMES.size())
		KEY_R: placer.rotate()
		KEY_S:
			if _tool == CatalogPanel.Tool.PLACE:
				placer.cycle_snap()
				_panel.set_snap_name(placer.snap_name())
				if placer.dragging != null:
					placer.drag_to(placer.dragging.position)
		KEY_DELETE, KEY_BACKSPACE: _delete_selected()
		KEY_ESCAPE:
			if _tool == CatalogPanel.Tool.WALK:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			elif placer.dragging != null:
				placer.cancel()
				_select(null)
		KEY_B:
			_backend_choice = PhysicsFactory.Backend.GODOT \
				if _backend_choice == PhysicsFactory.Backend.BOX3D else PhysicsFactory.Backend.BOX3D
			_start_backend()
		KEY_BRACKETLEFT: shopper.shove_force = maxf(50.0, shopper.shove_force - 50.0)
		KEY_BRACKETRIGHT: shopper.shove_force += 50.0
		KEY_E:
			if _tool == CatalogPanel.Tool.WALK:
				shopper.interact()


func _pointer_ray(screen: Vector2) -> Array:
	return [_camera.project_ray_origin(screen), _camera.project_ray_normal(screen)]


func _input_place(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(2.5, _dist * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(20.0, _dist * 1.1)
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_orbiting = mb.pressed
			_last_pointer = mb.position
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			var ray := _pointer_ray(mb.position)
			if mb.pressed:
				_last_pointer = mb.position
				if placer.dragging != null:
					# Sticky drag from the catalogue: a click is the drop.
					if placer.drop():
						_select(null)
				else:
					var hit := placer.pick(ray[0], ray[1])
					if hit != null and hit.state != PlacedItem.State.CARRIED:
						placer.lift(hit)
						_press_drag = true
						_select(hit)
					else:
						_select(null)
						_orbiting = true
			else:
				if _press_drag and placer.dragging != null:
					# Press-drag-release: release is the drop. If it does not
					# fit, keep it on the cursor so the shopper can find a spot.
					if placer.drop():
						_select(null)
				_press_drag = false
				_orbiting = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbiting:
			_yaw -= mm.relative.x * 0.006
			_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.5, -0.15)
		elif placer.dragging != null:
			var ray := _pointer_ray(mm.position)
			var hit = Placer.floor_hit(ray[0], ray[1])
			if hit != null:
				placer.drag_to(hit)
				_panel.show_selected(placer.dragging)
	elif event is InputEventMagnifyGesture:
		_dist = clampf(_dist / (event as InputEventMagnifyGesture).factor, 2.5, 20.0)


func _input_paint(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(2.5, _dist * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(20.0, _dist * 1.1)
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_orbiting = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			var ray := _pointer_ray(mb.position)
			var surface := room.pick_surface(ray[0], ray[1])
			if mb.pressed:
				if surface != "":
					painter.apply(surface)
				else:
					_orbiting = true
			else:
				_orbiting = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbiting:
			_yaw -= mm.relative.x * 0.006
			_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.5, -0.15)
		else:
			var ray := _pointer_ray(mm.position)
			painter.set_hover(room.pick_surface(ray[0], ray[1]))


## Light tool: a lamp being dragged in behaves as in Place; otherwise a tap
## selects a lamp to dim, and the view orbits like everywhere else.
func _input_light(event: InputEvent) -> void:
	if placer.dragging != null:
		_input_place(event)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(2.5, _dist * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(20.0, _dist * 1.1)
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_orbiting = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var ray := _pointer_ray(mb.position)
				var hit := placer.pick(ray[0], ray[1])
				if hit != null and hit.item.is_light():
					_select(hit)
				else:
					_select(null)
					_orbiting = true
			else:
				_orbiting = false
	elif event is InputEventMouseMotion and _orbiting:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.006
		_pitch = clampf(_pitch - mm.relative.y * 0.006, -1.5, -0.15)
	elif event is InputEventMagnifyGesture:
		_dist = clampf(_dist / (event as InputEventMagnifyGesture).factor, 2.5, 20.0)


func _input_walk(event: InputEvent) -> void:
	if event.device == InputEvent.DEVICE_ID_EMULATION:
		return   # a touch dressed as a mouse: pointer capture is meaningless
	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			shopper.interact()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		shopper.turn(mm.relative.x * 0.0035, mm.relative.y * 0.0035)


func _walk_intent() -> Vector3:
	var v := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): v.z -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): v.z += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): v.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): v.x += 1
	if _touch != null and _touch.visible:
		var st := _touch.stick_vector()
		v += Vector3(st.x, 0, st.y)
	return v

#endregion


#region Frame

func _physics_process(dt: float) -> void:
	if _tool == CatalogPanel.Tool.WALK:
		shopper.step(_walk_intent(), dt)
	backend.step(dt)
	placer.update(dt)


func _process(_dt: float) -> void:
	_update_camera()
	_update_hud()
	if _touch != null:
		_touch.set_carrying(shopper.carrying != null)


func _update_camera() -> void:
	if _tool == CatalogPanel.Tool.WALK:
		_camera.h_offset = 0.0
		_camera.global_position = shopper.eye()
		_camera.global_basis = Basis(Vector3.UP, shopper.yaw) * Basis(Vector3.RIGHT, shopper.pitch)
		room.update_cutaway(Vector3.ZERO, false)
		return
	_cam_pivot.position = Vector3.ZERO
	_cam_pivot.rotation = Vector3(_pitch, _yaw, 0)
	_camera.position = Vector3(0, 0, _dist)
	_camera.rotation = Vector3.ZERO
	# Slide the view right so the side panel does not sit over the room.
	_camera.h_offset = -_dist * 0.11
	room.update_cutaway(-_camera.global_basis.z, true)


func _update_hud() -> void:
	var lines := PackedStringArray()
	lines.append("Backend: %s   (B to swap)" % PhysicsFactory.backend_name(backend))
	match _tool:
		CatalogPanel.Tool.PLACE:
			lines.append("PLACE — tap a catalogue item, drag, tap to drop")
			lines.append("Snap: %s (S)   Rotate: R   Orbit: right-drag" % placer.snap_name())
			if placer.dragging != null:
				lines.append("Holding %s — %s" % [placer.dragging.item.name,
					"fits" if placer.dragging.valid else "doesn't fit"])
		CatalogPanel.Tool.PAINT:
			lines.append("PAINT — tap a wall or the floor")
			if painter.hover != "":
				lines.append("Over: %s" % painter.hover)
		CatalogPanel.Tool.WALK:
			if _touch != null:
				lines.append("WALK — stick to move, drag to look, walk into things to shove them")
			else:
				lines.append("WALK — click to look, WASD, E carry/drop, Esc frees mouse")
			lines.append("Shove force: %d N ([ ])" % int(shopper.shove_force))
			if shopper.carrying != null:
				lines.append("Carrying %s" % shopper.carrying.item.name)
		CatalogPanel.Tool.LIGHT:
			lines.append("LIGHT — sliders for the sun and ceiling light; tap a lamp to dim it")
			if placer.dragging != null:
				lines.append("Placing %s — tap to drop" % placer.dragging.item.name)
	var placed := 0
	var bad := 0
	for p in placer.items:
		if p.state == PlacedItem.State.GHOST:
			continue
		placed += 1
		if not p.valid:
			bad += 1
	lines.append("Items: %d%s%s" % [placed,
		"   settling…" if placer.any_settling() else "",
		"   %d not fitting" % bad if bad > 0 else ""])
	_hud.text = "\n".join(lines)


func _on_layout_changed() -> void:
	bridge.post(Layout.capture(placer, room, lighting))
	if _selected != null:
		_panel.show_selected(_selected)

#endregion


#region Host / uploads

func _on_host_catalog(data: Dictionary) -> void:
	catalog.load_dict(data)
	_panel.refresh_items()


func _on_upload() -> void:
	if HostBridge.is_web():
		bridge.pick_file()
	elif _file_dialog != null:
		_file_dialog.popup_centered_ratio(0.7)


func _on_model_bytes(bytes: PackedByteArray, filename: String) -> void:
	var item := ModelLoader.from_bytes(bytes, filename)
	if item == null:
		return
	catalog.add(item)
	_panel.refresh_items()
	_spawn_item(item)


func _add_to_cart() -> void:
	bridge.post({"type": "add_to_cart", "items": placer.cart_lines()})

#endregion
