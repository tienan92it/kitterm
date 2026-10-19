import { describe, expect, it } from "vitest";

import {
  badgeForPath,
  badgeOf,
  branchLine,
  changesLabel,
  diffWhat,
  entryCounts,
  entryName,
  type GitEntry,
  type GitStatus,
  gitTabLabel,
  parseStatus,
  parseUnifiedDiff,
  wantsStaged,
} from "./edit-git";
import { hunkHeader } from "./line-diff";

// The git tab's pure parts (`code-editor` round 5; rules 5, 7 and 9 of the
// `Editor components` frame): the badge of a status entry, the folder
// rollup, the counts line, the tab, and the unified diff as hunks.

const entry = (path: string, xy: string, kind: GitEntry["kind"] = "ordinary", extra: Partial<GitEntry> = {}): GitEntry => ({
  path,
  index: xy[0],
  worktree: xy[1],
  kind,
  ...extra,
});

const status = (files: GitEntry[], extra: Partial<GitStatus> = {}): GitStatus => ({
  root: "/w/kitterm",
  branch: "goal/code-editor",
  upstream: "origin/goal/code-editor",
  ahead: 1,
  behind: 0,
  detached: false,
  files,
  counts: { changed: files.length, staged: 2, unstaged: 1, untracked: 0, conflicts: 0 },
  ...extra,
});

describe("the badge of a status entry", () => {
  it("reads the index column first, then the worktree column", () => {
    expect(badgeOf(entry("a.ts", ".M"))).toEqual({ letter: "M", tone: "warning" });
    expect(badgeOf(entry("a.ts", "M."))).toEqual({ letter: "M", tone: "warning" });
    expect(badgeOf(entry("a.ts", "MM"))).toEqual({ letter: "M", tone: "warning" });
    expect(badgeOf(entry("a.ts", "A."))).toEqual({ letter: "A", tone: "success" });
    expect(badgeOf(entry("a.ts", "AM"))).toEqual({ letter: "A", tone: "success" });
    expect(badgeOf(entry("a.ts", ".D"))).toEqual({ letter: "D", tone: "danger" });
    expect(badgeOf(entry("a.ts", "D."))).toEqual({ letter: "D", tone: "danger" });
    expect(badgeOf(entry("a.ts", ".T"))).toEqual({ letter: "M", tone: "warning" });
  });

  it("names a rename, a copy, a conflict and an untracked file, and nothing for an ignored one", () => {
    expect(badgeOf(entry("new.ts", "R.", "renamed", { origPath: "old.ts" }))).toEqual({ letter: "R", tone: "warning" });
    expect(badgeOf(entry("copy.ts", "C.", "copied"))).toEqual({ letter: "R", tone: "warning" });
    expect(badgeOf(entry("x.ts", "UU", "unmerged"))).toEqual({ letter: "U", tone: "danger" });
    expect(badgeOf(entry("x.ts", "??", "untracked"))).toEqual({ letter: "?", tone: "faint" });
    expect(badgeOf(entry("build/", "!!", "ignored"))).toBeNull();
  });
});

describe("the folder rollup", () => {
  const files = [entry("Web/terminal/src/md.ts", ".M"), entry("Web/terminal/src/osc52.ts", "A."), entry("dist/x", "!!", "ignored")];
  const tree = status(files);

  it("gives a file its own badge and a folder M when a changed path is under it", () => {
    expect(badgeForPath(tree, "/w/kitterm/Web/terminal/src/osc52.ts", false)).toEqual({ letter: "A", tone: "success" });
    expect(badgeForPath(tree, "/w/kitterm/Web/terminal/src/md.ts", false)).toEqual({ letter: "M", tone: "warning" });
    expect(badgeForPath(tree, "/w/kitterm/Web", true)).toEqual({ letter: "M", tone: "warning" });
    expect(badgeForPath(tree, "/w/kitterm/Web/terminal/src", true)).toEqual({ letter: "M", tone: "warning" });
    expect(badgeForPath(tree, "/w/kitterm", true)).toEqual({ letter: "M", tone: "warning" });
  });

  it("gives a clean file, a clean folder, an ignored path and a folder that only shares a prefix nothing", () => {
    expect(badgeForPath(tree, "/w/kitterm/Web/terminal/src/md.css", false)).toBeNull();
    expect(badgeForPath(tree, "/w/kitterm/Sources", true)).toBeNull();
    expect(badgeForPath(tree, "/w/kitterm/dist", true)).toBeNull();
    expect(badgeForPath(tree, "/w/kitterm/Web/term", true)).toBeNull();
    expect(badgeForPath(null, "/w/kitterm/Web", true)).toBeNull();
  });
});

