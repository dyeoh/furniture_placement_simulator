// Flat C API over Box3D for the Three.js build.
//
// The game only needs a dozen calls through its PhysicsBackend seam (see
// src/physics/backend.ts), so this exposes exactly those and nothing else:
// no Godot, no embind, just int handles and one shared float buffer. Vectors
// and transforms cross the JS/wasm boundary through fps_io() -- a static
// scratch array JS views as a Float32Array -- so a frame's worth of calls
// allocates nothing on either side.
//
// The mover is Box3DCharacterBody::move_and_slide
// (engine/box3d-godot/godot/src/box3d_character.cpp) without the Godot node:
// collide -> solve planes -> sweep, five passes, then the missing normal
// impulse on any dynamic body the capsule pressed into. Keeping it line for
// line is what makes the Box3D numbers comparable across the two stacks.

#include "box3d/box3d.h"
#include "box3d/collision.h"
#include "box3d/math_functions.h"

#include <emscripten/emscripten.h>
#include <float.h>
#include <string.h>

#define MAX_BODIES 4096
#define MAX_MOVERS 16
#define MAX_PLANES 64

static float g_io[64];
static b3WorldId g_world;
static int g_has_world = 0;

static b3BodyId g_bodies[MAX_BODIES];
static int g_body_used[MAX_BODIES];

typedef struct Mover
{
	int used;
	float radius, height;
	uint64_t mask;
} Mover;
static Mover g_movers[MAX_MOVERS];

EMSCRIPTEN_KEEPALIVE float* fps_io( void )
{
	return g_io;
}

EMSCRIPTEN_KEEPALIVE void fps_world_create( float gx, float gy, float gz )
{
	if ( g_has_world )
		b3DestroyWorld( g_world );
	b3WorldDef def = b3DefaultWorldDef();
	def.gravity = ( b3Vec3 ){ gx, gy, gz };
	// Single-threaded: the store embed cannot be cross-origin isolated, so
	// there are no wasm threads -- the same constraint as the Godot build.
	def.workerCount = 1;
	g_world = b3CreateWorld( &def );
	g_has_world = 1;
	memset( g_body_used, 0, sizeof( g_body_used ) );
	memset( g_movers, 0, sizeof( g_movers ) );
}

EMSCRIPTEN_KEEPALIVE void fps_world_destroy( void )
{
	if ( g_has_world )
		b3DestroyWorld( g_world );
	g_has_world = 0;
	memset( g_body_used, 0, sizeof( g_body_used ) );
	memset( g_movers, 0, sizeof( g_movers ) );
}

EMSCRIPTEN_KEEPALIVE void fps_world_set_gravity( float gx, float gy, float gz )
{
	b3World_SetGravity( g_world, ( b3Vec3 ){ gx, gy, gz } );
}

EMSCRIPTEN_KEEPALIVE void fps_world_step( float dt, int substeps )
{
	b3World_Step( g_world, dt, substeps );
}

// io[0..6] = position xyz, rotation quaternion xyzw.
EMSCRIPTEN_KEEPALIVE int fps_body_create( int type, float hx, float hy, float hz, float density, float friction,
										  uint32_t layer, uint32_t mask )
{
	int id = -1;
	for ( int i = 0; i < MAX_BODIES; ++i )
	{
		if ( !g_body_used[i] )
		{
			id = i;
			break;
		}
	}
	if ( id < 0 )
		return -1;

	b3BodyDef bd = b3DefaultBodyDef();
	bd.type = (b3BodyType)type;
	bd.position = ( b3Pos ){ g_io[0], g_io[1], g_io[2] };
	bd.rotation = ( b3Quat ){ { g_io[3], g_io[4], g_io[5] }, g_io[6] };
	b3BodyId body = b3CreateBody( g_world, &bd );

	b3ShapeDef sd = b3DefaultShapeDef();
	sd.density = density;
	sd.baseMaterial.friction = friction;
	sd.filter.categoryBits = layer;
	sd.filter.maskBits = mask;
	b3BoxHull box = b3MakeBoxHull( hx, hy, hz );
	b3CreateHullShape( body, &sd, &box.base );

	g_bodies[id] = body;
	g_body_used[id] = 1;
	return id;
}

