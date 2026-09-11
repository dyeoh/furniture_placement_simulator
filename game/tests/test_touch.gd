extends SceneTree

## The on-screen walkthrough controls, driven by synthetic touch events
## through the real viewport so the routing is what a phone would do: two
## fingers at once, one on the stick and one on the look pad, and the mouse
## events Godot synthesises from touches never leaking to the scene.

var _fails: Array[String] = []
var _looked := Vector2.ZERO
var _interacts := 0
var _leaked := 0


func _init() -> void:
	run.call_deferred()


func check(label: String, cond: bool, detail: String = "") -> void:
	print("  [%s] %s%s" % ["OK  " if cond else "FAIL", label, ("   " + detail) if detail != "" else ""])
	if not cond:
		_fails.append(label)


func touch(index: int, pressed: bool, at: Vector2) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = pressed
	ev.position = at
	Input.parse_input_event(ev)
	await process_frame


func drag(index: int, from: Vector2, to: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = to
	ev.relative = to - from
	Input.parse_input_event(ev)
	await process_frame


func run() -> void:
	await process_frame
	# The headless window is tiny and the project stretches to it; events are
	# easier to reason about at 1:1.
	get_root().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_root().size = Vector2i(1280, 720)
	# A node behind the controls: any pointer event that reaches it leaked.
	var leak_counter := Leak.new()
	leak_counter.owner_test = self
	get_root().add_child(leak_counter)
	var layer := CanvasLayer.new()
	get_root().add_child(layer)
	var tc := TouchControls.new()
	layer.add_child(tc)
	tc.look.connect(func(rel: Vector2): _looked += rel)
	tc.interact_pressed.connect(func(): _interacts += 1)
	await process_frame
	await process_frame

	var vp := get_root().size
	check("viewport has a size", vp.x > 0 and vp.y > 0, str(vp))
	var left := Vector2(vp.x * 0.2, vp.y * 0.7)
	var right := Vector2(vp.x * 0.75, vp.y * 0.5)

	# --- stick: base appears under the finger, vector follows it
	await touch(0, true, left)
	check("stick idle on press", tc.stick_vector().is_zero_approx())
	await drag(0, left, left + Vector2(0, -30))
	check("half forward", tc.stick_vector().is_equal_approx(Vector2(0, -0.5)), str(tc.stick_vector()))
	await drag(0, left + Vector2(0, -30), left + Vector2(200, 0))
	check("clamped to unit", tc.stick_vector().is_equal_approx(Vector2(1, 0)), str(tc.stick_vector()))

	# --- second finger on the look pad while the first still steers
	await touch(1, true, right)
	await drag(1, right, right + Vector2(40, -10))
	check("look pad drag", _looked.is_equal_approx(Vector2(40, -10)), str(_looked))
	check("stick unaffected by look finger", tc.stick_vector().is_equal_approx(Vector2(1, 0)))
	await touch(1, false, right + Vector2(40, -10))
	await drag(1, right, right + Vector2(40, 0))
	check("released finger no longer looks", _looked.is_equal_approx(Vector2(40, -10)), str(_looked))

	# --- a third finger on the stick zone does not steal the stick
	await touch(2, true, left + Vector2(60, 0))
	await drag(2, left + Vector2(60, 0), left + Vector2(60, -50))
	check("stick keeps its first finger", tc.stick_vector().is_equal_approx(Vector2(1, 0)), str(tc.stick_vector()))
	await touch(2, false, left + Vector2(60, -50))
	await touch(0, false, left + Vector2(200, 0))
	check("release centres the stick", tc.stick_vector().is_zero_approx())

	# --- the emulated mouse press Godot derives from a touch must be swallowed
	var mb := InputEventMouseButton.new()
	mb.device = InputEvent.DEVICE_ID_EMULATION
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.position = right
	Input.parse_input_event(mb)
	await process_frame
	var em := InputEventMouseMotion.new()
	em.device = InputEvent.DEVICE_ID_EMULATION
	em.position = right + Vector2(25, 0)
	em.relative = Vector2(25, 0)
	em.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(em)
	await process_frame
	check("emulated mouse swallowed", _leaked == 0, "%d leaked" % _leaked)
	check("emulated mouse does not double-drive the look", _looked.is_equal_approx(Vector2(40, -10)), str(_looked))
	var emu := InputEventMouseButton.new()
	emu.device = InputEvent.DEVICE_ID_EMULATION
	emu.button_index = MOUSE_BUTTON_LEFT
	emu.pressed = false
	emu.position = right + Vector2(25, 0)
	Input.parse_input_event(emu)
	await process_frame

	# --- a real mouse drives the pads too, for trying it on a desktop
	var real := InputEventMouseButton.new()
	real.button_index = MOUSE_BUTTON_LEFT
	real.pressed = true
	real.position = left
	Input.parse_input_event(real)
	await process_frame
	var mm := InputEventMouseMotion.new()
	mm.position = left + Vector2(0, -60)
	mm.relative = Vector2(0, -60)
	mm.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(mm)
	await process_frame
	check("mouse steers the stick", tc.stick_vector().is_equal_approx(Vector2(0, -1)), str(tc.stick_vector()))
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = left + Vector2(0, -60)
	Input.parse_input_event(up)
	await process_frame
	check("mouse release centres the stick", tc.stick_vector().is_zero_approx())

	# --- carry button label
	tc.set_carrying(true)
	check("carry label", tc._grab.text == "Put down")
	tc.set_carrying(false)
	check("carry label back", tc._grab.text == "Pick up")
	tc.queue_free()
	leak_counter.queue_free()
	await process_frame

	# --- pinch zoom in the planner view, through the real scene
	var scene: Node3D = load("res://scenes/showroom.tscn").instantiate()
	get_root().add_child(scene)
	for i in 5:
		await process_frame
	var before: float = scene._dist
	var a := Vector2(vp.x * 0.6, vp.y * 0.5)
	var b := Vector2(vp.x * 0.7, vp.y * 0.5)
	await touch(0, true, a)
	await touch(1, true, b)
	await drag(0, a, a - Vector2(80, 0))
	await drag(1, b, b + Vector2(80, 0))
	check("spreading fingers zooms in", scene._dist < before, "%.2f -> %.2f" % [before, scene._dist])
	var mid: float = scene._dist
	await drag(0, a - Vector2(80, 0), a)
	await drag(1, b + Vector2(80, 0), b)
	check("pinching fingers zooms out", scene._dist > mid, "%.2f -> %.2f" % [mid, scene._dist])
	await touch(1, false, b)
	await drag(0, a, a + Vector2(50, 0))
	check("one finger left does not zoom", is_equal_approx(scene._dist, before), "%.2f" % scene._dist)
	await touch(0, false, a + Vector2(50, 0))
	scene.queue_free()

	print("")
	if _fails.is_empty():
		print("ALL PASSED")
		quit(0)
	else:
		print("FAILED: %s" % ", ".join(_fails))
		quit(1)


## Counts pointer events that got past the controls to the scene.
class Leak extends Node:
	var owner_test: SceneTree

	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventMouseButton or event is InputEventScreenTouch:
			owner_test._leaked += 1
