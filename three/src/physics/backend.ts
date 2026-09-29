// The one seam between game code and a physics engine. ← physics_backend.gd
//
// Nothing in placement/, walkthrough/ or room/ may call Box3D or Rapier
// directly. Only the dozen calls the showroom actually makes are here -- the
// Godot seam's pools, queries and events serve the brawler it came from, not
// this app.
//
// Ids are opaque ints: not indices, not stable across a backend swap.

import { Quaternion, Vector3 } from 'three';

export const BODY_STATIC = 0;
export const BODY_KINEMATIC = 1;
export const BODY_DYNAMIC = 2;
export type BodyType = typeof BODY_STATIC | typeof BODY_KINEMATIC | typeof BODY_DYNAMIC;

/** Every collider in the showroom is a box (catalogue pieces and the room). */
export interface BoxShape {
  /** Full extents in metres. */
  size: Vector3;
  density?: number;
  friction?: number;
}

export interface Xform {
  p: Vector3;
  q: Quaternion;
}

export function xform(p = new Vector3(), q = new Quaternion()): Xform {
  return { p, q };
}

/**
 * Result of one mover_move, filled in place: a mover steps every physics
 * frame and a fresh object per tick is garbage for nothing. ← move_result.gd
 */
export class MoveResult {
  position = new Vector3();
  velocity = new Vector3();
  grounded = false;
  groundNormal = new Vector3(0, 1, 0);
}

export interface PhysicsBackend {
  readonly name: string;
  /** Milliseconds the last step() spent inside the engine, for the bench. */
  readonly lastStepMs: number;

  shutdown(): void;
  setGravity(g: Vector3): void;
  step(dt: number): void;

  /** A kinematic capsule outside the solver, driven by game code. */
  moverCreate(radius: number, height: number, mask: number): number;
  moverDestroy(id: number): void;
  /** [position] is the capsule centre; [groundDot] the cosine of the steepest walkable slope. */
  moverMove(id: number, position: Vector3, velocity: Vector3, dt: number, up: Vector3,
    groundDot: number, out: MoveResult): void;

  bodyCreate(shape: BoxShape, xf: Xform, type: BodyType, layer: number, mask: number): number;
  bodyDestroy(id: number): void;
  bodyGetTransform(id: number, out: Xform): Xform;
  bodyApplyImpulse(id: number, impulse: Vector3, point: Vector3): void;
  bodyIsSleeping(id: number): boolean;
}