EMSCRIPTEN_KEEPALIVE void fps_body_destroy( int id )
{
	if ( id < 0 || id >= MAX_BODIES || !g_body_used[id] )
		return;
	b3DestroyBody( g_bodies[id] );
	g_body_used[id] = 0;
}

// Writes io[0..6] = position xyz, rotation quaternion xyzw.
EMSCRIPTEN_KEEPALIVE void fps_body_get_transform( int id )
{
	b3WorldTransform t = b3Body_GetTransform( g_bodies[id] );
	g_io[0] = (float)t.p.x;
	g_io[1] = (float)t.p.y;
	g_io[2] = (float)t.p.z;
	g_io[3] = t.q.v.x;
	g_io[4] = t.q.v.y;
	g_io[5] = t.q.v.z;
	g_io[6] = t.q.s;
}

// Writes 7 floats per body for [ids] read from io as floats: bulk sync for
// the per-frame transform pull, one call instead of one per piece.
EMSCRIPTEN_KEEPALIVE void fps_body_get_transforms( const int* ids, int count, float* out )
{
	for ( int i = 0; i < count; ++i )
	{
		b3WorldTransform t = b3Body_GetTransform( g_bodies[ids[i]] );
		float* o = out + i * 7;
		o[0] = (float)t.p.x;
		o[1] = (float)t.p.y;
		o[2] = (float)t.p.z;
		o[3] = t.q.v.x;
		o[4] = t.q.v.y;
		o[5] = t.q.v.z;
		o[6] = t.q.s;
	}
}

// io[0..2] impulse, io[3..5] world point.
EMSCRIPTEN_KEEPALIVE void fps_body_apply_impulse( int id )
{
	b3Body_ApplyLinearImpulse( g_bodies[id], ( b3Vec3 ){ g_io[0], g_io[1], g_io[2] },
							   ( b3Pos ){ g_io[3], g_io[4], g_io[5] }, true );
}

EMSCRIPTEN_KEEPALIVE int fps_body_is_sleeping( int id )
{
	return b3Body_IsAwake( g_bodies[id] ) ? 0 : 1;
}

EMSCRIPTEN_KEEPALIVE int fps_mover_create( float radius, float height, uint32_t mask )
{
	for ( int i = 0; i < MAX_MOVERS; ++i )
	{
		if ( !g_movers[i].used )
		{
			g_movers[i] = ( Mover ){ 1, radius, height, mask };
			return i;
		}
	}
	return -1;
}

EMSCRIPTEN_KEEPALIVE void fps_mover_destroy( int id )
{
	if ( id >= 0 && id < MAX_MOVERS )
		g_movers[id].used = 0;
}

typedef struct MoverContext
{
	b3CollisionPlane planes[MAX_PLANES];
	b3Vec3 points[MAX_PLANES];
	b3ShapeId shapes[MAX_PLANES];
	int count;
} MoverContext;

static bool plane_result_cb( b3ShapeId shape, const b3PlaneResult* results, int count, void* context )
{
	MoverContext* ctx = (MoverContext*)context;
	for ( int i = 0; i < count && ctx->count < MAX_PLANES; ++i )
	{
		b3CollisionPlane* cp = &ctx->planes[ctx->count];
		cp->plane = results[i].plane;
		cp->pushLimit = FLT_MAX;
		cp->push = 0.0f;
		cp->clipVelocity = true;
		ctx->points[ctx->count] = results[i].point;
		ctx->shapes[ctx->count] = shape;
		ctx->count += 1;
	}
	return true;
}

