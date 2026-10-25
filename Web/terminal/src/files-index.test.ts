import { describe, expect, it } from "vitest";

import { readFilesIndex } from "./edit-fetch";
import { filesIndexUrl } from "./edit-model";

// `GET /api/files/index` (`code-editor` round 14, rule 8 of
// `corpus/07-projects-and-tree.md`): the file index behind the palette, and
// the URL it is read from.

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

describe("filesIndexUrl", () => {
  it("names the path and, when given, the session", () => {
    expect(filesIndexUrl("/repo")).toBe("/api/files/index?path=%2Frepo");
    expect(filesIndexUrl("/repo/src", "sess-1")).toBe("/api/files/index?path=%2Frepo%2Fsrc&session=sess-1");
  });
});

describe("readFilesIndex", () => {
  it("sends If-None-Match and reads the root, the files and the truncated flag", async () => {
    const { fetch, sent } = fake(
      () =>
        new Response(JSON.stringify({ ok: true, root: "/repo", files: ["a.ts", "src/b.ts"], truncated: false }), {
          status: 200,
          headers: { ETag: '"abc"' },
        }),
    );
    const result = await readFilesIndex(fetch, filesIndexUrl("/repo"), '"old"');
    expect(header(sent[0], "If-None-Match")).toBe('"old"');
    expect(sent[0].init?.cache).toBe("no-store");
    expect(result).toEqual({ kind: "ok", answer: { root: "/repo", files: ["a.ts", "src/b.ts"], truncated: false, etag: '"abc"' } });
  });

  it("marks a cap past the limit", async () => {
    const { fetch } = fake(() => new Response(JSON.stringify({ ok: true, root: "/repo", files: ["a.ts"], truncated: true }), { status: 200 }));
    const result = await readFilesIndex(fetch, "/u");
    expect(result).toMatchObject({ kind: "ok", answer: { truncated: true } });
  });

  it("reads 304 as unchanged", async () => {
    const { fetch } = fake(() => new Response(null, { status: 304 }));
    expect(await readFilesIndex(fetch, "/u", '"abc"')).toEqual({ kind: "unchanged" });
  });

  it("says the daemon's word on a refusal (no repository) and names an unreachable daemon", async () => {
    const refused = fake(() => new Response(JSON.stringify({ ok: false, error: "outside the repository" }), { status: 404 }));
    expect(await readFilesIndex(refused.fetch, "/u")).toEqual({ kind: "error", status: 404, reason: "the daemon answered 404: outside the repository" });
    const gone = fake(() => new Error("network"));
    expect(await readFilesIndex(gone.fetch, "/u")).toEqual({ kind: "error", status: null, reason: "the daemon did not answer" });
  });
});
