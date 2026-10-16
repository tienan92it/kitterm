/**
 * What the pane overlay and the `/md` page share when they show a file.
 *
 * Both views show the same two things — a Markdown file rendered, or any text
 * file as coloured source with line numbers — and say the same words when the
 * file is cut, empty or cannot be read (`corpus/01-approved-design.md`, rule
 * 6). The choice between rendered and source is one key in `localStorage`,
 * so a reader who picked source in the overlay gets source on the page.
 *
 * A link inside a rendered file is decided here, not in the renderer: a
 * relative `.md` path is resolved against the file's own directory and
 * handed to the view that owns the navigation; a `#fragment` scrolls to the
 * heading it names. Nothing here fetches: the overlay reaches files through
 * its pane's session, the page through a route, and each hands this module
 * the URL rule it uses.
 */

import { tokenize, languageFor, type Language } from "./highlight";
import { fragmentTarget, parseMarkdown, renderMarkdown } from "./markdown";

export type MarkdownView = "rendered" | "source";

/** The viewer's choice, shared by the overlay and the page. */
export const VIEW_KEY = "kitterm.markdown.view";

/** The choice kept per viewer; `rendered` when none is kept or storage fails. */
export function loadView(): MarkdownView {
  try {
    return localStorage.getItem(VIEW_KEY) === "source" ? "source" : "rendered";
  } catch {
    return "rendered";
  }
}

export function saveView(view: MarkdownView): void {
  try {
    localStorage.setItem(VIEW_KEY, view);
  } catch {
    // A viewer with no storage keeps the default next time; the choice still
    // holds for this view.
  }
}

/** Whether the name is a Markdown file by the grammar table (`.md`, `.markdown`, `.mdx`). */
export function isMarkdownName(name: string): boolean {
  return languageFor(name) === "md";
}

/** Bytes for a human: the size a listing would show, not an exact count. */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

// MARK: - The words (rule 6)

/** The header's sub line for a cut file: `1.2 MB · the first 256 KB shown`. */
export function cutHeader(totalBytes: number, shownBytes: number): string {
  return `${formatBytes(totalBytes)} · the first ${formatBytes(shownBytes)} shown`;
}

/** The last line of a cut file: `Showing the first 256 KB of 1.2 MB.` */
export function cutFooter(totalBytes: number, shownBytes: number): string {
  return `Showing the first ${formatBytes(shownBytes)} of ${formatBytes(totalBytes)}.`;
}

/** `Cannot read docs/goals/LOOP.md: the daemon answered 404.` */
export function cannotRead(path: string, reason: string): string {
  return `Cannot read ${path}: ${reason}.`;
}

/** `NOTES.md is empty.` */
export function emptyFile(name: string): string {
  return `${name} is empty.`;
}

/** The reason for a response that is not 200: the status, and the daemon's
 * own word when it adds something to the status (`the daemon answered 413:
 * file over 262144 bytes`; a 404's `not found` adds nothing). */
export function daemonAnswered(status: number, error: string | null = null): string {
  const word = error?.trim();
  return word && word !== "not found" ? `the daemon answered ${status}: ${word}` : `the daemon answered ${status}`;
}

export const DAEMON_UNREACHABLE = "the daemon did not answer";

/** The `error` field of a JSON error body, or `null` when the body is not one. */
export async function errorWord(response: Response): Promise<string | null> {
  try {
    const body = (await response.json()) as { error?: unknown };
    return typeof body.error === "string" ? body.error : null;
  } catch {
    return null;
  }
}

// MARK: - Paths

/** The last path component: `README.md` for `/a/b/README.md`; the whole path when it has no `/`. */
export function basename(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1) || path;
}

/** `path#fragment` split; the fragment without its `#`, `""` with none. */
export function splitFragment(target: string): { path: string; fragment: string } {
  const hash = target.indexOf("#");
  if (hash < 0) return { path: target, fragment: "" };
  return { path: target.slice(0, hash), fragment: target.slice(hash + 1) };
}

/**
 * `link` resolved against the directory of `from`. `from` is the file the
 * link was read in, absolute (`/a/b/c.md`) or relative to a root
 * (`goal/STATE.md`, a knowledge path); a `link` that starts with `/` is
 * taken as it is. `.` and `..` are folded; a `..` above the root of an
 * absolute path is dropped, and one above a relative path is kept, so the
 * daemon's own refusal of it is what the reader sees.
 */
export function resolveRelative(from: string, link: string): string {
  if (link.startsWith("/")) return link;
  const absolute = from.startsWith("/");
  const directory = from.slice(0, from.lastIndexOf("/") + 1);
  const out: string[] = [];
  for (const segment of `${directory}${link}`.split("/")) {
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      if (out.length > 0 && out[out.length - 1] !== "..") out.pop();
      else if (!absolute) out.push("..");
      continue;
    }
    out.push(segment);
  }
  return `${absolute ? "/" : ""}${out.join("/")}`;
}

const SCHEME = /^[a-z][a-z0-9+.-]*:/i;

