/**
 * Pane layout persistence.
 *
 * sessionStorage is per-tab, which is exactly the scope we want: reloading a tab
 * restores its own splits and reattaches each pane to its still-running shell,
 * while a new tab starts fresh. This deliberately does not survive a browser
 * restart, and does not try to outlive the daemon — a dead session id already
 * degrades into a freshly spawned shell on the daemon side.
 *
 * Every read is defensive: a corrupt blob must fall back to a single fresh pane
 * rather than break boot.
 */

import { parseLayout, serializeLayout, type LayoutNode, type PaneId } from "./pane-layout";

const KEY_LAYOUT = "kitterm:layout";
/** Pre-splits key: a tab reloading across the deploy still finds its shell. */
const KEY_LEGACY_SESSION = "kitterm:session-id";

const VERSION = 1;

export type PaneSession = {
  /** Null until the daemon reports one, or after the shell exits. */
  sessionId: string | null;
  /** Last known cwd, so a respawned pane lands in the right folder. */
  cwd?: string;
  /** Durable key for this pane's own history file, so up-arrow survives a
   * restart with the commands run in THIS pane. Generated once per pane. */
  histKey?: string;
};

export type StoredLayout = {
  root: LayoutNode;
  focus: PaneId;
  sessions: Map<PaneId, PaneSession>;
};

const readRaw = (key: string): string | null => {
  try {
    return sessionStorage.getItem(key);
  } catch {
    return null;
  }
};

const writeRaw = (key: string, value: string): void => {
  try {
    sessionStorage.setItem(key, value);
  } catch {
    // private mode / quota — ignore
  }
};

const removeRaw = (key: string): void => {
  try {
    sessionStorage.removeItem(key);
  } catch {
    // ignore
  }
};

export const loadLayout = (): StoredLayout | null => {
  const raw = readRaw(KEY_LAYOUT);
  if (!raw) return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;

  const blob = parsed as Record<string, unknown>;
  if (blob.v !== VERSION) return null;

  const root = parseLayout(blob.root);
  if (!root) return null;

  const sessions = new Map<PaneId, PaneSession>();
  if (Array.isArray(blob.sessions)) {
    for (const entry of blob.sessions) {
      if (typeof entry !== "object" || entry === null) continue;
      const record = entry as Record<string, unknown>;
      if (typeof record.pane !== "string" || !record.pane) continue;
      sessions.set(record.pane, {
        sessionId: typeof record.sessionId === "string" ? record.sessionId : null,
        cwd: typeof record.cwd === "string" ? record.cwd : undefined,
        histKey: typeof record.histKey === "string" ? record.histKey : undefined,
      });
    }
  }

  const focus = typeof blob.focus === "string" ? blob.focus : "";
  return { root, focus, sessions };
};

export const saveLayout = ({ root, focus, sessions }: StoredLayout): void => {
  writeRaw(
    KEY_LAYOUT,
    JSON.stringify({
      v: VERSION,
      root: serializeLayout(root),
      focus,
      sessions: [...sessions].map(([pane, session]) => ({
        pane,
        sessionId: session.sessionId,
        ...(session.cwd ? { cwd: session.cwd } : {}),
        ...(session.histKey ? { histKey: session.histKey } : {}),
      })),
    }),
  );
};

export const clearLayout = (): void => removeRaw(KEY_LAYOUT);

/** Read (and consume) the pre-splits single-session key. */
export const takeLegacySessionId = (): string | null => {
  const id = readRaw(KEY_LEGACY_SESSION);
  if (id) removeRaw(KEY_LEGACY_SESSION);
  return id;
};
