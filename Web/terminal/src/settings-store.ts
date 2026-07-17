import {
  DEFAULT_FONT_ID,
  LOCAL_FONT_ID,
  type TerminalFontId,
  findFontById,
} from "./fonts";
import { DEFAULT_THEME_ID, type TerminalThemeId, findThemeById } from "./themes";

export const FONT_SIZE_MIN = 9;
export const FONT_SIZE_MAX = 24;
export const FONT_SIZE_DEFAULT = 13;

const KEY_THEME = "kitterm:theme-id";
const KEY_FONT = "kitterm:font-id";
const KEY_FONT_SIZE = "kitterm:font-size";
const KEY_LOCAL_FONT = "kitterm:local-font-family";

export interface KittermSettings {
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

export const loadSettings = (): KittermSettings => {
  const themeId = findThemeById(readRaw(KEY_THEME) ?? DEFAULT_THEME_ID).id;
  const fontId = findFontById(readRaw(KEY_FONT) ?? DEFAULT_FONT_ID).id;
  const parsedSize = Number(readRaw(KEY_FONT_SIZE));
  const fontSize = clampFontSize(
    Number.isFinite(parsedSize) ? parsedSize : FONT_SIZE_DEFAULT,
  );
  const rawLocal = readRaw(KEY_LOCAL_FONT)?.trim() ?? "";
  const localFontFamily = rawLocal.length > 0 ? rawLocal : null;
  return { themeId, fontId, fontSize, localFontFamily };
};

export const saveSettings = (settings: KittermSettings): void => {
  writeRaw(KEY_THEME, settings.themeId);
  writeRaw(KEY_FONT, settings.fontId);
  writeRaw(KEY_FONT_SIZE, String(clampFontSize(settings.fontSize)));
  if (settings.localFontFamily?.trim()) {
    writeRaw(KEY_LOCAL_FONT, settings.localFontFamily.trim());
  } else {
    removeRaw(KEY_LOCAL_FONT);
  }
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

export { LOCAL_FONT_ID };
