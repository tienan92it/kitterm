/**
 * The pure parts of the `/edit` page (`code-editor` round 4, the frames of
 * `design/editor.pen` and `corpus/02-approved-design.md` rules 2, 6 and
 * the components frame's rules 2, 3, 10, 11 and 12): the buffer's state
 * machine and its words, the bar under the header, the read-only
 * decisions, the bytes of a file as text and back (the BOM and the line
 * ending kept), the header's facts, and the page's URLs.
 *
 * Nothing here touches the DOM, the clock or the network; `edit.ts` paints
 * what this decides, and `edit-fetch.ts` talks to the daemon.
 */

import { LanguageDescription } from "@codemirror/language";

import { basename, formatBytes } from "./markdown-view";
import { homePath } from "./sessions-tree";

// MARK: - The buffer

/** What the buffer is, against the disk. */
export type BufferState = "clean" | "edited" | "saving" | "saved" | "read-only";

/** The bar under the header: none, the disk moved under an edited buffer
 * (`?`), or a save was refused with 412 (`!`). */
export type BarKind = "none" | "changed" | "refused";

export interface EditorModel {
  state: BufferState;
  bar: BarKind;
}

export type EditorEvent =
  | { type: "edit" }
  /** The buffer equals the text its tag names again (an undo). */
  | { type: "unchanged" }
  | { type: "save-start" }
  | { type: "save-ok" }
  | { type: "save-conflict" }
  | { type: "save-failed" }
  | { type: "disk-changed" }
  | { type: "reload" }
  | { type: "keep-mine" };

export const INITIAL_MODEL: EditorModel = { state: "clean", bar: "none" };

/** The model for a file the page will not save. */
export const READ_ONLY_MODEL: EditorModel = { state: "read-only", bar: "none" };

/**
 * The next model. A read-only buffer takes no event. An edit during a save
 * makes the buffer edited again, so the save's `saved` never claims what
 * the user typed after the PUT left; an undo back to the text the tag
 * names reads clean again. A refused save leaves the buffer
 * edited under the `!` bar; `keep-mine` is a save with the disk's tag,
 * which the caller starts.
 */
export function reduce(model: EditorModel, event: EditorEvent): EditorModel {
  if (model.state === "read-only") return model;
  switch (event.type) {
    case "edit":
      return { ...model, state: "edited" };
    case "unchanged":
      return model.state === "edited" ? { ...model, state: "clean" } : model;
    case "save-start":
    case "keep-mine":
      return { ...model, state: "saving" };
    case "save-ok":
      return { state: model.state === "saving" ? "saved" : "edited", bar: "none" };
    case "save-conflict":
      return { state: "edited", bar: "refused" };
    case "save-failed":
      return { ...model, state: "edited" };
    case "disk-changed":
      return diskChangeAction(model.state) === "reload" ? model : { ...model, bar: "changed" };
    case "reload":
      return { state: "clean", bar: "none" };
  }
}

/** What a new tag on the disk means: an unedited buffer reloads silently,
 * an edited one gets the bar (the work's step 5). */
export function diskChangeAction(state: BufferState): "reload" | "bar" {
  return state === "clean" || state === "saved" || state === "read-only" ? "reload" : "bar";
}

/** Whether leaving the page would lose typed work. */
export function hasUnsavedWork(model: EditorModel): boolean {
  return model.state === "edited" || model.state === "saving";
}

// MARK: - The words

/** The header's state run: the mark and the word, and the colour that
 * paints both (rule 3 of the components frame). `null` while the buffer
 * equals the disk and nothing has happened. */
export interface StateRun {
  mark: string;
  word: string;
  tone: "warning" | "accent" | "success" | "faint";
}

export function stateRun(state: BufferState): StateRun | null {
  switch (state) {
    case "clean":
      return null;
    case "edited":
      return { mark: "●", word: "edited", tone: "warning" };
    case "saving":
      return { mark: "◐", word: "saving", tone: "accent" };
    case "saved":
      return { mark: "✓", word: "saved", tone: "success" };
    case "read-only":
      return { mark: "–", word: "read only", tone: "faint" };
  }
}

export const CHANGED_ON_DISK = "Changed on disk since you opened it.";
export const NOT_SAVED = "Not saved: changed on disk since you opened it.";
export const NO_PROJECT = "No project here: open /edit from a shell inside a checkout.";
export const NO_FILE_NAMED = "No file named. Open /edit?path=<file>&session=<id>.";

/** The bar's sentence and mark for a kind, `null` with no bar. */
export function barLine(bar: BarKind): { mark: string; tone: "warning" | "danger"; text: string } | null {
  if (bar === "changed") return { mark: "?", tone: "warning", text: CHANGED_ON_DISK };
  if (bar === "refused") return { mark: "!", tone: "danger", text: NOT_SAVED };
  return null;
}

/** `src is empty.` under a folder with nothing in it. */
export function emptyFolder(name: string): string {
  return `${name} is empty.`;
}

/** A save the daemon refused for a reason that is not the content: the
 * `!` bar's sentence with the daemon's word, `Not saved: the daemon
 * answered 403: outside every project.` */
export function notSaved(reason: string): string {
  return `Not saved: ${reason}.`;
}

