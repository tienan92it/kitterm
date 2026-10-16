/**
 * Showing what a path in the output points at.
 *
 * The daemon has already decided what is safe to render — see `FilePreview` —
 * and says so in `X-Kitterm-Kind`. This trusts that decision rather than
 * sniffing the bytes again: two places guessing at a content type is how one of
 * them ends up wrong.
 *
 * Source is coloured, and every span is built with `textContent`. A file's
 * bytes never become markup here, which is the same rule the daemon follows by
 * refusing to serve HTML as HTML. A Markdown file shows rendered by default,
 * through the renderer in `markdown.ts`, which builds the DOM the same way;
 * `[x] rendered [ ] source` switches to the coloured source, and `open full
 * width` opens the same file at `/md`.
 *
 * The overlay is a peer of the paste prompt and the file picker: it lives inside
 * the pane, closes on Escape or a tap outside, and hands focus back to the
 * terminal underneath.
 */

import { languageFor } from "./highlight";
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

export { formatBytes } from "./markdown-view";

/** What the daemon said about the file it sent. */
export interface PreviewMeta {
  kind: "image" | "pdf" | "text" | "binary";
  totalBytes: number;
  truncated: boolean;
  filename: string;
}

export interface PreviewHandle {
  close(): void;
}

export interface PreviewOptions {
  /** The file's path as the daemon resolved it: what a relative link inside
   * a Markdown file resolves against, and what `open full width` names. */
  path?: string;
  /** The route that serves a path's bytes through this pane's session, for
   * a `.md` link opened in place and for an image. Without it a `.md` link
   * does nothing and every image is text. */
  contentUrl?: (path: string) => string;
}

/** `/md?path=<file>`: the page that shows the same file full width. */
export function fullWidthUrl(path: string): string {
  return `/md?path=${encodeURIComponent(path)}`;
}

/** The meta the route's headers carry, for a fetch the overlay made itself. */
export function metaFromHeaders(headers: Headers, path: string): PreviewMeta {
  return {
    kind: (headers.get("X-Kitterm-Kind") as PreviewMeta["kind"]) || "binary",
    totalBytes: Number(headers.get("X-Kitterm-Total-Bytes") ?? "0"),
    truncated: headers.get("X-Kitterm-Truncated") === "1",
    filename: basename(path),
  };
}

/**
 * The line under the filename: what it is, how big, and whether this is all of
 * it. Truncation is stated rather than implied — a log that stops mid-line
 * otherwise reads as a file that ends there.
 */
export function describePreview(meta: PreviewMeta): string {
  const size = formatBytes(meta.totalBytes);
  if (meta.kind === "binary") return `${size} · not previewable`;
  return meta.truncated ? `${size} · showing the first part` : size;
}

/** Whether the daemon's text is a Markdown file the overlay renders. */
function isMarkdown(meta: PreviewMeta): boolean {
  return meta.kind === "text" && isMarkdownName(meta.filename);
}

/**
 * Show `body` in `host`. The caller has already fetched it, because only the
 * caller knows which session's directory the path was relative to.
 */
