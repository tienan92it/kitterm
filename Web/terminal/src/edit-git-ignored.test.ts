import { describe, expect, it } from "vitest";

import { isIgnoredPath, parseStatus } from "./edit-git";

// The ignored paths of `GET /api/git/status` (`code-editor` round 13, rule
// 19 of `corpus/09-approved-frames.md`): never in `files` or `counts`, so
// the tree dims a path without counting it as a change.

describe("parseStatus", () => {
  it("reads the ignored paths and the truncated flag", () => {
    const status = parseStatus({ root: "/w/kitterm", files: [], counts: {}, ignored: [".build/", "debug.log"], ignoredTruncated: true });
    expect(status.ignored).toEqual([".build/", "debug.log"]);
    expect(status.ignoredTruncated).toBe(true);
  });

  it("leaves both unset for a body with neither, like branches and writes", () => {
    const status = parseStatus({ root: "/w/kitterm", files: [], counts: {} });
    expect(status.ignored).toBeUndefined();
    expect(status.ignoredTruncated).toBeUndefined();
  });

  it("sets an empty ignored array, not undefined, when the body carries one", () => {
    const status = parseStatus({ root: "/w/kitterm", files: [], counts: {}, ignored: [] });
    expect(status.ignored).toEqual([]);
  });
});

describe("isIgnoredPath", () => {
  const status = parseStatus({ root: "/w/kitterm", files: [], counts: {}, ignored: [".build/", "Web/terminal/node_modules/", "debug.log"] });

  it("is false with no status or no ignored paths", () => {
    expect(isIgnoredPath(null, "/w/kitterm/.build")).toBe(false);
    expect(isIgnoredPath(parseStatus({ root: "/w/kitterm", files: [], counts: {} }), "/w/kitterm/.build")).toBe(false);
  });

  it("is true for an ignored directory itself and an ignored file", () => {
    expect(isIgnoredPath(status, "/w/kitterm/.build")).toBe(true);
    expect(isIgnoredPath(status, "/w/kitterm/debug.log")).toBe(true);
  });

  it("is true for anything under an ignored directory, at any depth", () => {
    expect(isIgnoredPath(status, "/w/kitterm/.build/x.txt")).toBe(true);
    expect(isIgnoredPath(status, "/w/kitterm/Web/terminal/node_modules/pkg/index.js")).toBe(true);
  });

  it("is false for a path that only shares a prefix with an ignored name", () => {
    expect(isIgnoredPath(status, "/w/kitterm/.build-tools")).toBe(false);
    expect(isIgnoredPath(status, "/w/kitterm/Web/terminal/node_modules2")).toBe(false);
  });

  it("is false for a tracked path and for one outside the root", () => {
    expect(isIgnoredPath(status, "/w/kitterm/src/a.ts")).toBe(false);
    expect(isIgnoredPath(status, "/w/other/.build")).toBe(false);
  });

  it("is true for the root itself when the root is ignored", () => {
    const rootIgnored = parseStatus({ root: "/w/kitterm", files: [], counts: {}, ignored: [""] });
    expect(isIgnoredPath(rootIgnored, "/w/kitterm")).toBe(true);
  });
});
