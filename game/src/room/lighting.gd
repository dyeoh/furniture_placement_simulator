class_name Lighting
extends RefCounted

## The room's light: a sun the shopper can swing round the sky, ambient from
## a procedural sky, and a ceiling light. Floor lamps are furniture (see
## PlacedItem.light); this only owns what is not placeable.
##
## The Compatibility renderer does not tonemap, and it adds its light passes
## in gamma space, so a sun at 0.5 plus ambient at 0.2 already brings a
## sunlit white wall to ~0.9. The defaults sit just under clipping; the
## sliders can push past it, and pale timber will blow out if they do --
## that is the shopper's call, as it would be with a real dimmer.

const SUN_MAX := 1.0
const AMBIENT_MAX := 1.0
const CEILING_MAX := 3.0

## Daylight to candle. Warmth 0 is a cool white, 1 an incandescent orange.
const COOL := Color(0.92, 0.95, 1.0)
const WARM := Color(1.0, 0.72, 0.45)

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
	sky_mat.sky_top_color = Color(0.72, 0.76, 0.82)
	sky_mat.sky_horizon_color = Color(0.86, 0.85, 0.83)
	# Ground half bright: it is all the ceiling gets, standing in for bounce.
	sky_mat.ground_bottom_color = Color(0.8, 0.78, 0.74)
	sky_mat.ground_horizon_color = Color(0.86, 0.84, 0.8)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
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
	var natural := ModelLibrary.natural_size("modern_ceiling_lamp_01") * 0.65
	ceiling_fitting = ModelLibrary.instantiate("modern_ceiling_lamp_01", natural)
	var drop := 0.6
	if ceiling_fitting != null:
		ceiling_fitting.position = Vector3(0, room_height - natural.y * 0.5, 0)
		# The globe wraps the bulb; letting it cast would shadow its own light.
		ModelLibrary.set_casts_shadow(ceiling_fitting, false)
		drop = natural.y
		parent.add_child(ceiling_fitting)
	ceiling_light.position = Vector3(0, room_height - drop + 0.15, 0)
	apply()


## Low spec: no shadow from the ceiling light (the one positional shadow),
## a tighter, unblurred sun shadow.
func set_low_spec(low: bool) -> void:
	ceiling_light.shadow_enabled = not low
	sun.shadow_blur = 0.0 if low else 1.5
	sun.directional_shadow_max_distance = 12.0 if low else 25.0
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
	env.ambient_light_energy = float(settings["ambient"]["energy"]) * AMBIENT_MAX
	var c: Dictionary = settings["ceiling"]
	ceiling_light.visible = bool(c["on"])
	ceiling_light.light_energy = float(c["energy"]) * CEILING_MAX
	ceiling_light.light_color = warmth_color(float(c["warmth"]))
	changed.emit()


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
