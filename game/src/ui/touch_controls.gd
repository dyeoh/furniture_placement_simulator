class_name TouchControls
extends Control

## On-screen controls for the walkthrough on touch devices.
##
## The left of the screen is a floating stick -- the base appears under the
## first finger, so nobody has to hit a small target while looking at the
## room -- and the right is a look pad: drag to turn. A button toggles carry,
## another leaves Walk. Everything is drawn in code; nothing to ship.
##
## Only touch events (and, for trying it with a mouse, real mouse events)
## drive the pads. The mouse events Godot synthesises from touches are
## swallowed so a tap never reaches the scene as a click that would try to
## capture the pointer.

signal look(relative: Vector2)
signal interact_pressed
signal exit_pressed

const STICK_RADIUS := 60.0
const KNOB_RADIUS := 26.0
const MARGIN := 24.0
## Fraction of the width given to the stick; the rest is the look pad.
const STICK_ZONE := 0.45
const MOUSE_INDEX := -2

var _stick: Stick
var _pad: LookPad
var _grab: Button
var _carrying := false


## True on a touchscreen, or when asked for (`?touch=1` on the web, `--touch`
## after `--` on the desktop) so the controls can be tried with a mouse.
static func wanted() -> bool:
	if DisplayServer.is_touchscreen_available():
		return true
	if OS.get_cmdline_user_args().has("--touch"):
		return true
	return HostBridge.query_param("touch") == "1"


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_stick = Stick.new()
	_stick.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stick.anchor_right = STICK_ZONE
	add_child(_stick)

	_pad = LookPad.new()
	_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pad.anchor_left = STICK_ZONE
	_pad.dragged.connect(func(rel: Vector2): look.emit(rel))
	add_child(_pad)

	_grab = _button("Pick up", Vector2(150, 64), Control.PRESET_BOTTOM_RIGHT)
	_grab.pressed.connect(func(): interact_pressed.emit())
	var exit := _button("‹ Planner", Vector2(0, 44), Control.PRESET_TOP_LEFT)
	exit.pressed.connect(func(): exit_pressed.emit())


func _button(text: String, min_size: Vector2, preset: Control.LayoutPreset) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.add_theme_font_size_override("font_size", 18)
	add_child(b)
	# Offsets by hand: the preset's MINSIZE mode measures the label, not the
	# custom minimum, and the button would grow past the corner.
	var sz := min_size.max(b.get_combined_minimum_size())
	b.set_anchors_preset(preset)
	var right := preset == Control.PRESET_BOTTOM_RIGHT or preset == Control.PRESET_TOP_RIGHT
	var bottom := preset == Control.PRESET_BOTTOM_RIGHT or preset == Control.PRESET_BOTTOM_LEFT
	b.offset_left = -MARGIN - sz.x if right else MARGIN
	b.offset_right = -MARGIN if right else MARGIN + sz.x
	b.offset_top = -MARGIN - sz.y if bottom else MARGIN
	b.offset_bottom = -MARGIN if bottom else MARGIN + sz.y
	return b


## Desired walking direction, screen axes: x right, y down (= backwards).
func stick_vector() -> Vector2:
	return _stick.vector


func set_carrying(carrying: bool) -> void:
	if carrying == _carrying:
		return
	_carrying = carrying
	_grab.text = "Put down" if carrying else "Pick up"


## A Control that turns touches (and real mouse presses) into a per-finger
## press/drag/release stream and swallows everything else.
class TouchPad extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		accept_event()
		if event is InputEventScreenTouch:
			var t := event as InputEventScreenTouch
			_finger(t.index, t.pressed, t.position)
		elif event is InputEventScreenDrag:
			var d := event as InputEventScreenDrag
			_moved(d.index, d.position, d.relative)
		elif event.device == InputEvent.DEVICE_ID_EMULATION:
			return   # a touch we already saw, dressed as a mouse
		elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			var mb := event as InputEventMouseButton
			_finger(MOUSE_INDEX, mb.pressed, mb.position)
		elif event is InputEventMouseMotion:
			var mm := event as InputEventMouseMotion
			_moved(MOUSE_INDEX, mm.position, mm.relative)

	func _finger(_index: int, _pressed: bool, _at: Vector2) -> void:
		pass

	func _moved(_index: int, _at: Vector2, _relative: Vector2) -> void:
		pass


class Stick extends TouchPad:
	var vector := Vector2.ZERO
	var _index := -1
	var _origin := Vector2.ZERO

	func _finger(index: int, pressed: bool, at: Vector2) -> void:
		if pressed and _index == -1:
			_index = index
			_origin = at
			vector = Vector2.ZERO
		elif not pressed and index == _index:
			_index = -1
			vector = Vector2.ZERO
		queue_redraw()

	func _moved(index: int, at: Vector2, _relative: Vector2) -> void:
		if index != _index:
			return
		vector = ((at - _origin) / STICK_RADIUS).limit_length(1.0)
		queue_redraw()

	func _draw() -> void:
		var c := _origin if _index != -1 else Vector2(MARGIN + STICK_RADIUS, size.y - MARGIN - STICK_RADIUS)
		draw_circle(c, STICK_RADIUS, Color(0, 0, 0, 0.18))
		draw_arc(c, STICK_RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.6), 2.0, true)
		draw_circle(c + vector * STICK_RADIUS, KNOB_RADIUS, Color(1, 1, 1, 0.8))


class LookPad extends TouchPad:
	signal dragged(relative: Vector2)
	var _index := -1
	var _last := Vector2.ZERO

	func _finger(index: int, pressed: bool, at: Vector2) -> void:
		if pressed and _index == -1:
			_index = index
			_last = at
		elif not pressed and index == _index:
			_index = -1

	## The delta is taken from this pad's own last position, never from the
	## event's `relative`: with two fingers down the web build computes that
	## against the other finger now and then, which jerks the camera.
	func _moved(index: int, at: Vector2, _relative: Vector2) -> void:
		if index != _index:
			return
		dragged.emit(at - _last)
		_last = at

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var text := "drag to look around"
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, 14).x
		draw_string(font, Vector2((size.x - w) * 0.5, size.y - MARGIN - 20), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0, 0, 0, 0.4))
