/**
 * The project tree of the `/edit` page (`corpus/02-approved-design.md`
 * rule 3, the components frame's rule 4): one level per expand, from the
 * project root, on `GET /api/files`. This module holds the tree and
 * decides what is listed and shown; `edit.ts` paints the rows and asks the
 * daemon.
 *
 * The listing request carries `hidden=1` (`listingUrl`, `edit-model.ts`), so
 * a dotfile (`.env`, `.github/`, `.gitignore`) is a row like any other
 * (`corpus/06-dotfiles.md` rule 1); `childrenOf` drops only `HIDDEN_NAMES`,
 * what a normal editor hides by default (rule 2). The badges a folder and a
 * file wear from `git status` are round 5's; a node carries none yet.
 */

import type { ListingEntry } from "./edit-fetch";

/** The names `childrenOf` drops regardless of the listing: VS Code's
 * `files.exclude` default (`corpus/06-dotfiles.md` rule 2). The save route
 * refuses everything under `.git` on its own, so dropping it here is only
 * about the tree. */
export const HIDDEN_NAMES: ReadonlySet<string> = new Set([".git", ".svn", ".hg", "CVS", ".DS_Store", "Thumbs.db"]);

export interface TreeNode {
  name: string;
  /** Absolute, under the root. */
  path: string;
  dir: boolean;
  open: boolean;
  /** `null` until listed; the daemon's order (directories first). */
  children: TreeNode[] | null;
  /** The listing's error sentence, when the daemon refused it. */
  error: string | null;
  /**
   * The next folder of a compact chain (rule 6 of `corpus/07-projects-and-
   * tree.md`, rule 20 of `Editor components 2`, `design/editor.pen`): set once this
   * node's listing is known to hold exactly one directory and nothing
   * else. One row names the whole chain, `Web/terminal`; its open state,
   * its children and its badge are the chain's last node's
   * (`chainTail`), up to `MAX_COMPACT_CHAIN` links.
   */
  compactWith: TreeNode | null;
}

/** A chain of folders that each hold exactly one folder and nothing else
 * folds into one row (rule 6); longer than this, the chain still shows but
 * stops compacting past the cap. */
export const MAX_COMPACT_CHAIN = 8;

/** The root row: the project's name, open, not yet listed. */
export function treeRoot(root: string, name: string): TreeNode {
  return { name, path: root, dir: true, open: true, children: null, error: null, compactWith: null };
}

/** The last node of `node`'s compact chain: `node` itself with no chain.
 * Its `open` and `children` decide whether the chain's row is expanded. */
export function chainTail(node: TreeNode): TreeNode {
  return node.compactWith ? chainTail(node.compactWith) : node;
}

/** `Web/terminal`: `node`'s name, then its chain's, joined by `/`. */
export function chainName(node: TreeNode): string {
  return node.compactWith ? `${node.name}/${chainName(node.compactWith)}` : node.name;
}

/** The entries the tree shows: `HIDDEN_NAMES` dropped, the daemon's order
 * kept (folders first, then by name). */
export function childrenOf(parent: TreeNode, entries: ListingEntry[]): TreeNode[] {
  return entries
    .filter((entry) => !HIDDEN_NAMES.has(entry.name))
    .map((entry) => ({
      name: entry.name,
      path: parent.path === "/" ? `/${entry.name}` : `${parent.path}/${entry.name}`,
      dir: entry.dir,
      open: false,
      children: null,
      error: null,
      compactWith: null,
    }));
}

/** The single directory `node` is compactable with (rule 6): its listed
 * children hold exactly one entry, a directory, and nothing else. `null`
 * when the chain stops here (no children, several, or any file). */
export function compactCandidate(node: TreeNode): TreeNode | null {
  const kids = node.children;
  return kids && kids.length === 1 && kids[0].dir ? kids[0] : null;
}

/** The node at `path`, or `null`. */
export function findNode(tree: TreeNode, path: string): TreeNode | null {
  if (tree.path === path) return tree;
  for (const child of tree.children ?? []) {
    const hit = findNode(child, path);
    if (hit) return hit;
  }
  return null;
}

