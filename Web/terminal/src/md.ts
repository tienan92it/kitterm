/**
 * The `/md` page: one file, full width.
 *
 * `?path=<file>` reads the file through `GET /api/files/content` (full
 * grade), the route the pane overlay reads through, so `open full width`
 * shows what the overlay showed. `?project=<id>&path=<knowledge path>` reads
 * a goal's file through `GET /api/projects/<id>/knowledge/<path>` (watch
 * grade), the route the fleet view's goal and record links used to open
 * raw; they open here now. The daemon decides what the bytes are on both.
 *
 * The page is the overlay without the card: one header bar with the path
 * and the size at the left and `[x] rendered [ ] source` at the right, then
 * the file in a column of at most 72 characters, centred. The rendered view,
 * the source view, the toggle's key and the words of rule 6 are the shared
 * ones in `markdown-view.ts`. A `.md` link inside the file navigates within
 * the page in the same form, so a knowledge file's links stay on the
 * knowledge route. A path that is not Markdown shows as source alone.
 */

import "./tokens.css";
import "./styles.css";
import "./md.css";

import { resolveFontFamily } from "./fonts";
import { languageFor } from "./highlight";
import { fragmentTarget } from "./markdown";
import {
  basename,
  cannotRead,
  cutFooter,
  cutHeader,
  DAEMON_UNREACHABLE,
  daemonAnswered,
  emptyFile,
  errorWord,
  formatBytes,
  imageResolver,
  isMarkdownName,
  loadView,
  noteLine,
  renderedView,
  resolveRelative,
  saveView,
  scrollToFragment,
  sourceView,
  viewToggle,
  type MarkdownView,
} from "./markdown-view";
import { knowledgeUrl } from "./sessions-model";
import { homePath } from "./sessions-tree";
import { loadSettings } from "./settings-store";
import { applyThemeTokens } from "./theme-tokens";
import { findThemeById } from "./themes";

/** What the query names: a file by its path, or a file of a project's knowledge package. */
export type PageTarget = { kind: "file"; path: string } | { kind: "knowledge"; project: string; path: string };

/** The target the query names, or `null` for a query that names none. */
export function pageTarget(search: string): PageTarget | null {
  const params = new URLSearchParams(search);
  const path = params.get("path");
  if (path === null || path === "") return null;
  const project = params.get("project");
  if (project !== null && project !== "") return { kind: "knowledge", project, path };
  return { kind: "file", path };
}

/** The page's own URL for a target, the path's segments encoded and its slashes kept. */
export function pageUrl(target: PageTarget): string {
  const path = target.path.split("/").map(encodeURIComponent).join("/");
  return target.kind === "file"
    ? `/md?path=${path}`
    : `/md?project=${encodeURIComponent(target.project)}&path=${path}`;
}

/** The preview route for a file by path, with no session: the path is absolute. */
export function fileContentUrl(path: string): string {
  return `/api/files/content?path=${encodeURIComponent(path)}`;
}

/** The route the target's bytes come from. */
export function sourceUrl(target: PageTarget): string {
  return target.kind === "file" ? fileContentUrl(target.path) : knowledgeUrl(target.project, target.path);
}

/** What names the file in a sentence: the path, or `<project> / <path>` for a knowledge file. */
export function pageLabel(target: PageTarget): string {
  return target.kind === "file" ? target.path : `${target.project} / ${target.path}`;
}

/** What the header prints (rule 11): a path under the home directory as
 * `~/…`, the fleet view's rule; the label's full form is the element's title. */
export function pageHeading(target: PageTarget): string {
  return target.kind === "file" ? homePath(target.path) : pageLabel(target);
}

/** The sentence for a page with no target. */
export const NO_TARGET = "No file named. Open /md?path=<file> or /md?project=<id>&path=<knowledge path>.";

/**
 * Paint the page into `root` for the query `search`, scroll to `hash` once
 * the file is in, and go through `navigate` when a `.md` link is clicked.
 */
export async function bootMarkdownPage(
  root: HTMLElement,
  search: string,
  hash: string,
  navigate: (url: string) => void,
): Promise<void> {
  const target = pageTarget(search);

  const header = document.createElement("header");
  header.className = "md-page-header";
  const name = document.createElement("div");
  name.className = "md-page-name";
  const path = document.createElement("span");
  path.className = "md-page-path";
  const size = document.createElement("span");
  size.className = "md-page-size";
  name.append(path, size);
  header.append(name);

  const main = document.createElement("div");
  main.className = "md-page-main";
  root.replaceChildren(header, main);

  if (target === null) {
    path.textContent = "/md";
    main.append(noteLine(NO_TARGET));
    return;
  }

  const label = pageLabel(target);
  const filename = basename(target.path);
  path.textContent = pageHeading(target);
  path.title = label;
  document.title = `${filename} — kitterm`;

  let response: Response;
  try {
    response = await fetch(sourceUrl(target), { credentials: "same-origin" });
  } catch {
    main.append(noteLine(cannotRead(label, DAEMON_UNREACHABLE)));
    return;
  }
  if (!response.ok) {
    main.append(noteLine(cannotRead(label, daemonAnswered(response.status, await errorWord(response)))));
    return;
  }

  // The knowledge route serves whole files as text and sends no kind: a
  // header that is absent reads as the text it is.
  const kind = response.headers.get("X-Kitterm-Kind") ?? "text";
  const body = await response.blob();
  const totalBytes = Number(response.headers.get("X-Kitterm-Total-Bytes") ?? body.size);
  const truncated = response.headers.get("X-Kitterm-Truncated") === "1";
  if (kind !== "text") {
    size.textContent = formatBytes(totalBytes);
    main.append(noteLine("This file has no preview."));
    return;
  }

  const text = await body.text();
  const markdown = isMarkdownName(filename);
  size.textContent = truncated ? cutHeader(totalBytes, body.size) : formatBytes(totalBytes);

  let view: MarkdownView = markdown ? loadView() : "source";
  if (markdown) {
    header.append(
      viewToggle(view, (choice) => {
        view = choice;
        saveView(choice);
        render();
      }),
    );
  }

  const open = (link: string, fragment: string): void => {
    const next: PageTarget = { ...target, path: resolveRelative(target.path, link) };
    navigate(`${pageUrl(next)}${fragment === "" ? "" : `#${fragmentTarget(fragment)}`}`);
  };

  const render = (): void => {
    main.replaceChildren();
    if (markdown && text === "") {
      main.append(noteLine(emptyFile(filename)));
    } else if (markdown && view === "rendered") {
      main.append(
        renderedView(text, {
          // A knowledge file's images stay text: that route serves every
          // file as text, so an `<img>` from it would show nothing.
          resolveImage: target.kind === "file" ? imageResolver(target.path, fileContentUrl) : undefined,
          onOpen: open,
        }),
      );
    } else {
      main.append(sourceView(text, languageFor(filename)));
    }
    if (truncated) main.append(noteLine(cutFooter(totalBytes, body.size)));
  };
  render();
  if (hash !== "") scrollToFragment(main, hash.replace(/^#(md-)?/, ""));
}

const root = document.getElementById("md");
if (root) {
  const settings = loadSettings();
  const theme = findThemeById(settings.themeId);
  applyThemeTokens(theme.colors, {
    accent: theme.accent,
    fontFamily: resolveFontFamily(settings.fontId, settings.localFontFamily),
  });
  void bootMarkdownPage(root, location.search, location.hash, (url) => location.assign(url));
}
