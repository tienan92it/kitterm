/**
 * The working mark turns (`design-foundation.md`, principle 4): a character
 * cycle at 90 ms a frame, not a CSS transition, so it costs no layout and
 * reads at a glance from across a room. This module is the pure part: the
 * three candidate cycles, the measurement that picks one, and the frame for
 * a tick. `sessions.ts` owns the timer and the marks.
 *
 * The glyph is measured, not assumed. A missing glyph renders as a box,
 * which is worse than no animation, and braille is not in every monospace
 * face. `pickCycle` tries the cycles in order and takes the first whose
 * every glyph, the rest glyph included, advances by the width of the mark
 * column in the page's own font. When none does, the mark rests on the
 * plain `>` the model prints (`markGlyph`), and nothing turns.
 */

/** One cycle: the frames the mark turns through and the glyph it rests
 * on under `prefers-reduced-motion`, the cycle's full cell. */
export type Cycle = { name: "braille" | "quadrant" | "block"; frames: readonly string[]; rest: string };

/** The candidates, in the order the foundation names them: braille, which
 * matches the pane; the quadrants; then the block ramp, which the usage
 * chart already proves. */
export const CYCLES: readonly Cycle[] = [
  { name: "braille", frames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"], rest: "⣿" },
  { name: "quadrant", frames: ["◐", "◓", "◑", "◒"], rest: "●" },
  { name: "block", frames: ["▁", "▃", "▅", "▇"], rest: "█" },
];

/** One frame every 90 ms. */
export const FRAME_MS = 90;

/** A glyph's advance width in a font, in px. `null` where the page cannot
 * measure (no canvas), which picks no cycle. */
export type Measure = (text: string) => number;

/**
 * The first cycle whose glyphs all fit the mark column, or null. `column`
 * is the advance width of one cell of the page's mono face, the `ch` the
 * mark column is set in; a glyph whose advance differs by more than
 * `tolerance` px comes from a fallback face or is double width, and either
 * would move the line every frame.
 */
export function pickCycle(measure: Measure, column: number, tolerance = 0.5): Cycle | null {
  if (!(column > 0)) return null;
  const fits = (glyph: string): boolean => Math.abs(measure(glyph) - column) <= tolerance;
  return CYCLES.find((cycle) => cycle.frames.every(fits) && fits(cycle.rest)) ?? null;
}

/** The frame a cycle shows at a tick: the tick modulo the cycle's length. */
export function frameAt(cycle: Cycle, tick: number): string {
  return cycle.frames[((tick % cycle.frames.length) + cycle.frames.length) % cycle.frames.length];
}

/** A measure over a canvas in `font`, the page's own stack as computed on
 * the body; null where there is no canvas to draw on. */
export function canvasMeasure(font: string): Measure | null {
  if (typeof document === "undefined" || typeof document.createElement !== "function") return null;
  const canvas = document.createElement("canvas");
  const context = typeof canvas.getContext === "function" ? canvas.getContext("2d") : null;
  if (!context) return null;
  context.font = font;
  return (text) => context.measureText(text).width;
}
