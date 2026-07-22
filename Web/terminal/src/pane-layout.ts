/**
 * Split-pane layout: an immutable binary tree plus pure geometry.
 *
 * A binary tree keeps every mutation local — a splitter drag is one `ratio`
 * write, closing a pane replaces its parent with the surviving sibling — and it
 * serializes to plain JSON with no ids to reconcile on reload.
 *
 * `computeRects` flattens the tree to normalized (0..1) rectangles, and is the
 * single source of geometric truth: rendering, splitter placement, and
 * directional navigation all derive from it. Panes are positioned absolutely
 * from these rects rather than nested in flex containers, so a split never
 * re-parents a live xterm node (which would risk WebGL context loss) and never
 * hits the flex `min-height: auto` trap where a pane refuses to shrink below
 * its content and `fit()` then reports a stale size.
 */

export type PaneId = string;

/** `row` lays children out along x (side by side); `column` along y (stacked). */
export type SplitDir = "row" | "column";

export type LeafNode = { kind: "leaf"; pane: PaneId };

export type SplitNode = {
  kind: "split";
  id: string;
  dir: SplitDir;
  /** Fraction of the split's extent given to `a`, in [MIN_RATIO, 1-MIN_RATIO]. */
  ratio: number;
  a: LayoutNode;
  b: LayoutNode;
};

export type LayoutNode = LeafNode | SplitNode;

/** Normalized rectangle within the layout container; all values in 0..1. */
export type Rect = { x: number; y: number; w: number; h: number };

export type Direction = "left" | "right" | "up" | "down";

/** Smallest fraction a split may give either side, so a pane stays usable. */
export const MIN_RATIO = 0.1;

/** Floating-point slack for adjacency tests on normalized coordinates. */
const EPSILON = 1e-6;

export const leaf = (pane: PaneId): LeafNode => ({ kind: "leaf", pane });

export const clampRatio = (ratio: number): number => {
  if (!Number.isFinite(ratio)) return 0.5;
  return Math.min(1 - MIN_RATIO, Math.max(MIN_RATIO, ratio));
};

/** Panes in document order (depth-first, `a` before `b`). */
export const paneIds = (root: LayoutNode): PaneId[] => {
  if (root.kind === "leaf") return [root.pane];
  return [...paneIds(root.a), ...paneIds(root.b)];
};

export const countPanes = (root: LayoutNode): number =>
  root.kind === "leaf" ? 1 : countPanes(root.a) + countPanes(root.b);

/**
 * Replace `target` with a split holding it and `newPane`.
 *
 * The split id is derived from `newPane` rather than generated, which keeps
 * this pure: pane ids are unique and each is introduced exactly once.
 */
export const splitPane = (
  root: LayoutNode,
  target: PaneId,
  dir: SplitDir,
  newPane: PaneId,
  ratio = 0.5,
): LayoutNode => {
  if (root.kind === "leaf") {
    if (root.pane !== target) return root;
    return {
      kind: "split",
      id: `s-${newPane}`,
      dir,
      ratio: clampRatio(ratio),
      a: root,
      b: leaf(newPane),
    };
  }
  return {
    ...root,
    a: splitPane(root.a, target, dir, newPane, ratio),
    b: splitPane(root.b, target, dir, newPane, ratio),
  };
};

/** Remove a pane, collapsing its parent into the surviving sibling. */
export const removePane = (root: LayoutNode, pane: PaneId): LayoutNode | null => {
  if (root.kind === "leaf") return root.pane === pane ? null : root;
  const a = removePane(root.a, pane);
  const b = removePane(root.b, pane);
  if (a === null) return b;
  if (b === null) return a;
  if (a === root.a && b === root.b) return root;
  return { ...root, a, b };
};

export const setSplitRatio = (
  root: LayoutNode,
  splitId: string,
  ratio: number,
): LayoutNode => {
  if (root.kind === "leaf") return root;
  if (root.id === splitId) return { ...root, ratio: clampRatio(ratio) };
  return {
    ...root,
    a: setSplitRatio(root.a, splitId, ratio),
    b: setSplitRatio(root.b, splitId, ratio),
  };
};

const FULL: Rect = { x: 0, y: 0, w: 1, h: 1 };

/** Split a rect into the two child rects implied by `dir` and `ratio`. */
const divide = (rect: Rect, dir: SplitDir, ratio: number): [Rect, Rect] => {
  if (dir === "row") {
    const wa = rect.w * ratio;
    return [
      { x: rect.x, y: rect.y, w: wa, h: rect.h },
      { x: rect.x + wa, y: rect.y, w: rect.w - wa, h: rect.h },
    ];
  }
  const ha = rect.h * ratio;
  return [
    { x: rect.x, y: rect.y, w: rect.w, h: ha },
    { x: rect.x, y: rect.y + ha, w: rect.w, h: rect.h - ha },
  ];
};

