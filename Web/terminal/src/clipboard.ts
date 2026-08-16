/**
 * Clipboard access that still works off a secure origin.
 *
 * `navigator.clipboard` is gated on a secure context, and `--lan` serves plain
 * HTTP to exactly the devices that need it most. There the whole object is
 * `undefined`, so `navigator.clipboard.writeText(...)` threw a `TypeError`
 * *synchronously* — before any promise existed — and every `.catch` written
 * around those calls was dead code. Copying a share link, a command link, or a
 * selection all failed silently.
 *
 * Writing has a fallback that predates the async API and is not origin-gated:
 * a `document.execCommand("copy")` over a temporary selection. Reading has
 * none — no non-secure API can read the clipboard, by design — so `readText`
 * reports that it cannot, and the caller asks the user to paste into a field
 * instead (see `pasteFallback`).
 *
 * Both entry points are async and never reject: a caller decides what to say
 * about a `false`, and no caller should have to guard the call itself.
 */

/** The async API, or null when this origin does not get one. */
const asyncClipboard = (): Clipboard | null => {
  try {
    return typeof navigator !== "undefined" && navigator.clipboard ? navigator.clipboard : null;
  } catch {
    // Some embedded webviews throw on the property access itself.
    return null;
  }
};

/**
 * True when `readText` has any chance of working. False means a paste must be
 * driven by the user's own paste gesture rather than read from script.
 */
export const canReadClipboard = (): boolean => {
  const clipboard = asyncClipboard();
  return !!clipboard && typeof clipboard.readText === "function";
};

/**
 * `execCommand("copy")` needs a real, selected, focused element in the
 * document. The textarea is positioned rather than hidden — `display:none` or
 * `visibility:hidden` makes it unselectable — and is removed before returning.
 *
 * `readonly` would block the copy in some browsers, so the field stays
 * editable; it exists for a single turn of the event loop and is never painted.
 */
const copyViaExecCommand = (text: string): boolean => {
  if (typeof document === "undefined" || typeof document.execCommand !== "function") {
    return false;
  }
  const field = document.createElement("textarea");
  field.value = text;
  field.setAttribute("aria-hidden", "true");
  field.tabIndex = -1;
  field.style.position = "fixed";
  field.style.top = "0";
  field.style.left = "0";
  field.style.width = "1px";
  field.style.height = "1px";
  field.style.padding = "0";
  field.style.border = "none";
  field.style.opacity = "0";
  // iOS scrolls to a focused field; anchoring at the viewport top keeps that
  // scroll a no-op instead of a visible jump.
  field.style.pointerEvents = "none";

  const previous = document.activeElement;
  document.body.append(field);
  let copied = false;
  try {
    field.focus({ preventScroll: true });
    field.setSelectionRange(0, field.value.length);
    copied = document.execCommand("copy");
  } catch {
    copied = false;
  } finally {
    field.remove();
    if (previous instanceof HTMLElement) previous.focus({ preventScroll: true });
  }
  return copied;
};

/**
 * Put `text` on the clipboard. Resolves false when neither route worked, which
 * a caller should surface — showing the text so it can be copied by hand beats
 * a button that does nothing.
 *
 * Call this synchronously from the user gesture that asked for it: Safari
 * revokes user activation across an `await`.
 */
export const writeClipboard = async (text: string): Promise<boolean> => {
  const clipboard = asyncClipboard();
  if (clipboard && typeof clipboard.writeText === "function") {
    try {
      await clipboard.writeText(text);
      return true;
    } catch {
      // Permission denied or a transient failure — try the old route before
      // giving up, since it asks the document rather than the permission model.
      //
      // On Safari this second attempt is close to hopeless: the `await` above
      // has already consumed the transient user activation `execCommand`
      // needs. It costs nothing and helps on other engines. The path that
      // matters — a plain-HTTP origin — never reaches here, because
      // `asyncClipboard()` returns null and the fallback runs synchronously.
    }
  }
  return copyViaExecCommand(text);
};

/**
 * Read the clipboard, or null when this origin cannot — which is not an error,
 * just the answer. Callers fall back to asking the user to paste.
 */
export const readClipboard = async (): Promise<string | null> => {
  const clipboard = asyncClipboard();
  if (!clipboard || typeof clipboard.readText !== "function") return null;
  try {
    const text = await clipboard.readText();
    return text || null;
  } catch {
    return null;
  }
};
