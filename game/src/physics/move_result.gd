class_name MoveResult
extends RefCounted

## Result of a single [method PhysicsBackend.mover_move] call.
##
## Deliberately filled *in place* rather than returned fresh: a mover is stepped
## every physics frame, and allocating a new RefCounted per fighter per tick is
## pure garbage churn for no benefit. Callers own one of these for the lifetime
## of their mover and hand it back each frame.
##
## The plane data is the whole reason this project uses Box3D's mover API rather
## than a PhysicsServer3D character body: [member ground_normal] and
## [member wall_normal] are what make wall-jumping and arachnid wall-crawling
## fall out almost for free.

## World position after the move (cast + depenetration solve).
var position := Vector3.ZERO

## Velocity after clipping against every touching plane. This is NOT simply
## delta/dt -- deriving it that way bleeds energy incorrectly and ruins the
## feel of a wall slide.
var velocity := Vector3.ZERO

## True when a plane was classified as ground for the *active* up vector.
## Note "up" is per-locomotion-mode: for arachnid mode it is the surface normal,
## not world up, so a spider on a ceiling is legitimately "grounded".
var grounded := false
var ground_normal := Vector3.UP

## Set when a plane is steep enough to count as a wall. Drives wall-jumping.
var on_wall := false
var wall_normal := Vector3.ZERO

var on_ceiling := false

## Fraction [0,1] of the requested translation achieved by the swept cast.
## Less than 1 means we hit something mid-move; this is what prevents the
## tunneling that the upstream binding suffers from.
var cast_fraction := 1.0

## Every contact plane normal gathered this move. The array is reused across
## frames and may be longer than [member plane_count] -- always iterate to
## plane_count, never to size().
var plane_normals := PackedVector3Array()
var plane_count := 0

## Bodies the mover touched, for damage/interaction. Reused; see touched_count.
var touched := []
var touched_count := 0


func reset() -> void:
	grounded = false
	on_wall = false
	on_ceiling = false
	ground_normal = Vector3.UP
	wall_normal = Vector3.ZERO
	cast_fraction = 1.0
	plane_count = 0
	touched_count = 0
