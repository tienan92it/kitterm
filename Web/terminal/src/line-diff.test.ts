import { describe, expect, it } from "vitest";

import { diffCounts, hunkHeader, lineDiff, splitLines } from "./line-diff";

// `compare` on the `/edit` page (`corpus/02-approved-design.md` rule 8):
// the unified diff of the disk against the buffer, by line, in git's shape.

const render = (oldText: string, newText: string): string[] => {
  const diff = lineDiff(oldText, newText);
  const out: string[] = [];
  for (const hunk of diff.hunks) {
    out.push(hunkHeader(hunk));
    for (const line of hunk.lines) out.push(`${line.kind === "add" ? "+" : line.kind === "del" ? "-" : " "}${line.text}`);
  }
  return out;
};

describe("splitLines", () => {
  it("ends the last line at the last newline and keeps an empty text empty", () => {
    expect(splitLines("a\nb\n")).toEqual(["a", "b"]);
    expect(splitLines("a\nb")).toEqual(["a", "b"]);
    expect(splitLines("")).toEqual([]);
    expect(splitLines("\n")).toEqual([""]);
  });
});

describe("lineDiff", () => {
  it("gives no hunk for equal texts", () => {
    const diff = lineDiff("a\nb\n", "a\nb\n");
    expect(diff.hunks).toEqual([]);
    expect(diffCounts(diff)).toBe("+0 −0");
  });

  it("marks a changed line as a deletion and an addition with three lines of context", () => {
    const old = ["1", "2", "3", "4", "5", "6", "7", "8", "9"].join("\n") + "\n";
    const next = ["1", "2", "3", "4", "five", "6", "7", "8", "9"].join("\n") + "\n";
    expect(render(old, next)).toEqual(["@@ -2,7 +2,7 @@", " 2", " 3", " 4", "-5", "+five", " 6", " 7", " 8"]);
    const diff = lineDiff(old, next);
    expect(diffCounts(diff)).toBe("+1 −1");
    expect(diff.hunks[0].lines[3]).toEqual({ kind: "del", text: "5", oldNumber: 5 });
    expect(diff.hunks[0].lines[4]).toEqual({ kind: "add", text: "five", newNumber: 5 });
    expect(diff.hunks[0].lines[0]).toEqual({ kind: "context", text: "2", oldNumber: 2, newNumber: 2 });
  });

  it("joins two changes within six lines into one hunk and splits farther ones", () => {
    const base = Array.from({ length: 30 }, (_, i) => String(i + 1));
    const near = [...base];
    near[4] = "x";
    near[9] = "y";
    const one = lineDiff(base.join("\n"), near.join("\n"));
    expect(one.hunks).toHaveLength(1);
    expect(hunkHeader(one.hunks[0])).toBe("@@ -2,12 +2,12 @@");
    const far = [...base];
    far[2] = "x";
    far[25] = "y";
    const two = lineDiff(base.join("\n"), far.join("\n"));
    expect(two.hunks).toHaveLength(2);
    expect(hunkHeader(two.hunks[0])).toBe("@@ -1,6 +1,6 @@");
    expect(hunkHeader(two.hunks[1])).toBe("@@ -23,7 +23,7 @@");
  });

  it("counts the lines added to the end and removed from the start", () => {
    const diff = lineDiff("a\nb\n", "b\nc\nd\n");
    expect(render("a\nb\n", "b\nc\nd\n")).toEqual(["@@ -1,2 +1,3 @@", "-a", " b", "+c", "+d"]);
    expect(diff.added).toBe(2);
    expect(diff.removed).toBe(1);
  });

  it("prints git's header for an empty old text and a one-line range", () => {
    expect(render("", "a\nb\nc\n")).toEqual(["@@ -0,0 +1,3 @@", "+a", "+b", "+c"]);
    expect(render("a\n", "")).toEqual(["@@ -1 +0,0 @@", "-a"]);
    expect(render("a\n", "b\n")).toEqual(["@@ -1 +1 @@", "-a", "+b"]);
  });

  it("finds the shortest script, not the first difference", () => {
    // Myers keeps the common `b c d` and takes one deletion and one
    // insertion; a first-difference scanner would rewrite every line.
    const diff = lineDiff("a\nb\nc\nd\n", "b\nc\nd\ne\n");
    expect(diff.added).toBe(1);
    expect(diff.removed).toBe(1);
  });

  it("handles a few thousand lines", () => {
    const old = Array.from({ length: 4000 }, (_, i) => `line ${i}`);
    const next = old.map((line, i) => (i % 97 === 0 ? `${line} changed` : line));
    const diff = lineDiff(old.join("\n"), next.join("\n"));
    expect(diff.added).toBe(42);
    expect(diff.removed).toBe(42);
  });
});
