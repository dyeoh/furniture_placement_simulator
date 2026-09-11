class_name CatalogPanel
extends PanelContainer

## The side panel: tools, catalogue, selected-item controls, paint swatches.
##
## Built in code rather than as a .tscn so it can be regenerated when the host
## page swaps the catalogue at runtime. Buttons are sized for thumbs -- this
## runs inside a storefront on phones as much as on desktops.

signal tool_selected(tool: int)
signal item_chosen(item: FurnitureItem)
signal snap_cycled
signal rotate_pressed
signal delete_pressed
signal finish_chosen(key: String)
signal swatch_chosen(color: Color)
signal paint_all_pressed
signal upload_pressed
signal clear_pressed
signal cart_pressed
signal export_pressed
## group is "sun" | "ambient" | "ceiling"; key is the setting within it.
signal light_changed(group: String, key: String, value: Variant)
signal lamp_changed(key: String, value: Variant)
signal add_lamp_pressed

enum Tool { PLACE, PAINT, WALK, LIGHT }
const TOOL_NAMES := ["Place", "Paint", "Walk", "Light"]

const BTN_MIN := Vector2(0, 40)

var catalog: Catalog

var _tool_buttons: Array[Button] = []
var _snap_btn: Button
var _items_box: VBoxContainer
var _selected_box: VBoxContainer
var _selected_label: Label
var _finish_opt: OptionButton
var _paint_box: VBoxContainer
var _walk_box: VBoxContainer
var _light_box: VBoxContainer
var _lamp_box: VBoxContainer
var _picker: ColorPickerButton
var _cart_btn: Button
var _catalog_box: VBoxContainer
## Sliders/toggles by "group/key", so a restored layout can move them.
var _light_controls: Dictionary = {}
var _syncing := false


