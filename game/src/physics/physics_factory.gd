class_name PhysicsFactory
extends RefCounted

## Chooses which [PhysicsBackend] the game runs on.
##
## The whole point of the abstraction is that this is the only place the choice
## is made. Flip the project setting (or pass an override) and nothing above
## the interface changes.

enum Backend { BOX3D, GODOT }

const SETTING := "furniture_sim/physics/backend"


## Reads the project setting, falling back to Box3D, and degrades gracefully to
## the Godot backend when the extension is missing rather than hard-crashing on
## a fresh clone that has not built the GDExtension yet.
static func create(override: int = -1) -> PhysicsBackend:
	var want: int = override
	if want < 0:
		want = int(ProjectSettings.get_setting(SETTING, Backend.BOX3D))

	if want == Backend.BOX3D:
		if ClassDB.class_exists("Box3DWorld") and ClassDB.class_exists("Box3DCharacterBody"):
			return Box3DBackend.new()
		push_warning(
			"Box3D GDExtension not loaded -- falling back to Godot physics. "
			+ "Build engine/box3d-godot (scons platform=macos arch=arm64 target=editor) "
			+ "and confirm bin/box3d.gdextension has a macos.editor entry. "
			+ "Note the fallback does NOT behave identically: the shopper mover's "
			+ "contact planes are approximated, so walking into furniture feels different.")
	return GodotPhysicsBackend.new()


static func backend_name(b: PhysicsBackend) -> String:
	if b is Box3DBackend:
		return "Box3D"
	return "Godot (Jolt)"
