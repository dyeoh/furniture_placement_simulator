class_name DimensionLines
extends Node3D

## Architectural dimension lines for the room: width along an X edge, depth
## along a Z edge, each a bar with end ticks and a label, drawn on the floor
## just outside the walls.
##
## They sit on the side facing the camera -- the wall the cutaway has hidden
## -- so they are never behind a wall; [method update] moves them as the
## view orbits. Bars are thin boxes rather than line primitives because a
## one-pixel line disappears at phone resolutions.

const OFFSET := 0.35
const BAR := 0.015
const TICK := 0.25
const COLOR := Color(0.22, 0.22, 0.24)

var room: RoomBuilder
var _width_line: Node3D
var _depth_line: Node3D
var _mat: StandardMaterial3D


func build(p_room: RoomBuilder) -> void:
	room = p_room
	for c in get_children():
		c.queue_free()
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = COLOR
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_width_line = _line(room.width, "%.2f m" % room.width, false)
	_depth_line = _line(room.depth, "%.2f m" % room.depth, true)
	add_child(_width_line)
	add_child(_depth_line)
	update(["south", "east"])


## Move each line to the edge whose wall is cut away (facing the camera).
func update(hidden_walls: Array) -> void:
	if _width_line == null:
		return
	var h := room.half_extents()
	var out := room.wall_thickness + OFFSET
	var z := (h.y + out) if hidden_walls.has("south") or not hidden_walls.has("north") else -(h.y + out)
	var x := (h.x + out) if hidden_walls.has("east") or not hidden_walls.has("west") else -(h.x + out)
	_width_line.position = Vector3(0, 0.01, z)
	_depth_line.position = Vector3(x, 0.01, 0)


## A bar of [param length] along X (or Z when [param along_z]) centred on
## the node, ticks at both ends, label above the middle.
func _line(length: float, text: String, along_z: bool) -> Node3D:
	var n := Node3D.new()
	var axis := Vector3.BACK if along_z else Vector3.RIGHT
	var across := Vector3.RIGHT if along_z else Vector3.BACK
	_bar(n, axis * length + across * BAR + Vector3.UP * BAR, Vector3.ZERO)
	for s in [-1.0, 1.0]:
		_bar(n, axis * BAR + across * TICK + Vector3.UP * BAR, axis * (s * length * 0.5))
	var label := Label3D.new()
	label.text = text
	label.font_size = 48
	label.outline_size = 12
	label.modulate = COLOR
	label.outline_modulate = Color(1, 1, 1, 0.9)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = 0.00055
	label.no_depth_test = true
	label.position = Vector3.UP * 0.18
	n.add_child(label)
	return n


func _bar(parent: Node3D, size: Vector3, at: Vector3) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
