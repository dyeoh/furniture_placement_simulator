import { expect, test } from 'bun:test';
import { FurnitureItem } from '../src/catalog/furniture-item';
import { catalog } from './helpers';

test('store W x D x H mm becomes scene X, Y (height), Z (depth) metres', () => {
  const shelf = catalog().find('segu-shelf')!;
  expect(shelf.size.toArray()).toEqual([1.35, 2.1, 0.3]);
  expect(shelf.model).toBe('wooden_display_shelves_01');
});

test('fixtures are appended: lamp, windows, door', () => {
  const c = catalog();
  expect(c.find('floor-lamp')!.isLight()).toBe(true);
  expect(c.find('window')!.isOpening()).toBe(true);
  expect(c.find('door')!.sill).toBe(0);
  expect(c.find('window')!.sill).toBeCloseTo(0.9);
});

test('generated shapes and generic models are chosen by name', () => {
  expect(catalog().find('naka-bed')!.shapeKind).toBe('bed');
  expect(FurnitureItem.fromDict({ name: 'Oak Bedside Table' }, {}).model).toBe('side_table_01');
  expect(FurnitureItem.fromDict({ name: 'Coat Rack' }, {}).shapeKind).toBe('rack');
});

test('a default finish the product is not sold in falls back to one it is', () => {
  const it = FurnitureItem.fromDict({ name: 'X', finish: 'nope', variants: { oak: 1, ash: 2 } }, {});
  expect(it.finish).toBe('oak');
  expect(it.variantFor('ash')).toBe(2);
});