func build(p_catalog: Catalog, on_web: bool) -> void:
	catalog = p_catalog
	custom_minimum_size = Vector2(250, 0)
	for c in get_children():
		c.queue_free()

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var title := Label.new()
	title.text = "Room Planner"
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)

	# --- tools
	var tools := HBoxContainer.new()
	root.add_child(tools)
	_tool_buttons.clear()
	for i in TOOL_NAMES.size():
		var b := Button.new()
		b.text = TOOL_NAMES[i]
		b.toggle_mode = true
		b.custom_minimum_size = BTN_MIN
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): tool_selected.emit(i))
		tools.add_child(b)
		_tool_buttons.append(b)
	set_tool(Tool.PLACE)

	# --- selected item (Place and Light tools): shared by furniture and lamps
	_selected_box = VBoxContainer.new()
	root.add_child(_selected_box)
	_selected_label = Label.new()
	_selected_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_selected_box.add_child(_selected_label)
	var row := HBoxContainer.new()
	_selected_box.add_child(row)
	var rot := Button.new()
	rot.text = "Rotate"
	rot.custom_minimum_size = BTN_MIN
	rot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rot.pressed.connect(func(): rotate_pressed.emit())
	row.add_child(rot)
	var del := Button.new()
	del.text = "Remove"
	del.custom_minimum_size = BTN_MIN
	del.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del.pressed.connect(func(): delete_pressed.emit())
	row.add_child(del)
	_finish_opt = OptionButton.new()
	_finish_opt.custom_minimum_size = BTN_MIN
	_finish_opt.item_selected.connect(func(i: int): finish_chosen.emit(_finish_opt.get_item_metadata(i)))
	_selected_box.add_child(_finish_opt)
	# Lamp controls live in the same slot as the finish picker: a selected
	# lamp has no timber to choose but a light to dim.
	_lamp_box = VBoxContainer.new()
	_selected_box.add_child(_lamp_box)
	_toggle(_lamp_box, "On", "lamp/on", true, func(v): lamp_changed.emit("on", v))
	_slider(_lamp_box, "Brightness", "lamp/energy", 0.0, 1.0, 0.6, func(v): lamp_changed.emit("energy", v))
	_slider(_lamp_box, "Warmth", "lamp/warmth", 0.0, 1.0, 0.7, func(v): lamp_changed.emit("warmth", v))
	_lamp_box.visible = false
	_selected_box.visible = false

	# --- placement section
	_catalog_box = VBoxContainer.new()
	_catalog_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_catalog_box)
	_snap_btn = Button.new()
	_snap_btn.custom_minimum_size = BTN_MIN
	_snap_btn.pressed.connect(func(): snap_cycled.emit())
	_catalog_box.add_child(_snap_btn)
	set_snap_name("Grid 25 cm")


	var cat_label := Label.new()
	cat_label.text = "Catalogue"
	_catalog_box.add_child(cat_label)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 160)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_catalog_box.add_child(scroll)
	_items_box = VBoxContainer.new()
	_items_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_items_box)
	refresh_items()

	var upload := Button.new()
	upload.text = "Upload model (.glb)"
	upload.custom_minimum_size = BTN_MIN
	upload.pressed.connect(func(): upload_pressed.emit())
	_catalog_box.add_child(upload)

	# --- paint section
	_paint_box = VBoxContainer.new()
	_paint_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_paint_box)
	var plabel := Label.new()
	plabel.text = "Tap a wall or the floor to paint it"
	plabel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_paint_box.add_child(plabel)
	var grid := GridContainer.new()
	grid.columns = 6
	_paint_box.add_child(grid)
	for sw in Painter.SWATCHES:
		var b := Button.new()
		b.custom_minimum_size = Vector2(34, 34)
		b.tooltip_text = sw[0]
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(sw[1])
		sb.corner_radius_top_left = 4
		sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4
		sb.corner_radius_bottom_right = 4
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.add_theme_stylebox_override("pressed", sb)
		var col := Color(sw[1])
		b.pressed.connect(func(): swatch_chosen.emit(col))
		grid.add_child(b)
	_picker = ColorPickerButton.new()
	_picker.text = "Custom colour"
	_picker.custom_minimum_size = BTN_MIN
	_picker.color = Color("#b7c4a8")
	_picker.color_changed.connect(func(c: Color): swatch_chosen.emit(c))
	_paint_box.add_child(_picker)
	var pall := Button.new()
	pall.text = "Paint all walls"
	pall.custom_minimum_size = BTN_MIN
	pall.pressed.connect(func(): paint_all_pressed.emit())
	_paint_box.add_child(pall)
	_paint_box.visible = false

	# --- light section
	_light_box = VBoxContainer.new()
	_light_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_light_box)
	var sun_label := Label.new()
	sun_label.text = "Sun"
	_light_box.add_child(sun_label)
	_slider(_light_box, "Height", "sun/elevation", 10.0, 80.0, 55.0, func(v): light_changed.emit("sun", "elevation", v))
	_slider(_light_box, "Direction", "sun/azimuth", 0.0, 360.0, 330.0, func(v): light_changed.emit("sun", "azimuth", v))
	_slider(_light_box, "Brightness", "sun/energy", 0.0, 1.0, 0.5, func(v): light_changed.emit("sun", "energy", v))
	_slider(_light_box, "Warmth", "sun/warmth", 0.0, 1.0, 0.35, func(v): light_changed.emit("sun", "warmth", v))
	_slider(_light_box, "Ambient", "ambient/energy", 0.0, 1.0, 0.3, func(v): light_changed.emit("ambient", "energy", v))
	_toggle(_light_box, "Ceiling light", "ceiling/on", false, func(v): light_changed.emit("ceiling", "on", v))
	_slider(_light_box, "Brightness", "ceiling/energy", 0.0, 1.0, 0.5, func(v): light_changed.emit("ceiling", "energy", v))
	_slider(_light_box, "Warmth", "ceiling/warmth", 0.0, 1.0, 0.6, func(v): light_changed.emit("ceiling", "warmth", v))
	var add_lamp := Button.new()
	add_lamp.text = "Add floor lamp"
	add_lamp.custom_minimum_size = BTN_MIN
	add_lamp.pressed.connect(func(): add_lamp_pressed.emit())
	_light_box.add_child(add_lamp)
	var lamp_hint := Label.new()
	lamp_hint.text = "Tap a lamp to dim it or remove it."
	lamp_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_light_box.add_child(lamp_hint)
	_light_box.visible = false

	# --- footer
	_walk_box = VBoxContainer.new()
	_walk_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_walk_box)
	var wlabel := Label.new()
	wlabel.text = "Click the room to look around.\nWASD to walk, E to pick up or put down.\nEsc frees the mouse."
	wlabel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_walk_box.add_child(wlabel)
	_walk_box.visible = false
	var clear := Button.new()
	clear.text = "Clear room"
	clear.custom_minimum_size = BTN_MIN
	clear.pressed.connect(func(): clear_pressed.emit())
	root.add_child(clear)
	_cart_btn = Button.new()
	_cart_btn.text = "Add room to cart" if on_web else "Print layout JSON"
	_cart_btn.custom_minimum_size = BTN_MIN
	_cart_btn.pressed.connect(func(): (cart_pressed if on_web else export_pressed).emit())
	root.add_child(_cart_btn)


