import { describe, expect, it } from "vitest";

import { readFile, readListing, readProject, saveFile } from "./edit-fetch";

// The `/edit` page against the daemon (`rounds/003.md`'s route API): the
// read with `If-None-Match`, the save with `X-Kitterm-Editor: 1` and
// `If-Match`, and what each answer becomes.

interface Sent {
  url: string;
  init: RequestInit | undefined;
}

const fake = (answer: (sent: Sent) => Response | Error) => {
  const sent: Sent[] = [];
  const fetch = async (url: string, init?: RequestInit): Promise<Response> => {
    sent.push({ url, init });
    const out = answer({ url, init });
    if (out instanceof Error) throw out;
    return out;
  };
  return { fetch, sent };
};

const header = (sent: Sent, name: string): string | undefined => (sent.init?.headers as Record<string, string> | undefined)?.[name];

describe("readFile", () => {
  it("sends If-None-Match and reads the tag, the kind and the counts", async () => {
    const { fetch, sent } = fake(
      () =>
        new Response("hello\n", {
          status: 200,
          headers: {
            ETag: '"sha256:abc"',
            "X-Kitterm-Kind": "text",
            "X-Kitterm-Total-Bytes": "6",
            "X-Kitterm-Truncated": "0",
            "X-Kitterm-Mode": "644",
            "Content-Type": "text/plain; charset=utf-8",
          },
        }),
    );
    const result = await readFile(fetch, "/api/files/content?path=a", '"sha256:old"');
    expect(header(sent[0], "If-None-Match")).toBe('"sha256:old"');
    expect(sent[0].init?.cache).toBe("no-store");
    expect(result).toMatchObject({ kind: "file", etag: '"sha256:abc"', fileKind: "text", totalBytes: 6, truncated: false, mode: "644" });
    expect(new TextDecoder().decode((result as { bytes: Uint8Array }).bytes)).toBe("hello\n");
  });

  it("reads 304 as unchanged and sends no header without a tag", async () => {
    const { fetch, sent } = fake(() => new Response(null, { status: 304 }));
    expect(await readFile(fetch, "/u", '"sha256:abc"')).toEqual({ kind: "unchanged" });
    const plain = fake(() => new Response("x", { status: 200 }));
    await readFile(plain.fetch, "/u");
    expect(header(plain.sent[0], "If-None-Match")).toBeUndefined();
    expect(sent).toHaveLength(1);
  });

  it("says the daemon's word on an error and names an unreachable daemon", async () => {
    const refused = fake(() => new Response(JSON.stringify({ ok: false, error: "watch-only token" }), { status: 403 }));
    expect(await readFile(refused.fetch, "/u")).toEqual({ kind: "error", status: 403, reason: "the daemon answered 403: watch-only token" });
    const gone = fake(() => new Error("network"));
    expect(await readFile(gone.fetch, "/u")).toEqual({ kind: "error", status: null, reason: "the daemon did not answer" });
  });

  it("reads a cut file with no tag", async () => {
    const { fetch } = fake(
      () => new Response("x".repeat(10), { status: 200, headers: { "X-Kitterm-Kind": "text", "X-Kitterm-Total-Bytes": "300000", "X-Kitterm-Truncated": "1" } }),
    );
    expect(await readFile(fetch, "/u")).toMatchObject({ kind: "file", etag: null, truncated: true, totalBytes: 300000 });
  });
});

