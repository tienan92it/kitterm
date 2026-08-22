/**
 * The drawn icons for the extra-keys row.
 *
 * One set, one grid, so the row stops mixing sources. Before this it drew from
 * three at once: Unicode arrows, an APL character (U+2338) for browse, a
 * fullwidth plus for attach, and one hand-built SVG. Each came out at a
 * different weight, and two of them render differently on every platform.
 *
 * **The grid**, which every icon here follows and any new one must:
 *
 * - `24 × 24` viewBox, so a path can be lifted from any of the common
 *   line sets — Feather, Lucide, Heroicons — without rescaling.
 * - Stroke only, never fill. `currentColor`, so icons follow the theme the way
 *   the lettered keys already do.
 * - Stroke width `2`, round caps and joins. Rendered at 20px that lands near
 *   1.7px, which sits at the same visual weight as the row's 16px text.
 * - Detail kept out. These are read at 20px on a phone, in a hurry, and every
 *   extra line closes up at that size.
 *
 * The row keeps words for keys that *are* words — Esc, Tab, Ctrl, ⌃C. Those
 * are names, not pictures, and lettering them is what every terminal does. The
 * rule is: name it if it has a name, draw it if it does not.
 */

export type IconName =
  | "arrow-left"
  | "arrow-up"
  | "arrow-down"
  | "arrow-right"
  | "folder"
  | "paperclip";

/** Each icon is its path list, so the set is data and can be checked. */
export const ICONS: Record<IconName, readonly string[]> = {
  // Shaft plus head: at this size a bare chevron reads as a scroll hint, and
  // these have to read as the arrow *keys*.
  "arrow-left": ["M19 12H5", "M12 19l-7-7 7-7"],
  "arrow-up": ["M12 19V5", "M5 12l7-7 7 7"],
  "arrow-down": ["M12 5v14", "M19 12l-7 7-7-7"],
  "arrow-right": ["M5 12h14", "M12 5l7 7-7 7"],
  // Browse the machine the session runs on.
  "folder": ["M3 7.5A1.5 1.5 0 0 1 4.5 6h4.2l2 2.4h8.8A1.5 1.5 0 0 1 21 9.9v8.6a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5z"],
  // Attach a file from this device. Drawn open and shallow: the usual tight
  // paperclip spiral fills in completely at 20px.
  "paperclip": ["M16.5 9.4 10 15.9a2.1 2.1 0 0 0 3 3l6.5-6.5a4.2 4.2 0 0 0-6-6l-6.6 6.6a6.3 6.3 0 0 0 8.9 8.9l5.7-5.7"],
} as const;

export const ICON_VIEWBOX = "0 0 24 24";
export const ICON_STROKE_WIDTH = "2";

/** Build one icon. Returns the element so a caller can hold on to it. */
export function buildIcon(name: IconName): SVGSVGElement {
  return buildIconFromPaths(ICONS[name]);
}

/**
 * The shared shell every icon in the row is drawn into, so weight and geometry
 * cannot drift between them. Exported for the keyboard toggle, which owns one
 * mutable path of its own and so cannot be a static entry in `ICONS`.
 */
export function buildIconFromPaths(paths: readonly string[]): SVGSVGElement {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", ICON_VIEWBOX);
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", ICON_STROKE_WIDTH);
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  for (const d of paths) {
    const path = document.createElementNS(ns, "path");
    path.setAttribute("d", d);
    svg.append(path);
  }
  return svg;
}
