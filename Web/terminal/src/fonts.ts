export const LOCAL_FONT_ID = "local" as const;

export type TerminalFontId =
  | "menlo"
  | "sf-mono"
  | "monaco"
  | "courier-new"
  | "ui-monospace"
  | "andale-mono"
  | "consolas"
  | "liberation-mono"
  | typeof LOCAL_FONT_ID;

export interface TerminalFont {
  id: TerminalFontId;
  label: string;
  family: string;
}

export const DEFAULT_FONT_ID: TerminalFontId = "menlo";

export const TERMINAL_FONTS: TerminalFont[] = [
  {
    id: "menlo",
    label: "Menlo",
    family: "Menlo, Monaco, 'Courier New', monospace",
  },
  {
    id: "sf-mono",
    label: "SF Mono",
    family: "'SF Mono', Menlo, Monaco, monospace",
  },
  {
    id: "monaco",
    label: "Monaco",
    family: "Monaco, Menlo, 'Courier New', monospace",
  },
  {
    id: "andale-mono",
    label: "Andale Mono",
    family: "'Andale Mono', Menlo, Monaco, monospace",
  },
  {
    id: "consolas",
    label: "Consolas",
    family: "Consolas, 'Courier New', monospace",
  },
  {
    id: "liberation-mono",
    label: "Liberation Mono",
    family: "'Liberation Mono', 'Courier New', monospace",
  },
  {
    id: "courier-new",
    label: "Courier New",
    family: "'Courier New', Courier, monospace",
  },
  {
    id: "ui-monospace",
    label: "System UI Mono",
    family: "ui-monospace, SFMono-Regular, Menlo, Monaco, monospace",
  },
];

export const findFontById = (id: string): TerminalFont => {
  if (id === LOCAL_FONT_ID) {
    return {
      id: LOCAL_FONT_ID,
      label: "Local font",
      family: "Menlo, Monaco, monospace",
    };
  }
  return (
    TERMINAL_FONTS.find((font) => font.id === id) ??
    TERMINAL_FONTS.find((font) => font.id === DEFAULT_FONT_ID)!
  );
};

/** Escape a font-family name for a double-quoted CSS family string. */
export const escapeCssFontFamily = (family: string): string =>
  family.replace(/\\/g, "\\\\").replace(/"/g, '\\"');

export const resolveFontFamily = (
  fontId: TerminalFontId,
  localFontFamily: string | null,
): string => {
  if (fontId === LOCAL_FONT_ID && localFontFamily?.trim()) {
    return `"${escapeCssFontFamily(localFontFamily.trim())}", Menlo, Monaco, monospace`;
  }
  return findFontById(fontId).family;
};
