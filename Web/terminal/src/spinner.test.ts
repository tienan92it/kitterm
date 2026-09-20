import { describe, expect, it } from "vitest";

import { FRAME_MS, frameAt, QUADRANT } from "./spinner";

/**
 * The working mark turns (`agent-dashboard`, capability 5;
 * `design-foundation.md`, principle 4) through the quadrants the design
 * draws and rests on `◐`. Round 14 replaced the three-candidate
 * measurement (braille first, `●` at rest) with this one cycle, at the
 * human's word: the `Components` frame and the `SESSIONS` legend both
 * show `◐`, and the mark's column is a fixed 16 px, so no glyph can move
 * the line.
 */
describe("the quadrant cycle", () => {
  it("is the only cycle: four quadrants, resting on the first, at 90 ms a frame", () => {
    expect(QUADRANT.frames).toEqual(["◐", "◓", "◑", "◒"]);
    expect(QUADRANT.rest).toBe("◐");
    expect(QUADRANT.frames[0]).toBe(QUADRANT.rest);
    expect(FRAME_MS).toBe(90);
  });

  it("turns through the cycle and wraps", () => {
    expect([0, 1, 2, 3, 4, 5].map((tick) => frameAt(QUADRANT, tick))).toEqual(["◐", "◓", "◑", "◒", "◐", "◓"]);
    expect(frameAt(QUADRANT, -1)).toBe("◒");
  });
});
