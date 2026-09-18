import { beforeAll, describe, expect, it } from "vitest";

import { installFakePage, type FakePage } from "./fake-page";

/**
 * The page with the band in place of the strip (`agent-dashboard`,
 * capability 4), rendered by `sessions.ts` itself against a fleet that
 * holds one of everything the strip used to list: a session waiting for
 * input, a failed one, a pending approval on a session with no project,
 * an approval whose session is gone, and a live goal with proposals. Each
 * is a mark on the line it belongs to, the band counts them, and no
 * session is on the page twice. The routes are then changed to 0 and to
 * 20 items and the page polled, so the band's shape is read at all three.
 */

const NOW = 1_758_000_000_000;
const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };

const crew = {
  id: "s-crew",
  name: "the-band round 4",
  cwd: "/w/kitterm",
  state: "running",
  mergedState: "working",
  marks: 0,
  project: { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true },
  labels: { crew: "agent-dashboard", goal: "agent-dashboard", round: "4", task: "the-band-replaces-the-strip" },
  lastOutputAt: NOW,
};
const waiting = { ...crew, id: "s-waiting", name: "release notes", state: "idle", mergedState: "needs-input", labels: {}, agent: { status: "needs-input", message: "Claude needs your input", at: NOW } };
const broke = { ...crew, id: "s-broke", name: "bench", state: "idle", mergedState: "failed", labels: {}, lastExit: 1 };
/** A session outside every project, blocked on a tool call. */
const held = { ...crew, id: "s-held", name: "held", cwd: "/w/elsewhere", project: undefined, state: "idle", mergedState: "needs-approval", labels: {}, pendingApproval: true };
const loose = { ...held, id: "s-loose", name: "loose", mergedState: "idle", pendingApproval: false };

const onHeld = { id: "a-held", tool: "Bash", input: JSON.stringify({ command: "rm -rf build" }), session: "s-held", waitingMs: 45_000 };
/** The daemon no longer lists this approval's session (`facts.md`). */
const orphan = { id: "a-orphan", tool: "Write", input: JSON.stringify({ file_path: "/w/x" }), session: "gone", waitingMs: 5_000 };

const goals = [
  {
    slug: "agent-dashboard", goal: "/sessions is a dashboard", status: "active", round: 4, budget: 6,
    proposals: 2, lastRound: 3, lastRecord: "agent-dashboard/rounds/003.md", lastDecision: "done",
    tasks: [{ slug: "the-band-replaces-the-strip", state: "pending" }],
  },
];

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [crew, waiting, broke, held, loose] },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals },
  "/api/approvals": { approvals: [onHeld, orphan] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/daily": {
    ok: true, timeZone: "UTC", from: "2026-08-20", to: "2026-09-18", refreshedAt: NOW, recordedSessions: 1, days: [], projects: [],
    totals: { costUSD: 2316.45, apportionedUSD: 0, tokens: { input: 1, output: 1, cacheCreation: 0, cacheRead: 0, requests: 1 }, sessions: 1, unbilledSessions: 0 },
  },
  "/api/usage/limits": {
    ok: true, hasReading: true, receivedAt: Date.now(), ageSeconds: 1, stale: false,
    rateLimits: { five_hour: { used_percentage: 19, resets_at: Date.now() / 1000 + 3600 }, seven_day: { used_percentage: 42, resets_at: Date.now() / 1000 + 86_400 } },
  },
};

let page: FakePage;

beforeAll(async () => {
  page = installFakePage(routes);
  await import("./sessions");
  await page.settle();
});

const cells = () => page.root.querySelectorAll(".band-cell").map((cell) => [cell.tagName, cell.querySelector(".band-value")?.textContent, cell.querySelector(".band-noun")?.textContent]);
const marked = () => page.root.querySelectorAll("[data-needs]");
const sessionLinks = () => page.root.querySelectorAll(".row").flatMap((row) => row.querySelectorAll(".open").map((a) => a.href));

