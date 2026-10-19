import { describe, expect, it } from "vitest";

import { ancestorsOf, childrenOf, findNode, treeRoot, triangle, visibleRows } from "./edit-tree";

// The project tree (`corpus/02-approved-design.md` rule 3): one level per
// expand from the root, `.git` hidden, the open file's folders open.

describe("the tree", () => {
  it("starts as the root row, open and unlisted, and lists one level without .git", () => {
    const root = treeRoot("/w/kitterm", "kitterm");
    expect(root).toEqual({ name: "kitterm", path: "/w/kitterm", dir: true, open: true, children: null, error: null });
    root.children = childrenOf(root, [
      { name: ".git", dir: true },
      { name: "Web", dir: true },
      { name: "src", dir: true },
      { name: "Package.swift", dir: false, size: 10 },
    ]);
    expect(root.children.map((c) => c.path)).toEqual(["/w/kitterm/Web", "/w/kitterm/src", "/w/kitterm/Package.swift"]);
    expect(root.children[0]).toMatchObject({ dir: true, open: false, children: null });
    expect(triangle(root)).toBe("▼");
    expect(triangle(root.children[0])).toBe("▶");
    expect(triangle(root.children[2])).toBe("");
  });

  it("shows a closed folder's children only once it is open", () => {
    const root = treeRoot("/w", "w");
    root.children = childrenOf(root, [{ name: "src", dir: true }, { name: "a.ts", dir: false }]);
    const src = findNode(root, "/w/src");
    expect(src).not.toBeNull();
    src!.children = childrenOf(src!, [{ name: "b.ts", dir: false }]);
    expect(visibleRows(root).map((r) => [r.node.name, r.depth])).toEqual([["w", 0], ["src", 1], ["a.ts", 1]]);
    src!.open = true;
    expect(visibleRows(root).map((r) => [r.node.name, r.depth])).toEqual([["w", 0], ["src", 1], ["b.ts", 2], ["a.ts", 1]]);
    expect(findNode(root, "/w/nowhere")).toBeNull();
  });

  it("names the folders to open for a file, root first, and none outside the root", () => {
    expect(ancestorsOf("/w/kitterm", "/w/kitterm/Web/terminal/src/md.ts")).toEqual([
      "/w/kitterm",
      "/w/kitterm/Web",
      "/w/kitterm/Web/terminal",
      "/w/kitterm/Web/terminal/src",
    ]);
    expect(ancestorsOf("/w/kitterm", "/w/kitterm/README.md")).toEqual(["/w/kitterm"]);
    expect(ancestorsOf("/w/kitterm", "/w/other/a.ts")).toEqual([]);
    expect(ancestorsOf("/", "/a/b.ts")).toEqual(["/", "/a"]);
  });
});
