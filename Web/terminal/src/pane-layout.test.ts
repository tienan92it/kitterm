import { describe, expect, it } from "vitest";

import {
  MIN_RATIO,
  clampRatio,
  computeRects,
  computeSplitters,
  countPanes,
  leaf,
  nextPane,
  paneIds,
  paneInDirection,
  parseLayout,
  removePane,
  serializeLayout,
  setSplitRatio,
  splitBounds,
  splitPane,
  type LayoutNode,
} from "./pane-layout";

/** Four panes: left column split in two, right column split in two.
 *
 *   +-----+-----+
 *   |  a  |  c  |
 *   +-----+-----+
 *   |  b  |  d  |
 *   +-----+-----+
 */
const quad = (): LayoutNode => {
  let tree: LayoutNode = leaf("a");
  tree = splitPane(tree, "a", "row", "c"); // a | c
  tree = splitPane(tree, "a", "column", "b"); // a over b, beside c
  tree = splitPane(tree, "c", "column", "d"); // c over d
  return tree;
};

describe("splitPane", () => {
  it("replaces the target leaf with a split holding it and the new pane", () => {
    const tree = splitPane(leaf("a"), "a", "row", "b");
    expect(tree.kind).toBe("split");
    expect(paneIds(tree)).toEqual(["a", "b"]);
  });

  it("leaves the tree untouched when the target is absent", () => {
    const before = leaf("a");
    expect(splitPane(before, "missing", "row", "b")).toBe(before);
  });

  it("splits a nested pane without disturbing its siblings", () => {
    const tree = splitPane(splitPane(leaf("a"), "a", "row", "b"), "b", "column", "c");
    expect(paneIds(tree)).toEqual(["a", "b", "c"]);
    expect(countPanes(tree)).toBe(3);
  });

  it("derives a stable split id from the new pane", () => {
    const tree = splitPane(leaf("a"), "a", "row", "b");
    expect(tree.kind === "split" && tree.id).toBe("s-b");
  });
});

describe("removePane", () => {
  it("collapses the parent into the surviving sibling", () => {
    const tree = removePane(splitPane(leaf("a"), "a", "row", "b"), "b");
    expect(tree).toEqual(leaf("a"));
  });

  it("returns null when the last pane goes", () => {
    expect(removePane(leaf("a"), "a")).toBeNull();
  });

  it("keeps the other three panes of a quad intact", () => {
    const tree = removePane(quad(), "b");
    expect(tree).not.toBeNull();
    expect(paneIds(tree as LayoutNode)).toEqual(["a", "c", "d"]);
  });

  it("is identity for an unknown pane", () => {
    const before = quad();
    expect(removePane(before, "missing")).toBe(before);
  });
});

describe("clampRatio / setSplitRatio", () => {
  it("clamps to the usable band", () => {
    expect(clampRatio(0)).toBe(MIN_RATIO);
    expect(clampRatio(1)).toBe(1 - MIN_RATIO);
    expect(clampRatio(0.5)).toBe(0.5);
  });

  it("falls back to a half split on any non-finite ratio", () => {
    // NaN/Infinity mean corrupt input, not "as far as possible" — a neutral
    // split is safer than silently pinning a pane to the minimum.
    expect(clampRatio(Number.NaN)).toBe(0.5);
    expect(clampRatio(Number.POSITIVE_INFINITY)).toBe(0.5);
    expect(clampRatio(Number.NEGATIVE_INFINITY)).toBe(0.5);
  });

  it("updates only the addressed split", () => {
    const tree = setSplitRatio(quad(), "s-c", 0.25);
    const rects = computeRects(tree);
    expect(rects.get("a")?.w).toBeCloseTo(0.25);
    // The nested column splits keep their own ratios.
    expect(rects.get("a")?.h).toBeCloseTo(0.5);
  });

  it("clamps through setSplitRatio too", () => {
    const tree = setSplitRatio(splitPane(leaf("a"), "a", "row", "b"), "s-b", 5);
    expect(computeRects(tree).get("a")?.w).toBeCloseTo(1 - MIN_RATIO);
  });
});

describe("computeRects", () => {
  it("gives a single pane the whole container", () => {
    expect(computeRects(leaf("a")).get("a")).toEqual({ x: 0, y: 0, w: 1, h: 1 });
  });

  it("tiles a quad exactly, with no gaps or overlap", () => {
    const rects = computeRects(quad());
    expect(rects.size).toBe(4);

    const area = [...rects.values()].reduce((sum, r) => sum + r.w * r.h, 0);
    expect(area).toBeCloseTo(1);

    expect(rects.get("a")).toEqual({ x: 0, y: 0, w: 0.5, h: 0.5 });
    expect(rects.get("b")).toEqual({ x: 0, y: 0.5, w: 0.5, h: 0.5 });
    expect(rects.get("c")).toEqual({ x: 0.5, y: 0, w: 0.5, h: 0.5 });
    expect(rects.get("d")).toEqual({ x: 0.5, y: 0.5, w: 0.5, h: 0.5 });
  });

  it("respects a non-even ratio", () => {
    const tree = setSplitRatio(splitPane(leaf("a"), "a", "row", "b"), "s-b", 0.3);
    const rects = computeRects(tree);
    expect(rects.get("a")?.w).toBeCloseTo(0.3);
    expect(rects.get("b")?.x).toBeCloseTo(0.3);
    expect(rects.get("b")?.w).toBeCloseTo(0.7);
  });
});

