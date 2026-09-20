import { describe, expect, it } from "vitest";

import { countdown, QUOTA_CAUTION_PERCENT, quotaAge, quotaFill, quotaLabel, quotaLevel, quotaPanel, quotaReadAge, type UsageLimits } from "./sessions-model";

/**
 * The quota bars (`workspace-ledger`, capability 3; reshaped in
 * `agent-dashboard` round 11 to the Components frame's bar): what the page
 * draws from `GET /api/usage/limits`. Every case runs against a fixed
 * clock, the corpus fixture's: a reading four minutes old, the session
 * window at 24% resetting in 49 minutes, the weekly at 27% resetting in a
 * day and 14 hours, which is the human's own screenshot. A bar is a fill,
 * 0 to 1, and the colour it wears: the accent under 80%, the caution at
 * 80% and over. Chartered in round 11: the twenty ASCII cells
 * (`quotaCells`, `QUOTA_CELLS`, `filled`) pinned the `[####····]` form
 * the frame replaced.
 */
const NOW = Date.UTC(2026, 8, 16, 8, 0, 0);
const MIN = 60_000;
const HOUR = 60 * MIN;
const seconds = (ms: number): number => Math.floor(ms / 1000);

const reading = (extra: Partial<UsageLimits> = {}): UsageLimits => ({
  ok: true,
  hasReading: true,
  receivedAt: NOW - 4 * MIN,
  ageSeconds: 240,
  stale: false,
  rateLimits: {
    five_hour: { used_percentage: 24, resets_at: seconds(NOW + 49 * MIN) },
    seven_day: { used_percentage: 27.4, resets_at: seconds(NOW + 38 * HOUR) },
  },
  ...extra,
});

describe("quotaPanel", () => {
  it("draws nothing when the route did not answer", () => {
    expect(quotaPanel(null, NOW)).toBeNull();
    expect(quotaPanel(undefined, NOW)).toBeNull();
    expect(quotaPanel({ ok: false, hasReading: false }, NOW)).toBeNull();
  });

  it("says in words when no reading has ever arrived, and names the command", () => {
    const panel = quotaPanel({ ok: true, hasReading: false }, NOW);
    expect(panel?.bars).toEqual([]);
    expect(panel?.note).toBe(
      "No quota reading yet. Run kitterm statusline install, then open a Claude Code session; its statusline posts one.",
    );
  });

  it("draws one bar per window with its countdown, the screenshot's two", () => {
    const panel = quotaPanel(reading(), NOW);
    expect(panel?.note).toBe("read 4m ago");
    expect(panel?.bars.map((b) => [b.label, Math.round(b.fill * 1000), b.level, b.percent, b.reset, b.state])).toEqual([
      ["Session (5h)", 240, "accent", "24%", "resets 49m", "fresh"],
      ["Weekly", 274, "accent", "27%", "resets 1d 14h", "fresh"],
    ]);
  });

  it("turns the fill and the number caution at 80% and not at 79%", () => {
    // The Components frame: `Weekly 87% ... 80% and over: caution`. The
    // label and the reset carry no level; the page never colours them.
    const at = (percent: number) => quotaPanel(reading({ rateLimits: { five_hour: { used_percentage: percent, resets_at: seconds(NOW + 49 * MIN) } } }), NOW)!.bars[0];
    expect(QUOTA_CAUTION_PERCENT).toBe(80);
    expect([79, 79.9, 80, 87, 100, 140].map((p) => at(p).level)).toEqual(["accent", "accent", "caution", "caution", "caution", "caution"]);
    expect(at(80)).toMatchObject({ fill: 0.8, level: "caution", percent: "80%", reset: "resets 49m", state: "fresh" });
    expect(at(79)).toMatchObject({ fill: 0.79, level: "accent", percent: "79%" });
    // A stale reading keeps its level: the page greys the fill by state.
    expect(quotaPanel(reading({ stale: true, rateLimits: { five_hour: { used_percentage: 91, resets_at: seconds(NOW + HOUR) } } }), NOW)!.bars[0]).toMatchObject({ level: "caution", state: "stale" });
  });

  it("lists the three known windows in order, then any other by key", () => {
    const panel = quotaPanel(
      reading({
        rateLimits: {
          zzz_window: { used_percentage: 1, resets_at: seconds(NOW + HOUR) },
          spend_limit: { used_percentage: 62.8, resets_at: seconds(NOW + 30 * 24 * HOUR) },
          seven_day: { used_percentage: 27, resets_at: seconds(NOW + 38 * HOUR) },
          five_hour: { used_percentage: 24, resets_at: seconds(NOW + 49 * MIN) },
        },
      }),
      NOW,
    );
    expect(panel?.bars.map((b) => b.key)).toEqual(["five_hour", "seven_day", "spend_limit", "zzz_window"]);
    expect(panel?.bars.map((b) => b.label)).toEqual(["Session (5h)", "Weekly", "Spend limit", "zzz window"]);
    expect(panel?.bars[2].percent).toBe("63%");
    expect(panel?.bars[2].reset).toBe("resets 30d");
  });

  it("says reset and the reading's age on a window past its reset, and keeps its last value in the faint grey", () => {
    // Round 14, the human's word: never `resets 1d 17h ago`. Chartered,
    // this replaced the empty bar with `reset` for its number and `12m
    // ago` for its reset. The reading is stale, as `GET /api/usage/limits`
    // answers once the statusline stopped posting: the session window
    // reset 1d 17h ago and the reading is 1d 19h old.
    const panel = quotaPanel(
      reading({
        receivedAt: NOW - (43 * HOUR + 12 * MIN),
        ageSeconds: 43 * 3600 + 12 * 60,
        stale: true,
        rateLimits: {
          five_hour: { used_percentage: 91, resets_at: seconds(NOW - (41 * HOUR + 5 * MIN)) },
          seven_day: { used_percentage: 27, resets_at: seconds(NOW + 38 * HOUR) },
        },
      }),
      NOW,
    );
    expect(panel?.bars[0]).toEqual({
      key: "five_hour",
      label: "Session (5h)",
      fill: 0.91,
      level: "accent",
      percent: "91%",
      reset: "reset · read 1d 19h ago",
      state: "reset",
    });
    expect(panel?.bars.filter((b) => /^resets .* ago$/.test(b.reset)), "no window prints resets … ago").toEqual([]);
    // The window with a future reset prints as today, stale.
    expect(panel?.bars[1]).toMatchObject({ percent: "27%", reset: "resets 1d 14h", state: "stale", level: "accent" });
    // A past window on a fresh reading is the same, its age from `ageSeconds`.
    const fresh = quotaPanel(reading({ rateLimits: { five_hour: { used_percentage: 91, resets_at: seconds(NOW - 12 * MIN) } } }), NOW);
    expect(fresh?.bars[0]).toMatchObject({ percent: "91%", reset: "reset · read 4m ago", state: "reset", fill: 0.91 });
    expect(quotaReadAge({ ageSeconds: 20 }, NOW)).toBe("read just now");
    expect(quotaReadAge({ receivedAt: NOW - 3 * HOUR }, NOW), "from receivedAt when the daemon sends no age").toBe("read 3h ago");
  });

  it("keeps a stale reading's bars and says how old they are", () => {
    const panel = quotaPanel(reading({ receivedAt: NOW - 3 * HOUR, ageSeconds: 3 * 3600, stale: true }), NOW);
    expect(panel?.note).toBe("read 3h ago; open a Claude Code session to refresh it.");
    expect(panel?.bars.map((b) => b.state)).toEqual(["stale", "stale"]);
    expect(panel?.bars[0].percent).toBe("24%");
  });

  it("says when the last reading carried no window", () => {
    const panel = quotaPanel(reading({ rateLimits: {} }), NOW);
    expect(panel?.bars).toEqual([]);
    expect(panel?.note).toBe(
      "The last reading, 4m ago, carried no quota window: an API-key account, or a session before its first response.",
    );
  });

  it("reads a reading under a minute old as just now", () => {
    expect(quotaPanel(reading({ receivedAt: NOW - 20_000 }), NOW)?.note).toBe("read just now");
    expect(quotaAge(NOW - 2 * 24 * HOUR, NOW)).toBe("read 2d ago");
  });
});

