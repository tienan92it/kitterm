import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import { parseCss } from "./theme-contrast-derive";

/**
 * The palette's own phone rule (`code-editor` round 14, a foreman
 * correction after round 14's own Playwright check at 390 px): a phone has
 * no keys to name, so the hint `↑ ↓ choose · Enter opens · Esc closes`
 * squeezed the query input to a sliver; it drops below 768 px and the
 * input takes the row.
 */
const SOURCE = readFileSync(new URL("./edit.css", import.meta.url), "utf8");
const RULES = parseCss("edit.css", SOURCE);

describe("the palette's keys hint", () => {
  it("shows at 1200 px: no display rule outside the phone media condition", () => {
    const wide = RULES.find((r) => r.selector === ".edit-palette-keys" && r.conditions.length === 0);
    expect(wide?.decls.has("display")).toBe(false);
  });

  it("drops below 768 px so the query input takes the row", () => {
    const narrow = RULES.find(
      (r) => r.selector === ".edit-palette-keys" && r.conditions.some((c) => c.includes("max-width: 767px")),
    );
    expect(narrow?.decls.get("display")).toBe("none");
  });
});
