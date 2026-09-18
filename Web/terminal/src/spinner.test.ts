import { describe, expect, it } from "vitest";

import { canvasMeasure, CYCLES, FRAME_MS, frameAt, type Measure, pickCycle } from "./spinner";

/**
 * The working mark turns (`agent-dashboard`, capability 5;
 * `design-foundation.md`, principle 4): a character cycle, its glyph
 * measured against the mark column rather than assumed, so the page never
 * ships a box. The measures here are fakes that stand for a font: one
 * that has braille at the cell width, one whose braille comes from a
 * fallback face and is wider, one with no matching glyph at all.
 */

const COLUMN = 7.2;
const [braille, quadrant, block] = CYCLES;
const glyphsOf = (cycle: typeof braille): string[] => [...cycle.frames, cycle.rest];

/** A font where every glyph in `wide` advances by `by` px more than a cell. */
const font = (wide: readonly string[], by = 4): Measure => (text) => COLUMN + (wide.includes(text) ? by : 0);

describe("pickCycle", () => {
  it("takes braille first when every frame and the rest glyph fit the column", () => {
    expect(pickCycle(font([]), COLUMN)?.name).toBe("braille");
  });

  it("falls to the quadrants when one braille frame comes from a wider face", () => {
    expect(pickCycle(font(["⠼"]), COLUMN)?.name).toBe("quadrant");
    // The rest glyph counts too: a cycle whose rest would move the line is out.
    expect(pickCycle(font([braille.rest]), COLUMN)?.name).toBe("quadrant");
  });

  it("falls to the block ramp when the quadrants do not fit either", () => {
    expect(pickCycle(font([...glyphsOf(braille), ...glyphsOf(quadrant)]), COLUMN)?.name).toBe("block");
  });

  it("picks nothing when no cycle fits, so the mark stays on the plain >", () => {
    expect(pickCycle(font(CYCLES.flatMap(glyphsOf)), COLUMN)).toBeNull();
    expect(pickCycle(font([]), 0), "no column to match").toBeNull();
  });

  it("allows a fraction of a pixel and no more", () => {
    expect(pickCycle(font(glyphsOf(braille), 0.4), COLUMN)?.name).toBe("braille");
    expect(pickCycle(font(glyphsOf(braille), 0.6), COLUMN)?.name).toBe("quadrant");
    expect(pickCycle(font(glyphsOf(braille), -0.6), COLUMN)?.name).toBe("quadrant");
  });

  it("names the three cycles in the foundation's order, ten braille frames first", () => {
    expect(CYCLES.map((c) => c.name)).toEqual(["braille", "quadrant", "block"]);
    expect(braille.frames).toEqual(["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]);
    expect(quadrant.frames).toEqual(["◐", "◓", "◑", "◒"]);
    expect(block.frames).toEqual(["▁", "▃", "▅", "▇"]);
    expect(FRAME_MS).toBe(90);
  });
});

describe("frameAt", () => {
  it("turns through the cycle and wraps", () => {
    expect([0, 1, 9, 10, 11].map((tick) => frameAt(braille, tick))).toEqual(["⠋", "⠙", "⠏", "⠋", "⠙"]);
    expect(frameAt(quadrant, 4)).toBe("◐");
  });
});

describe("canvasMeasure", () => {
  it("measures nothing where there is no canvas to draw on", () => {
    expect(canvasMeasure("400 12px monospace")).toBeNull();
  });
});

/**
 * The measurement, pinned. Read on 2026-09-18 from the page itself, with a
 * canvas in the body's computed font — `12px / 18px Menlo, Monaco, "Courier
 * New", monospace` — on the machine the round ran on: every braille glyph
 * advanced 8.2 px against a 7.22 px cell, because Menlo has no braille and
 * the fallback face is wider, while every quadrant and every block glyph
 * advanced 7.22. The page therefore turned through the quadrants and rested
 * on ●, which is what the live check saw. A face that carries braille at
 * the cell width picks braille, and the first block above proves that
 * path; this one proves the fallback the page actually took.
 */
describe("the measurement on 2026-09-18, Menlo", () => {
  const MENLO: Record<string, number> = {
    "0": 7.22, "⠋": 8.2, "⠙": 8.2, "⠹": 8.2, "⠸": 8.2, "⠼": 8.2, "⠴": 8.2, "⠦": 8.2, "⠧": 8.2, "⠇": 8.2, "⠏": 8.2, "⣿": 8.2,
    "◐": 7.22, "◓": 7.22, "◑": 7.22, "◒": 7.22, "●": 7.22, "▁": 7.22, "▃": 7.22, "▅": 7.22, "▇": 7.22, "█": 7.22,
  };
  const measure: Measure = (text) => {
    const width = MENLO[text];
    if (width === undefined) throw new Error(`unmeasured glyph ${text}`);
    return width;
  };

  it("skips braille, which the fallback face draws a pixel wide, and takes the quadrants", () => {
    const picked = pickCycle(measure, measure("0"));
    expect(picked?.name).toBe("quadrant");
    expect(picked?.rest).toBe("●");
    expect(picked && [0, 1, 2, 3].map((tick) => frameAt(picked, tick))).toEqual(["◐", "◓", "◑", "◒"]);
  });
});
