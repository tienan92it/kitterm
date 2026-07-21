/** Tab title composition.
 *
 * Two optional parts: a fixed custom name typed in settings, and the current
 * folder. Both empty (or unknown) falls back to the product name. */

export const TAB_TITLE_FALLBACK = "kitterm";

const SEPARATOR = " · ";

export interface TabTitleInput {
  /** Fixed name from settings; empty means "not set". */
  custom: string;
  /** Whether the folder segment is enabled. */
  showFolder: boolean;
  /** Current folder name, or null while unknown. */
  folder: string | null;
}

export const composeTabTitle = ({ custom, showFolder, folder }: TabTitleInput): string => {
  const parts: string[] = [];
  const trimmed = custom.trim();
  if (trimmed) parts.push(trimmed);
  if (showFolder && folder?.trim()) parts.push(folder.trim());
  return parts.length > 0 ? parts.join(SEPARATOR) : TAB_TITLE_FALLBACK;
};

/** Last path component, tolerating trailing slashes. `/` maps to `/`. */
export const folderFromCwd = (cwd: string): string | null => {
  const trimmed = cwd.trim().replace(/\/+$/, "");
  if (!trimmed) return cwd.trim() ? "/" : null;
  const segment = trimmed.slice(trimmed.lastIndexOf("/") + 1);
  return segment || "/";
};

/** OSC 7 payload: `file://host/percent/encoded/path`. */
export const cwdFromOsc7 = (data: string): string | null => {
  if (!data.startsWith("file://")) return null;
  const path = data.slice("file://".length).replace(/^[^/]*/, "");
  if (!path) return null;
  try {
    return decodeURIComponent(path);
  } catch {
    return path;
  }
};

/** iTerm2 shell integration: `CurrentDir=/path` (other keys are ignored). */
export const cwdFromOsc1337 = (data: string): string | null => {
  const prefix = "CurrentDir=";
  if (!data.startsWith(prefix)) return null;
  const path = data.slice(prefix.length).trim();
  return path || null;
};
