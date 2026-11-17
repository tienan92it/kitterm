import { vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { USAGE_DEFAULT, usageRange } from "./sessions-model";

/**
 * The fixture of the two paint-first page tests (`fleet-first-paint`,
 * round 1): one fleet whose five slow sections each sit behind a gate the
 * test opens. `installFakePage` answers at once; this wraps its `fetch` so
 * a request for a gated section waits until the test releases it.
 * Test-only; nothing ships it.
 */

export const NOW = new Date(2026, 8, 10, 12, 0, 0).getTime();

/** The slow sections, and the event feed the page watches. */
export type Gate = "archives" | "usage" | "yield" | "bills" | "lifetime" | "events";

const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };
const ref = { id: kitterm.id, name: kitterm.name, root: kitterm.root };
const tokens = { input: 0, output: 0, cacheCreation: 0, cacheRead: 0, requests: 0 };
const START = Date.parse("2026-09-10T01:00:00Z");

function days(): { usage: unknown[]; yield: unknown[] } {
  const usage: unknown[] = [];
  const yieldDays: unknown[] = [];
  for (let i = 1; i <= 10; i += 1) {
    const day = `2026-09-${String(i).padStart(2, "0")}`;
    usage.push({ day, costUSD: 10, apportionedUSD: 0, tokens, sessions: 1, unbilledSessions: 0, apiMs: 3_600_000, measuredUSD: 10, projects: [] });
    yieldDays.push({ day, mergedPullRequests: i, mergedLines: i * 100, releases: 1, projects: [] });
  }
  return { usage, yield: yieldDays };
}

/** The routes of the fixture; a test may replace an entry between polls. */
export function paintFirstRoutes(): Record<string, unknown> {
  const fixture = days();
  return {
    "/api/sessions": {
      ok: true,
      sessions: [{
        id: "s-crew", name: "crew", cwd: kitterm.root, state: "running", mergedState: "working", marks: 0, project: ref,
        agentModel: "claude-opus-5", agentModelName: "Opus 5", agentTranscript: "/t/crew.jsonl", lastOutputAt: NOW - 12_000,
      }],
    },
    "/api/projects": { projects: [kitterm] },
    "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [] },
    "/api/approvals": { approvals: [{ id: "a-1", tool: "Bash", input: "swift test", session: "s-crew", waitingMs: 4000 }] },
    "/api/usage/limits": { ok: true, hasReading: false },
    "/api/profiles": { profiles: [] },
    "/api/archives": { archives: [{ id: "arch-1", name: "old", cwd: kitterm.root }, { id: "arch-2", name: "older", cwd: kitterm.root }] },
    "/api/usage/daily": (query: URLSearchParams) => ({
      ok: true, timeZone: "UTC", from: query.get("from"), to: query.get("to"), refreshedAt: NOW, recordedSessions: 10,
      days: fixture.usage, totals: { costUSD: 100, apportionedUSD: 0, tokens, sessions: 10, unbilledSessions: 0 },
      models: [{ model: "claude-opus-5", name: "Opus 5", costUSD: 100, apportionedUSD: 0, inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 1, cacheCreationInputTokens: 0, sessions: 10 }],
      projects: [{ ...ref, costUSD: 100, apportionedUSD: 0, tokens, sessions: 10, unbilledSessions: 0 }],
      lowCache: [{ sessionId: "x", project: "kitterm", costUSD: 15.84, cacheShare: 0.94 }],
    }),
    "/api/yield": { ok: true, from: "2026-09-01", to: "2026-09-10", projects: [], totals: { checkouts: 0, counted: 0, mergedPullRequests: 0, mergedLines: 0, releases: 0 } },
    "/api/yield/daily": (query: URLSearchParams) => ({ ok: true, from: query.get("from"), to: query.get("to"), days: fixture.yield }),
    "/api/sessions/s-crew/cost": { ok: true, hasBill: true, estimated: false, bill: { totalCostUSD: 4.31, startTime: START } },
  };
}

/** The gate a request waits at, or null for a request that answers at
 * once. `/api/usage/daily` serves two sections: the chosen range is the
 * usage, any other range is the lifetime read. */
function gateOf(url: string): Gate | null {
  const path = url.replace(/\?.*$/, "");
  if (path === "/api/archives") return "archives";
  if (path === "/api/yield") return "yield";
  if (path === "/api/yield/daily") return "lifetime";
  if (path === "/api/usage/daily") return url.includes(`from=${usageRange(USAGE_DEFAULT.span, NOW).from}&`) ? "usage" : "lifetime";
  if (/^\/api\/sessions\/[^/]+\/cost$/.test(path)) return "bills";
  if (path === "/api/events") return "events";
  return null;
}

export type GatedPage = {
  page: FakePage;
  /** How many requests the page made for a section, answered or not. */
  asked(gate: Gate): number;
  /** The requests the daemon answered, by section; a held one is not in. */
  answered(): Gate[];
  /** Answer the requests held at the gate; the next one waits again. */
  release(gate: Gate): Promise<void>;
  /** Remove the gate: answer what it holds and everything after. */
  open(gate: Gate): Promise<void>;
  /** A panel of the page by its class (`usage`, `value`, `where`, ...). */
  panel(name: string): FakeElement;
  /** The text of every waiting line on the page, in page order. */
  waiting(): string[];
};

/** Install the page with every gate closed. Call before `sessions.ts` is
 * imported, as `installFakePage`. */
export function installGatedPage(routes: Record<string, unknown>): GatedPage {
  vi.spyOn(Date, "now").mockReturnValue(NOW);
  const page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  const answer = globalThis.fetch;
  const closed = new Set<Gate>(["archives", "usage", "yield", "bills", "lifetime", "events"]);
  const held = new Map<Gate, Array<() => void>>();
  const asks: Gate[] = [];
  const answers: Gate[] = [];
  vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
    const gate = gateOf(String(input));
    if (gate !== null) {
      asks.push(gate);
      if (closed.has(gate)) await new Promise<void>((resolve) => held.set(gate, [...(held.get(gate) ?? []), resolve]));
      answers.push(gate);
    }
    return answer(input, init);
  });
  const release = async (gate: Gate): Promise<void> => {
    const waiting = held.get(gate) ?? [];
    held.delete(gate);
    for (const resolve of waiting) resolve();
    await page.settle();
  };
  return {
    page,
    asked: (gate) => asks.filter((g) => g === gate).length,
    answered: () => [...answers],
    release,
    open: async (gate) => {
      closed.delete(gate);
      await release(gate);
    },
    panel: (name) => page.root.querySelectorAll(".panel").find((p) => p.classList.contains(name))!,
    waiting: () => page.root.querySelectorAll(".section-waiting").map((el) => el.textContent),
  };
}
