import { describe, expect, it } from "vitest";

import { fuzzyMatch, highlightRuns, matchPath, splitPath } from "./palette-match";

describe("fuzzyMatch", () => {
  it("matches a subsequence case-insensitively and reports its positions in order", () => {
    const result = fuzzyMatch("doc", "GoalsLayoutDocsTests.swift");
    expect(result).not.toBeNull();
    expect(result!.positions).toEqual([11, 12, 13]);
    expect(result!.positions).toEqual([...result!.positions].sort((a, b) => a - b));
  });

  it("finds no match for a query that is not a subsequence", () => {
    expect(fuzzyMatch("xyz", "readme.md")).toBeNull();
    expect(fuzzyMatch("toolong", "ab")).toBeNull();
  });

  it("matches an empty query against anything, with no positions and no score", () => {
    const result = fuzzyMatch("", "anything.ts");
    expect(result).toEqual({ score: 0, positions: [] });
  });

  it("ranks a consecutive run over the same letters scattered apart", () => {
    const consecutive = fuzzyMatch("ab", "xabx")!;
    const scattered = fuzzyMatch("ab", "xaxbx")!;
    expect(consecutive.score).toBeGreaterThan(scattered.score);
  });

  it("ranks a match that starts a word or a path segment over one that does not", () => {
    // "Docs" starts a camelCase word in the first candidate; the same three
    // letters sit mid-word, with no boundary, in the second.
    const atWordStart = fuzzyMatch("doc", "layoutDocsTest")!;
    const midWord = fuzzyMatch("doc", "layoutdocstest")!;
    expect(atWordStart.score).toBeGreaterThan(midWord.score);

    // A path segment start ("/docs") outranks a match with no boundary at all.
    const atSegmentStart = fuzzyMatch("doc", "src/docs.md", 4)!;
    const noBoundary = fuzzyMatch("doc", "sardocs.md", 0)!;
    expect(atSegmentStart.score).toBeGreaterThan(noBoundary.score);
  });

  it("ranks a match inside the base name over the same letters in the directory alone", () => {
    const inBaseName = fuzzyMatch("doc", "src/x/docs.md", 6)!;
    const inDirectory = fuzzyMatch("doc", "docs/x/y.md", 5)!;
    expect(inBaseName.score).toBeGreaterThan(inDirectory.score);
  });

  it("breaks a tie in score with the earlier candidate left to the caller: two equal matches score equal", () => {
    const a = fuzzyMatch("ab", "ab.ts")!;
    const b = fuzzyMatch("ab", "ab.go")!;
    expect(a.score).toBe(b.score);
  });
});

describe("matchPath", () => {
  it("scores the base-name bonus from the path's own last segment", () => {
    const inName = matchPath("doc", "src/x/docs.md")!;
    const inDirOnly = matchPath("doc", "docs/x/y.md")!;
    expect(inName.score).toBeGreaterThan(inDirOnly.score);
  });

  it("matches a path with no directory like a bare name", () => {
    expect(matchPath("doc", "docs.md")).toEqual(fuzzyMatch("doc", "docs.md", 0));
  });
});

describe("splitPath", () => {
  it("splits the base name from the directory", () => {
    expect(splitPath("Tests/KittermCLITests/GoalsLayoutDocsTests.swift")).toEqual({
      name: "GoalsLayoutDocsTests.swift",
      directory: "Tests/KittermCLITests",
    });
  });

  it("has no directory at the root", () => {
    expect(splitPath("README.md")).toEqual({ name: "README.md", directory: "" });
  });
});

describe("highlightRuns", () => {
  it("splits a name into matched and plain runs at the matched positions", () => {
    const match = fuzzyMatch("ab", "xaxb")!;
    expect(highlightRuns("xaxb", match.positions, 0)).toEqual([
      { text: "x", matched: false },
      { text: "a", matched: true },
      { text: "x", matched: false },
      { text: "b", matched: true },
    ]);
  });

  it("joins a consecutive run of matched letters into one run", () => {
    const match = fuzzyMatch("ab", "xabx")!;
    expect(highlightRuns("xabx", match.positions, 0)).toEqual([
      { text: "x", matched: false },
      { text: "ab", matched: true },
      { text: "x", matched: false },
    ]);
  });

  it("never marks a position before offset: a match in the directory paints no letter of the name", () => {
    // "src/" (4 chars) then "docs.md"; a match at index 1 ('r' of "src")
    // sits before the base name's offset and must not appear as a run.
    const positions = [1];
    expect(highlightRuns("docs.md", positions, 4)).toEqual([{ text: "docs.md", matched: false }]);
  });

  it("returns the whole name unmatched with no positions", () => {
    expect(highlightRuns("plain.ts", [], 0)).toEqual([{ text: "plain.ts", matched: false }]);
  });
});
