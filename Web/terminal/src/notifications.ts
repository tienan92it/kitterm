/**
 * Desktop-notification parsing and dispatch.
 *
 * A program in the shell asks for the user's attention with an OSC sequence:
 *   OSC 9  ; <body> ST                      (iTerm2 / Windows Terminal — body only)
 *   OSC 777 ; notify ; <title> ; <body> ST   (urxvt / VTE / VS Code)
 *   OSC 99 ; <metadata> ; <payload> ST       (kitty — richer, chunked)
 *
 * The pane parses these (the daemon never touches ANSI) and hands the result
 * to the app shell, which decides whether to surface it: a browser tab is the
 * one terminal that can badge itself, notify a closed laptop's phone, and
 * deep-link straight back to the session that asked.
 *
 * Agents are the reason this matters — a long-running command or a coding
 * agent blocked on input emits one of these, and the notification names which
 * session it was.
 */

export type TerminalNotification = {
  /** Null when the source carried only a body (OSC 9). */
  title: string | null;
  body: string;
};

/** OSC 9: the whole payload is the body. */
export function parseOsc9(data: string): TerminalNotification | null {
  const body = data.trim();
  if (!body) return null;
  return { title: null, body };
}

/** OSC 777: `notify;<title>;<body>`. Anything else (other 777 subcommands) is
 * ignored. */
export function parseOsc777(data: string): TerminalNotification | null {
  const parts = data.split(";");
  if (parts[0] !== "notify") return null;
  const title = parts[1] ?? "";
  const body = parts.slice(2).join(";");
  if (!title && !body) return null;
  // With only one field present, treat it as the body — a title with no body
  // reads as an empty notification.
  if (!body) return { title: null, body: title };
  return { title: title || null, body };
}

/**
 * OSC 99 (kitty desktop notifications). Metadata is colon-separated `key=value`;
 * the keys we act on:
 *   i  notification id (groups chunks of one notification)
 *   p  payload type: `title` (default) or `body`
 *   e  `1` if the payload is base64
 *   d  `0` = more chunks follow; `1` (default) = this completes the notification
 *
 * We deliberately support the realistic subset — title/body text, base64, and
 * multi-chunk assembly — and ignore the rest (icons, buttons, sounds), which
 * no browser notification surfaces anyway.
 */
const MAX_PENDING = 32;
/** Per-field cap on accumulated text. Far above what any OS notification
 * shows, and it bounds memory against a producer that streams chunks into
 * one id forever. */
const MAX_FIELD_CHARS = 4096;

type Pending = { title: string; body: string };

export class Osc99Assembler {
  private readonly pending = new Map<string, Pending>();

  /** Feed one OSC 99 sequence; returns a notification when one completes. */
  feed(data: string): TerminalNotification | null {
    const sep = data.indexOf(";");
    const metaRaw = sep === -1 ? data : data.slice(0, sep);
    const payloadRaw = sep === -1 ? "" : data.slice(sep + 1);

    const meta = new Map<string, string>();
    for (const pair of metaRaw.split(":")) {
      const eq = pair.indexOf("=");
      if (eq > 0) meta.set(pair.slice(0, eq), pair.slice(eq + 1));
    }

    const id = meta.get("i") ?? "";
    // Only title/body payloads become text; anything else (icon, buttons,
    // sound, …) must not leak into the notification, but its `d` flag still
    // counts toward completing the id.
    const p = meta.get("p") ?? "title";
    const which = p === "title" || p === "body" ? p : null;
    const done = meta.get("d") !== "0"; // default 1 = done

    let payload = payloadRaw;
    if (meta.get("e") === "1") {
      try {
        payload = decodeBase64Utf8(payloadRaw);
      } catch {
        payload = "";
      }
    }

    const acc = this.pending.get(id) ?? { title: "", body: "" };
    if (which) acc[which] = (acc[which] + payload).slice(0, MAX_FIELD_CHARS);

    if (!done) {
      this.pending.set(id, acc);
      // Bound memory against a producer that opens ids and never finishes them.
      if (this.pending.size > MAX_PENDING) {
        const oldest = this.pending.keys().next().value;
        if (oldest !== undefined && oldest !== id) this.pending.delete(oldest);
      }
      return null;
    }

    this.pending.delete(id);
    const title = acc.title.trim();
    const body = acc.body.trim();
    if (!title && !body) return null;
    if (!body) return { title: null, body: title };
    return { title: title || null, body };
  }
}

function decodeBase64Utf8(b64: string): string {
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

/**
 * Decides whether a notification is surfaced, tracks which sessions still want
 * attention, and drives the app badge. All side effects are injected so the
 * policy is testable without a DOM.
 */
export type NotificationDeps = {
  /** The page is visible (foreground tab). */
  isVisible: () => boolean;
  /** Session id of the currently focused pane, or null. */
  focusedSessionId: () => string | null;
  /** Set the app badge count (0 clears). */
  setBadge: (count: number) => void;
  /** Fire a system notification; `onClick` focuses the session. `key` groups
   * repeat notifications from one session so they replace rather than stack.
   * Returns false if it could not be shown (no permission yet). */
  show: (title: string, body: string, onClick: () => void, key?: string) => boolean;
  /** Focus the pane owning this session (deep link). */
  focusSession: (sessionId: string) => void;
};

export class NotificationCenter {
  /** Sessions that raised attention and have not been looked at since. */
  private readonly waiting = new Set<string>();

  constructor(private readonly deps: NotificationDeps) {}

  /** A pane parsed a notification. */
  raise(sessionId: string | null, note: TerminalNotification): void {
    // Presence suppression: never interrupt the user about the pane they are
    // already looking at.
    const looking =
      this.deps.isVisible() &&
      sessionId !== null &&
      sessionId === this.deps.focusedSessionId();
    if (looking) return;

    if (sessionId) {
      this.waiting.add(sessionId);
      this.deps.setBadge(this.waiting.size);
    }
    this.deps.show(
      note.title ?? note.body,
      note.title ? note.body : "",
      () => {
        if (sessionId) this.deps.focusSession(sessionId);
      },
      sessionId ?? undefined,
    );
  }

  /** The user is now looking at this session — drop its pending attention. */
  clear(sessionId: string): void {
    if (this.waiting.delete(sessionId)) {
      this.deps.setBadge(this.waiting.size);
    }
  }

  /** Panes still waiting (for tests / diagnostics). */
  get waitingCount(): number {
    return this.waiting.size;
  }
}
