class_name Quality
extends RefCounted

## Two tiers, so a 2017 phone gets a usable planner rather than a slideshow.
##
## Low spec renders 3D at 70% and drops the expensive shadows. It is chosen
## up front from a `?quality=low|high` hint or a weak-looking device
## (little memory, few cores), and otherwise by a watchdog: if frames
## average slower than 30 fps for a few seconds after start-up, drop down
## once and stay there -- flapping between tiers looks worse than either.

signal changed(low: bool)

const RENDER_SCALE_LOW := 0.7
const SLOW_FRAME_MS := 33.0
## Ignore the first seconds: shader compilation and the initial settle make
## everything look slow.
const GRACE_SECONDS := 6.0
const WINDOW_SECONDS := 3.0

var low := false
## A hint or a weak device decided; the watchdog stays out of it.
var forced := false

var _elapsed := 0.0
var _window := 0.0
var _frames := 0


func decide() -> void:
	var hint := HostBridge.query_param("quality")
	if hint == "low" or hint == "high":
		low = (hint == "low")
		forced = true
	elif device_looks_slow():
		low = true
		forced = true


## Off the web there is nothing to ask; on it, memory and cores are all a
## browser will say. 2 GB / 2 cores is the 2016 phone tier.
static func device_looks_slow() -> bool:
	if not HostBridge.is_web():
		return false
	return bool(JavaScriptBridge.eval(
		"(navigator.deviceMemory || 8) <= 2 || (navigator.hardwareConcurrency || 4) <= 2", true))


func apply(viewport: Viewport, lighting: Lighting) -> void:
	viewport.scaling_3d_scale = RENDER_SCALE_LOW if low else 1.0
	viewport.positional_shadow_atlas_size = 1024 if low else 4096
	lighting.set_low_spec(low)


func label() -> String:
	return "low" if low else "high"


## Call once per rendered frame with the frame's delta.
func watch(dt: float) -> void:
	if low or forced:
		return
	_elapsed += dt
	if _elapsed < GRACE_SECONDS:
		return
	_window += dt
	_frames += 1
	if _window < WINDOW_SECONDS:
		return
	var avg_ms := _window / float(_frames) * 1000.0
	_window = 0.0
	_frames = 0
	if avg_ms > SLOW_FRAME_MS:
		low = true
		changed.emit(true)
