import { describe, expect, it } from "vitest";

import {
  edgeScrollDirection,
  selectionSpan,
  spanForWord,
  wordRangeAt,
} from "./touch-select";

describe("wordRangeAt", () => {
  it("takes the whole non-whitespace run, not a punctuation-split word", () => {
    // The point of the gesture on a terminal: one press grabs the whole path.
    const line = "cd /Users/an/Workspace/kitterm && ls";
    expect(wordRangeAt(line, 6)).toEqual({ start: 3, end: 30 });
    expect(line.slice(3, 30)).toBe("/Users/an/Workspace/kitterm");
  });

  it("reaches both ends of a line without running off it", () => {
    const line = "alpha omega";
    expect(wordRangeAt(line, 0)).toEqual({ start: 0, end: 5 });
    expect(wordRangeAt(line, 10)).toEqual({ start: 6, end: 11 });
  });

  it("takes a single cell when the press lands on whitespace", () => {
    expect(wordRangeAt("a  b", 1)).toEqual({ start: 1, end: 2 });
  });

  it("stays in range past the end of a short line", () => {
    const range = wordRangeAt("ab", 40);
    expect(range.start).toBeGreaterThanOrEqual(0);
    expect(range.start).toBeLessThan(2);
  });

  it("survives an empty line", () => {
    expect(wordRangeAt("", 0)).toEqual({ start: 0, end: 1 });
  });
});

describe("selectionSpan", () => {
  const cols = 80;

  it("covers both endpoints, including the cell under the finger", () => {
    expect(selectionSpan({ col: 4, row: 10 }, { col: 9, row: 10 }, cols)).toEqual({
      column: 4,
      row: 10,
      length: 6,
    });
  });

  it("normalises a backwards drag, which is how you extend upwards", () => {
    const forwards = selectionSpan({ col: 2, row: 5 }, { col: 7, row: 9 }, cols);
    const backwards = selectionSpan({ col: 7, row: 9 }, { col: 2, row: 5 }, cols);
    expect(backwards).toEqual(forwards);
    expect(backwards).toEqual({ column: 2, row: 5, length: 4 * cols + 6 });
  });

  it("expresses a multi-line selection as a length that runs past the row", () => {
    // xterm wraps a length longer than the row onto the rows below; that is
    // the only way its select(column, row, length) can span lines at all.
    const span = selectionSpan({ col: 78, row: 3 }, { col: 1, row: 4 }, cols);
    expect(span).toEqual({ column: 78, row: 3, length: 4 });
  });

  it("selects one cell when it never moved", () => {
    expect(selectionSpan({ col: 12, row: 2 }, { col: 12, row: 2 }, cols).length).toBe(1);
  });

  it("degrades to an empty span rather than dividing by zero", () => {
    expect(selectionSpan({ col: 0, row: 0 }, { col: 3, row: 1 }, 0).length).toBe(0);
  });
});

describe("spanForWord", () => {
  it("turns a word range into a one-row span", () => {
    expect(spanForWord(7, { start: 3, end: 9 })).toEqual({ column: 3, row: 7, length: 6 });
  });

  it("never produces a zero-length selection", () => {
    expect(spanForWord(0, { start: 5, end: 5 }).length).toBe(1);
  });
});

describe("edgeScrollDirection", () => {
  it("is still in the middle of the pane", () => {
    expect(edgeScrollDirection(300, 600)).toBe(0);
  });

  it("scrolls up near the top and down near the bottom", () => {
    expect(edgeScrollDirection(4, 600)).toBe(-1);
    expect(edgeScrollDirection(596, 600)).toBe(1);
  });

  it("picks the nearer edge in a pane too short for two zones", () => {
    // Both zones overlap at this height; without a tie-break the two would
    // fight and the view would jitter instead of scrolling.
    expect(edgeScrollDirection(10, 50)).toBe(-1);
    expect(edgeScrollDirection(40, 50)).toBe(1);
  });

  it("does nothing for a pane with no height", () => {
    expect(edgeScrollDirection(0, 0)).toBe(0);
  });
});
