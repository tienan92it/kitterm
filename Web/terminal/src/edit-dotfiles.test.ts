import { describe, expect, it } from "vitest";

import { listingUrl } from "./edit-model";
import { childrenOf, HIDDEN_NAMES, treeRoot } from "./edit-tree";

// Dotfiles in the `/edit` tree (`corpus/06-dotfiles.md`): the listing asks
// for hidden entries (rule 1) and the tree drops only the six names a
// normal editor hides by default (rule 2), never every dotfile.

describe("the listing request", () => {
  it("carries hidden=1, which main's listingUrl does not", () => {
    // A regression test: against main's `listingUrl`, this URL has no
    // `hidden` parameter and the daemon drops every dotfile from the
    // answer.
    expect(listingUrl("/w", "S1")).toContain("hidden=1");
    expect(new URL(listingUrl("/w/kitterm"), "http://x").searchParams.get("hidden")).toBe("1");
  });
});

describe("childrenOf (rule 2)", () => {
  it("keeps a dotfile that is not one of the six hidden names", () => {
    const root = treeRoot("/w", "w");
    // The daemon's own order (directories first, then by name).
    root.children = childrenOf(root, [
      { name: ".github", dir: true },
      { name: ".env", dir: false },
      { name: ".gitignore", dir: false },
    ]);
    expect(root.children.map((c) => c.name)).toEqual([".github", ".env", ".gitignore"]);
  });

  it("drops each of the six names VS Code's files.exclude hides by default", () => {
    const root = treeRoot("/w", "w");
    root.children = childrenOf(root, [
      { name: ".git", dir: true },
      { name: ".svn", dir: true },
      { name: ".hg", dir: true },
      { name: "CVS", dir: true },
      { name: ".DS_Store", dir: false },
      { name: "Thumbs.db", dir: false },
      { name: "kept.ts", dir: false },
    ]);
    expect(root.children.map((c) => c.name)).toEqual(["kept.ts"]);
    for (const name of [".git", ".svn", ".hg", "CVS", ".DS_Store", "Thumbs.db"]) {
      expect(HIDDEN_NAMES.has(name)).toBe(true);
    }
  });
});
