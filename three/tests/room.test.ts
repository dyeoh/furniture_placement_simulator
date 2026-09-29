import { expect, test } from 'bun:test';
import { Vector2, Vector4 } from 'three';
import { RoomBuilder } from '../src/room/room-builder';

test('a wall with no holes is one segment', () => {
  const segs = RoomBuilder.wallSegments(6, 2.7, []);
  expect(segs.length).toBe(1);
  expect(segs[0].toArray()).toEqual([-3, 0, 3, 2.7]);
});

test('a window splits a wall into left, below, above, right', () => {
  const segs = RoomBuilder.wallSegments(6, 2.7, [new Vector4(-0.6, 0.6, 0.9, 2.1)]);
  expect(segs.length).toBe(4);
  const area = segs.reduce((a, s) => a + (s.z - s.x) * (s.w - s.y), 0);
  expect(area).toBeCloseTo(6 * 2.7 - 1.2 * 1.2);
});

test('overlapping holes merge', () => {
  const segs = RoomBuilder.wallSegments(6, 2.7, [new Vector4(-1, 0.5, 1, 2), new Vector4(0, 1.5, 1, 2)]);
  const area = segs.reduce((a, s) => a + (s.z - s.x) * (s.w - s.y), 0);
  expect(area).toBeCloseTo(6 * 2.7 - 2.5 * 1);
});

test('subtractSpans', () => {
  const out = RoomBuilder.subtractSpans(new Vector2(0, 10), [new Vector2(2, 3), new Vector2(2.5, 4), new Vector2(9, 12)]);
  expect(out.map((v) => v.toArray())).toEqual([[0, 2], [4, 9]]);
});
