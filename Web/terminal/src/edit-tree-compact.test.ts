import { describe, expect, it } from "vitest";

import { chainName, chainTail, childrenOf, compactCandidate, navigateTree, treeRoot, triangle, visibleRows } from "./edit-tree";

// Compact folders (`code-editor` round 13, rule 6 of
// `corpus/07-projects-and-tree.md`, rule 20 of `corpus/09-approved-
// frames.md`): a chain of folders that each hold exactly one folder and
// nothing else shows as one row, named by the chain; a file at any link
// ends it.

describe("compactCandidate", () => {
  it("names the single directory a node holds and nothing else", () => {
    const node = treeRoot("/w/Web", "Web");
    node.children = childrenOf(node, [{ name: "terminal", dir: true }]);
    expect(compactCandidate(node)?.name).toBe("terminal");
  });

  it("stops the chain at a folder with a file, with several entries, or with none", () => {
    const withFile = treeRoot("/w/Web", "Web");
    withFile.children = childrenOf(withFile, [{ name: "terminal", dir: true }, { name: "a.ts", dir: false }]);
    expect(compactCandidate(withFile)).toBeNull();

    const several = treeRoot("/w/Web", "Web");
    several.children = childrenOf(several, [{ name: "terminal", dir: true }, { name: "other", dir: true }]);
    expect(compactCandidate(several)).toBeNull();

    const empty = treeRoot("/w/Web", "Web");
    empty.children = [];
    expect(compactCandidate(empty)).toBeNull();

    const unlisted = treeRoot("/w/Web", "Web");
    expect(compactCandidate(unlisted)).toBeNull();
  });
});

describe("the compact chain's row", () => {
  it("names the chain, folds as one row, and opens to the tail's children", () => {
    const root = treeRoot("/w", "w");
    root.children = childrenOf(root, [{ name: "Web", dir: true }]);
    const web = root.children[0];
    web.children = childrenOf(web, [{ name: "terminal", dir: true }]);
    const terminal = web.children[0];
    terminal.children = childrenOf(terminal, [{ name: "src", dir: true }, { name: "edit.html", dir: false }]);
    web.compactWith = terminal;

    expect(chainName(web)).toBe("Web/terminal");
    expect(chainTail(web)).toBe(terminal);
    expect(triangle(chainTail(web))).toBe("▶");

    // Closed: one row for the whole chain, no row for `terminal` itself.
    let rows = visibleRows(root);
    expect(rows.map((r) => [r.displayName, r.depth])).toEqual([
      ["w", 0],
      ["Web/terminal", 1],
    ]);

    // Opening the tail (as a click on the chain's row does) reveals the
    // tail's own children, at the chain's row's depth plus one — never a
    // row for the intermediate `terminal` link.
    terminal.open = true;
    rows = visibleRows(root);
    expect(rows.map((r) => [r.displayName, r.depth])).toEqual([
      ["w", 0],
      ["Web/terminal", 1],
      ["src", 2],
      ["edit.html", 2],
    ]);
  });

  it("does not compact a folder a file ends the chain at", () => {
    const root = treeRoot("/w", "w");
    root.children = childrenOf(root, [{ name: "Web", dir: true }]);
    const web = root.children[0];
    web.children = childrenOf(web, [{ name: "terminal", dir: true }]);
    const terminal = web.children[0];
    terminal.children = childrenOf(terminal, [{ name: "src", dir: true }, { name: "edit.html", dir: false }]);
    // `terminal` is not compacted further: its own listing holds a file
    // too, so `Web/terminal/src` never shows as one row.
    web.compactWith = terminal;
    expect(compactCandidate(terminal)).toBeNull();
  });
});

describe("navigate", () => {
  const tree = () => {
    const root = treeRoot("/w", "w");
    root.children = childrenOf(root, [{ name: "src", dir: true }, { name: "a.ts", dir: false }]);
    const src = root.children[0];
    src.children = childrenOf(src, [{ name: "b.ts", dir: false }]);
    src.open = true;
    return visibleRows(root); // [w, src, b.ts, a.ts]
  };

  it("moves up and down, clamped at the ends", () => {
    const rows = tree();
    expect(navigateTree(rows, 1, "down").focusIndex).toBe(2);
    expect(navigateTree(rows, 3, "down").focusIndex).toBe(3);
    expect(navigateTree(rows, 0, "up").focusIndex).toBe(0);
    expect(navigateTree(rows, 2, "up").focusIndex).toBe(1);
  });

  it("home and end jump to the first and the last row", () => {
    const rows = tree();
    expect(navigateTree(rows, 2, "home").focusIndex).toBe(0);
    expect(navigateTree(rows, 0, "end").focusIndex).toBe(3);
  });

  it("closes an open row in place, else goes to the parent", () => {
    const rows = tree();
    // src (index 1) is open: closes in place.
    expect(navigateTree(rows, 1, "left")).toEqual({ focusIndex: 1, toggle: "close" });
    // b.ts (index 2) is a file: goes to its parent, src.
    expect(navigateTree(rows, 2, "left").focusIndex).toBe(1);
    // w (index 0) has no parent: stays.
    expect(navigateTree(rows, 0, "left").focusIndex).toBe(0);
  });

  it("opens a closed row in place, else goes to its first child", () => {
    const rows = tree();
    // a.ts (index 3, depth 1) is a closed folder's sibling file: stays (a file opens nothing).
    expect(navigateTree(rows, 3, "right").focusIndex).toBe(3);
    // src (index 1) is open: goes to its first child, b.ts.
    expect(navigateTree(rows, 1, "right").focusIndex).toBe(2);
    // b.ts (index 2) is a file: stays.
    expect(navigateTree(rows, 2, "right").focusIndex).toBe(2);
  });

  it("opens a closed folder in place without moving", () => {
    const root = treeRoot("/w", "w");
    root.children = childrenOf(root, [{ name: "src", dir: true }]);
    const rows = visibleRows(root);
    expect(navigateTree(rows, 1, "right")).toEqual({ focusIndex: 1, toggle: "open" });
  });
});