/**
 * The directories, root first, that must be open and listed for `file`'s
 * row to show: every ancestor of `file` under the root. Empty for a file
 * outside the root.
 */
export function ancestorsOf(root: string, file: string): string[] {
  const prefix = root === "/" ? "/" : `${root}/`;
  if (!file.startsWith(prefix)) return [];
  const rest = file.slice(prefix.length).split("/");
  rest.pop();
  const out: string[] = [root];
  let at = root === "/" ? "" : root;
  for (const segment of rest) {
    at = `${at}/${segment}`;
    out.push(at);
  }
  return out;
}

/**
 * The directories, root first, to open and list so that `folder` shows
 * open with its own entries (the folder form of `/edit`, round 7): its
 * ancestors under the root, then the folder itself; the root alone for the
 * root. Empty for a folder outside the root.
 */
export function foldersToOpen(root: string, folder: string): string[] {
  if (folder === root) return [root];
  const above = ancestorsOf(root, folder);
  return above.length === 0 ? [] : [...above, folder];
}

export interface TreeRow {
  /** The chain's head: its own path and name, never shown for a chain of
   * more than one link. */
  node: TreeNode;
  /** `node` itself with no chain, else the chain's last link: its `open`
   * and `children` decide the row's expansion and its badge. */
  tail: TreeNode;
  /** `node`'s name, joined with every chain link's (`Web/terminal`). */
  displayName: string;
  /** 0 for the root. */
  depth: number;
}

/** The rows in order: a node (or its compact chain), then its tail's
 * children when the chain is open. */
export function visibleRows(tree: TreeNode): TreeRow[] {
  const rows: TreeRow[] = [];
  const walk = (node: TreeNode, depth: number): void => {
    const tail = chainTail(node);
    rows.push({ node, tail, displayName: chainName(node), depth });
    if (tail.dir && tail.open && tail.children) for (const child of tail.children) walk(child, depth + 1);
  };
  walk(tree, 0);
  return rows;
}

/** `▼` for an open folder (or chain), `▶` for a closed one, nothing for a
 * file; the chain's own open state is its tail's. */
export function triangle(tail: TreeNode): string {
  if (!tail.dir) return "";
  return tail.open ? "▼" : "▶";
}

// --- the keyboard (rule 7 of `corpus/07-projects-and-tree.md`, rule 21 of
// `Editor components 2`, `design/editor.pen`) -----------------------------

export type TreeKey = "up" | "down" | "left" | "right" | "home" | "end";

export interface NavResult {
  /** The row to focus after the key; unchanged when nothing moves. */
  focusIndex: number;
  /** Set when the key also opens or closes the focused row's chain. */
  toggle?: "open" | "close";
}

/**
 * Where the keyboard moves from `rows[index]` on `key` (rule 7): `↑` `↓`
 * move the selection; `←` closes an open row in place, else moves to its
 * parent (the nearest earlier row at a smaller depth); `→` opens a closed
 * row in place, else moves to its first child (the next row, one depth
 * in); `Home` and `End` the first and the last row. Pure: `edit.ts` applies
 * the toggle (which may need to list a folder first) and moves the focus.
 */
export function navigateTree(rows: readonly TreeRow[], index: number, key: TreeKey): NavResult {
  const row = rows[index];
  switch (key) {
    case "up":
      return { focusIndex: Math.max(0, index - 1) };
    case "down":
      return { focusIndex: Math.min(rows.length - 1, index + 1) };
    case "home":
      return { focusIndex: 0 };
    case "end":
      return { focusIndex: rows.length - 1 };
    case "left":
      if (row.tail.dir && row.tail.open) return { focusIndex: index, toggle: "close" };
      for (let i = index - 1; i >= 0; i -= 1) if (rows[i].depth < row.depth) return { focusIndex: i };
      return { focusIndex: index };
    case "right":
      if (row.tail.dir && !row.tail.open) return { focusIndex: index, toggle: "open" };
      if (row.tail.dir && row.tail.open && rows[index + 1]?.depth === row.depth + 1) return { focusIndex: index + 1 };
      return { focusIndex: index };
  }
}
