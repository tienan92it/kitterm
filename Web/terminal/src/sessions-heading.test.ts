import { describe, expect, it } from "vitest";

import { HEADING_LINE_PX, PROFILE_SHORT_CELLS, PROFILE_WHOLE_CELLS, headingLine, type HeadingLine } from "./sessions-model";

/**
 * The card heading at 390 px (`steady-suite`, capability 2): the name is
 * never the thing that gives way. The select labels are the page's default
 * and `~/.kitterm/profiles.json` as bundled on 2026-09-16; the names are
 * the four projects on the live page that day.
 */
const BUNDLED = ["local shell", "box", "zbox", "ubash"];
const LIVE = ["kitterm", "market-data-pipeline", "nghenhan-mt5", "trading-data-api"];
const NO_LIVE = "no live session";
const LONG_PROFILE = ["local shell", "production-bastion"];
const LONG_NAME = "kitterm-shell-integration-tests";

/** How far the line gave way: 0 whole, 1 no count, 2 short select, 3 no select, 4 two lines. */
function rank(line: HeadingLine): number {
  if (!line.fits) return 4;
  if (line.profile === null) return 3;
  if (line.profile === "short") return 2;
  if (line.tally === null) return 1;
  return 0;
}

function expectWhole(line: HeadingLine, name: string): void {
  expect(line.name).toBe(name);
  if (line.fits) expect(line.px).toBeLessThanOrEqual(HEADING_LINE_PX);
}

describe("the card heading at 390 px", () => {
  it("cannot hold all four beside a real name, so the count drops first", () => {
    for (const name of LIVE) {
      const line = headingLine({ name, tally: NO_LIVE, profiles: BUNDLED });
      expectWhole(line, name);
      expect(line.tally, name).toBeNull();
      expect(line.profile, name).toBe("whole");
      expect(line.fits, name).toBe(true);
    }
    // The measurement: whole, the count, the select and `[new]` leave room
    // for a six-character name and no more.
    expect(headingLine({ name: "abcdef", tally: NO_LIVE, profiles: BUNDLED }).tally).toBe(NO_LIVE);
    expect(headingLine({ name: "abcdefg", tally: NO_LIVE, profiles: BUNDLED }).tally).toBeNull();
  });

  it("keeps the count when the line has no select", () => {
    for (const name of LIVE) {
      const alone = headingLine({ name, tally: NO_LIVE, profiles: [] });
      expect(alone.tally, name).toBe(NO_LIVE);
      expect(alone.profile, name).toBeNull();
      expectWhole(alone, name);
      const watching = headingLine({ name, tally: NO_LIVE, profiles: null });
      expect(watching.tally, name).toBe(NO_LIVE);
      expect(watching.px).toBeLessThan(alone.px);
    }
  });

  it("holds every live name whole with the widest profile selected", () => {
    for (const name of LIVE) {
      const line = headingLine({ name, tally: null, profiles: BUNDLED });
      expectWhole(line, name);
      expect(line.profile, name).toBe("whole");
      expect(line.fits, name).toBe(true);
    }
  });

  it("a long profile name: the select is capped and the name stays whole", () => {
    for (const name of LIVE) {
      const line = headingLine({ name, tally: NO_LIVE, profiles: LONG_PROFILE });
      expectWhole(line, name);
      expect(line.profile, name).toBe("whole");
      expect(line.tally, name).toBeNull();
      // The cap is what holds it: the same width as with the bundled labels.
      expect(line.px).toBe(headingLine({ name, tally: NO_LIVE, profiles: BUNDLED }).px);
    }
    expect(PROFILE_WHOLE_CELLS).toBe("local shell".length);
    expect(PROFILE_SHORT_CELLS).toBeGreaterThanOrEqual(Math.max(...BUNDLED.slice(1).map((p) => p.length)));
  });

  it("a long project name: the select shrinks, then drops, and the name stays whole", () => {
    const shrunk = headingLine({ name: "a-twenty-four-char-name!", tally: NO_LIVE, profiles: BUNDLED });
    expectWhole(shrunk, "a-twenty-four-char-name!");
    expect(shrunk.tally).toBeNull();
    expect(shrunk.profile).toBe("short");

    const dropped = headingLine({ name: LONG_NAME, tally: NO_LIVE, profiles: BUNDLED });
    expectWhole(dropped, LONG_NAME);
    expect(dropped.tally).toBeNull();
    expect(dropped.profile).toBeNull();
    expect(dropped.fits).toBe(true);
  });

  it("both long: the name stays whole and the select gives way", () => {
    const line = headingLine({ name: LONG_NAME, tally: NO_LIVE, profiles: LONG_PROFILE });
    expectWhole(line, LONG_NAME);
    expect(line.tally).toBeNull();
    expect(line.profile).toBeNull();
    expect(line.fits).toBe(true);
  });

  it("says when the name and [new] alone are two lines", () => {
    const name = "x".repeat(40);
    const line = headingLine({ name, tally: NO_LIVE, profiles: BUNDLED });
    expect(line.name).toBe(name);
    expect(line.fits).toBe(false);
    expect(line.tally).toBeNull();
    expect(line.profile).toBeNull();
    expect(headingLine({ name: "x".repeat(32), tally: NO_LIVE, profiles: BUNDLED }).fits).toBe(true);
  });

  it("gives way in one direction as the name grows", () => {
    let last = 0;
    const seen = new Set<number>();
    for (let n = 1; n <= 50; n++) {
      const r = rank(headingLine({ name: "n".repeat(n), tally: NO_LIVE, profiles: BUNDLED }));
      expect(r, `${n} characters`).toBeGreaterThanOrEqual(last);
      last = r;
      seen.add(r);
    }
    expect([...seen].sort()).toEqual([0, 1, 2, 3, 4]);
  });
});
