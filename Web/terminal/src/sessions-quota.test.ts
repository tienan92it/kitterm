import { describe, expect, it } from "vitest";

import { countdown, QUOTA_CELLS, quotaAge, quotaCells, quotaLabel, quotaPanel, type UsageLimits } from "./sessions-model";

/**
 * The quota bars (`workspace-ledger`, capability 3): what the page draws
 * from `GET /api/usage/limits`. Every case runs against a fixed clock, the
 * corpus fixture's: a reading four minutes old, the session window at 24%
 * resetting in 49 minutes, the weekly at 27% resetting in a day and 14
 * hours, which is the human's own screenshot.
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
    expect(panel?.bars.map((b) => [b.label, `[${b.cells}]`, b.percent, b.reset, b.state])).toEqual([
      ["Session (5h)", "[#####···············]", "24%", "resets 49m", "fresh"],
      ["Weekly", "[#####···············]", "27%", "resets 1d 14h", "fresh"],
    ]);
    expect(panel?.bars[0].filled).toBe(5);
    expect(panel?.bars.every((b) => b.cells.length === QUOTA_CELLS)).toBe(true);
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

  it("draws a window past its own reset empty and says so", () => {
    const panel = quotaPanel(
      reading({
        rateLimits: {
          five_hour: { used_percentage: 91, resets_at: seconds(NOW - 12 * MIN) },
          seven_day: { used_percentage: 27, resets_at: seconds(NOW + 38 * HOUR) },
        },
      }),
      NOW,
    );
    expect(panel?.bars[0]).toEqual({
      key: "five_hour",
      label: "Session (5h)",
      filled: 0,
      cells: "·".repeat(QUOTA_CELLS),
      percent: "reset",
      reset: "12m ago",
      state: "reset",
    });
    expect(panel?.bars[1].state).toBe("fresh");
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

describe("quotaCells", () => {
  it("rounds to the nearest cell and clamps to the bar", () => {
    expect(quotaCells(0)).toEqual({ filled: 0, cells: "·".repeat(20) });
    expect(quotaCells(2.4)).toEqual({ filled: 0, cells: "·".repeat(20) });
    expect(quotaCells(2.5).filled).toBe(1);
    expect(quotaCells(24).filled).toBe(5);
    expect(quotaCells(27.4).filled).toBe(5);
    expect(quotaCells(50).cells).toBe("##########··········");
    expect(quotaCells(100)).toEqual({ filled: 20, cells: "#".repeat(20) });
    expect(quotaCells(140).filled).toBe(20);
    expect(quotaCells(-5).filled).toBe(0);
    expect(quotaCells(Number.NaN).filled).toBe(0);
    expect(quotaCells(50, 8).cells).toBe("####····");
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
