class_name BenchHooks
extends Node

## The sim's half of the web benchmark (tests/web/bench): a {type:"bench"}
## message that puts the view where a scenario wants it and reports what the
## engine spent. The three.js build answers the same messages
## (three/src/bench/hooks.ts), so the bench page drives both stacks through
## one contract; layouts go through the ordinary {type:"layout"}.
##
##   {type:"bench", op:"orbit", yaw, pitch, dist}   planner view, fixed angle
##   {type:"bench", op:"walk", x, z, yaw, intent:[x, z]}
##                                                  first person at (x, z),
##                                                  walking with [intent]
##   {type:"bench", op:"stats"}                     -> {type:"bench_stats", ...}
##
## `?ui=0` hides the panel, the HUD and the dimension lines, so the two
## builds can be screenshotted and compared for look (compare-look.mjs).

var showroom: Node
var ui_hidden := false


static func install(p_showroom: Node) -> BenchHooks:
	var hooks := BenchHooks.new()
	hooks.name = "BenchHooks"
	hooks.showroom = p_showroom
	hooks.ui_hidden = HostBridge.query_param("ui") == "0"
	p_showroom.add_child(hooks)
	p_showroom.bridge.bench_requested.connect(hooks._on_bench)
	return hooks


func _process(_dt: float) -> void:
	if not ui_hidden:
		return
	var panel: Control = showroom._panel
	if panel != null and panel.get_parent() is CanvasLayer:
		(panel.get_parent() as CanvasLayer).visible = false
	if is_instance_valid(showroom._dims):
		showroom._dims.visible = false


func _on_bench(m: Dictionary) -> void:
	match str(m.get("op", "")):
		"orbit":
			showroom.bench_intent = null
			if showroom._tool != CatalogPanel.Tool.PLACE:
				showroom._set_tool(CatalogPanel.Tool.PLACE)
			showroom._yaw = float(m.get("yaw", 0.35))
			showroom._pitch = float(m.get("pitch", -0.95))
			showroom._dist = float(m.get("dist", 9.0))
		"walk":
			if showroom._tool != CatalogPanel.Tool.WALK:
				showroom._set_tool(CatalogPanel.Tool.WALK)
			var shopper: Shopper = showroom.shopper
			if m.has("x"):
				shopper.position = Vector3(float(m["x"]), Shopper.HEIGHT * 0.5 + 0.05, float(m.get("z", 0.0)))
				shopper.velocity = Vector3.ZERO
			if m.has("yaw"):
				shopper.yaw = float(m["yaw"])
			var i: Array = m.get("intent", [0, 0])
			showroom.bench_intent = Vector3(float(i[0]), 0.0, float(i[1]))
		"stats":
			var steps := maxi(int(showroom.bench_physics_steps), 1)
			var placer: Placer = showroom.placer
			showroom.bridge.post({
				"type": "bench_stats",
				"engine": "godot",
				"physics": PhysicsFactory.backend_name(showroom.backend),
				"physics_ms": float(showroom.bench_physics_usec) / 1000.0 / steps,
				"physics_steps": int(showroom.bench_physics_steps),
				"calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				"triangles": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
				"engine_static_mb": float(OS.get_static_memory_usage()) / 1048576.0,
				"items": placer.items.size(),
				"settling": placer.any_settling(),
			})
			showroom.bench_physics_usec = 0
			showroom.bench_physics_steps = 0
