class_name Lighting
extends RefCounted

## The room's light: a sun the shopper can swing round the sky, a ceiling
## light, and the ambient that stands in for light bouncing around the room.
## Floor lamps are furniture (see PlacedItem.light); this only owns what is
## not placeable.
##
## Ambient is not a fixed sky. It is bounce, so it comes from the light that
## is actually there: the sun through the windows (all of it when there is no
## ceiling), the ceiling light and the lamps, tinted by them. Switch
## everything off under a ceiling and the room goes dark; a lamp-lit evening
## is warm all over, not just in the lamp's pool. The "ambient" setting is
## how much of that the room bounces back (the Bounce slider).
##
## The Compatibility renderer adds its light passes in gamma space, so a sun
## at 0.5 plus ambient at 0.2 already brings a sunlit white wall to ~0.9. AgX
## tonemapping (which Compatibility does apply) rolls that off instead of
## clipping, so a bright sun or a ceiling light at full keeps some shape in
## a white bedspread rather than flattening it; exposure is nudged up to
## win back what AgX's desaturation takes from the midtones. No glow: the
## buffer is LDR, so everything white blooms, not just the lamps.

const SUN_MAX := 1.0
const AMBIENT_MAX := 1.0
const CEILING_MAX := 3.0

## Daylight to candle. Warmth 0 is a cool white, 1 an incandescent orange.
const COOL := Color(0.92, 0.95, 1.0)
const WARM := Color(1.0, 0.72, 0.45)

## Bounce per unit of each source (settings energies are 0..1).
const BOUNCE_CEILING := 0.35
const BOUNCE_LAMP := 0.25
## Glazing to daylight: a covered room gets the full sun's bounce once its
## windows are 40% of its floor area (1 / 2.5), proportionally less below.
const GLAZING_GAIN := 2.5
## Bounce slider x bounce x this = ambient energy. Chosen so the default room
## (no ceiling, sun 0.5, Bounce 0.3) keeps the 0.3 it always had.
const AMBIENT_GAIN := 2.0
## Moonlight: dark, not a black screen.
const AMBIENT_FLOOR := 0.02
## Daylight bounce colour: the old sky's average, a touch of the sun in it.
const DAYLIGHT := Color(0.78, 0.78, 0.79)
## The sky-ish fill light at the default sun, scaled with daylight in.
const FILL_ENERGY := 0.12

const DEFAULTS := {
	"sun": {"elevation": 55.0, "azimuth": 330.0, "energy": 0.5, "warmth": 0.35},
	"ambient": {"energy": 0.3},
	"ceiling": {"on": false, "energy": 0.5, "warmth": 0.6},
}

signal changed

var settings: Dictionary = DEFAULTS.duplicate(true)

var sun: DirectionalLight3D
var fill: DirectionalLight3D
var env: Environment
var ceiling_light: OmniLight3D
var ceiling_fitting: Node3D
var _fitting_size := Vector3.ZERO
var _sky_mat: ProceduralSkyMaterial
## Room and lamp state feeding the bounce (set_room, set_lamps).
var _has_ceiling := false
var _glazing := 0.0
var _lamp_energy := 0.0
var _lamp_warmth := 0.7
var _low_spec := false
## Room diagonal in metres; the sun's shadows only need to cover the room.
var _extent := 0.0


static func warmth_color(w: float) -> Color:
	return COOL.lerp(WARM, clampf(w, 0.0, 1.0))


func setup(parent: Node3D, room_height: float) -> void:
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.shadow_blur = 1.5
	sun.light_angular_distance = 1.0
	sun.directional_shadow_max_distance = 25.0
	parent.add_child(sun)
	fill = DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-30), deg_to_rad(150), 0)
	fill.light_energy = 0.12
	parent.add_child(fill)

	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.94, 0.93, 0.9)
	# Near-neutral: a blue sky tints every mattress blue and paints the
	# ceiling with the ground colour. Just enough gradient for reflections
	# to read as "a room", not a photograph of the outdoors.
	var sky_mat := ProceduralSkyMaterial.new()
	_sky_mat = sky_mat
	sky_mat.sky_top_color = Color(0.72, 0.76, 0.82)
	sky_mat.sky_horizon_color = Color(0.86, 0.85, 0.83)
	# Ground half bright: it is all the ceiling gets, standing in for bounce.
	sky_mat.ground_bottom_color = Color(0.8, 0.78, 0.74)
	sky_mat.ground_horizon_color = Color(0.86, 0.84, 0.8)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Reflections stay on the sky, dimmed with the bounce (see _apply_bounce).
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.15
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	ceiling_light = OmniLight3D.new()
	ceiling_light.omni_range = 9.0
	ceiling_light.omni_attenuation = 1.0
	ceiling_light.shadow_enabled = true
	ceiling_light.shadow_blur = 2.0
	parent.add_child(ceiling_light)
	# The model is nearly a metre of cord and globe; two thirds keeps it above
	# eye level in the walkthrough.
	_fitting_size = ModelLibrary.natural_size("modern_ceiling_lamp_01") * 0.65
	ceiling_fitting = ModelLibrary.instantiate("modern_ceiling_lamp_01", _fitting_size)
	if ceiling_fitting != null:
		# The globe wraps the bulb; letting it cast would shadow its own light.
		ModelLibrary.set_casts_shadow(ceiling_fitting, false)
		parent.add_child(ceiling_fitting)
	set_room_height(room_height)
	apply()


