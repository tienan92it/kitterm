/**
 * Showing what a path in the output points at.
 *
 * The daemon has already decided what is safe to render — see `FilePreview` —
 * and says so in `X-Kitterm-Kind`. This trusts that decision rather than
 * sniffing the bytes again: two places guessing at a content type is how one of
 * them ends up wrong.
 *
 * The overlay is a peer of the paste prompt and the file picker: it lives inside
 * the pane, closes on Escape or a tap outside, and hands focus back to the
 * terminal underneath.
 */

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

/**
 * Show `body` in `host`. The caller has already fetched it, because only the
 * caller knows which session's directory the path was relative to.
 */
export function showPreview(
  host: HTMLElement,
  meta: PreviewMeta,
  body: Blob,
  onClosed?: () => void,
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
  title.textContent = meta.filename;
  const sub = document.createElement("div");
  sub.className = "preview-sub";
  sub.textContent = describePreview(meta);
  const heading = document.createElement("div");
  heading.className = "preview-heading";
  heading.append(title, sub);
  const close = document.createElement("button");
  close.type = "button";
  close.className = "preview-close";
  close.textContent = "✕";
  close.setAttribute("aria-label", "Close preview");
  header.append(heading, close);

  const bodyEl = document.createElement("div");
  bodyEl.className = "preview-body";

  // One object URL, revoked on close. Without that the blob is held for the
  // life of the page, and a few large previews add up.
  let objectUrl: string | null = null;
  const urlFor = (): string => {
    objectUrl ??= URL.createObjectURL(body);
    return objectUrl;
  };

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
    const pre = document.createElement("pre");
    pre.className = "preview-text";
    // As text, always. The daemon sends HTML and SVG here too, precisely so
    // they are read rather than run.
    void body.text().then((text) => {
      pre.textContent = text;
    });
    bodyEl.append(pre);
  } else {
    const note = document.createElement("p");
    note.className = "preview-note";
    note.textContent = "This file has no preview.";
    bodyEl.append(note);
  }

  card.append(header, bodyEl);
  scrim.append(card);
  host.append(scrim);

  let closed = false;
  const dismiss = (): void => {
    if (closed) return;
    closed = true;
    document.removeEventListener("keydown", onKeydown, true);
    if (objectUrl) URL.revokeObjectURL(objectUrl);
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
