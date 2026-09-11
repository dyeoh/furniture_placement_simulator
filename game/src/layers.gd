class_name Layers
extends RefCounted

## Collision layer bits, shared by every system.
##
## Three is all a showroom needs. Furniture and the shopper are separate so the
## walkthrough can ask "what furniture did I touch" without the answer including
## the walls, and so a carried item can be masked out of the shopper's own
## collisions while it is being driven to the carry point.

const ROOM      := 1 << 0   # floor and walls
const FURNITURE := 1 << 1
const SHOPPER   := 1 << 2

const ALL := 0xFFFFFFF

## Everything solid the shopper stands on or bumps into.
const SOLID := ROOM | FURNITURE