describe("saveFile", () => {
  const bytes = new TextEncoder().encode("mine\n");

  it("PUTs the bytes with the editor header and If-Match, and keeps the new tag on 200", async () => {
    const { fetch, sent } = fake(() => new Response(JSON.stringify({ ok: true, etag: '"sha256:new"', bytes: 5 }), { status: 200, headers: { ETag: '"sha256:new"' } }));
    const result = await saveFile(fetch, "/api/files/content?path=a&session=S", bytes, '"sha256:old"');
    expect(result).toEqual({ kind: "saved", etag: '"sha256:new"' });
    expect(sent[0].init?.method).toBe("PUT");
    expect(sent[0].init?.credentials).toBe("same-origin");
    expect(header(sent[0], "X-Kitterm-Editor")).toBe("1");
    expect(header(sent[0], "If-Match")).toBe('"sha256:old"');
    expect(sent[0].init?.body).toBe(bytes);
  });

  it("reads a 412 as a conflict with the disk's current tag", async () => {
    const { fetch } = fake(
      () => new Response(JSON.stringify({ ok: false, error: "If-Match does not name the current content", etag: '"sha256:disk"' }), { status: 412, headers: { ETag: '"sha256:disk"' } }),
    );
    expect(await saveFile(fetch, "/u", bytes, '"sha256:old"')).toEqual({ kind: "conflict", etag: '"sha256:disk"' });
    // The body's tag when the header is missing; null when neither is.
    const bodyOnly = fake(() => new Response(JSON.stringify({ ok: false, etag: '"sha256:b"' }), { status: 412 }));
    expect(await saveFile(bodyOnly.fetch, "/u", bytes, '"sha256:old"')).toEqual({ kind: "conflict", etag: '"sha256:b"' });
    const neither = fake(() => new Response(JSON.stringify({ ok: false }), { status: 412 }));
    expect(await saveFile(neither.fetch, "/u", bytes, '"sha256:old"')).toEqual({ kind: "conflict", etag: null });
  });

  it("names every other refusal with the daemon's sentence", async () => {
    const cases: Array<[number, string, string]> = [
      [428, "If-Match is required: the ETag the read gave", "the daemon answered 428: If-Match is required: the ETag the read gave"],
      [403, "outside every project", "the daemon answered 403: outside every project"],
      [409, "hard-linked file", "the daemon answered 409: hard-linked file"],
      [413, "body exceeds 262144 bytes", "the daemon answered 413: body exceeds 262144 bytes"],
    ];
    for (const [status, error, reason] of cases) {
      const { fetch } = fake(() => new Response(JSON.stringify({ ok: false, error }), { status }));
      expect(await saveFile(fetch, "/u", bytes, '"sha256:old"'), String(status)).toEqual({ kind: "refused", status, reason });
    }
    const gone = fake(() => new Error("network"));
    expect(await saveFile(gone.fetch, "/u", bytes, '"sha256:old"')).toEqual({ kind: "refused", status: null, reason: "the daemon did not answer" });
    const tagless = fake(() => new Response(JSON.stringify({ ok: true }), { status: 200 }));
    expect(await saveFile(tagless.fetch, "/u", bytes, '"sha256:old"')).toMatchObject({ kind: "refused", status: 200 });
  });
});

describe("readProject and readListing", () => {
  it("reads the project and the resolved path, or no project", async () => {
    const withProject = fake(() => new Response(JSON.stringify({ ok: true, path: "/w/k/src/a.ts", project: { id: "k", name: "kitterm", root: "/w/k", relative: "src/a.ts" } })));
    expect(await readProject(withProject.fetch, "/u")).toEqual({
      kind: "ok",
      answer: { path: "/w/k/src/a.ts", project: { id: "k", name: "kitterm", root: "/w/k", relative: "src/a.ts" } },
    });
    const loose = fake(() => new Response(JSON.stringify({ ok: true, path: "/tmp/a.ts" })));
    expect(await readProject(loose.fetch, "/u")).toEqual({ kind: "ok", answer: { path: "/tmp/a.ts", project: null } });
    const missing = fake(() => new Response(JSON.stringify({ ok: false, error: "no such directory" }), { status: 404 }));
    expect(await readProject(missing.fetch, "/u")).toEqual({ kind: "error", status: 404, reason: "the daemon answered 404: no such directory" });
  });

  it("reads a listing's entries in the daemon's order", async () => {
    const { fetch } = fake(() => new Response(JSON.stringify({ ok: true, path: "/w", entries: [{ name: "src", dir: true }, { name: "a.ts", dir: false, size: 12 }] })));
    expect(await readListing(fetch, "/u")).toEqual({ kind: "ok", entries: [{ name: "src", dir: true }, { name: "a.ts", dir: false, size: 12 }] });
    const refused = fake(() => new Response(JSON.stringify({ ok: false, error: "cannot list that directory" }), { status: 404 }));
    expect(await readListing(refused.fetch, "/u")).toEqual({ kind: "error", status: 404, reason: "the daemon answered 404: cannot list that directory" });
  });
});
