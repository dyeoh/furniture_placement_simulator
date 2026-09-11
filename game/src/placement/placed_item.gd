class_name PlacedItem
extends RefCounted

## One piece of furniture in the room: a catalogue item plus where it is and
## what the solver is doing with it.
##
## An item has a physics body only when it has been let go of. While it is
## being dragged it is a ghost -- a mesh following the pointer -- because a
## rigid body driven around by the cursor fights every other body it passes
## through. Committing creates the body; picking it back up destroys it.

enum State { GHOST, SETTLING, PLACED, CARRIED }

var item: FurnitureItem
var state := State.GHOST
## Yaw in quarter turns, 0..3. Ninety-degree steps keep AABBs exact, which is
## what lets overlap validation be a plain box test.
var yaw := 0
## Centre of the footprint on the floor (y is the bottom face).
var position := Vector3.ZERO
## Finish key; empty means "the catalogue default".
var finish := ""
var body := -1
## Whether the current placement passes validation. Kept on the item so the
## HUD can flag a piece that was shoved into a wall during the walkthrough.
var valid := true
## Seconds spent in SETTLING. Sleep is only trusted after a short grace period
## because a body reports nothing useful on the frame it is created.
var settle_time := 0.0
## Extra height above the floor for the intended transform. Zero when placed;
## the walkthrough raises it to carry an item at chest height, and a drop
## commits the body from up there so it visibly falls.
var lift_y := 0.0
## Lamp state, for items whose catalogue entry is a light: on, energy (0..1
## of LIGHT_MAX_ENERGY), warmth (0 = daylight white, 1 = candle).
var light := {"on": true, "energy": 0.6, "warmth": 0.7}

const LIGHT_MAX_ENERGY := 3.0
const LIGHT_RANGE := 5.0

var node: Node3D
var _tint_mesh: MeshInstance3D
var _ghost_mat: StandardMaterial3D
## The timber material shared by every generated part, or null when the
## visual is a model (ModelLibrary retints those) or an upload.
var _wood_mat: StandardMaterial3D
var _model_node: Node3D
var _omni: OmniLight3D


func angle() -> float:
	return yaw * PI * 0.5


func basis() -> Basis:
	return Basis(Vector3.UP, angle())


## Footprint extents after rotation: quarter turns swap width and depth.
func rotated_size() -> Vector3:
	var s := item.size
	if yaw % 2 == 1:
		return Vector3(s.z, s.y, s.x)
	return s


func centre() -> Vector3:
	return position + Vector3.UP * item.size.y * 0.5


## Bounding box. From the live body when there is one (it may have tipped or
## been shoved), from the intended placement otherwise.
func aabb(backend: PhysicsBackend) -> AABB:
	if body >= 0 and backend != null:
		var xf := backend.body_get_transform(body)
		var half := item.size * 0.5
		var ext := Vector3(
			absf(xf.basis.x.x) * half.x + absf(xf.basis.y.x) * half.y + absf(xf.basis.z.x) * half.z,
			absf(xf.basis.x.y) * half.x + absf(xf.basis.y.y) * half.y + absf(xf.basis.z.y) * half.z,
			absf(xf.basis.x.z) * half.x + absf(xf.basis.y.z) * half.y + absf(xf.basis.z.z) * half.z)
		return AABB(xf.origin - ext, ext * 2.0)
	var rs := rotated_size()
	return AABB(centre() - rs * 0.5, rs)


func intended_transform() -> Transform3D:
	return Transform3D(basis(), centre() + Vector3.UP * lift_y)


#region Visuals

func build_visual(parent: Node3D, color: Color) -> void:
	node = Node3D.new()
	node.name = "Item_" + item.id
	parent.add_child(node)
	if item.mesh_scene != null:
		var inst := item.mesh_scene.instantiate()
		if inst is Node3D:
			(inst as Node3D).position = item.mesh_offset
		node.add_child(inst)
	elif item.model != "" and ModelLibrary.has(item.model):
		_model_node = ModelLibrary.instantiate(item.model, item.size)
		node.add_child(_model_node)
		ModelLibrary.tint(_model_node, item.model, color)
	else:
		_wood_mat = SurfaceMaterials.wood(color)
		node.add_child(FurnitureShapes.build(item.shape_kind, item.size, _wood_mat))
	if item.is_light():
		_omni = OmniLight3D.new()
		_omni.omni_range = LIGHT_RANGE
		_omni.omni_attenuation = 1.2
		_omni.shadow_enabled = false
		# Just under the shade, so the shade itself catches the light.
		_omni.position = Vector3(0, item.size.y * 0.5 - item.size.y * 0.3, 0)
		node.add_child(_omni)
		apply_light()
	# Validity overlay: a translucent shell slightly larger than the item. Used
	# instead of tinting the item's own material so uploaded models -- whose
	# materials we do not own -- get the same green/red feedback.
	var shell := BoxMesh.new()
	shell.size = item.size + Vector3.ONE * 0.02
	_tint_mesh = MeshInstance3D.new()
	_tint_mesh.mesh = shell
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.albedo_color = Color(0.3, 0.9, 0.4, 0.35)
	_tint_mesh.material_override = _ghost_mat
	_tint_mesh.visible = false
	node.add_child(_tint_mesh)
	sync_visual(null)


func set_color(color: Color) -> void:
	if _wood_mat != null:
		SurfaceMaterials.tint(_wood_mat, "oak_veneer_01", color)
	elif _model_node != null:
		ModelLibrary.tint(_model_node, item.model, color)


func set_light(on: bool, energy: float, warmth: float) -> void:
	light = {"on": on, "energy": clampf(energy, 0.0, 1.0), "warmth": clampf(warmth, 0.0, 1.0)}
	apply_light()


func apply_light() -> void:
	if _omni == null:
		return
	_omni.visible = bool(light["on"])
	_omni.light_energy = float(light["energy"]) * LIGHT_MAX_ENERGY
	_omni.light_color = Lighting.warmth_color(float(light["warmth"]))


func set_tint(show: bool, ok: bool) -> void:
	if _tint_mesh == null:
		return
	_tint_mesh.visible = show
	_ghost_mat.albedo_color = Color(0.3, 0.9, 0.4, 0.35) if ok else Color(0.95, 0.3, 0.25, 0.4)


func set_highlight(on: bool) -> void:
	if _tint_mesh == null:
		return
	if on:
		_tint_mesh.visible = true
		_ghost_mat.albedo_color = Color(1.0, 0.85, 0.3, 0.25)
	elif state != State.GHOST:
		_tint_mesh.visible = false


## Visual follows the body when there is one, the intended placement otherwise.
func sync_visual(backend: PhysicsBackend) -> void:
	if node == null:
		return
	if body >= 0 and backend != null:
		node.global_transform = backend.body_get_transform(body)
	else:
		node.global_transform = intended_transform()


func free_visual() -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
	node = null
	_tint_mesh = null
	_wood_mat = null
	_model_node = null
	_omni = null

#endregion


func to_dict() -> Dictionary:
	var d := {
		"id": item.id,
		"x": snappedf(position.x, 0.001), "z": snappedf(position.z, 0.001),
		"yaw": yaw, "finish": finish,
	}
	if item.is_light():
		d["light"] = light.duplicate()
	return d