/** A path with no scheme and no host: the only kind an image may load from. */
export function isRelativePath(src: string): boolean {
  const compact = src.replace(/[\s\u0000-\u001f\u007f]/g, "");
  if (compact === "" || compact.startsWith("#")) return false;
  if (compact.startsWith("//") || compact.startsWith("\\\\")) return false;
  return !SCHEME.test(compact);
}

/**
 * The image rule for a file at `path`: a relative `src` resolves against the
 * file's directory to the URL `url` builds, so the daemon decides what the
 * bytes are and an `<img>` whose request answers a non-image shows nothing;
 * anything else is its alt text and its address, as the renderer's default.
 */
export function imageResolver(path: string, url: (path: string) => string): (src: string) => string | null {
  return (src) => (isRelativePath(src) ? url(resolveRelative(path, src.trim())) : null);
}

// MARK: - The views

/**
 * The source, in a gutter-and-code pair.
 *
 * The gutter is one text node rather than an element per line: a 5000-line file
 * would otherwise cost 5000 elements before a single word is coloured. Both
 * columns share the pane's line height, which is what keeps the numbers level
 * with their lines.
 */
export function sourceView(text: string, language: Language): HTMLElement {
  // A file's last newline ends its last line; it does not start another.
  const source = text.endsWith("\n") ? text.slice(0, -1) : text;

  const view = document.createElement("div");
  view.className = "preview-code";

  const gutter = document.createElement("div");
  gutter.className = "code-gutter";
  // The numbers are scenery for a screen reader, and they are not selectable,
  // so copying a block of code copies the code.
  gutter.setAttribute("aria-hidden", "true");
  const lines = source.split("\n").length;
  gutter.textContent = Array.from({ length: lines }, (_, i) => String(i + 1)).join("\n");

  const code = document.createElement("pre");
  code.className = "code-text";
  for (const token of tokenize(source, language)) {
    if (token.kind === "plain") {
      code.append(document.createTextNode(token.text));
      continue;
    }
    const span = document.createElement("span");
    span.className = `tok-${token.kind}`;
    // Never innerHTML. The file may be the hostile one.
    span.textContent = token.text;
    code.append(span);
  }

  view.append(gutter, code);
  return view;
}

export interface RenderedOptions {
  /** The image rule; the default shows every image as text. */
  resolveImage?: (src: string) => string | null;
  /** A relative `.md` link was clicked: the path as written and the fragment, `""` with none. */
  onOpen?: (path: string, fragment: string) => void;
}

/**
 * The rendered file in a `.md-body`. A `#fragment` link scrolls inside the
 * body; a `.md` link goes to `onOpen`, which the overlay and the page answer
 * each in their own way. Every element comes from the renderer, so the body
 * carries nothing the renderer did not set.
 */
export function renderedView(text: string, options: RenderedOptions = {}): HTMLElement {
  const body = document.createElement("div");
  body.className = "md-body";
  body.append(renderMarkdown(parseMarkdown(text), { resolveImage: options.resolveImage }));
  for (const anchor of body.querySelectorAll("[data-markdown]")) {
    anchor.addEventListener("click", (event) => {
      const target = anchor.getAttribute("data-markdown") ?? "";
      const { path, fragment } = splitFragment(target);
      if (path === "") {
        // The heading is on this page; the browser's own jump would also
        // rewrite the pane's location hash.
        if (scrollToFragment(body, fragment)) event.preventDefault();
        return;
      }
      event.preventDefault();
      options.onOpen?.(path, fragment);
    });
  }
  return body;
}

/** Scroll to the heading `fragment` names under `root`; false when no heading carries that id. */
export function scrollToFragment(root: ParentNode, fragment: string): boolean {
  const id = fragmentTarget(fragment);
  if (id === "") return false;
  // A heading id is `md-` plus a slug, so a quoted attribute match needs no
  // escaping and works where `CSS.escape` is absent.
  const target = root.querySelector(`[id="${id.replace(/["\\]/g, "")}"]`);
  if (!target) return false;
  (target as HTMLElement).scrollIntoView();
  return true;
}

/** `[x] rendered [ ] source`: a radio group that prints its state as text. */
export function viewToggle(current: MarkdownView, onChange: (view: MarkdownView) => void): HTMLElement {
  const group = document.createElement("div");
  group.className = "view-toggle";
  group.setAttribute("role", "radiogroup");
  group.setAttribute("aria-label", "View");
  const choices: MarkdownView[] = ["rendered", "source"];
  const buttons = choices.map((choice) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "view-choice";
    button.setAttribute("role", "radio");
    button.dataset.view = choice;
    button.dataset.focus = `view:${choice}`;
    button.addEventListener("click", () => {
      if (button.getAttribute("aria-checked") === "true") return;
      paint(choice);
      onChange(choice);
    });
    return button;
  });
  const paint = (view: MarkdownView): void => {
    buttons.forEach((button, i) => {
      const on = choices[i] === view;
      button.setAttribute("aria-checked", on ? "true" : "false");
      button.textContent = `[${on ? "x" : " "}] ${choices[i]}`;
    });
  };
  paint(current);
  group.append(...buttons);
  return group;
}

/** One centred sentence in the body: the cut line, the error, the empty file. */
export function noteLine(text: string): HTMLElement {
  const note = document.createElement("p");
  note.className = "preview-note";
  note.textContent = text;
  return note;
}
