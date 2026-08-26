import { describe, expect, it } from "vitest";

import { looksLikePath, pathCandidates, trimSurroundings } from "./links";

const texts = (line: string) => pathCandidates(line).map((c) => c.text);

describe("trimSurroundings", () => {
  const trim = (text: string) => trimSurroundings({ text, start: 0, end: text.length }).text;

  it("drops the sentence's punctuation, not the path's", () => {
    expect(trim("src/main.ts.")).toBe("src/main.ts");
    expect(trim("src/main.ts,")).toBe("src/main.ts");
    expect(trim('"src/main.ts"')).toBe("src/main.ts");
  });

  it("unwraps a pair the sentence put around the path", () => {
    expect(trim("(src/main.ts)")).toBe("src/main.ts");
    expect(trim("[src/main.ts]")).toBe("src/main.ts");
  });

  it("drops a closer with no opener to match it", () => {
    expect(trim("src/main.ts)")).toBe("src/main.ts");
  });

  // A real path may contain brackets, and a compiler prints them constantly.
  it("keeps a closer the token opened itself", () => {
    expect(trim("logs[0].json")).toBe("logs[0].json");
    expect(trim("a/b(1).txt")).toBe("a/b(1).txt");
  });

  it("reports the range it trimmed to", () => {
    const out = trimSurroundings({ text: "a/b.ts).", start: 10, end: 18 });
    expect(out).toEqual({ text: "a/b.ts", start: 10, end: 16 });
  });
});

describe("looksLikePath", () => {
  it("accepts the unambiguous shapes", () => {
    for (const t of ["/etc/hosts", "~/notes.md", "./run.sh", "../pkg/x.go", "src/main.ts"]) {
      expect(looksLikePath(t)).toBe(true);
    }
  });

  it("accepts a bare filename that carries an extension", () => {
    expect(looksLikePath("README.md")).toBe(true);
    expect(looksLikePath("Dockerfile")).toBe(false);
  });

  // Each of these would cost a round trip on nearly every line of output.
  it("rejects what is not worth asking about", () => {
    expect(looksLikePath("the")).toBe(false);
    expect(looksLikePath("-v")).toBe(false);
    expect(looksLikePath("--force")).toBe(false);
    expect(looksLikePath("a")).toBe(false);
  });

  // Those belong to the web-links addon, which needs no confirmation.
  it("leaves URLs alone", () => {
    expect(looksLikePath("https://example.com/a.png")).toBe(false);
    expect(looksLikePath("file:///tmp/x")).toBe(false);
  });
});

describe("pathCandidates", () => {
  it("finds a path in a sentence and reports its columns", () => {
    const line = "wrote src/main.ts ok";
    expect(pathCandidates(line)).toEqual([{ text: "src/main.ts", start: 6, end: 17 }]);
  });

  it("finds several on one line", () => {
    expect(texts("cp /tmp/a.txt ~/b.txt")).toEqual(["/tmp/a.txt", "~/b.txt"]);
  });

  it("finds nothing in ordinary prose", () => {
    expect(texts("Compiling the project now")).toEqual([]);
  });

  it("survives an empty line", () => {
    expect(texts("")).toEqual([]);
  });

  // The shape a compiler actually prints.
  it("handles a diagnostic line", () => {
    expect(texts("ERROR in ./src/app.tsx:12:5")).toContain("./src/app.tsx:12:5");
  });
});