describe("computeSplitters", () => {
  it("emits one splitter per split node", () => {
    expect(computeSplitters(quad())).toHaveLength(3);
    expect(computeSplitters(leaf("a"))).toHaveLength(0);
  });

  it("places the boundary on the dividing line", () => {
    const splitters = computeSplitters(splitPane(leaf("a"), "a", "row", "b"));
    expect(splitters[0]?.dir).toBe("row");
    expect(splitters[0]?.rect.x).toBeCloseTo(0.5);
    expect(splitters[0]?.rect.h).toBeCloseTo(1);
  });
});

describe("splitBounds", () => {
  it("returns the whole container for the root split", () => {
    const tree = splitPane(leaf("a"), "a", "row", "b");
    expect(splitBounds(tree, "s-b")).toEqual({ x: 0, y: 0, w: 1, h: 1 });
  });

  it("returns the subtree rect for a nested split", () => {
    expect(splitBounds(quad(), "s-d")).toEqual({ x: 0.5, y: 0, w: 0.5, h: 1 });
  });

  it("returns null for an unknown split", () => {
    expect(splitBounds(quad(), "nope")).toBeNull();
  });
});

describe("paneInDirection", () => {
  it("moves across a quad", () => {
    const tree = quad();
    expect(paneInDirection(tree, "a", "right")).toBe("c");
    expect(paneInDirection(tree, "c", "left")).toBe("a");
    expect(paneInDirection(tree, "a", "down")).toBe("b");
    expect(paneInDirection(tree, "b", "up")).toBe("a");
  });

  it("returns null at the edges", () => {
    const tree = quad();
    expect(paneInDirection(tree, "a", "left")).toBeNull();
    expect(paneInDirection(tree, "a", "up")).toBeNull();
    expect(paneInDirection(tree, "d", "right")).toBeNull();
    expect(paneInDirection(tree, "d", "down")).toBeNull();
  });

  it("picks the overlapping neighbour in an L-shaped layout", () => {
    // Full-height left pane, right column split in two.
    //   +-----+-----+
    //   |     |  b  |
    //   |  a  +-----+
    //   |     |  c  |
    //   +-----+-----+
    const tree = splitPane(splitPane(leaf("a"), "a", "row", "b"), "b", "column", "c");
    expect(paneInDirection(tree, "b", "left")).toBe("a");
    expect(paneInDirection(tree, "c", "left")).toBe("a");
    // From the tall pane, the first overlapping neighbour wins.
    expect(paneInDirection(tree, "a", "right")).toBe("b");
  });

  it("returns null for an unknown source pane", () => {
    expect(paneInDirection(quad(), "missing", "right")).toBeNull();
  });
});

describe("nextPane", () => {
  it("cycles forward and backward with wrapping", () => {
    const tree = quad();
    expect(nextPane(tree, "a", 1)).toBe("b");
    expect(nextPane(tree, "d", 1)).toBe("a");
    expect(nextPane(tree, "a", -1)).toBe("d");
  });

  it("falls back to the first pane when the source is unknown", () => {
    expect(nextPane(quad(), "missing", 1)).toBe("a");
  });
});

describe("serializeLayout / parseLayout", () => {
  it("round-trips through JSON", () => {
    const tree = quad();
    const restored = parseLayout(JSON.parse(JSON.stringify(serializeLayout(tree))));
    expect(restored).toEqual(tree);
  });

  it("round-trips a single leaf", () => {
    expect(parseLayout(serializeLayout(leaf("solo")))).toEqual(leaf("solo"));
  });

  it.each([
    ["null", null],
    ["a bare string", "leaf"],
    ["a number", 7],
    ["an unknown kind", { kind: "grid", pane: "a" }],
    ["a leaf with no pane", { kind: "leaf" }],
    ["a leaf with an empty pane", { kind: "leaf", pane: "" }],
    ["a split with a bad dir", { kind: "split", id: "s", dir: "diagonal", ratio: 0.5, a: { kind: "leaf", pane: "a" }, b: { kind: "leaf", pane: "b" } }],
    ["a split with a NaN ratio", { kind: "split", id: "s", dir: "row", ratio: Number.NaN, a: { kind: "leaf", pane: "a" }, b: { kind: "leaf", pane: "b" } }],
    ["a split with no id", { kind: "split", dir: "row", ratio: 0.5, a: { kind: "leaf", pane: "a" }, b: { kind: "leaf", pane: "b" } }],
    ["a split missing a child", { kind: "split", id: "s", dir: "row", ratio: 0.5, a: { kind: "leaf", pane: "a" } }],
    ["a split with a corrupt child", { kind: "split", id: "s", dir: "row", ratio: 0.5, a: { kind: "leaf", pane: "a" }, b: { kind: "leaf" } }],
  ])("returns null for %s", (_label, raw) => {
    expect(parseLayout(raw)).toBeNull();
  });

  it("clamps an out-of-range ratio rather than rejecting the tree", () => {
    const parsed = parseLayout({
      kind: "split",
      id: "s",
      dir: "row",
      ratio: 0.99,
      a: { kind: "leaf", pane: "a" },
      b: { kind: "leaf", pane: "b" },
    });
    expect(parsed?.kind === "split" && parsed.ratio).toBe(1 - MIN_RATIO);
  });
});
