import { languages } from "@codemirror/language-data";
import { describe, expect, it } from "vitest";

import {
  barLine,
  CHANGED_ON_DISK,
  contentUrl,
  decodeText,
  diskChangeAction,
  editUrl,
  type EditorModel,
  encodeText,
  hasUnsavedWork,
  headerFacts,
  headerName,
  INITIAL_MODEL,
  languageOf,
  listingUrl,
  NOT_SAVED,
  notSaved,
  projectUrl,
  READ_ONLY_MODEL,
  readOnlyReason,
  reduce,
  stateRun,
  terminalUrl,
} from "./edit-model";

// The pure parts of the `/edit` page: the buffer's state machine and its
// words (`corpus/02-approved-design.md` rule 6, the components frame's
// rules 3, 10 and 11), the read-only decisions, the bytes, the facts and
// the URLs.

const run = (model: EditorModel, ...events: Parameters<typeof reduce>[1][]): EditorModel =>
  events.reduce((m, e) => reduce(m, e), model);

describe("the buffer's state machine", () => {
  it("starts clean with no state word and the save control quiet", () => {
    expect(INITIAL_MODEL).toEqual({ state: "clean", bar: "none" });
    expect(stateRun("clean")).toBeNull();
    expect(hasUnsavedWork(INITIAL_MODEL)).toBe(false);
  });

  it("reads ● edited, ◐ saving, ✓ saved after an edit, a save and its answer", () => {
    const edited = reduce(INITIAL_MODEL, { type: "edit" });
    expect(edited.state).toBe("edited");
    expect(stateRun("edited")).toEqual({ mark: "●", word: "edited", tone: "warning" });
    expect(hasUnsavedWork(edited)).toBe(true);
    const saving = reduce(edited, { type: "save-start" });
    expect(stateRun(saving.state)).toEqual({ mark: "◐", word: "saving", tone: "accent" });
    const saved = reduce(saving, { type: "save-ok" });
    expect(saved).toEqual({ state: "saved", bar: "none" });
    expect(stateRun("saved")).toEqual({ mark: "✓", word: "saved", tone: "success" });
    expect(hasUnsavedWork(saved)).toBe(false);
    // The next edit takes the word away again.
    expect(reduce(saved, { type: "edit" }).state).toBe("edited");
  });

  it("reads clean again when an undo brings the buffer back to the text its tag names", () => {
    const edited = reduce(INITIAL_MODEL, { type: "edit" });
    expect(reduce(edited, { type: "unchanged" })).toEqual({ state: "clean", bar: "none" });
    // Under the ? bar the bar stays: the disk still differs from the tag.
    const under = reduce(edited, { type: "disk-changed" });
    expect(reduce(under, { type: "unchanged" })).toEqual({ state: "clean", bar: "changed" });
    // A saving or a saved buffer is not edited, so the event changes nothing.
    const saving = reduce(edited, { type: "save-start" });
    expect(reduce(saving, { type: "unchanged" })).toBe(saving);
  });

  it("keeps the buffer edited when a keystroke lands during the save", () => {
    const typedDuringSave = run(INITIAL_MODEL, { type: "edit" }, { type: "save-start" }, { type: "edit" });
    expect(typedDuringSave.state).toBe("edited");
    expect(reduce(typedDuringSave, { type: "save-ok" }).state).toBe("edited");
  });

  it("raises the ! bar on a 412 and keeps the buffer edited", () => {
    const refused = run(INITIAL_MODEL, { type: "edit" }, { type: "save-start" }, { type: "save-conflict" });
    expect(refused).toEqual({ state: "edited", bar: "refused" });
    expect(barLine("refused")).toEqual({ mark: "!", tone: "danger", text: NOT_SAVED });
    expect(NOT_SAVED).toBe("Not saved: changed on disk since you opened it.");
    // keep mine is a save; its success clears the bar.
    expect(run(refused, { type: "keep-mine" }).state).toBe("saving");
    expect(run(refused, { type: "keep-mine" }, { type: "save-ok" })).toEqual({ state: "saved", bar: "none" });
    // reload takes the disk's bytes and clears it too.
    expect(reduce(refused, { type: "reload" })).toEqual({ state: "clean", bar: "none" });
  });

  it("raises the ? bar when the disk moves under an edited buffer, and reloads silently under a clean one", () => {
    const edited = reduce(INITIAL_MODEL, { type: "edit" });
    expect(reduce(edited, { type: "disk-changed" })).toEqual({ state: "edited", bar: "changed" });
    expect(barLine("changed")).toEqual({ mark: "?", tone: "warning", text: CHANGED_ON_DISK });
    expect(CHANGED_ON_DISK).toBe("Changed on disk since you opened it.");
    expect(diskChangeAction("edited")).toBe("bar");
    expect(diskChangeAction("saving")).toBe("bar");
    expect(diskChangeAction("clean")).toBe("reload");
    expect(diskChangeAction("saved")).toBe("reload");
    expect(reduce(INITIAL_MODEL, { type: "disk-changed" })).toEqual(INITIAL_MODEL);
    expect(barLine("none")).toBeNull();
  });

  it("keeps a failed save edited with no bar of its own", () => {
    const failed = run(INITIAL_MODEL, { type: "edit" }, { type: "save-start" }, { type: "save-failed" });
    expect(failed).toEqual({ state: "edited", bar: "none" });
    expect(notSaved("the daemon answered 403: outside every project")).toBe(
      "Not saved: the daemon answered 403: outside every project.",
    );
  });

  it("holds a read-only buffer through every event", () => {
    expect(stateRun("read-only")).toEqual({ mark: "–", word: "read only", tone: "faint" });
    for (const type of ["edit", "unchanged", "save-start", "save-ok", "save-conflict", "disk-changed", "reload", "keep-mine"] as const) {
      expect(reduce(READ_ONLY_MODEL, { type })).toBe(READ_ONLY_MODEL);
    }
    expect(diskChangeAction("read-only")).toBe("reload");
    expect(hasUnsavedWork(READ_ONLY_MODEL)).toBe(false);
  });
});

