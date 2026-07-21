import { DEFAULT_FONT_ID, type TerminalFontId, findFontById } from "./fonts";
import { DEFAULT_THEME_ID, type TerminalThemeId, findThemeById } from "./themes";

export const FONT_SIZE_MIN = 9;
export const FONT_SIZE_MAX = 24;
export const FONT_SIZE_DEFAULT = 13;

const KEY_THEME = "kitterm:theme-id";
const KEY_FONT = "kitterm:font-id";
const KEY_FONT_SIZE = "kitterm:font-size";
const KEY_LOCAL_FONT = "kitterm:local-font-family";
// Tab title is keyed by session id, not stored globally: a new tab gets a new
// session and so its own title, while an observer tab joining an existing
// session reads the controller's title. Kept in localStorage (not
// sessionStorage) so it is visible across tabs of the same browser.
const KEY_TAB_TITLES = "kitterm:tab-titles";
/** Sessions are ephemeral; keep only the most recent entries. */
const MAX_TAB_TITLE_ENTRIES = 50;

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

/** Tab title for `sessionId`, or the defaults when it has none stored. */
export const loadTabTitle = (sessionId: string): TabTitleSettings => {
  const entry = readTabTitleMap()[sessionId];
  if (!entry) return { ...DEFAULT_TAB_TITLE };
  return {
    tabTitle: typeof entry.t === "string" ? entry.t : "",
    tabTitleShowFolder: entry.f !== false,
  };
};

/** Controller-only: observers must never write a session's title. */
export const saveTabTitle = (
  sessionId: string,
  { tabTitle, tabTitleShowFolder }: TabTitleSettings,
): void => {
  const map = readTabTitleMap();
  const trimmed = tabTitle.trim();
  // Strictly increasing, so pruning orders by true recency even when several
  // writes land in the same millisecond.
  const newest = Object.values(map).reduce((max, e) => Math.max(max, e?.at ?? 0), 0);
  map[sessionId] = { at: Math.max(Date.now(), newest + 1), f: tabTitleShowFolder };
  if (trimmed) map[sessionId].t = trimmed;
  // `writeRaw` already absorbs quota / private-mode failures.
  writeRaw(KEY_TAB_TITLES, JSON.stringify(pruneTabTitles(map)));
};

/** Fires in *other* tabs of this browser when a title changes; an observer
 * uses it to mirror the controller live. */
export const isTabTitleStorageEvent = (event: StorageEvent): boolean =>
  event.key === KEY_TAB_TITLES || event.key === null;