export const computeRects = (root: LayoutNode, bounds: Rect = FULL): Map<PaneId, Rect> => {
  const out = new Map<PaneId, Rect>();
  const walk = (node: LayoutNode, rect: Rect): void => {
    if (node.kind === "leaf") {
      out.set(node.pane, rect);
      return;
    }
    const [ra, rb] = divide(rect, node.dir, node.ratio);
    walk(node.a, ra);
    walk(node.b, rb);
  };
  walk(root, bounds);
  return out;
};

export type SplitterRect = { splitId: string; dir: SplitDir; rect: Rect };

/** The boundary strip between each split's two children, as a zero-thickness
 * line the view thickens into a draggable target. */
export const computeSplitters = (root: LayoutNode, bounds: Rect = FULL): SplitterRect[] => {
  const out: SplitterRect[] = [];
  const walk = (node: LayoutNode, rect: Rect): void => {
    if (node.kind === "leaf") return;
    const [ra, rb] = divide(rect, node.dir, node.ratio);
    out.push({
      splitId: node.id,
      dir: node.dir,
      rect:
        node.dir === "row"
          ? { x: rect.x + rect.w * node.ratio, y: rect.y, w: 0, h: rect.h }
          : { x: rect.x, y: rect.y + rect.h * node.ratio, w: rect.w, h: 0 },
    });
    walk(node.a, ra);
    walk(node.b, rb);
  };
  walk(root, bounds);
  return out;
};

/** The rect of the split that owns `splitId` — the drag needs it to convert a
 * pointer position into a ratio. */
export const splitBounds = (root: LayoutNode, splitId: string, bounds: Rect = FULL): Rect | null => {
  if (root.kind === "leaf") return null;
  if (root.id === splitId) return bounds;
  const [ra, rb] = divide(bounds, root.dir, root.ratio);
  return splitBounds(root.a, splitId, ra) ?? splitBounds(root.b, splitId, rb);
};

/**
 * Nearest pane in a direction: among panes strictly beyond the source edge
 * whose perpendicular span overlaps the source, pick the closest.
 */
export const paneInDirection = (
  root: LayoutNode,
  from: PaneId,
  dir: Direction,
): PaneId | null => {
  const rects = computeRects(root);
  const src = rects.get(from);
  if (!src) return null;

  let best: { pane: PaneId; distance: number } | null = null;
  for (const [pane, rect] of rects) {
    if (pane === from) continue;

    let distance: number;
    let overlaps: boolean;
    if (dir === "left" || dir === "right") {
      overlaps = rect.y < src.y + src.h - EPSILON && src.y < rect.y + rect.h - EPSILON;
      distance =
        dir === "left" ? src.x - (rect.x + rect.w) : rect.x - (src.x + src.w);
    } else {
      overlaps = rect.x < src.x + src.w - EPSILON && src.x < rect.x + rect.w - EPSILON;
      distance = dir === "up" ? src.y - (rect.y + rect.h) : rect.y - (src.y + src.h);
    }
    if (!overlaps || distance < -EPSILON) continue;
    if (!best || distance < best.distance) best = { pane, distance };
  }
  return best?.pane ?? null;
};

/** Cycle through panes in document order, wrapping at both ends. */
export const nextPane = (root: LayoutNode, from: PaneId, delta: 1 | -1): PaneId | null => {
  const ids = paneIds(root);
  const index = ids.indexOf(from);
  if (index === -1) return ids[0] ?? null;
  const next = (index + delta + ids.length) % ids.length;
  return ids[next] ?? null;
};

export const serializeLayout = (root: LayoutNode): unknown =>
  root.kind === "leaf"
    ? { kind: "leaf", pane: root.pane }
    : {
        kind: "split",
        id: root.id,
        dir: root.dir,
        ratio: root.ratio,
        a: serializeLayout(root.a),
        b: serializeLayout(root.b),
      };

/** Parse untrusted JSON back into a tree. Returns null on anything malformed
 * rather than throwing — a corrupt layout must degrade to a fresh single pane,
 * never break boot. */
export const parseLayout = (raw: unknown): LayoutNode | null => {
  if (typeof raw !== "object" || raw === null) return null;
  const node = raw as Record<string, unknown>;

  if (node.kind === "leaf") {
    return typeof node.pane === "string" && node.pane ? leaf(node.pane) : null;
  }
  if (node.kind !== "split") return null;
  if (typeof node.id !== "string" || !node.id) return null;
  if (node.dir !== "row" && node.dir !== "column") return null;
  if (typeof node.ratio !== "number" || !Number.isFinite(node.ratio)) return null;

  const a = parseLayout(node.a);
  const b = parseLayout(node.b);
  if (!a || !b) return null;

  return { kind: "split", id: node.id, dir: node.dir, ratio: clampRatio(node.ratio), a, b };
};