export function showPreview(
  host: HTMLElement,
  meta: PreviewMeta,
  body: Blob,
  onClosed?: () => void,
  options: PreviewOptions = {},
): PreviewHandle {
  const scrim = document.createElement("div");
  scrim.className = "preview-scrim";

  const card = document.createElement("div");
  card.className = "preview-card";
  card.setAttribute("role", "dialog");
  card.setAttribute("aria-label", `Preview of ${meta.filename}`);

  const header = document.createElement("div");
  header.className = "preview-header";
  const title = document.createElement("div");
  title.className = "preview-title";
  const sub = document.createElement("div");
  sub.className = "preview-sub";
  const heading = document.createElement("div");
  heading.className = "preview-heading";
  heading.append(title, sub);

  let view: MarkdownView = loadView();
  const controls = document.createElement("div");
  controls.className = "preview-controls";
  const toggle = viewToggle(view, (choice) => {
    view = choice;
    saveView(choice);
    render();
  });
  const openFull = document.createElement("a");
  openFull.className = "preview-open-full";
  openFull.textContent = "open full width";
  openFull.target = "_blank";
  openFull.rel = "noopener";
  const close = document.createElement("button");
  close.type = "button";
  close.className = "preview-close";
  close.textContent = "✕";
  close.setAttribute("aria-label", "Close preview");
  controls.append(toggle, openFull, close);
  header.append(heading, controls);

  const bodyEl = document.createElement("div");
  bodyEl.className = "preview-body";

  // The file on show. A `.md` link replaces all three in place.
  let current = { meta, body, path: options.path ?? null };

  // One object URL per shown file, revoked when the next one replaces it and
  // on close. Without that the blob is held for the life of the page, and a
  // few large previews add up.
  let objectUrl: string | null = null;
  const urlFor = (): string => {
    objectUrl ??= URL.createObjectURL(current.body);
    return objectUrl;
  };
  const revoke = (): void => {
    if (objectUrl) URL.revokeObjectURL(objectUrl);
    objectUrl = null;
  };

  /** The text of the shown file as the view wants it, or the kind's own element. */
  const render = (afterText?: (shown: HTMLElement) => void): void => {
    const { meta, body } = current;
    const markdown = isMarkdown(meta);
    bodyEl.classList.toggle("preview-body-rendered", markdown && view === "rendered");
    bodyEl.replaceChildren();
    if (meta.kind === "image") {
      const img = document.createElement("img");
      img.className = "preview-image";
      img.alt = meta.filename;
      img.src = urlFor();
      bodyEl.append(img);
    } else if (meta.kind === "pdf") {
      // The browser's own viewer. Sandboxed by the response's CSP, and served as
      // application/pdf rather than anything that could script.
      const frame = document.createElement("iframe");
      frame.className = "preview-frame";
      frame.title = meta.filename;
      frame.src = urlFor();
      bodyEl.append(frame);
    } else if (meta.kind === "text") {
      // As text, always. The daemon sends HTML and SVG here too, precisely so
      // they are read rather than run.
      void body.text().then((text) => {
        if (!scrim.isConnected || current.body !== body) return;
        const sheet = document.createElement("div");
        sheet.className = markdown && view === "rendered" ? "md-sheet" : "preview-source";
        if (markdown && text === "") {
          sheet.append(noteLine(emptyFile(meta.filename)));
        } else if (markdown && view === "rendered") {
          sheet.append(
            renderedView(text, {
              resolveImage:
                current.path !== null && options.contentUrl ? imageResolver(current.path, options.contentUrl) : undefined,
              onOpen: (path, fragment) => void open(path, fragment),
            }),
          );
        } else {
          sheet.append(sourceView(text, languageFor(meta.filename)));
        }
        if (markdown && meta.truncated) sheet.append(noteLine(cutFooter(meta.totalBytes, body.size)));
        bodyEl.append(sheet);
        afterText?.(sheet);
      });
    } else {
      bodyEl.append(noteLine("This file has no preview."));
    }
  };

  /** The header and the controls for the shown file, then its body. */
  const present = (afterText?: (shown: HTMLElement) => void): void => {
    const { meta, body, path } = current;
    const markdown = isMarkdown(meta);
    card.setAttribute("aria-label", `Preview of ${meta.filename}`);
    title.textContent = meta.filename;
    sub.textContent = markdown && meta.truncated ? cutHeader(meta.totalBytes, body.size) : describePreview(meta);
    toggle.hidden = !markdown;
    openFull.hidden = !markdown || path === null;
    if (path !== null) openFull.href = fullWidthUrl(path);
    render(afterText);
  };

  /** A relative `.md` link: the same overlay, the linked file. */
  const open = async (link: string, fragment: string): Promise<void> => {
    const { contentUrl } = options;
    if (current.path === null || !contentUrl) return;
    const path = resolveRelative(current.path, link);
    let response: Response;
    try {
      response = await fetch(contentUrl(path), { credentials: "same-origin" });
    } catch {
      showError(path, DAEMON_UNREACHABLE);
      return;
    }
    if (!response.ok) {
      showError(path, daemonAnswered(response.status, await errorWord(response)));
      return;
    }
    const body = await response.blob();
    if (!scrim.isConnected) return;
    revoke();
    current = { meta: metaFromHeaders(response.headers, path), body, path };
    present((shown) => {
      if (fragment !== "") scrollToFragment(shown, fragment);
    });
  };

  /** The error state: the header keeps the name, the body is the one sentence. */
  const showError = (path: string, reason: string): void => {
    if (!scrim.isConnected) return;
    title.textContent = basename(path);
    sub.textContent = "";
    openFull.href = fullWidthUrl(path);
    bodyEl.classList.remove("preview-body-rendered");
    bodyEl.replaceChildren(noteLine(cannotRead(path, reason)));
  };

  present();
  card.append(header, bodyEl);
  scrim.append(card);
  host.append(scrim);

  let closed = false;
  const dismiss = (): void => {
    if (closed) return;
    closed = true;
    document.removeEventListener("keydown", onKeydown, true);
    revoke();
    scrim.remove();
    // Hand focus back, or the terminal underneath ignores the keyboard.
    onClosed?.();
  };

  // Capture phase: xterm's key handling sits below, and Escape here means
  // "close the preview", not a key for the shell.
  function onKeydown(event: KeyboardEvent): void {
    if (event.key !== "Escape") return;
    event.preventDefault();
    event.stopPropagation();
    dismiss();
  }

  close.addEventListener("click", dismiss);
  scrim.addEventListener("click", (event) => {
    if (event.target === scrim) dismiss();
  });
  document.addEventListener("keydown", onKeydown, true);
  close.focus();

  return { close: dismiss };
}
