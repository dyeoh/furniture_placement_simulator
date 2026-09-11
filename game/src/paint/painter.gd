class_name Painter
extends RefCounted

## Sims-style surface painting: pick a swatch, click a wall or the floor.
##
## Deliberately tiny. Materials belong to RoomBuilder (one per surface); this
## only decides which surface the pointer is over and what colour to hand it.

signal painted(surface: String, color: Color)

## Wall paints, then timber tones matching the catalogue finishes so a floor
## can be "the same oak as the shelf". Names show in the swatch tooltip.
const SWATCHES := [
	["Chalk", "#eeebe3"], ["Linen", "#e3d9c6"], ["Sage", "#b7c4a8"],
	["Eucalyptus leaf", "#7f9a7a"], ["Clay", "#c9967a"], ["Terracotta", "#b3624a"],
	["Ochre", "#d9a441"], ["Slate", "#6c7480"], ["Ink", "#2f3540"],
	["Blush", "#e8c4c0"], ["Sky", "#b9cfe0"], ["Charcoal", "#3d3b3a"],
	["American Oak", "#d2b48c"], ["Eucalyptus", "#b58a5a"], ["Blackwood", "#6b4a2f"],
	["Japanese Black", "#2b2b2e"], ["Pale concrete", "#cfcac2"], ["Warm white", "#f6f1e7"],
]

var room: RoomBuilder
var color := Color("#b7c4a8")
var hover := ""


func setup(p_room: RoomBuilder) -> void:
	room = p_room


func set_hover(surface: String) -> void:
	if surface == hover:
		return
	_set_emission(hover, false)
	hover = surface
	_set_emission(hover, true)


func clear_hover() -> void:
	set_hover("")


func apply(surface: String) -> bool:
	if surface == "" or not room.materials.has(surface):
		return false
	room.paint(surface, color)
	painted.emit(surface, color)
	return true


func apply_all_walls() -> void:
	for s in RoomBuilder.SURFACES:
		if s != "floor":
			room.paint(s, color)
			painted.emit(s, color)


## Hover feedback as a faint emissive lift rather than a colour change, so the
## preview never lies about what the swatch will look like.
func _set_emission(surface: String, on: bool) -> void:
	if surface == "" or not room.materials.has(surface):
		return
	var m: StandardMaterial3D = room.materials[surface]
	m.emission_enabled = on
	m.emission = Color(0.35, 0.33, 0.25)
	m.emission_energy_multiplier = 1.0
