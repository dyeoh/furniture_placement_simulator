class_name ModelLoader
extends RefCounted

## Turn an uploaded GLB/glTF into a catalogue item.
##
## The visual is the model's own scene; the collider is a box the size of its
## bounding box by default, because a convex hull of a hollow bookcase would
## be a solid block anyway and a box settles more predictably. Hull is opt-in.
##
## Models exported in millimetres are common for furniture (the store's own
## dimensions are in mm), so anything absurdly large is assumed to be mm and
## scaled down by 1000 -- a 1350-unit shelf is 1.35 m, not a skyscraper.

const MM_THRESHOLD := 50.0


static func from_bytes(bytes: PackedByteArray, item_name: String, use_hull := false) -> FurnitureItem:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_buffer(bytes, "", state)
	if err != OK:
		push_error("ModelLoader: glTF parse failed (%d)" % err)
		return null
	var scene := doc.generate_scene(state)
	if scene == null:
		push_error("ModelLoader: no scene in glTF")
		return null
	return from_scene(scene, item_name, use_hull)


static func from_scene(scene: Node, item_name: String, use_hull := false) -> FurnitureItem:
	var root := scene as Node3D
	if root == null:
		root = Node3D.new()
		root.add_child(scene)
	var points := PackedVector3Array()
	var bounds := _measure(root, Transform3D.IDENTITY, points)
	if not bounds.has_volume():
		push_error("ModelLoader: model has no mesh geometry")
		root.queue_free()
		return null

	var scale := 1.0
	if bounds.get_longest_axis_size() > MM_THRESHOLD:
		scale = 0.001
	var size := bounds.size * scale
	var centre := bounds.get_center() * scale

	# Wrap so the collider's centre is the item's origin regardless of where
	# the artist put the model's pivot.
	var wrapper := Node3D.new()
	wrapper.name = "Model"
	root.scale = Vector3.ONE * scale
	root.position = -centre
	wrapper.add_child(root)
	_own(wrapper, wrapper)
	var packed := PackedScene.new()
	packed.pack(wrapper)
	wrapper.queue_free()

	var it := FurnitureItem.new()
	it.id = "upload-" + item_name.get_basename().to_lower().replace(" ", "-")
	it.name = item_name.get_basename()
	it.size = size
	# Roughly the density of a solid-ish timber piece; uploads carry no mass.
	it.mass = clampf(size.x * size.y * size.z * 120.0, 3.0, 150.0)
	it.wall_snap = size.y > 0.9   # tall things live against walls
	it.color = Color(0.8, 0.8, 0.8)
	it.mesh_scene = packed
	if use_hull and points.size() >= 4:
		var scaled := PackedVector3Array()
		scaled.resize(points.size())
		for i in points.size():
			scaled[i] = (points[i] - bounds.get_center()) * scale
		it.shape = {"type": PhysicsBackend.SHAPE_HULL, "points": scaled}
	else:
		it.shape = {"type": PhysicsBackend.SHAPE_BOX, "size": size}
	return it


## Merged world-space AABB of every mesh under [param n]; also gathers vertices
## for an optional hull.
static func _measure(n: Node, xf: Transform3D, points: PackedVector3Array) -> AABB:
	var out := AABB()
	var first := true
	var local := xf
	if n is Node3D:
		local = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mesh: Mesh = (n as MeshInstance3D).mesh
		var box := local * mesh.get_aabb()
		out = box
		first = false
		# Hull points are subsampled: a 100k-vertex model does not need every
		# vertex to describe its silhouette, and the solver hulls it anyway.
		var verts := mesh.get_faces()
		var stride := maxi(1, verts.size() / 2000)
		for i in range(0, verts.size(), stride):
			points.append(local * verts[i])
	for c in n.get_children():
		var sub := _measure(c, local, points)
		if sub.has_volume() or sub.size != Vector3.ZERO:
			out = sub if first else out.merge(sub)
			first = false
	return out


static func _own(n: Node, owner: Node) -> void:
	for c in n.get_children():
		c.owner = owner
		_own(c, owner)