describe("the words", () => {
  it("labels the section, the tab and the branch", () => {
    expect(changesLabel({ changed: 3, staged: 2, unstaged: 1, untracked: 0, conflicts: 0 })).toBe("CHANGES 3 · 2 staged");
    expect(changesLabel({ changed: 0, staged: 0, unstaged: 0, untracked: 0, conflicts: 0 })).toBe("CHANGES 0 · 0 staged");
    expect(gitTabLabel(true, { changed: 3, staged: 2, unstaged: 1, untracked: 0, conflicts: 0 })).toBe("[x] git 3");
    expect(gitTabLabel(false, { changed: 0, staged: 0, unstaged: 0, untracked: 0, conflicts: 0 })).toBe("[ ] git 0");
    expect(gitTabLabel(false, null)).toBe("[ ] git");
    expect(branchLine(status([]))).toEqual({ name: "goal/code-editor", ab: "↑1 ↓0", detached: false });
    expect(branchLine(status([], { branch: null, detached: true, upstream: null }))).toEqual({ name: "HEAD", ab: "no upstream", detached: true });
    expect(branchLine(status([], { ahead: 0, behind: 4 })).ab).toBe("↑0 ↓4");
  });

  it("prints a row's counts and name", () => {
    expect(entryCounts(entry("a.ts", ".M", "ordinary", { additions: 21, deletions: 1 }))).toBe("+21 −1");
    expect(entryCounts(entry("a.ts", "A.", "ordinary", { additions: 62, deletions: 0 }))).toBe("+62");
    expect(entryCounts(entry("a.ts", ".D", "ordinary", { additions: 0, deletions: 5 }))).toBe("−5");
    expect(entryCounts(entry("a.ts", "R.", "renamed", { additions: 0, deletions: 0 }))).toBe("+0");
    expect(entryCounts(entry("logo.png", "??", "untracked"))).toBe("–");
    expect(entryName(entry("Web/terminal/src/md.ts", ".M"))).toBe("md.ts");
    expect(entryName(entry("src/new.ts", "R.", "renamed", { origPath: "src/old.ts" }))).toBe("old.ts → new.ts");
  });

  it("asks the index's diff for a staged-only file and says what each diff compares", () => {
    const unstaged = entry("a.ts", ".M");
    const stagedOnly = entry("b.ts", "M.");
    const both = entry("c.ts", "MM");
    const untracked = entry("d.ts", "??", "untracked");
    expect(wantsStaged(unstaged)).toBe(false);
    expect(wantsStaged(stagedOnly)).toBe(true);
    expect(wantsStaged(both)).toBe(false);
    expect(wantsStaged(untracked)).toBe(false);
    expect(wantsStaged(entry("e.ts", "UU", "unmerged"))).toBe(false);
    expect(diffWhat(unstaged, false)).toBe("working tree against HEAD");
    expect(diffWhat(stagedOnly, true)).toBe("index against HEAD");
    expect(diffWhat(both, false)).toBe("working tree against index");
    expect(diffWhat(untracked, false)).toBe("untracked, all added");
  });
});

