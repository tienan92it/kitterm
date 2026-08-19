/**
 * Pane layout persistence.
 *
 * The store depends on how the client was launched, because "the same window
 * again" means different things in a tab and in an installed app.
 *
 * **In a browser tab: sessionStorage**, which is per-tab. Reloading restores
 * that tab's splits and reattaches each pane to its still-running shell, while
 * a new tab starts fresh. This deliberately does not survive a browser restart.
 *
 * **In an installed app: localStorage.** A home-screen app gets a *fresh*
 * sessionStorage on every launch, so under the tab rule it could never
 * reattach: each launch spawned new shells and the previous scrollback looked
 * lost, while the old shells kept running unreferenced. An installed app is a
 * single window that the user reopens, so per-app is the right scope for it —
 * and localStorage is per-app inside its own storage container.
 *
 * Neither store tries to outlive the daemon: a dead session id already degrades
 * into a freshly spawned shell on the daemon side, so a stale layout is safe.
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
  /** Session profile this pane was opened as. Kept so a respawn after a
   * daemon restart re-runs the profile's connect command. */
  profile?: string;
};

export type StoredLayout = {
  root: LayoutNode;
  focus: PaneId;
  sessions: Map<PaneId, PaneSession>;
};

/**
 * True when this client is an installed app rather than a browser tab.
 *
 * `display-mode: standalone` is the launch context the manifest asks for, and
 * it is what iOS, Android and desktop installs all report. The iOS-only
 * `navigator.standalone` is the fallback for older home-screen apps that do not
 * answer the media query.
 */
export const isInstalledApp = (): boolean => {
  try {
    if (window.matchMedia?.("(display-mode: standalone)").matches) return true;
    return (navigator as { standalone?: boolean }).standalone === true;
  } catch {
    return false;
  }
};

/** The *choice* is resolved once — the launch context cannot change without a
 * reload, and a read and its matching write must never disagree about where
 * they looked. The storage object itself is re-read every time, so this never
 * holds a stale reference. */
let installed: boolean | undefined;
const store = (): Storage | null => {
  if (installed === undefined) installed = isInstalledApp();
  try {
    return installed ? localStorage : sessionStorage;
  } catch {
    return null;
  }
};

const readRaw = (key: string): string | null => {
  try {
    return store()?.getItem(key) ?? null;
  } catch {
    return null;
  }
};

const writeRaw = (key: string, value: string): void => {
  try {
    store()?.setItem(key, value);
  } catch {
    // private mode / quota — ignore
  }
};

const removeRaw = (key: string): void => {
  try {
    store()?.removeItem(key);
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
        profile: typeof record.profile === "string" ? record.profile : undefined,
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
        ...(session.profile ? { profile: session.profile } : {}),
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
