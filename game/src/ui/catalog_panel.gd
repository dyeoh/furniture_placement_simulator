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

enum Tool { PLACE, PAINT, WALK }

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
var _picker: ColorPickerButton
var _cart_btn: Button
var _catalog_box: VBoxContainer


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
	for i in ["Place", "Paint", "Walk"].size():
		var b := Button.new()
		b.text = ["Place", "Paint", "Walk"][i]
		b.toggle_mode = true
		b.custom_minimum_size = BTN_MIN
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): tool_selected.emit(i))
		tools.add_child(b)
		_tool_buttons.append(b)
	set_tool(Tool.PLACE)

	# --- placement section
	_catalog_box = VBoxContainer.new()
	_catalog_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_catalog_box)
	_snap_btn = Button.new()
	_snap_btn.custom_minimum_size = BTN_MIN
	_snap_btn.pressed.connect(func(): snap_cycled.emit())
	_catalog_box.add_child(_snap_btn)
	set_snap_name("Grid 25 cm")

	_selected_box = VBoxContainer.new()
	_catalog_box.add_child(_selected_box)
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
	_selected_box.visible = false

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


func refresh_items() -> void:
	for c in _items_box.get_children():
		c.queue_free()
	for it in catalog.items:
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


func set_snap_name(n: String) -> void:
	_snap_btn.text = "Snap: " + n


func show_selected(p: PlacedItem) -> void:
	if p == null:
		_selected_box.visible = false
		return
	_selected_box.visible = true
	_selected_label.text = p.item.name + ("" if p.valid else "  — doesn't fit here")
	_finish_opt.clear()
	var idx := 0
	var sel := 0
	for key in catalog.finishes:
		_finish_opt.add_item(str(catalog.finishes[key].get("name", key)))
		_finish_opt.set_item_metadata(idx, key)
		if key == p.finish:
			sel = idx
		idx += 1
	_finish_opt.visible = idx > 0
	if idx > 0:
		_finish_opt.select(sel)
