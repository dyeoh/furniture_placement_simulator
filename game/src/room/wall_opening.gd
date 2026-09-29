class_name WallOpening
extends RefCounted

## A window or door set into one wall. Architecture, not furniture: it has no
## body, never reaches the cart, and lives in the wall rather than on the
## floor. A window cuts a hole in the wall's visual (the sun comes in through
## it); a door is a closed leaf on the inside face and cuts nothing.
##
## Placement is one number: [member offset] along the wall's run -- X for the
## north and south walls, Z for east and west. Height comes from the
## catalogue's sill.

var item: FurnitureItem
var wall := "north"
var offset := 0.0
var valid := true
## Dragging it (new from the catalogue, or lifted off a wall).
var ghost := false
var node: Node3D
## On a cut-away wall: hidden, except the frame keeps casting its shadow.
var cut := false
var _tint_mesh: MeshInstance3D
var _tint_mat: StandardMaterial3D


func width() -> float:
	return item.size.x


func height() -> float:
	return item.size.y


func sill() -> float:
	return item.sill


func head() -> float:
	return item.sill + item.size.y


func cuts_wall() -> bool:
	return item.shape_kind == "window"


## Along-wall span [lo, hi].
func span() -> Vector2:
	return Vector2(offset - width() * 0.5, offset + width() * 0.5)


func to_dict() -> Dictionary:
	return {"id": item.id, "wall": wall, "offset": snappedf(offset, 0.001)}


#region Visuals

## Frame, glass or leaf, built in the wall's frame: the node sits on the wall's
## centre plane at the opening's centre, local +Z pointing into the room.
func build_visual(parent: Node3D, wall_thickness: float) -> void:
	free_visual()
	node = Node3D.new()
	node.name = "Opening_" + item.id
	parent.add_child(node)
	node.add_child(FurnitureShapes.build(item.shape_kind,
		Vector3(width(), height(), wall_thickness), null))
	var shell := BoxMesh.new()
	shell.size = Vector3(width(), height(), wall_thickness) + Vector3.ONE * 0.04
	_tint_mesh = MeshInstance3D.new()
	_tint_mesh.mesh = shell
	_tint_mat = StandardMaterial3D.new()
	_tint_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_tint_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tint_mesh.material_override = _tint_mat
	_tint_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.add_child(_tint_mesh)
	set_cut(cut)


func set_cut(p_cut: bool) -> void:
	cut = p_cut
	if node == null:
		return
	for g in node.find_children("*", "GeometryInstance3D", true, false):
		if g == _tint_mesh:
			continue
		if g.has_meta("caster"):
			(g as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY \
				if cut else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		else:
			(g as GeometryInstance3D).visible = not cut
	set_tint(ghost or not valid, valid)


## Same colours as PlacedItem: green fits, red does not, yellow selected.
func set_tint(show: bool, ok: bool) -> void:
	if _tint_mesh == null:
		return
	_tint_mesh.visible = show and not cut
	_tint_mat.albedo_color = Color(0.3, 0.9, 0.4, 0.35) if ok else Color(0.95, 0.3, 0.25, 0.4)


func set_highlight(on: bool) -> void:
	if _tint_mesh == null:
		return
	if on:
		_tint_mesh.visible = not cut
		_tint_mat.albedo_color = Color(1.0, 0.85, 0.3, 0.25)
	else:
		set_tint(ghost or not valid, valid)


func free_visual() -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
	node = null
	_tint_mesh = null
	_tint_mat = null

#endregion
