import { describe, expect, it, vi } from "vitest";

import { childPath, describeSize, fetchListing } from "./file-picker";

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
