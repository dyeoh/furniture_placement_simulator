class_name ModelLibrary
extends RefCounted

## Generic CC0 furniture models (Poly Haven) standing in for the store's
## products, which publish no geometry.
##
## A model is stretched per axis into the catalogue item's box, so a 1350 mm
## shelf and a 1400 mm one are the same mesh at two sizes; the collider is
## still the box, so nothing physical depends on the mesh. Each model's albedo
## is tinted towards the chosen finish the same way the room textures are:
## divide by the model's own mean colour, multiply by the finish.

const DIR := "res://assets/models/"

## model -> { mean: linear mean albedo of its main wood texture,
##            yaw: turn so the model's front faces +Z (the room side of a
##                 wall-snapped item) }
## Means measured once from the 1K albedo maps.
const MODELS := {
	"wooden_display_shelves_01": {"mean": Color(0.522, 0.304, 0.165), "yaw": -PI * 0.5},
	"modern_wooden_cabinet": {"mean": Color(0.050, 0.025, 0.010), "yaw": 0.0},
	"drawer_cabinet": {"mean": Color(0.187, 0.105, 0.051), "yaw": 0.0},
	"side_table_01": {"mean": Color(0.243, 0.109, 0.040), "yaw": 0.0},
	"wooden_table_02": {"mean": Color(0.253, 0.078, 0.024), "yaw": 0.0},
	"modern_ceiling_lamp_01": {"mean": Color(0.5, 0.5, 0.5), "yaw": 0.0},
}

## Name keywords, first match wins. Order matters: "bedside table" is a side
## table, "coffee table" is not a dining table.
const BY_NAME := [
	["bedside", "side_table_01"], ["side table", "side_table_01"],
	["nightstand", "side_table_01"],
	["shelf", "wooden_display_shelves_01"], ["shelves", "wooden_display_shelves_01"],
	["bookcase", "wooden_display_shelves_01"],
	["drawer", "drawer_cabinet"], ["chest", "drawer_cabinet"],
	["tv", "modern_wooden_cabinet"], ["wall unit", "modern_wooden_cabinet"],
	["buffet", "modern_wooden_cabinet"], ["cabinet", "modern_wooden_cabinet"],
	["sideboard", "modern_wooden_cabinet"],
	["table", "wooden_table_02"], ["desk", "wooden_table_02"],
]

## A tint no brighter than this many times the texture, so a dark walnut
## model asked to be pale oak lifts as far as it can without its highlights
## blowing out to white.
const MAX_GAIN := 3.0

static var _scenes: Dictionary = {}
static var _bounds: Dictionary = {}


static func for_name(item_name: String) -> String:
	var n := item_name.to_lower()
	for pair in BY_NAME:
		if n.contains(pair[0]):
			return pair[1]
	return ""


static func has(model: String) -> bool:
	return MODELS.has(model)


## Bounding-box size of the model as authored, for pieces used at their own
## scale (the ceiling fitting).
static func natural_size(model: String) -> Vector3:
	if _scene(model) == null:
		return Vector3.ONE * 0.3
	return (_bounds[model] as AABB).size


## The model fitted into a box of [param size] centred on the returned node's
## origin. Null when the model is unknown or fails to load.
static func instantiate(model: String, size: Vector3) -> Node3D:
	var scene := _scene(model)
	if scene == null:
		return null
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return null
	# Bounds were measured with the yaw applied, so scaling happens in the
	# turned frame: a turn, then a per-axis stretch, then a recentre.
	var bounds: AABB = _bounds[model]
	var wrapper := Node3D.new()
	wrapper.name = "Model_" + model
	var s := Vector3(size.x / maxf(bounds.size.x, 1e-3), size.y / maxf(bounds.size.y, 1e-3),
		size.z / maxf(bounds.size.z, 1e-3))
	var turned := Node3D.new()
	turned.rotation.y = float(MODELS[model]["yaw"])
	turned.add_child(inst)
	var fitted := Node3D.new()
	fitted.scale = s
	fitted.position = -bounds.get_center() * s
	fitted.add_child(turned)
	wrapper.add_child(fitted)
	return wrapper


## Retint every surface of [param node] towards [param color]. Materials are
## duplicated once per placed item so two shelves can wear different timbers.
static func tint(node: Node, model: String, color: Color) -> void:
	var mean: Color = MODELS.get(model, {}).get("mean", Color(0.5, 0.5, 0.5))
	var t := SurfaceMaterials.normalised(color, mean)
	var lin := t.srgb_to_linear()
	var gain := maxf(lin.r, maxf(lin.g, lin.b))
	if gain > MAX_GAIN:
		t = (lin * (MAX_GAIN / gain)).linear_to_srgb()
		t.a = 1.0
	for mi in _meshes(node):
		for i in mi.mesh.get_surface_count():
			var m := mi.get_active_material(i)
			if m == null:
				continue
			if not mi.has_meta("owned_%d" % i):
				m = m.duplicate()
				mi.set_surface_override_material(i, m)
				mi.set_meta("owned_%d" % i, true)
			if m is StandardMaterial3D:
				(m as StandardMaterial3D).albedo_color = t


static func _scene(model: String) -> PackedScene:
	if not MODELS.has(model):
		return null
	if not _scenes.has(model):
		var path := "%s%s/%s.gltf" % [DIR, model, model]
		var scene: PackedScene = load(path)
		if scene == null:
			push_error("ModelLibrary: cannot load %s" % path)
			return null
		_scenes[model] = scene
		var probe := scene.instantiate()
		var turn := Transform3D(Basis(Vector3.UP, float(MODELS[model]["yaw"])), Vector3.ZERO)
		_bounds[model] = ModelLoader._measure(probe, turn, PackedVector3Array())
		probe.free()
	return _scenes[model]


## Meshes that should not throw shadows (a lamp fitting around its own bulb).
static func set_casts_shadow(node: Node, casts: bool) -> void:
	for mi in _meshes(node):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out
