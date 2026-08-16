/**
 * Touch text selection.
 *
 * xterm draws the screen into a WebGL canvas, so there is no DOM text for a
 * phone's own long-press selection to grab — and our swipe handler claims
 * vertical drags for scrolling before xterm's mouse-selection path ever sees
 * them. The result was that `getSelection()` was always empty on a phone and
 * copying was impossible, whatever the clipboard API said.
 *
 * The gesture: long-press to enter select mode and take the word under the
 * finger, drag to extend, then act from a bar. Same shape as the platform
 * gesture, so it needs no teaching.
 *
 * This module is the arithmetic only — no DOM, no xterm — so the parts that
 * are easy to get subtly wrong (a reversed drag, a selection that wraps lines,
 * a word touching the edge of a line) are tested directly.
 */

/** A cell in buffer coordinates: 0-based column, absolute row including
 * scrollback — the coordinate space `Terminal.select` speaks. */
export interface BufferCell {
  col: number;
  row: number;
}

/** The argument triple for `Terminal.select(column, row, length)`. */
export interface SelectionSpan {
  column: number;
  row: number;
  length: number;
}

/** How long a finger must rest before the press means "select". Matches the
 * platform's own long-press closely enough to feel native. */
export const LONG_PRESS_MS = 450;

/** Movement above this cancels the long press — it was a scroll, not a press.
 * Generous enough for the drift of a finger held still. */
export const LONG_PRESS_MOVE_TOLERANCE_PX = 10;

/** Within this distance of the top or bottom edge, dragging keeps scrolling,
 * so a selection can run past what fits on screen. */
export const EDGE_AUTOSCROLL_PX = 44;

/** Repeat interval for that edge scroll — roughly a line per frame pair. */
export const EDGE_AUTOSCROLL_MS = 60;

const isWordChar = (character: string): boolean => character.trim().length > 0;

/**
 * The run of non-whitespace around `col`, as a half-open `[start, end)` range.
 *
 * Whitespace-delimited rather than word-delimited on purpose: on a terminal the
 * thing worth grabbing is a path, a URL, a hash, or a container id, and
 * splitting those on punctuation would make every selection a drag. A press on
 * whitespace takes the single cell, so the gesture always yields something to
 * extend from.
 */
export const wordRangeAt = (line: string, col: number): { start: number; end: number } => {
  if (col < 0 || col >= line.length || !isWordChar(line[col])) {
    const start = Math.max(0, Math.min(col, Math.max(line.length - 1, 0)));
    return { start, end: start + 1 };
  }
  let start = col;
  while (start > 0 && isWordChar(line[start - 1])) start -= 1;
  let end = col + 1;
  while (end < line.length && isWordChar(line[end])) end += 1;
  return { start, end };
};

/** Cell offset from the buffer origin, so two cells can be ordered and
 * subtracted regardless of which line each is on. */
const offsetOf = (cell: BufferCell, cols: number): number => cell.row * cols + cell.col;

/**
 * The span covering everything between `anchor` and `focus`, inclusive of the
 * cell under the finger.
 *
 * Dragging backwards is not an error — it is how you extend a selection
 * upwards — so the earlier cell becomes the start whichever way the drag went.
 * `length` may run past the end of a line: xterm wraps it onto the following
 * rows, which is what makes a multi-line selection expressible at all.
 */
export const selectionSpan = (
  anchor: BufferCell,
  focus: BufferCell,
  cols: number,
): SelectionSpan => {
  if (cols <= 0) return { column: anchor.col, row: anchor.row, length: 0 };
  const from = offsetOf(anchor, cols);
  const to = offsetOf(focus, cols);
  const start = Math.min(from, to);
  const end = Math.max(from, to);
  return {
    column: start % cols,
    row: Math.floor(start / cols),
    length: end - start + 1,
  };
};

/** The span for a word-sized initial selection on one row. */
export const spanForWord = (
  row: number,
  range: { start: number; end: number },
): SelectionSpan => ({
  column: range.start,
  row,
  length: Math.max(1, range.end - range.start),
});

/**
 * Lines to scroll for a drag this close to an edge: negative up, positive down,
 * zero for anything comfortably inside. `height` is the terminal's own height
 * in pixels and `y` the touch position within it.
 */
export const edgeScrollDirection = (y: number, height: number): number => {
  if (height <= 0) return 0;
  // A short pane could have overlapping top and bottom zones; the nearer edge
  // wins rather than the two cancelling to a jitter.
  const fromTop = y;
  const fromBottom = height - y;
  if (fromTop < EDGE_AUTOSCROLL_PX && fromTop <= fromBottom) return -1;
  if (fromBottom < EDGE_AUTOSCROLL_PX) return 1;
  return 0;
};