describe("the status body", () => {
  it("reads the route's shape and fills what is missing with its zero", () => {
    const parsed = parseStatus({
      ok: true,
      root: "/w/r",
      branch: "main",
      upstream: "origin/main",
      ahead: 2,
      behind: 1,
      detached: false,
      files: [
        { path: "a.txt", index: ".", worktree: "M", kind: "ordinary", additions: 2, deletions: 1 },
        { path: "new.txt", index: "R", worktree: ".", kind: "renamed", origPath: "old.txt" },
        { path: 7 },
        { path: "odd.txt", kind: "later" },
      ],
      counts: { changed: 3, staged: 1, unstaged: 1, untracked: 1, conflicts: 0 },
    });
    expect(parsed.root).toBe("/w/r");
    expect(parsed.branch).toBe("main");
    expect(parsed.ahead).toBe(2);
    expect(parsed.files.map((f) => f.path)).toEqual(["a.txt", "new.txt", "odd.txt"]);
    expect(parsed.files[0]).toEqual({ path: "a.txt", index: ".", worktree: "M", kind: "ordinary", additions: 2, deletions: 1 });
    expect(parsed.files[1].origPath).toBe("old.txt");
    expect(parsed.files[2]).toEqual({ path: "odd.txt", index: ".", worktree: ".", kind: "ordinary" });
    expect(parsed.counts).toEqual({ changed: 3, staged: 1, unstaged: 1, untracked: 1, conflicts: 0 });
    const empty = parseStatus({});
    expect(empty).toEqual({
      root: "",
      branch: null,
      upstream: null,
      ahead: 0,
      behind: 0,
      detached: false,
      files: [],
      counts: { changed: 0, staged: 0, unstaged: 0, untracked: 0, conflicts: 0 },
    });
  });
});

describe("the unified diff", () => {
  const text = [
    "diff --git a/a.txt b/a.txt",
    "index 4cb29ea..6addb9b 100644",
    "--- a/a.txt",
    "+++ b/a.txt",
    "@@ -1,3 +1,4 @@",
    " one",
    "-two",
    "+TWO",
    " three",
    "+four",
    "@@ -10 +11,2 @@ function f() {",
    " ten",
    "+eleven",
    "\\ No newline at end of file",
    "",
  ].join("\n");

  it("keeps the hunks with their numbers, counts the lines and drops the header", () => {
    const diff = parseUnifiedDiff(text);
    expect(diff.added).toBe(3);
    expect(diff.removed).toBe(1);
    expect(diff.hunks).toHaveLength(2);
    expect(hunkHeader(diff.hunks[0])).toBe("@@ -1,3 +1,4 @@");
    expect(diff.hunks[0].lines).toEqual([
      { kind: "context", text: "one", oldNumber: 1, newNumber: 1 },
      { kind: "del", text: "two", oldNumber: 2 },
      { kind: "add", text: "TWO", newNumber: 2 },
      { kind: "context", text: "three", oldNumber: 3, newNumber: 3 },
      { kind: "add", text: "four", newNumber: 4 },
    ]);
    expect(hunkHeader(diff.hunks[1])).toBe("@@ -10 +11,2 @@");
    expect(diff.hunks[1].lines).toEqual([
      { kind: "context", text: "ten", oldNumber: 10, newNumber: 11 },
      { kind: "add", text: "eleven", newNumber: 12 },
      { kind: "note", text: "\\ No newline at end of file" },
    ]);
  });

  it("reads an all-added file and an empty diff", () => {
    const added = parseUnifiedDiff("diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1,2 @@\n+new\n+file\n");
    expect(added.added).toBe(2);
    expect(added.hunks[0].oldStart).toBe(0);
    expect(added.hunks[0].oldLines).toBe(0);
    expect(added.hunks[0].lines.map((l) => l.newNumber)).toEqual([1, 2]);
    expect(parseUnifiedDiff("")).toEqual({ hunks: [], added: 0, removed: 0 });
    expect(parseUnifiedDiff("Binary files a/x and b/x differ\n")).toEqual({ hunks: [], added: 0, removed: 0 });
  });
});
