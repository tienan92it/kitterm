import { describe, expect, it } from "vitest";

import { ICONS, ICON_STROKE_WIDTH, ICON_VIEWBOX, type IconName } from "./icons";

const names = Object.keys(ICONS) as IconName[];

// The row used to draw from three sources at once — Unicode arrows, an APL
// character, a fullwidth plus — and every one came out at a different weight.
// These pin the single grid so a later icon cannot quietly leave it.
describe("the icon set", () => {
  it("shares one viewBox and one stroke weight", () => {
    expect(ICON_VIEWBOX).toBe("0 0 24 24");
    expect(ICON_STROKE_WIDTH).toBe("2");
  });

  it.each(names)("%s is at least one path, each starting at a move", (name) => {
    const paths = ICONS[name];
    expect(paths.length).toBeGreaterThan(0);
    for (const d of paths) expect(d.startsWith("M")).toBe(true);
  });

  it.each(names)("%s carries no fill or colour of its own", (name) => {
    // Colour comes from currentColor on the shell, so the icons follow the
    // theme. A path that hardcoded either would stay put when the theme moved.
    for (const d of ICONS[name]) {
      expect(d).not.toMatch(/fill|#[0-9a-f]{3}/i);
    }
  });

  it("has no two icons drawn the same, which would mean a copy-paste slip", () => {
    const shapes = names.map((n) => ICONS[n].join("|"));
    expect(new Set(shapes).size).toBe(shapes.length);
  });

  it("keeps the four arrows, which the row cannot lose", () => {
    for (const n of ["arrow-left", "arrow-up", "arrow-down", "arrow-right"]) {
      expect(names).toContain(n);
    }
  });
});
