// Which generic model stands in for a product, by name. ← ModelLibrary.BY_NAME
// First match wins: "bedside table" is a side table, "coffee table" is not a
// dining table. Kept apart from model-library.ts so the catalogue (and its
// unit tests) do not pull in three's loaders.

const BY_NAME: [string, string][] = [
  ['bedside', 'side_table_01'], ['side table', 'side_table_01'],
  ['nightstand', 'side_table_01'],
  ['shelf', 'wooden_display_shelves_01'], ['shelves', 'wooden_display_shelves_01'],
  ['bookcase', 'wooden_display_shelves_01'],
  ['drawer', 'drawer_cabinet'], ['chest', 'drawer_cabinet'],
  ['tv', 'modern_wooden_cabinet'], ['wall unit', 'modern_wooden_cabinet'],
  ['buffet', 'modern_wooden_cabinet'], ['cabinet', 'modern_wooden_cabinet'],
  ['sideboard', 'modern_wooden_cabinet'],
  ['table', 'wooden_table_02'], ['desk', 'wooden_table_02'],
];

export function forName(name: string): string {
  const n = name.toLowerCase();
  for (const [key, model] of BY_NAME) if (n.includes(key)) return model;
  return '';
}