describe("the band replaces the strip", () => {
  it("prints four cells: the working count, the need-you count as a link, the spend, the quota", () => {
    expect(cells()).toEqual([
      ["SPAN", "1", "working"],
      // The approval on the held session, the orphan approval, the waiting
      // row, the failed row, and the goal's proposals.
      ["A", "5", "need you"],
      ["SPAN", "$2,316.45", "30d"],
      ["SPAN", "42%", "7d quota"],
    ]);
    expect(page.document.title).toBe("(5) kitterm — sessions");
    expect(page.root.querySelector(".sr-only")?.textContent).toBe("5 items need you");
  });

  it("links the need-you cell to the first marked line, and to nothing else", () => {
    const link = page.root.querySelectorAll(".band-cell").find((cell) => cell.tagName === "A")!;
    expect(link.href).toBe("#needs-you");
    const targets = page.root.querySelectorAll('[id="needs-you"]');
    expect(targets).toHaveLength(1);
    expect(targets[0]).toBe(marked()[0]);
    expect(page.root.querySelectorAll(".band-list")).toEqual([]);
  });

  it("draws no strip and no count line: the band and the marks carry it", () => {
    expect(page.root.querySelectorAll(".strip")).toEqual([]);
    expect(page.root.querySelectorAll(".strip-item")).toEqual([]);
    expect(page.root.querySelectorAll(".fleet")).toEqual([]);
  });

  it("puts every session on the page once, the marked ones included", () => {
    const links = sessionLinks();
    expect([...links].sort()).toEqual(["s-broke", "s-crew", "s-held", "s-loose", "s-waiting"].map((id) => `/?session=${id}`));
    expect(new Set(links).size).toBe(links.length);
    expect(page.root.querySelectorAll(".row")).toHaveLength(5 + 1);
  });

  it("marks each strip item on the line it belongs to", () => {
    const kinds = marked().map((el) => el.dataset.needs);
    // The tree's own order: the project's rows first (waiting, then
    // failed, by state), then the goal's line, then the No project rows.
    expect(kinds).toEqual(["row", "row", "proposed", "approval", "approval"]);
    const rows = page.root.querySelectorAll(".row");
    const heldRow = rows.find((row) => row.querySelector(".open")?.href === "/?session=s-held")!;
    expect(heldRow.querySelector(".line-approval")?.textContent).toContain("approve Bash");
    const goal = page.root.querySelector('[data-needs="proposed"]')!;
    expect(goal.querySelector(".mark")?.className).toBe("mark attention");
    expect(goal.querySelectorAll("a").map((a) => a.textContent)).toContain("2 proposals");
    expect(goal.querySelectorAll("button").map((b) => b.textContent)).toContain("Dismiss");
  });

  it("gives an approval whose session is gone a line under No project", () => {
    const none = page.root.querySelectorAll("section").find((s) => s.getAttribute("aria-label") === "No project")!;
    const lines = none.querySelectorAll(".line-approval").map((line) => line.textContent);
    expect(lines.some((text) => text.includes("approve Write"))).toBe(true);
    expect(none.querySelectorAll(".row").length).toBe(3);
  });

  it("keeps four cells and no link when nothing needs a person", async () => {
    routes["/api/sessions"] = { ok: true, sessions: [crew, loose] };
    routes["/api/approvals"] = { approvals: [] };
    routes["/api/projects/kitterm/knowledge"] = { ok: true, project: "kitterm", goals: goals.map((g) => ({ ...g, proposals: 0 })) };
    await page.poll();
    expect(cells()).toEqual([
      ["SPAN", "1", "working"],
      ["SPAN", "0", "need you"],
      ["SPAN", "$2,316.45", "30d"],
      ["SPAN", "42%", "7d quota"],
    ]);
    expect(marked()).toEqual([]);
    expect(page.root.querySelectorAll('[id="needs-you"]')).toEqual([]);
    expect(page.document.title).toBe("kitterm — sessions");
  });

  it("keeps four cells with twenty items needing a person: the count grows, the band does not", async () => {
    const twenty = Array.from({ length: 20 }, (_, i) => ({ ...orphan, id: `a-${i}` }));
    routes["/api/approvals"] = { approvals: twenty };
    await page.poll();
    expect(cells()).toEqual([
      ["SPAN", "1", "working"],
      ["A", "20", "need you"],
      ["SPAN", "$2,316.45", "30d"],
      ["SPAN", "42%", "7d quota"],
    ]);
    expect(page.root.querySelectorAll(".band-cell")).toHaveLength(4);
    expect(page.root.querySelector(".band")?.children).toHaveLength(4);
    expect(marked()).toHaveLength(20);
    expect(page.root.querySelectorAll('[id="needs-you"]')).toHaveLength(1);
    // Twenty orphan approvals are twenty lines under No project, in the tree.
    const none = page.root.querySelectorAll("section").find((s) => s.getAttribute("aria-label") === "No project")!;
    expect(none.querySelectorAll(".line-approval")).toHaveLength(20);
  });
});
