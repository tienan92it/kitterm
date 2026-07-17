export interface LocalFontData {
  family: string;
  fullName: string;
  postscriptName: string;
  style: string;
}

declare global {
  interface Window {
    queryLocalFonts?: () => Promise<LocalFontData[]>;
  }
}

export type LocalFontPermissionState = "granted" | "denied" | "prompt" | "unsupported";

export const isLocalFontAccessSupported = (): boolean =>
  typeof window !== "undefined" && typeof window.queryLocalFonts === "function";

export const loadLocalFontPermissionState = async (): Promise<LocalFontPermissionState> => {
  if (!isLocalFontAccessSupported()) return "unsupported";
  if (!navigator.permissions?.query) return "unsupported";
  try {
    // Chrome exposes "local-fonts"; typings may not include it yet.
    const status = await navigator.permissions.query({
      name: "local-fonts" as PermissionName,
    });
    if (status.state === "granted" || status.state === "denied" || status.state === "prompt") {
      return status.state;
    }
    return "prompt";
  } catch {
    return "unsupported";
  }
};

/**
 * Triggers the browser permission prompt on first call (must be from a user
 * gesture). Returns sorted unique family names, or [] on failure / denial.
 */
export const queryLocalFonts = async (): Promise<readonly string[]> => {
  const queryFn = window.queryLocalFonts;
  if (typeof queryFn !== "function") return [];
  try {
    const fonts = await queryFn();
    const unique = new Set<string>();
    for (const font of fonts) {
      if (font.family) unique.add(font.family);
    }
    return [...unique].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: "base" }));
  } catch {
    return [];
  }
};
