import { describe, expect, it, vi } from "vitest";

import {
  childPath,
  clampSelection,
  describeSize,
  fetchListing,
  filterByQuery,
  matchScore,
  placeAtCursor,
} from "./file-picker";

describe("childPath", () => {
  it("joins without doubling or dropping the separator", () => {
    expect(childPath("/a/b", "c.txt")).toBe("/a/b/c.txt");
    expect(childPath("/", "etc")).toBe("/etc");
  });

  // Browsing reports real names; a space is the caller's problem to quote,
  // not ours to mangle — unlike a dropped file, nothing is renamed here.
  it("leaves awkward names intact", () => {
    expect(childPath("/a", "new 9.txt")).toBe("/a/new 9.txt");
  });
});

describe("describeSize", () => {
  it("scales units and says nothing for directories", () => {
    expect(describeSize({ name: "a", dir: false, size: 512 })).toBe("512 B");
    expect(describeSize({ name: "a", dir: false, size: 2048 })).toBe("2.0 KB");
    expect(describeSize({ name: "d", dir: true })).toBe("");
    expect(describeSize({ name: "a", dir: false })).toBe("");
  });
});

describe("fetchListing", () => {
  const ok = (body: unknown) =>
    ({ ok: true, status: 200, json: async () => body }) as Response;

  it("passes the path and session through", async () => {
    const fetchImpl = vi.fn(async () => ok({ ok: true, path: "/x", entries: [] }));
    await fetchListing("/x", "sess-1", fetchImpl as never);
    const url = (fetchImpl.mock.calls[0] as unknown as [string])[0];
    expect(url).toContain("path=%2Fx");
    expect(url).toContain("session=sess-1");
  });

  // Relative paths resolve against the session's directory on the daemon,
  // so omitting the path is meaningful rather than an error.
  it("omits the path when none is given", async () => {
    const fetchImpl = vi.fn(async () => ok({ ok: true, path: "/home", entries: [] }));
    await fetchListing(null, null, fetchImpl as never);
    expect((fetchImpl.mock.calls[0] as unknown as [string])[0]).not.toContain("path=");
  });

  it("explains a watch-only view", async () => {
    const fetchImpl = vi.fn(async () => ({ ok: false, status: 403 }) as Response);
    await expect(fetchListing(null, null, fetchImpl as never)).rejects.toThrow(/watch-only/);
  });

  it("reports an unlistable folder rather than returning junk", async () => {
    const fetchImpl = vi.fn(async () => ({ ok: false, status: 404 }) as Response);
    await expect(fetchListing("/nope", null, fetchImpl as never)).rejects.toThrow(/could not be listed/);
  });
});

describe("clampSelection", () => {
  // Holding an arrow key should come to rest at the end, not cycle.
  it("stops at both ends rather than wrapping", () => {
    expect(clampSelection(-1, 5)).toBe(0);
    expect(clampSelection(9, 5)).toBe(4);
    expect(clampSelection(2, 5)).toBe(2);
  });

  it("survives an empty list", () => {
    expect(clampSelection(3, 0)).toBe(0);
  });
});

describe("placeAtCursor", () => {
  const panel = { width: 360, height: 280 };
  const pane = { width: 1000, height: 800 };

  it("opens just below the cursor", () => {
    const at = placeAtCursor({ left: 120, top: 200, lineHeight: 18 }, panel, pane);
    expect(at.left).toBe(120);
    expect(at.top).toBe(208);
  });

  // Near the bottom it flips above, so the panel never covers the line you
  // are typing on — which is the line you are picking a file for.
  it("flips above the cursor when there is no room below", () => {
    const at = placeAtCursor({ left: 100, top: 780, lineHeight: 18 }, panel, pane);
    expect(at.top).toBeLessThan(780);
    expect(at.top).toBeGreaterThanOrEqual(8);
  });

  it("stays inside the pane on the right edge", () => {
    const at = placeAtCursor({ left: 980, top: 100, lineHeight: 18 }, panel, pane);
    expect(at.left + panel.width).toBeLessThanOrEqual(pane.width);
  });

  // The flip-above branch can compute a negative top near the top of the
  // pane, which put the panel partly off the edge.
  it("never places the panel above the pane's top edge", () => {
    const at = placeAtCursor({ left: 100, top: 30, lineHeight: 18 }, panel, { width: 900, height: 300 });
    expect(at.top).toBeGreaterThanOrEqual(8);
  });

  it("does not go off the left edge in a narrow pane", () => {
    const at = placeAtCursor({ left: 5, top: 40, lineHeight: 18 }, panel, { width: 200, height: 300 });
    expect(at.left).toBeGreaterThanOrEqual(8);
  });
});

describe("matchScore", () => {
  it("ranks prefix above substring above subsequence", () => {
    expect(matchScore("terminal-pane.ts", "term")).toBe(0);
    expect(matchScore("terminal-pane.ts", "pane")).toBe(1);
    expect(matchScore("terminal-pane.ts", "tpane")).toBe(2);
  });

  it("rejects a name the query cannot be found in", () => {
    expect(matchScore("readme.md", "xyz")).toBeNull();
  });

  it("ignores case and treats an empty query as a match", () => {
    expect(matchScore("README.md", "readme")).toBe(0);
    expect(matchScore("anything", "")).toBe(0);
  });
});

describe("filterByQuery", () => {
  const rows = [
    { label: "..", isParent: true },
    { label: "Sources", isParent: false },
    { label: "terminal-pane.ts", isParent: false },
    { label: "styles.css", isParent: false },
  ];

  it("returns everything, parent included, for an empty query", () => {
    expect(filterByQuery(rows, "")).toHaveLength(4);
  });

  // The parent link is navigation, not a search result.
  it("drops the parent link once a query is typed", () => {
    expect(filterByQuery(rows, "s").some((r) => r.isParent)).toBe(false);
  });

  it("orders better matches first", () => {
    // "s" prefixes Sources and styles.css; terminal-pane.ts only subsequences.
    const labels = filterByQuery(rows, "s").map((r) => r.label);
    expect(labels[0]).toBe("Sources");
    expect(labels).toContain("styles.css");
  });

  it("finds a scattered subsequence", () => {
    expect(filterByQuery(rows, "tpane").map((r) => r.label)).toEqual(["terminal-pane.ts"]);
  });

  it("returns nothing when nothing matches", () => {
    expect(filterByQuery(rows, "zzzz")).toEqual([]);
  });
});
