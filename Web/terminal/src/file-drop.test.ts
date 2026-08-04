import { describe, expect, it, vi } from "vitest";

import {
  MAX_FILES_PER_DROP,
  dragMayCarryFiles,
  readDrop,
  insertionText,
  quoteForShell,
  uploadDroppedFile,
  uploadDroppedFiles,
} from "./file-drop";

function fakeFile(name: string, contents = "x") {
  return {
    name,
    size: contents.length,
    arrayBuffer: async () => new TextEncoder().encode(contents).buffer,
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response;
}

describe("quoteForShell", () => {
  it("leaves ordinary paths alone", () => {
    expect(quoteForShell("/Users/a/.kitterm/drops/abc/notes.md")).toBe(
      "/Users/a/.kitterm/drops/abc/notes.md",
    );
  });

  // The daemon sanitises the filename, but the home directory above it is the
  // user's and may contain anything.
  it("quotes a path with a space", () => {
    expect(quoteForShell("/Users/My Name/drops/a.md")).toBe("'/Users/My Name/drops/a.md'");
  });

  it("escapes an embedded single quote rather than ending the quoting", () => {
    const quoted = quoteForShell("/Users/o'brien/a.md");
    expect(quoted.startsWith("'")).toBe(true);
    expect(quoted.endsWith("'")).toBe(true);
    expect(quoted).not.toBe("'/Users/o'brien/a.md'");
  });
});

describe("insertionText", () => {
  it("is empty when nothing uploaded", () => {
    expect(insertionText([])).toBe("");
  });

  // A trailing space so what you type next does not run into the path.
  it("joins paths and leaves a trailing space", () => {
    const text = insertionText([
      { path: "/drops/a.md", name: "a.md", bytes: 1 },
      { path: "/drops/b.png", name: "b.png", bytes: 2 },
    ]);
    expect(text).toBe("/drops/a.md /drops/b.png ");
  });

  it("never contains a newline, so nothing can run on its own", () => {
    const text = insertionText([{ path: "/drops/a.md", name: "a.md", bytes: 1 }]);
    expect(text).not.toContain("\n");
    expect(text).not.toContain("\r");
  });
});

describe("uploadDroppedFile", () => {
  it("posts the bytes and returns where they landed", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({ ok: true, path: "/drops/s/notes.md", name: "notes.md", bytes: 9 }),
    );
    const result = await uploadDroppedFile("sess-1", fakeFile("notes.md"), fetchImpl as never);
    expect(result.path).toBe("/drops/s/notes.md");

    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("/api/sessions/sess-1/files");
    expect(init.method).toBe("POST");
    expect((init.headers as Record<string, string>)["X-Kitterm-Filename"]).toBe("notes.md");
  });

  // A name is not a path, and must not be able to become one in the URL.
  it("encodes a hostile filename into the header", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({ ok: true, path: "/drops/s/x", name: "x", bytes: 1 }));
    await uploadDroppedFile("s", fakeFile("../../etc/passwd"), fetchImpl as never);
    const [, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    const header = (init.headers as Record<string, string>)["X-Kitterm-Filename"];
    expect(header).not.toContain("/");
    expect(decodeURIComponent(header)).toBe("../../etc/passwd");
  });

  it("explains a file that was too large", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({}, 413));
    await expect(
      uploadDroppedFile("s", fakeFile("big.bin"), fetchImpl as never),
    ).rejects.toThrow(/too large/);
  });

  it("explains a watch-only view", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({}, 403));
    await expect(uploadDroppedFile("s", fakeFile("a.md"), fetchImpl as never)).rejects.toThrow(
      /watch-only/,
    );
  });
});

describe("uploadDroppedFiles", () => {
  it("keeps going after one file fails", async () => {
    let call = 0;
    const fetchImpl = vi.fn(async () => {
      call += 1;
      return call === 2
        ? jsonResponse({}, 413)
        : jsonResponse({ ok: true, path: `/drops/${call}`, name: `f${call}`, bytes: 1 });
    });
    const { uploaded, errors } = await uploadDroppedFiles(
      "s",
      [fakeFile("a"), fakeFile("b"), fakeFile("c")],
      fetchImpl as never,
    );
    expect(uploaded).toHaveLength(2);
    expect(errors).toHaveLength(1);
  });

  it("takes only the first few of a large drop and says so", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({ ok: true, path: "/drops/x", name: "x", bytes: 1 }),
    );
    const files = Array.from({ length: MAX_FILES_PER_DROP + 5 }, (_, i) => fakeFile(`f${i}`));
    const { uploaded, errors } = await uploadDroppedFiles("s", files, fetchImpl as never);
    expect(uploaded).toHaveLength(MAX_FILES_PER_DROP);
    expect(errors.join(" ")).toMatch(/first/);
  });
});

describe("dragMayCarryFiles", () => {
  it("is true for a file drag and false for a plain text drag", () => {
    expect(dragMayCarryFiles({ types: ["Files"] } as unknown as DataTransfer)).toBe(true);
    expect(dragMayCarryFiles({ types: ["text/plain"] } as unknown as DataTransfer)).toBe(false);
  });

  // Safari withholds the payload mid-drag. Treating "cannot tell" as "no files"
  // is what let the browser navigate to the file and lose the tab.
  it("assumes files when the browser is withholding the drag data", () => {
    expect(dragMayCarryFiles({ types: [] } as unknown as DataTransfer)).toBe(true);
    expect(dragMayCarryFiles(null)).toBe(true);
  });
});

describe("readDrop", () => {
  const file = { name: "new 9.txt", size: 1, arrayBuffer: async () => new ArrayBuffer(1) };

  // The drop that started this: files present, types unhelpful.
  it("finds files even when types said nothing", () => {
    const payload = readDrop({ types: [], files: [file] } as unknown as DataTransfer);
    expect(payload.kind).toBe("files");
    if (payload.kind === "files") expect(payload.files[0].name).toBe("new 9.txt");
  });

  it("falls back to dragged text", () => {
    const payload = readDrop({
      types: ["text/plain"], files: [], getData: () => "some text",
    } as unknown as DataTransfer);
    expect(payload).toEqual({ kind: "text", text: "some text" });
  });

  it("reports nothing usable rather than throwing", () => {
    expect(readDrop(null).kind).toBe("empty");
    expect(readDrop({ types: [], files: [], getData: () => "" } as unknown as DataTransfer).kind)
      .toBe("empty");
  });
});
