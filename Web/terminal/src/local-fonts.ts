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

export const isLocalFontAccessSupported = (): boolean =>
  typeof window !== "undefined" && typeof window.queryLocalFonts === "function";

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
