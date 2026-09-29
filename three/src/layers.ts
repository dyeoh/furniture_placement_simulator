// Collision layer bits, shared by every system. ← game/src/layers.gd
//
// Furniture and the shopper are separate so the walkthrough can ask "what
// furniture did I touch" without the answer including the walls.

export const ROOM = 1 << 0; // floor and walls
export const FURNITURE = 1 << 1;
export const SHOPPER = 1 << 2;

export const ALL = 0xfffffff;

/** Everything solid the shopper stands on or bumps into. */
export const SOLID = ROOM | FURNITURE;
