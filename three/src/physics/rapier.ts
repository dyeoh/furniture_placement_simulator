// PhysicsBackend on Rapier (@dimforge/rapier3d-compat). ← godot_backend.gd's role
//
// The alternative engine, as Jolt is in the Godot build: Rapier is the common
// choice for a JS stack, so the bench answers what Box3D-in-wasm buys over it.
//
// The mover is Rapier's KinematicCharacterController over a body-less capsule
// collider. Box3D's mover lives outside the world entirely; the closest Rapier
// gets is a collider that takes part in queries but not in the solver (solver
// groups filter 0), so furniture never collides with the shopper's capsule and
// is only pushed by the controller's own impulses plus the Shopper's shove.

import RAPIER from '@dimforge/rapier3d-compat';
import { Vector3 } from 'three';
import { BODY_DYNAMIC, BODY_STATIC, type BodyType, type BoxShape, type MoveResult,
  type PhysicsBackend, type Xform } from './backend';
import { SHOPPER } from '../layers';

/** Rapier interaction groups: membership in the high 16 bits, filter in the low. */
function groups(layer: number, mask: number): number {
  return ((layer & 0xffff) << 16) | (mask & 0xffff);
}

interface Mover {
  collider: RAPIER.Collider;
  controller: RAPIER.KinematicCharacterController;
  mask: number;
}

/** Mass the controller imparts to dynamic bodies it walks into (kg). */
const SHOPPER_MASS = 75;

export class RapierBackend implements PhysicsBackend {
  readonly name = 'Rapier';
  lastStepMs = 0;
  private world: RAPIER.World;
  private bodies = new Map<number, RAPIER.RigidBody>();
  private movers = new Map<number, Mover>();
  private nextId = 1;
  private readonly tmp = new Vector3();

  private constructor() {
    this.world = new RAPIER.World({ x: 0, y: -9.8, z: 0 });
  }

  static async create(): Promise<RapierBackend> {
    await RAPIER.init();
    return new RapierBackend();
  }

  shutdown(): void {
    for (const m of this.movers.values()) this.world.removeCharacterController(m.controller);
    this.world.free();
    this.bodies.clear();
    this.movers.clear();
  }

  setGravity(g: Vector3): void {
    this.world.gravity = { x: g.x, y: g.y, z: g.z };
  }

  step(dt: number): void {
    const t0 = performance.now();
    this.world.timestep = dt;
    this.world.step();
    this.lastStepMs = performance.now() - t0;
  }

  moverCreate(radius: number, height: number, mask: number): number {
    const half = Math.max(height * 0.5 - radius, 0);
    const desc = RAPIER.ColliderDesc.capsule(half, radius)
      .setCollisionGroups(groups(SHOPPER, mask))
      .setSolverGroups(groups(SHOPPER, 0));
    const collider = this.world.createCollider(desc);
    const controller = this.world.createCharacterController(0.01);
    controller.setApplyImpulsesToDynamicBodies(true);
    controller.setCharacterMass(SHOPPER_MASS);
    controller.setSlideEnabled(true);
    const id = this.nextId++;
    this.movers.set(id, { collider, controller, mask });
    return id;
  }

  moverDestroy(id: number): void {
    const m = this.movers.get(id);
    if (!m) return;
    this.world.removeCharacterController(m.controller);
    this.world.removeCollider(m.collider, false);
    this.movers.delete(id);
  }

  moverMove(id: number, position: Vector3, velocity: Vector3, dt: number, up: Vector3,
    groundDot: number, out: MoveResult): void {
    const m = this.movers.get(id)!;
    m.controller.setUp({ x: up.x, y: up.y, z: up.z });
    m.controller.setMaxSlopeClimbAngle(Math.acos(Math.min(Math.max(groundDot, -1), 1)));
    m.collider.setTranslation({ x: position.x, y: position.y, z: position.z });
    const d = this.tmp.copy(velocity).multiplyScalar(dt);
    m.controller.computeColliderMovement(m.collider, { x: d.x, y: d.y, z: d.z },
      RAPIER.QueryFilterFlags.EXCLUDE_SENSORS, groups(SHOPPER, m.mask));
    const mv = m.controller.computedMovement();
    out.position.set(position.x + mv.x, position.y + mv.y, position.z + mv.z);
    m.collider.setTranslation({ x: out.position.x, y: out.position.y, z: out.position.z });

    // Clip the velocity against what was hit, as Box3D's b3ClipVector does:
    // walking into a wall must not keep pushing into it next frame.
    out.velocity.copy(velocity);
    out.grounded = m.controller.computedGrounded();
    out.groundNormal.copy(up);
    for (let i = 0; i < m.controller.numComputedCollisions(); i++) {
      const c = m.controller.computedCollision(i);
      if (!c) continue;
      // normal2 is on the obstacle, pointing out of it towards the character.
      const n = this.tmp.set(c.normal2.x, c.normal2.y, c.normal2.z);
      const vn = out.velocity.dot(n);
      if (vn < 0) out.velocity.addScaledVector(n, -vn);
      if (n.dot(up) >= groundDot) out.groundNormal.copy(n);
    }
  }

  bodyCreate(shape: BoxShape, xf: Xform, type: BodyType, layer: number, mask: number): number {
    const bd = type === BODY_DYNAMIC ? RAPIER.RigidBodyDesc.dynamic()
      : type === BODY_STATIC ? RAPIER.RigidBodyDesc.fixed()
        : RAPIER.RigidBodyDesc.kinematicPositionBased();
    bd.setTranslation(xf.p.x, xf.p.y, xf.p.z)
      .setRotation({ x: xf.q.x, y: xf.q.y, z: xf.q.z, w: xf.q.w });
    const body = this.world.createRigidBody(bd);
    const s = shape.size;
    const cd = RAPIER.ColliderDesc.cuboid(s.x * 0.5, s.y * 0.5, s.z * 0.5)
      .setDensity(shape.density ?? 1)
      .setFriction(shape.friction ?? 0.6)
      .setCollisionGroups(groups(layer, mask));
    this.world.createCollider(cd, body);
    const id = this.nextId++;
    this.bodies.set(id, body);
    return id;
  }

  bodyDestroy(id: number): void {
    const b = this.bodies.get(id);
    if (!b) return;
    this.world.removeRigidBody(b);
    this.bodies.delete(id);
  }

  bodyGetTransform(id: number, out: Xform): Xform {
    const b = this.bodies.get(id)!;
    const t = b.translation();
    const r = b.rotation();
    out.p.set(t.x, t.y, t.z);
    out.q.set(r.x, r.y, r.z, r.w);
    return out;
  }

  bodyApplyImpulse(id: number, impulse: Vector3, point: Vector3): void {
    this.bodies.get(id)?.applyImpulseAtPoint(
      { x: impulse.x, y: impulse.y, z: impulse.z }, { x: point.x, y: point.y, z: point.z }, true);
  }

  bodyIsSleeping(id: number): boolean {
    return this.bodies.get(id)?.isSleeping() ?? true;
  }
}