describe("quotaFill", () => {
  it("is the share of the bar, clamped, with the level the share earns", () => {
    expect(quotaFill(0)).toEqual({ fill: 0, level: "accent" });
    expect(quotaFill(24)).toEqual({ fill: 0.24, level: "accent" });
    expect(quotaFill(50)).toEqual({ fill: 0.5, level: "accent" });
    expect(quotaFill(100)).toEqual({ fill: 1, level: "caution" });
    expect(quotaFill(140)).toEqual({ fill: 1, level: "caution" });
    expect(quotaFill(-5)).toEqual({ fill: 0, level: "accent" });
    expect(quotaFill(Number.NaN)).toEqual({ fill: 0, level: "accent" });
    expect([79.99, 80].map(quotaLevel)).toEqual(["accent", "caution"]);
  });
});

describe("countdown", () => {
  it("prints the two largest units, rounded down", () => {
    expect(countdown(30_000)).toBe("<1m");
    expect(countdown(49 * MIN + 59_000)).toBe("49m");
    expect(countdown(3 * HOUR + 12 * MIN)).toBe("3h 12m");
    expect(countdown(3 * HOUR)).toBe("3h");
    expect(countdown(38 * HOUR)).toBe("1d 14h");
    expect(countdown(48 * HOUR)).toBe("2d");
    expect(countdown(-5)).toBe("<1m");
  });
});

describe("quotaLabel", () => {
  it("names the three windows and opens any other key", () => {
    expect(quotaLabel("five_hour")).toBe("Session (5h)");
    expect(quotaLabel("seven_day")).toBe("Weekly");
    expect(quotaLabel("spend_limit")).toBe("Spend limit");
    expect(quotaLabel("seven_day_opus")).toBe("seven day opus");
  });
});