## A labelled HSlider sized for thumbs. [param cb] gets the value on change,
## except while [method set_lighting] is moving the slider itself.
func _slider(parent: Control, text: String, key: String, lo: float, hi: float, value: float,
		cb: Callable) -> HSlider:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(76, 0)
	row.add_child(l)
	var sl := HSlider.new()
	sl.min_value = lo
	sl.max_value = hi
	sl.step = (hi - lo) / 100.0
	sl.value = value
	sl.custom_minimum_size = Vector2(0, 32)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.value_changed.connect(func(v: float):
		if not _syncing:
			cb.call(v))
	row.add_child(sl)
	_light_controls[key] = sl
	return sl


func _toggle(parent: Control, text: String, key: String, value: bool, cb: Callable) -> CheckButton:
	var t := CheckButton.new()
	t.text = text
	t.button_pressed = value
	t.custom_minimum_size = BTN_MIN
	t.toggled.connect(func(v: bool):
		if not _syncing:
			cb.call(v))
	parent.add_child(t)
	_light_controls[key] = t
	return t


## Move the light controls to match [param settings] (Lighting.to_dict()).
func set_lighting(settings: Dictionary) -> void:
	_syncing = true
	for group in settings:
		for key in settings[group]:
			_set_control("%s/%s" % [group, key], settings[group][key])
	_syncing = false


func _set_control(key: String, value: Variant) -> void:
	var c: Control = _light_controls.get(key)
	if c is HSlider:
		(c as HSlider).value = float(value)
	elif c is CheckButton:
		(c as CheckButton).button_pressed = bool(value)


func refresh_items() -> void:
	for c in _items_box.get_children():
		c.queue_free()
	for it in catalog.items:
		if it.is_light():
			continue   # fixtures are added from the Light tool
		var b := Button.new()
		var dims := "%d × %d × %d cm" % [roundi(it.size.x * 100), roundi(it.size.z * 100), roundi(it.size.y * 100)]
		b.text = "%s\n%s%s" % [it.name, dims, "  (est.)" if it.estimated else ""]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 48)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var item := it
		b.pressed.connect(func(): item_chosen.emit(item))
		_items_box.add_child(b)


func set_tool(tool: int) -> void:
	for i in _tool_buttons.size():
		_tool_buttons[i].button_pressed = (i == tool)
	if _catalog_box != null:
		_catalog_box.visible = (tool == Tool.PLACE)
	if _paint_box != null:
		_paint_box.visible = (tool == Tool.PAINT)
	if _walk_box != null:
		_walk_box.visible = (tool == Tool.WALK)
	if _light_box != null:
		_light_box.visible = (tool == Tool.LIGHT)
	if _selected_box != null and tool != Tool.PLACE and tool != Tool.LIGHT:
		_selected_box.visible = false


func set_snap_name(n: String) -> void:
	_snap_btn.text = "Snap: " + n


func show_selected(p: PlacedItem) -> void:
	if p == null:
		_selected_box.visible = false
		return
	_selected_box.visible = true
	_selected_label.text = p.item.name + ("" if p.valid else "  — doesn't fit here")
	if p.item.is_light():
		_finish_opt.visible = false
		_lamp_box.visible = true
		_syncing = true
		_set_control("lamp/on", p.light["on"])
		_set_control("lamp/energy", p.light["energy"])
		_set_control("lamp/warmth", p.light["warmth"])
		_syncing = false
		return
	_lamp_box.visible = false
	_finish_opt.clear()
	var idx := 0
	var sel := 0
	for key in p.item.finish_choices(catalog.finishes):
		_finish_opt.add_item(str(catalog.finishes[key].get("name", key)))
		_finish_opt.set_item_metadata(idx, key)
		if key == p.finish:
			sel = idx
		idx += 1
	_finish_opt.visible = idx > 0
	if idx > 0:
		_finish_opt.select(sel)