describe("the read-only decisions (rule 11)", () => {
  const text = { kind: "text", contentType: "text/plain; charset=utf-8", truncated: false, totalBytes: 10, shownBytes: 10, utf8: true };

  it("saves a whole UTF-8 text file", () => {
    expect(readOnlyReason(text)).toBeNull();
  });

  it("says a cut file is read only, before its kind", () => {
    expect(readOnlyReason({ ...text, truncated: true, totalBytes: 1.2 * 1024 * 1024, shownBytes: 256 * 1024 })).toBe(
      "Read only: 1.2 MB, the first 256 KB shown. A save would drop the rest.",
    );
    expect(readOnlyReason({ ...text, kind: "binary", truncated: true, totalBytes: 2 * 1024 * 1024, shownBytes: 256 * 1024 })).toMatch(
      /^Read only: 2.0 MB, the first 256 KB shown/,
    );
  });

  it("names the type of a file that is not text", () => {
    expect(readOnlyReason({ ...text, kind: "image", contentType: "image/png" })).toBe("Read only: not text (image/png).");
    expect(readOnlyReason({ ...text, kind: "binary", contentType: "application/octet-stream" })).toBe(
      "Read only: not text (application/octet-stream).",
    );
    expect(readOnlyReason({ ...text, kind: "pdf", contentType: null })).toBe("Read only: not text (pdf).");
  });

  it("refuses bytes that are not UTF-8", () => {
    expect(readOnlyReason({ ...text, utf8: false })).toBe("Read only: the bytes are not UTF-8.");
  });
});

describe("the bytes", () => {
  it("takes a BOM off and puts it back, and keeps CRLF on save", () => {
    const bytes = new Uint8Array([0xef, 0xbb, 0xbf, ...new TextEncoder().encode("a\r\nb\r\n")]);
    const decoded = decodeText(bytes);
    expect(decoded).toEqual({ text: "a\r\nb\r\n", utf8: true, bom: true, lineEnding: "CRLF" });
    // The editor joins lines with \n; the save restores the file's shape.
    expect(Array.from(encodeText("a\nb\nc\n", decoded))).toEqual(Array.from(new Uint8Array([0xef, 0xbb, 0xbf, ...new TextEncoder().encode("a\r\nb\r\nc\r\n")])));
    expect(headerFacts("TypeScript", decoded)).toBe("TypeScript · CRLF · UTF-8 BOM");
  });

  it("reads a plain LF file as it is and writes it back unchanged", () => {
    const decoded = decodeText(new TextEncoder().encode("let a = 1;\n"));
    expect(decoded).toEqual({ text: "let a = 1;\n", utf8: true, bom: false, lineEnding: "LF" });
    expect(new TextDecoder().decode(encodeText("let a = 2;\n", decoded))).toBe("let a = 2;\n");
    expect(headerFacts("TypeScript", decoded)).toBe("TypeScript · LF · UTF-8");
    expect(headerFacts(null, decoded)).toBe("Plain text · LF · UTF-8");
  });

  it("flags bytes that are not UTF-8", () => {
    const decoded = decodeText(new Uint8Array([0x61, 0xff, 0x62]));
    expect(decoded.utf8).toBe(false);
    expect(decoded.text).toBe("a�b");
  });
});

describe("the language, from CodeMirror's own list", () => {
  it("names TypeScript, Python, Markdown and nothing for an unknown name", () => {
    expect(languageOf("md.ts", languages)?.name).toBe("TypeScript");
    expect(languageOf("tool.py", languages)?.name).toBe("Python");
    expect(languageOf("README.md", languages)?.name).toBe("Markdown");
    expect(languageOf("Package.swift", languages)?.name).toBe("Swift");
    expect(languageOf("notes.unknownext", languages)).toBeNull();
    expect(languageOf("Dockerfile", languages)?.name).toBe("Dockerfile");
  });
});

describe("the header and the URLs", () => {
  it("names the project and the path under its root, or the path alone", () => {
    expect(headerName({ name: "kitterm", relative: "Web/terminal/src/md.ts" }, "/Users/antran/Workspace/kitterm/Web/terminal/src/md.ts")).toEqual({
      project: "kitterm",
      path: "Web/terminal/src/md.ts",
    });
    expect(headerName(null, "/Users/antran/notes.txt")).toEqual({ project: null, path: "~/notes.txt" });
  });

  it("builds the page's, the terminal's and the routes' URLs", () => {
    expect(editUrl("/w/a b.ts", "S1")).toBe("/edit?path=%2Fw%2Fa+b.ts&session=S1");
    expect(editUrl("/w/a.ts")).toBe("/edit?path=%2Fw%2Fa.ts");
    expect(terminalUrl("/w/src/a.ts")).toBe("/?cwd=%2Fw%2Fsrc");
    expect(terminalUrl("/a.ts")).toBe("/?cwd=%2F");
    expect(contentUrl("/w/a.ts", "S1")).toBe("/api/files/content?path=%2Fw%2Fa.ts&session=S1");
    expect(projectUrl("/w/a.ts")).toBe("/api/files/project?path=%2Fw%2Fa.ts");
    expect(listingUrl("/w", "S1")).toBe("/api/files?path=%2Fw&session=S1");
  });
});
