// Colour helpers. Godot colour literals and hex strings are sRGB; three's
// Color stores linear working-space values, so every literal goes through
// here once.

import { Color, SRGBColorSpace } from 'three';

/** A Godot `Color(r, g, b)` literal (sRGB components). */
export function srgb(r: number, g: number, b: number): Color {
  return new Color().setRGB(r, g, b, SRGBColorSpace);
}

/** `#rrggbb`, lower case, from a (linear) Color. */
export function toHex(c: Color): string {
  return '#' + c.getHexString();
}

/** Perceptual-ish luminance of the sRGB value, for picking legible ink. */
export function luminance(c: Color): number {
  const s = { r: 0, g: 0, b: 0 };
  c.getRGB(s, SRGBColorSpace);
  return 0.2126 * s.r + 0.7152 * s.g + 0.0722 * s.b;
}

/**
 * Colour that, multiplied with a texture whose linear mean albedo is [mean],
 * averages to [color]. ← SurfaceMaterials.normalised
 */
export function normalised(color: Color, mean: readonly [number, number, number]): Color {
  return new Color(
    color.r / Math.max(mean[0], 0.01),
    color.g / Math.max(mean[1], 0.01),
    color.b / Math.max(mean[2], 0.01));
}