// MARK: - Read only

/** What the read said about the bytes, as far as the page's decision needs. */
export interface ReadFacts {
  kind: string;
  contentType: string | null;
  truncated: boolean;
  totalBytes: number;
  shownBytes: number;
  utf8: boolean;
}

/**
 * The sentence that makes the file read only, or `null` for a file the
 * page saves (rule 11 of the components frame). A cut file first, because
 * a save would drop its rest whatever its kind; then a kind that is not
 * text; then bytes that are not UTF-8, which the editor cannot hold
 * without changing them.
 */
export function readOnlyReason(facts: ReadFacts): string | null {
  if (facts.truncated) {
    return `Read only: ${formatBytes(facts.totalBytes)}, the first ${formatBytes(facts.shownBytes)} shown. A save would drop the rest.`;
  }
  if (facts.kind !== "text") {
    const type = facts.contentType?.split(";")[0].trim() || facts.kind;
    return `Read only: not text (${type}).`;
  }
  if (!facts.utf8) return "Read only: the bytes are not UTF-8.";
  return null;
}

// MARK: - The bytes

export type LineEnding = "LF" | "CRLF";

/** A file's bytes as the editor holds them, and what to put back on save. */
export interface DecodedText {
  text: string;
  utf8: boolean;
  bom: boolean;
  lineEnding: LineEnding;
}

const BOM = [0xef, 0xbb, 0xbf];

/**
 * The bytes as text: a UTF-8 BOM is taken off and remembered, a `\r\n`
 * ending is remembered and the text is kept as the file wrote it (the
 * editor splits lines on either), and bytes that are not UTF-8 decode to
 * what a lenient decoder gives, with `utf8` false so the page refuses to
 * save them.
 */
export function decodeText(bytes: Uint8Array): DecodedText {
  const bom = bytes.length >= 3 && bytes[0] === BOM[0] && bytes[1] === BOM[1] && bytes[2] === BOM[2];
  const body = bom ? bytes.subarray(3) : bytes;
  let text: string;
  let utf8 = true;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(body);
  } catch {
    text = new TextDecoder("utf-8", { ignoreBOM: true }).decode(body);
    utf8 = false;
  }
  return { text, utf8, bom, lineEnding: text.includes("\r\n") ? "CRLF" : "LF" };
}

/**
 * The bytes to save: the editor's text (its lines joined with `\n`) with
 * the file's own line ending and its BOM put back, so a save changes only
 * what was typed.
 */
export function encodeText(text: string, shape: { bom: boolean; lineEnding: LineEnding }): Uint8Array {
  const joined = shape.lineEnding === "CRLF" ? text.replace(/\r?\n/g, "\r\n") : text;
  const body = new TextEncoder().encode(joined);
  if (!shape.bom) return body;
  const out = new Uint8Array(body.length + 3);
  out.set(BOM, 0);
  out.set(body, 3);
  return out;
}

// MARK: - The header

/** The language of a file by its name, from CodeMirror's own list. */
export function languageOf(filename: string, descriptions: readonly LanguageDescription[]): LanguageDescription | null {
  return LanguageDescription.matchFilename(descriptions, filename);
}

/** `TypeScript · LF · UTF-8`, the header's facts. */
export function headerFacts(language: string | null, decoded: { lineEnding: LineEnding; bom: boolean }): string {
  return [language ?? "Plain text", decoded.lineEnding, decoded.bom ? "UTF-8 BOM" : "UTF-8"].join(" · ");
}

/** The header's name: the project and the path under its root, or the
 * path alone (under the home directory as `~/…`) with no project. */
export function headerName(project: { name: string; relative: string } | null, path: string): { project: string | null; path: string } {
  if (project) return { project: project.name, path: project.relative };
  return { project: null, path: homePath(path) };
}

// MARK: - URLs

/** `/edit?path=<file>&session=<id>`, the page's own URL for a file. */
export function editUrl(path: string, session: string | null = null): string {
  const params = new URLSearchParams({ path });
  if (session) params.set("session", session);
  return `/edit?${params.toString()}`;
}

/** `/?cwd=<the file's directory>`: `open in terminal`. */
export function terminalUrl(path: string): string {
  const directory = path.slice(0, path.lastIndexOf("/")) || "/";
  return `/?cwd=${encodeURIComponent(directory)}`;
}

/** The content route for a path through a session, the read and the save. */
export function contentUrl(path: string, session: string | null = null): string {
  const params = new URLSearchParams({ path });
  if (session) params.set("session", session);
  return `/api/files/content?${params.toString()}`;
}

/** The project route for a path through a session. */
export function projectUrl(path: string, session: string | null = null): string {
  const params = new URLSearchParams({ path });
  if (session) params.set("session", session);
  return `/api/files/project?${params.toString()}`;
}

/** The listing route for a directory. */
export function listingUrl(path: string, session: string | null = null): string {
  const params = new URLSearchParams({ path });
  if (session) params.set("session", session);
  return `/api/files?${params.toString()}`;
}

/** The page's title: `md.ts — kitterm`. */
export function pageTitle(path: string): string {
  return `${basename(path)} — kitterm`;
}
