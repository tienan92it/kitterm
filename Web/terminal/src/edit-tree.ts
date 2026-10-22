/**
 * The project tree of the `/edit` page (`corpus/02-approved-design.md`
 * rule 3, the components frame's rule 4): one level per expand, from the
 * project root, on `GET /api/files`. This module holds the tree and
 * decides what is listed and shown; `edit.ts` paints the rows and asks the
 * daemon.
 *
 * `.git` is never a row: the save route refuses everything under it, and
 * the listing route hides dotfiles anyway. The badges a folder and a file
 * wear from `git status` are round 5's; a node carries none yet.
 */

import type { ListingEntry } from "./edit-fetch";

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
}

/** The root row: the project's name, open, not yet listed. */
export function treeRoot(root: string, name: string): TreeNode {
  return { name, path: root, dir: true, open: true, children: null, error: null };
}

/** The entries the tree shows: `.git` dropped, the daemon's order kept. */
export function childrenOf(parent: TreeNode, entries: ListingEntry[]): TreeNode[] {
  return entries
    .filter((entry) => entry.name !== ".git")
    .map((entry) => ({
      name: entry.name,
      path: parent.path === "/" ? `/${entry.name}` : `${parent.path}/${entry.name}`,
      dir: entry.dir,
      open: false,
      children: null,
      error: null,
    }));
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
  node: TreeNode;
  /** 0 for the root. */
  depth: number;
}

/** The rows in order: a node, then its children when it is open. */
export function visibleRows(tree: TreeNode): TreeRow[] {
  const rows: TreeRow[] = [];
  const walk = (node: TreeNode, depth: number): void => {
    rows.push({ node, depth });
    if (node.dir && node.open && node.children) for (const child of node.children) walk(child, depth + 1);
  };
  walk(tree, 0);
  return rows;
}

/** `▼` for an open folder, `▶` for a closed one, nothing for a file. */
export function triangle(node: TreeNode): string {
  if (!node.dir) return "";
  return node.open ? "▼" : "▶";
}
