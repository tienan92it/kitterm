import { DEFAULT_FONT_ID, type TerminalFontId, findFontById } from "./fonts";
import { DEFAULT_THEME_ID, type TerminalThemeId, findThemeById } from "./themes";

export const FONT_SIZE_MIN = 9;
export const FONT_SIZE_MAX = 24;
export const FONT_SIZE_DEFAULT = 13;

const KEY_THEME = "kitterm:theme-id";
const KEY_FONT = "kitterm:font-id";
const KEY_FONT_SIZE = "kitterm:font-size";
const KEY_LOCAL_FONT = "kitterm:local-font-family";
// Tab titles are keyed twice, not stored globally, and kept in localStorage
// (not sessionStorage) so they are visible across tabs of the same browser.
//
// By **session id**, so an observer tab joining a session reads the title its
// controller set. Session ids are ephemeral: a daemon restart or a dead shell
// mints a new one for every pane, and each new id takes a slot, so a title
// reached only this way is eventually pruned out from under a long-lived pane.
//
// By **hist key**, the pane's own durable id — the same one that keeps its
// shell history across a respawn. This is what makes a name stick to the pane
// the user gave it to rather than to whichever shell happened to be running.
// Panes booted from a share link have none; they are observers and read the
// session entry, which is the point.
const KEY_TAB_TITLES = "kitterm:tab-titles";
/** Two entries per named pane, and session ids churn; leave room for both. */
const MAX_TAB_TITLE_ENTRIES = 100;

export interface TabTitleSettings {
  /** Fixed tab name; empty means "not set". */
  tabTitle: string;
  /** Append the current folder to the tab title. */
  tabTitleShowFolder: boolean;
}

/** Frozen: callers spread it, and a stray mutation would change the default
 * for every tab and session in the page. */
export const DEFAULT_TAB_TITLE: Readonly<TabTitleSettings> = Object.freeze({
  tabTitle: "",
  tabTitleShowFolder: true,
});

export interface KittermSettings extends TabTitleSettings {
  themeId: TerminalThemeId;
  fontId: TerminalFontId;
  fontSize: number;
  localFontFamily: string | null;
}

export const clampFontSize = (value: number): number => {
  if (!Number.isFinite(value)) return FONT_SIZE_DEFAULT;
  return Math.min(FONT_SIZE_MAX, Math.max(FONT_SIZE_MIN, Math.round(value)));
};

const readRaw = (key: string): string | null => {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
};

const writeRaw = (key: string, value: string): void => {
  try {
    localStorage.setItem(key, value);
  } catch {
    // private mode / quota — ignore
  }
};

const removeRaw = (key: string): void => {
  try {
    localStorage.removeItem(key);
  } catch {
    // ignore
  }
};

interface StoredTabTitle {
  /** Custom name; absent means "not set". */
  t?: string;
  /** Folder segment enabled. */
  f?: boolean;
  /** Last write, for pruning. */
  at: number;
}

const readTabTitleMap = (): Record<string, StoredTabTitle> => {
  const raw = readRaw(KEY_TAB_TITLES);
  if (!raw) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return parsed as Record<string, StoredTabTitle>;
  } catch {
    return {};
  }
};

/** Drop all but the most recently written entries. */
const pruneTabTitles = (
  map: Record<string, StoredTabTitle>,
): Record<string, StoredTabTitle> => {
  const entries = Object.entries(map);
  if (entries.length <= MAX_TAB_TITLE_ENTRIES) return map;
  entries.sort((a, b) => (b[1]?.at ?? 0) - (a[1]?.at ?? 0));
  return Object.fromEntries(entries.slice(0, MAX_TAB_TITLE_ENTRIES));
};

export const loadSettings = (): KittermSettings => {
  const themeId = findThemeById(readRaw(KEY_THEME) ?? DEFAULT_THEME_ID).id;
  const fontId = findFontById(readRaw(KEY_FONT) ?? DEFAULT_FONT_ID).id;
  const rawSize = readRaw(KEY_FONT_SIZE);
  // Missing key must fall back to the default, not clamp Number(null) === 0 to the minimum.
  const fontSize =
    rawSize === null || rawSize.trim() === ""
      ? FONT_SIZE_DEFAULT
      : clampFontSize(Number(rawSize));
  const rawLocal = readRaw(KEY_LOCAL_FONT)?.trim() ?? "";
  const localFontFamily = rawLocal.length > 0 ? rawLocal : null;
  // Tab title needs a session id, which is not known at load; callers apply
  // `loadTabTitle` once the daemon confirms the session.
  return {
    themeId,
    fontId,
    fontSize,
    localFontFamily,
    ...DEFAULT_TAB_TITLE,
  };
};

export const saveThemeId = (themeId: TerminalThemeId): void => {
  writeRaw(KEY_THEME, findThemeById(themeId).id);
};

export const saveFontId = (fontId: TerminalFontId): void => {
  writeRaw(KEY_FONT, findFontById(fontId).id);
};

export const saveFontSize = (fontSize: number): void => {
  writeRaw(KEY_FONT_SIZE, String(clampFontSize(fontSize)));
};

export const saveLocalFontFamily = (family: string | null): void => {
  const trimmed = family?.trim() ?? "";
  if (trimmed) writeRaw(KEY_LOCAL_FONT, trimmed);
  else removeRaw(KEY_LOCAL_FONT);
};

/**
 * The title for a pane, or the defaults when it has none stored.
 *
 * Session id first, so an observer shows what its controller set. The hist key
 * is the fallback that survives a respawn: after a daemon restart the pane's
 * session id is new and has no entry, but its hist key is the one it booted
 * with.
 */
export const loadTabTitle = (
  sessionId: string | null,
  histKey?: string | null,
): TabTitleSettings => {
  const map = readTabTitleMap();
  const entry = (sessionId ? map[sessionId] : undefined) ?? (histKey ? map[histKey] : undefined);
  if (!entry) return { ...DEFAULT_TAB_TITLE };
  return {
    tabTitle: typeof entry.t === "string" ? entry.t : "",
    tabTitleShowFolder: entry.f !== false,
  };
};

/** Controller-only: observers must never write a session's title. */
export const saveTabTitle = (
  sessionId: string | null,
  histKey: string | null,
  { tabTitle, tabTitleShowFolder }: TabTitleSettings,
): void => {
  const keys = [sessionId, histKey].filter((key): key is string => !!key);
  if (keys.length === 0) return;
  const map = readTabTitleMap();
  const trimmed = tabTitle.trim();
  // Strictly increasing, so pruning orders by true recency even when several
  // writes land in the same millisecond.
  const newest = Object.values(map).reduce((max, e) => Math.max(max, e?.at ?? 0), 0);
  const at = Math.max(Date.now(), newest + 1);
  for (const key of keys) {
    map[key] = { at, f: tabTitleShowFolder };
    if (trimmed) map[key].t = trimmed;
  }
  // `writeRaw` already absorbs quota / private-mode failures.
  writeRaw(KEY_TAB_TITLES, JSON.stringify(pruneTabTitles(map)));
};

/** Fires in *other* tabs of this browser when a title changes; an observer
 * uses it to mirror the controller live. */
export const isTabTitleStorageEvent = (event: StorageEvent): boolean =>
  event.key === KEY_TAB_TITLES || event.key === null;
