// PhysicsBackend on Box3D compiled to wasm (native/box3d). ← box3d_backend.gd
//
// The same engine the Godot build ships, so a Godot-vs-Three comparison on
// this backend measures the stacks, not the solvers.

import { Vector3 } from 'three';
import createBox3D from './box3d/box3d.js';
import type { BodyType, BoxShape, MoveResult, PhysicsBackend, Xform } from './backend';

interface Box3DModule {
  HEAPF32: Float32Array;
  _fps_io(): number;
  _fps_world_create(gx: number, gy: number, gz: number): void;
  _fps_world_destroy(): void;
  _fps_world_set_gravity(gx: number, gy: number, gz: number): void;
  _fps_world_step(dt: number, substeps: number): void;
  _fps_body_create(type: number, hx: number, hy: number, hz: number, density: number,
    friction: number, layer: number, mask: number): number;
  _fps_body_destroy(id: number): void;
  _fps_body_get_transform(id: number): void;
  _fps_body_apply_impulse(id: number): void;
  _fps_body_is_sleeping(id: number): number;
  _fps_mover_create(radius: number, height: number, mask: number): number;
  _fps_mover_destroy(id: number): void;
  _fps_mover_move(id: number, dt: number, groundDot: number): void;
}

/** Box3D's default; the Godot world uses it too. */
const SUBSTEPS = 4;

export class Box3DBackend implements PhysicsBackend {
  readonly name = 'Box3D (wasm)';
  lastStepMs = 0;
  private io: Float32Array;

  private constructor(private m: Box3DModule) {
    this.io = this.view();
    m._fps_world_create(0, -9.8, 0);
  }

  /** [options] go to the Emscripten factory: `locateFile` in the browser, `wasmBinary` in tests. */
  static async create(options: Parameters<typeof createBox3D>[0] = {}): Promise<Box3DBackend> {
    const m = (await createBox3D(options)) as Box3DModule;
    return new Box3DBackend(m);
  }

  // Memory growth detaches the old buffer, so re-view on demand.
  private view(): Float32Array {
    if (!this.io || this.io.buffer !== this.m.HEAPF32.buffer) {
      this.io = new Float32Array(this.m.HEAPF32.buffer, this.m._fps_io(), 64);
    }
    return this.io;
  }

  shutdown(): void {
    this.m._fps_world_destroy();
  }

  setGravity(g: Vector3): void {
    this.m._fps_world_set_gravity(g.x, g.y, g.z);
  }

  step(dt: number): void {
    const t0 = performance.now();
    this.m._fps_world_step(dt, SUBSTEPS);
    this.lastStepMs = performance.now() - t0;
  }

  moverCreate(radius: number, height: number, mask: number): number {
    return this.m._fps_mover_create(radius, height, mask);
  }

  moverDestroy(id: number): void {
    this.m._fps_mover_destroy(id);
  }

  moverMove(id: number, position: Vector3, velocity: Vector3, dt: number, up: Vector3,
    groundDot: number, out: MoveResult): void {
    const io = this.view();
    io[0] = position.x; io[1] = position.y; io[2] = position.z;
    io[3] = velocity.x; io[4] = velocity.y; io[5] = velocity.z;
    io[6] = up.x; io[7] = up.y; io[8] = up.z;
    this.m._fps_mover_move(id, dt, groundDot);
    const r = this.view();
    out.position.set(r[0], r[1], r[2]);
    out.velocity.set(r[3], r[4], r[5]);
    out.grounded = r[6] > 0.5;
    out.groundNormal.set(r[7], r[8], r[9]);
  }

  bodyCreate(shape: BoxShape, xf: Xform, type: BodyType, layer: number, mask: number): number {
    const io = this.view();
    io[0] = xf.p.x; io[1] = xf.p.y; io[2] = xf.p.z;
    io[3] = xf.q.x; io[4] = xf.q.y; io[5] = xf.q.z; io[6] = xf.q.w;
    const s = shape.size;
    return this.m._fps_body_create(type, s.x * 0.5, s.y * 0.5, s.z * 0.5,
      shape.density ?? 1, shape.friction ?? 0.6, layer, mask);
  }

  bodyDestroy(id: number): void {
    this.m._fps_body_destroy(id);
  }

  bodyGetTransform(id: number, out: Xform): Xform {
    this.m._fps_body_get_transform(id);
    const r = this.view();
    out.p.set(r[0], r[1], r[2]);
    out.q.set(r[3], r[4], r[5], r[6]);
    return out;
  }

  bodyApplyImpulse(id: number, impulse: Vector3, point: Vector3): void {
    const io = this.view();
    io[0] = impulse.x; io[1] = impulse.y; io[2] = impulse.z;
    io[3] = point.x; io[4] = point.y; io[5] = point.z;
    this.m._fps_body_apply_impulse(id);
  }

  bodyIsSleeping(id: number): boolean {
    return this.m._fps_body_is_sleeping(id) !== 0;
  }
}