// In:  io[0..2] capsule centre, io[3..5] velocity, io[6..8] up.
// Out: io[0..2] new centre, io[3..5] clipped velocity, io[6] grounded (0/1),
//      io[7..9] ground normal, io[10] plane count.
EMSCRIPTEN_KEEPALIVE void fps_mover_move( int id, float dt, float ground_dot )
{
	const Mover* m = &g_movers[id];
	const b3Vec3 start = { g_io[0], g_io[1], g_io[2] };
	const b3Vec3 velocity = { g_io[3], g_io[4], g_io[5] };
	const b3Vec3 up = { g_io[6], g_io[7], g_io[8] };

	float half = m->height * 0.5f - m->radius;
	if ( half < 0.0f )
		half = 0.0f;
	b3Capsule mover;
	mover.center1 = ( b3Vec3 ){ 0.0f, -half, 0.0f };
	mover.center2 = ( b3Vec3 ){ 0.0f, half, 0.0f };
	mover.radius = m->radius;

	b3QueryFilter filter = b3DefaultQueryFilter();
	filter.maskBits = m->mask;

	const int MAX_ITERATIONS = 5;
	const float TOLERANCE = 0.01f;

	b3Pos position = ( b3Pos ){ start.x, start.y, start.z };
	const b3Pos target = ( b3Pos ){ start.x + velocity.x * dt, start.y + velocity.y * dt, start.z + velocity.z * dt };

	static MoverContext ctx;
	static MoverContext last;
	static b3Pos last_origin;
	last.count = 0;
	for ( int iteration = 0; iteration < MAX_ITERATIONS; ++iteration )
	{
		ctx.count = 0;
		b3World_CollideMover( g_world, position, &mover, filter, plane_result_cb, &ctx );
		b3Vec3 target_delta = b3SubPos( target, position );
		b3PlaneSolverResult result = b3SolvePlanes( target_delta, ctx.planes, ctx.count );
		last = ctx;
		last_origin = position;

		float fraction = b3World_CastMover( g_world, position, &mover, result.delta, filter, NULL, NULL );
		b3Vec3 delta = b3MulSV( fraction, result.delta );
		position = b3OffsetPos( position, delta );
		if ( b3LengthSquared( delta ) < TOLERANCE * TOLERANCE )
			break;
	}

	// The mover is infinitely heavy: push dynamic bodies it pressed into with
	// the normal impulse a contact solver would have applied.
	for ( int i = 0; i < last.count; ++i )
	{
		b3BodyId body = b3Shape_GetBody( last.shapes[i] );
		if ( !b3Body_IsValid( body ) || b3Body_GetType( body ) != b3_dynamicBody )
			continue;
		const b3Pos point = b3OffsetPos( last_origin, last.points[i] );
		const b3Vec3 normal = b3Neg( last.planes[i].plane.normal );
		const float inv_mass = b3Body_GetInverseMass( body );
		const b3Matrix3 inv_i = b3Body_GetWorldInverseRotationalInertia( body );
		const b3Pos center = b3Body_GetWorldCenter( body );
		const b3Vec3 r = b3SubPos( point, center );
		const b3Vec3 rn = b3Cross( r, normal );
		const float k = inv_mass + b3Dot( rn, b3MulMV( inv_i, rn ) );
		const float normal_mass = k > 0.0f ? 1.0f / k : 0.0f;
		const b3Vec3 vb = b3Add( b3Body_GetLinearVelocity( body ), b3Cross( b3Body_GetAngularVelocity( body ), r ) );
		const float vn = b3Dot( b3Sub( vb, velocity ), normal );
		const float impulse = b3MaxFloat( -normal_mass * vn, 0.0f );
		if ( impulse > 0.0f )
			b3Body_ApplyLinearImpulse( body, b3MulSV( impulse, normal ), point, true );
	}

	b3Vec3 clipped = last.count > 0 ? b3ClipVector( velocity, last.planes, last.count ) : velocity;

	// Floor: the plane whose normal is closest to up, within the ground cone.
	float best = ground_dot;
	b3Vec3 floor_n = { 0.0f, 0.0f, 0.0f };
	int grounded = 0;
	for ( int i = 0; i < last.count; ++i )
	{
		const b3Vec3 n = last.planes[i].plane.normal;
		const float d = b3Dot( n, up );
		if ( d >= best )
		{
			best = d;
			floor_n = n;
			grounded = 1;
		}
	}

	g_io[0] = (float)position.x;
	g_io[1] = (float)position.y;
	g_io[2] = (float)position.z;
	g_io[3] = clipped.x;
	g_io[4] = clipped.y;
	g_io[5] = clipped.z;
	g_io[6] = (float)grounded;
	g_io[7] = grounded ? floor_n.x : up.x;
	g_io[8] = grounded ? floor_n.y : up.y;
	g_io[9] = grounded ? floor_n.z : up.z;
	g_io[10] = (float)last.count;
}
