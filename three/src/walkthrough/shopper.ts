// A person walking through the room. ← shopper.gd
//
// A kinematic capsule on the backend's mover. Bumping is game-side: a mover
// stops at furniture but imparts little, so the shove is an impulse scaled by
// how hard the shopper walks into the piece. A side table skids; a bed does not.

import { Box3, Euler, Vector3 } from 'three';
import { SOLID } from '../layers';
import { MoveResult, type PhysicsBackend } from '../physics/backend';
import type { PlacedItem } from '../placement/placed-item';
import type { Placer } from '../placement/placer';

export const RADIUS = 0.3;
export const HEIGHT = 1.7;
const EYE = 1.55;
const SPEED = 2.2;
const ACCEL = 14;
const GRAVITY = 9.8;
const GROUND_DOT = 0.6428; // cos 50 degrees
const REACH = 1.4;
const CARRY_DISTANCE = 0.9;
const CARRY_MIN = 0.25;
const CARRY_HEIGHT = 0.6;
const UP = new Vector3(0, 1, 0);

export class Shopper {
  /** Steady push in newtons while walking into a piece; tunable live with [ ]. */
  shoveForce = 450;
  backend!: PhysicsBackend;
  placer!: Placer;
  /** Capsule centre (the mover convention on both backends). */
  position = new Vector3(0, HEIGHT * 0.5, 1.5);
  velocity = new Vector3();
  yaw = 0;
  pitch = 0;
  grounded = false;
  carrying: PlacedItem | null = null;
  private id = -1;
  private result = new MoveResult();

  setup(backend: PhysicsBackend, placer: Placer, spawnFeet: Vector3): void {
    this.backend = backend;
    this.placer = placer;
    this.position.copy(spawnFeet).addScaledVector(UP, HEIGHT * 0.5 + 0.05);
    this.velocity.set(0, 0, 0);
    this.carrying = null;
    this.id = backend.moverCreate(RADIUS, HEIGHT, SOLID);
  }

  release(): void {
    if (this.carrying) { this.placer.dropCarried(this.carrying); this.carrying = null; }
    if (this.id >= 0) { this.backend.moverDestroy(this.id); this.id = -1; }
  }

  forward(): Vector3 { return new Vector3(-Math.sin(this.yaw), 0, -Math.cos(this.yaw)); }
  right(): Vector3 { return new Vector3(Math.cos(this.yaw), 0, -Math.sin(this.yaw)); }
  feet(): Vector3 { return this.position.clone().addScaledVector(UP, -HEIGHT * 0.5); }
  eye(): Vector3 { return this.feet().addScaledVector(UP, EYE); }

  /** Camera orientation: yaw about Y, then pitch about X. */
  lookEuler(): Euler { return new Euler(this.pitch, this.yaw, 0, 'YXZ'); }

  turn(dx: number, dy: number): void {
    this.yaw -= dx;
    this.pitch = Math.min(Math.max(this.pitch - dy, -1.2), 1.2);
  }

  /** [intent]: desired horizontal direction, camera-relative (x right, z back), |v| <= 1. */
  step(intent: Vector3, dt: number): void {
    if (this.id < 0) return;
    const wish = this.forward().multiplyScalar(-intent.z).addScaledVector(this.right(), intent.x);
    if (wish.lengthSq() > 1) wish.normalize();
    const target = wish.clone().multiplyScalar(SPEED);
    const horiz = new Vector3(this.velocity.x, 0, this.velocity.z);
    const diff = target.sub(horiz);
    const maxStep = ACCEL * dt;
    if (diff.length() > maxStep) diff.setLength(maxStep);
    horiz.add(diff);
    this.velocity.x = horiz.x;
    this.velocity.z = horiz.z;
    this.velocity.y = this.grounded ? -0.5 : this.velocity.y - GRAVITY * dt;

    this.backend.moverMove(this.id, this.position, this.velocity, dt, UP, GROUND_DOT, this.result);
    this.position.copy(this.result.position);
    this.velocity.copy(this.result.velocity);
    this.grounded = this.result.grounded;

    this.shove(wish, dt);
    if (this.carrying) this.hold();
  }

  /** Keep the carried piece in front, inside the room and out of other furniture. */
  private hold(): void {
    const c = this.carrying!;
    const quarter = Math.round(this.yaw / (Math.PI * 0.5));
    c.yaw = ((quarter % 4) + 4) % 4;
    const half = c.rotatedSize().z * 0.5;
    let d = CARRY_DISTANCE;
    let at = new Vector3();
    for (;;) {
      at = this.placer.clampToRoom(c, this.feet().addScaledVector(this.forward(), d + half));
      if (d <= CARRY_MIN || !this.placer.blockedAt(c, at, CARRY_HEIGHT)) break;
      d -= 0.1;
    }
    this.placer.carryTo(c, at, quarter, CARRY_HEIGHT);
  }

  /** Push any piece the capsule is pressed against, in the direction of travel. */
  private shove(wish: Vector3, dt: number): void {
    if (wish.lengthSq() < 1e-4) return;
    const f = this.feet();
    const me = new Box3(new Vector3(f.x - RADIUS, f.y, f.z - RADIUS), new Vector3(f.x + RADIUS, f.y + HEIGHT, f.z + RADIUS))
      .expandByScalar(0.06);
    const impulse = new Vector3();
    for (const p of this.placer.items) {
      if (p.body < 0 || p === this.carrying) continue;
      const box = p.aabb();
      if (!me.intersectsBox(box)) continue;
      const c = box.getCenter(new Vector3());
      const toItem = c.clone().sub(this.position).setY(0);
      if (toItem.clone().normalize().dot(wish) < 0.3) continue;
      const contact = new Vector3(c.x, f.y + 0.9, c.z)
        .addScaledVector(toItem.normalize(), -box.getSize(new Vector3()).length() * 0.25);
      this.backend.bodyApplyImpulse(p.body, impulse.copy(wish).multiplyScalar(this.shoveForce * dt), contact);
    }
  }

  /** Pick up the nearest piece in front, or drop the one held. */
  interact(): void {
    if (this.carrying) { this.placer.dropCarried(this.carrying); this.carrying = null; return; }
    const probe = this.feet().addScaledVector(this.forward(), REACH * 0.6).addScaledVector(UP, 0.5);
    const p = this.placer.nearest(probe, REACH);
    if (p && this.placer.carry(p)) this.carrying = p;
  }
}