## Hang the fitting from the ceiling, and the light just inside its globe.
func set_room_height(room_height: float) -> void:
	var drop := 0.6
	if ceiling_fitting != null:
		ceiling_fitting.position = Vector3(0, room_height - _fitting_size.y * 0.5, 0)
		drop = _fitting_size.y
	ceiling_light.position = Vector3(0, room_height - drop + 0.15, 0)


## Low spec: no shadow from the ceiling light (the one positional shadow),
## a tighter, unblurred sun shadow.
func set_low_spec(low: bool) -> void:
	_low_spec = low
	ceiling_light.shadow_enabled = not low
	sun.shadow_blur = 0.0 if low else 1.5
	_apply_shadow_distance()
	RenderingServer.directional_shadow_atlas_set_size(2048 if low else 4096, true)


func set_sun(key: String, value: float) -> void:
	settings["sun"][key] = value
	apply()


func set_ambient(value: float) -> void:
	settings["ambient"]["energy"] = value
	apply()


func set_ceiling(key: String, value: Variant) -> void:
	settings["ceiling"][key] = value
	apply()


func apply() -> void:
	var s: Dictionary = settings["sun"]
	sun.rotation = Vector3(-deg_to_rad(float(s["elevation"])), deg_to_rad(float(s["azimuth"])), 0)
	sun.light_energy = float(s["energy"]) * SUN_MAX
	sun.light_color = warmth_color(float(s["warmth"]))
	var c: Dictionary = settings["ceiling"]
	ceiling_light.visible = bool(c["on"])
	ceiling_light.light_energy = float(c["energy"]) * CEILING_MAX
	ceiling_light.light_color = warmth_color(float(c["warmth"]))
	_apply_bounce()
	changed.emit()


## What the room is like, for daylight in: open to the sky, or covered with
## [param window_area] square metres of glass over [param floor_area].
func set_room(has_ceiling: bool, window_area: float, floor_area: float, extent := 0.0) -> void:
	_has_ceiling = has_ceiling
	_glazing = window_area / maxf(floor_area, 0.01)
	if extent > 0.0:
		_extent = extent
		_apply_shadow_distance()
	_apply_bounce()


## Spread the sun's shadow map over the room and a margin, not 25 m of
## nothing: a 6 x 5 m room gets about twice the shadow detail.
func _apply_shadow_distance() -> void:
	var d := 25.0 if _extent <= 0.0 else clampf(_extent * 1.5, 8.0, 25.0)
	sun.directional_shadow_max_distance = minf(d, 12.0) if _low_spec else d


## Lamps that are on: summed energy (0..1 each) and energy-weighted warmth.
func set_lamps(total_energy: float, mean_warmth: float) -> void:
	_lamp_energy = total_energy
	_lamp_warmth = mean_warmth
	_apply_bounce()


## Daylight reaching the room, 0..1 of the sun: all of it without a ceiling.
func daylight_in() -> float:
	var sun_e := float(settings["sun"]["energy"])
	return sun_e * (1.0 if not _has_ceiling else clampf(_glazing * GLAZING_GAIN, 0.0, 1.0))


## Ambient energy and colour from the light that is actually in the room.
func _apply_bounce() -> void:
	var day := daylight_in()
	var c: Dictionary = settings["ceiling"]
	var ceil_e := float(c["energy"]) * BOUNCE_CEILING if bool(c["on"]) else 0.0
	var lamp_e := _lamp_energy * BOUNCE_LAMP
	var bounce := day + ceil_e + lamp_e
	var col := DAYLIGHT
	if bounce > 1e-4:
		var sun_col := DAYLIGHT.lerp(warmth_color(float(settings["sun"]["warmth"])), 0.25)
		col = (sun_col * day + warmth_color(float(c["warmth"])) * ceil_e
			+ warmth_color(_lamp_warmth) * lamp_e) / bounce
	var energy := float(settings["ambient"]["energy"]) * AMBIENT_MAX * bounce * AMBIENT_GAIN
	env.ambient_light_color = col
	env.ambient_light_energy = maxf(AMBIENT_FLOOR, energy)
	# The fill is skylight, so only as much of it as daylight gets in; and
	# reflections of a bright sky in a dark room would make timber glow.
	fill.light_energy = FILL_ENERGY * day / 0.5
	_sky_mat.energy_multiplier = clampf(bounce / 0.5, 0.05, 1.0)

func to_dict() -> Dictionary:
	return settings.duplicate(true)


func from_dict(d: Dictionary) -> void:
	for group in DEFAULTS:
		if not (d.get(group) is Dictionary):
			continue
		for key in DEFAULTS[group]:
			if d[group].has(key):
				settings[group][key] = d[group][key]
	apply()
