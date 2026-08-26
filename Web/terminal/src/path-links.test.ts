import { describe, expect, it } from "vitest";

import { StatCache, rangeFor } from "./path-links";

const stat = (over: Partial<{ exists: boolean; dir: boolean; resolved: string }> = {}) => ({
  exists: true,
  dir: false,
  resolved: "/x",
  ...over,
});

describe("rangeFor", () => {
  // xterm counts from 1 and includes both ends; a candidate counts from 0 and
  // excludes its end. Getting this wrong underlines the wrong characters, which
  // no test of the detection alone would catch.
  it("converts a candidate's columns into xterm's coordinates", () => {
    expect(rangeFor({ text: "src/a.ts", start: 6, end: 14 }, 3)).toEqual({
      start: { x: 7, y: 4 },
      end: { x: 14, y: 4 },
    });
  });

  it("handles a candidate at the start of the row", () => {
    expect(rangeFor({ text: "ab", start: 0, end: 2 }, 0)).toEqual({
      start: { x: 1, y: 1 },
      end: { x: 2, y: 1 },
    });
  });

  it("spans exactly as many columns as the text is long", () => {
    const range = rangeFor({ text: "abcd", start: 10, end: 14 }, 0);
    expect(range.end.x - range.start.x + 1).toBe(4);
  });
});

describe("StatCache", () => {
  it("remembers an answer", () => {
    const cache = new StatCache();
    cache.set("a.ts", stat());
    expect(cache.get("a.ts")?.exists).toBe(true);
  });

  // Output repeats itself: a build log names the same missing file on every
  // line. Without a negative entry each render would ask about it again.
  it("remembers a no, so repeated output asks once", () => {
    const cache = new StatCache();
    cache.set("gone.ts", stat({ exists: false }));
    expect(cache.has("gone.ts")).toBe(true);
    expect(cache.unknown(["gone.ts"])).toEqual([]);
  });

  it("reports only what it has never been asked", () => {
    const cache = new StatCache();
    cache.set("a", stat());
    expect(cache.unknown(["a", "b", "c"])).toEqual(["b", "c"]);
  });

  it("asks about a repeated token once per batch", () => {
    const cache = new StatCache();
    expect(cache.unknown(["a", "a", "b", "a"])).toEqual(["a", "b"]);
  });

  // The whole reason the cache is keyed on the directory: `src/main.ts` names a
  // different file once the shell has moved.
  it("forgets everything when the directory changes", () => {
    const cache = new StatCache();
    cache.setContext("/repo");
    cache.set("src/main.ts", stat());
    expect(cache.size).toBe(1);

    cache.setContext("/other");
    expect(cache.has("src/main.ts")).toBe(false);
    expect(cache.size).toBe(0);
  });

  it("keeps what it knows while the directory holds still", () => {
    const cache = new StatCache();
    cache.setContext("/repo");
    cache.set("a", stat());
    cache.setContext("/repo");
    expect(cache.has("a")).toBe(true);
  });

  it("treats an unknown directory as its own context", () => {
    const cache = new StatCache();
    cache.setContext(null);
    cache.set("a", stat());
    cache.setContext(null);
    expect(cache.has("a")).toBe(true);
    cache.setContext("/repo");
    expect(cache.has("a")).toBe(false);
  });
});
