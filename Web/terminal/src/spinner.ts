/**
 * The working mark turns (`design-foundation.md`, principle 4): a character
 * cycle at 90 ms a frame, not a CSS transition, so it costs no layout and
 * reads at a glance from across a room. This module is the pure part: the
 * one cycle and the frame for a tick. `sessions.ts` owns the timer and the
 * marks.
 *
 * The cycle is the quadrants the design draws, `◐ ◓ ◑ ◒`, and the mark
 * rests on `◐` (the `Components` frame, "Row marks", and the `SESSIONS`
 * legend; round 14, the human's word). The mark sits in a fixed 16 px
 * column at `--mark-size`, so a glyph's advance never moves the line, and
 * nothing is measured.
 */

/** The cycle: the frames the mark turns through and the glyph it rests
 * on, under `prefers-reduced-motion` and in the legend. */
export type Cycle = { frames: readonly string[]; rest: string };

/** The quadrant cycle, the only one. */
export const QUADRANT: Cycle = { frames: ["◐", "◓", "◑", "◒"], rest: "◐" };

/** One frame every 90 ms. */
export const FRAME_MS = 90;

/** The frame a cycle shows at a tick: the tick modulo the cycle's length. */
export function frameAt(cycle: Cycle, tick: number): string {
  return cycle.frames[((tick % cycle.frames.length) + cycle.frames.length) % cycle.frames.length];
}
