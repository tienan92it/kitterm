import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, fakeStatus, fakeThrow, installFakePage, type FakePage } from "./fake-page";

/**
 * The SERVERS section as the page paints it (`running-servers` round 3,
 * `corpus/01-approved-design.md`): under the tree and above the folds, the
 * header with the counts, one row per listed server on the line grid, the
 * link for a server that answers HTTP, and `▶ N other servers`, a
 * disclosure button that keeps its state across repaints; the sentence
 * with no server; `supported: false` hides it. `sessions-servers.test.ts`
 * pins the data; `sessions-servers-css.test.ts` the sheet.
 */

const NOW = Date.now();
const DAY = 86_400_000;
const apps = { id: "foundation-apps", name: "foundation-apps", root: "/Users/an/Workspace/foundation-apps", registered: false };
const pipeline = { id: "market-data-pipeline", name: "market-data-pipeline", root: "/Users/an/Workspace/market-data-pipeline", registered: true };
const homebrew = { id: "homebrew", name: "homebrew", root: "/opt/homebrew", registered: false };
const FOREMAN = "9A1B2C3D-4E5F-4A6B-8C7D-0E1F2A3B4C5D";

const servers = [
  { port: 6379, addresses: ["127.0.0.1", "::1"], pid: 500, program: "redis-server", startedAt: NOW - 12 * DAY, project: homebrew, launcher: undefined, http: false },
  { port: 3000, addresses: ["0.0.0.0", "::"], pid: 440, program: "next-server (v15.1.0)", startedAt: NOW - 25 * DAY, project: apps, launcher: "node", parent: "node", http: true },
  { port: 5432, addresses: ["127.0.0.1"], pid: 200, program: "postgres", startedAt: NOW - 5 * DAY, session: { id: FOREMAN, name: "lume-cafe postgres (local)" }, http: false },
  { port: 7000, addresses: ["0.0.0.0"], pid: 9, program: "ControlCenter", startedAt: NOW - 25 * DAY },
  { port: 3003, addresses: ["127.0.0.1"], pid: 310, program: "kubectl", startedAt: NOW - 46 * 60_000, project: pipeline, session: { id: FOREMAN, name: "foreman", through: "claude" }, http: true },
];

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [] },
  "/api/projects": { projects: [pipeline] },
  "/api/projects/market-data-pipeline/knowledge": { ok: true, project: "market-data-pipeline", goals: [] },
  "/api/approvals": { approvals: [] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
  "/api/usage/limits": { ok: true, hasReading: false },
  "/api/servers": { ok: true, supported: true, readAt: NOW - 1000, ageSeconds: 1, servers },
};

let page: FakePage;

beforeAll(async () => {
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  await import("./sessions");
  await page.settle();
  await page.poll();
});

const kids = (el: FakeElement): FakeElement[] => el.children.filter((c): c is FakeElement => typeof c !== "string");
const block = () => page.root.querySelector(".servers-head")!;
const head = () => block().querySelector(".servers")!;
const lines = () => block().querySelectorAll(".line-review");
const rows = () => lines().filter((row) => !row.classList.contains("line-fold"));
const fold = () => lines().find((row) => row.classList.contains("line-fold"))!;
const button = () => fold().querySelector("button")!;
const cells = (row: FakeElement): string[] => kids(row.querySelector(".main")!).map((c) => `${c.className}${c.getAttribute("data-col") ? `@${c.getAttribute("data-col")}` : ""}=${c.textContent}`);
const requests = (path: string) => page.requests.filter((url) => url.replace(/\?.*$/, "") === path);

describe("the section", () => {
  it("sits between the tree and the folds, with its label in the gutter and the counts, the listed count a mark in the accent", () => {
    const order = page.root.children.filter((c): c is FakeElement => typeof c !== "string").map((c) => c.className.split(" ")[0]);
    expect(order.slice(order.indexOf("tree"))).toEqual(["tree", "servers-head", "folds"]);
    expect(block().hidden).toBe(false);
    expect(kids(block()).map((c) => `${c.tagName.toLowerCase()}.${c.className}`)).toEqual(["span.servers-label", "p.servers", "div.servers-rows"]);
    expect(block().querySelector(".servers-label")?.textContent).toBe("SERVERS");
    expect(head().textContent).toBe("3 listening · 2 HTTP · 2 other");
    expect(kids(head()).map((c) => `${c.className}=${c.textContent}`)).toEqual(["mark listening wide=3"]);
  });

  it("asked the route once with the fleet, after the grade was known", () => {
    expect(requests("/api/servers").length).toBe(1);
    expect(page.requests.indexOf("/api/profiles")).toBeLessThan(page.requests.indexOf("/api/servers"));
  });
});

describe("the rows", () => {
  it("draws one line per listed server by port, and the fold last, closed", () => {
    expect(rows().map((row) => row.querySelector(".pr")?.textContent)).toEqual(["localhost:3000", "localhost:3003", "localhost:5432"]);
    expect(lines().at(-1)).toBe(fold());
    expect(fold().textContent).toBe("▶2 other servers");
    expect([button().className, button().getAttribute("aria-expanded"), button().getAttribute("data-focus")]).toEqual(["mark disclosure", "false", "fold:servers-other"]);
  });

  it("is a line on the grid: the ● mark in the accent as the line's own child, then the cells in the frame's order", () => {
    const row = rows()[0];
    expect(row.className).toBe("line line-review line-server");
    expect(kids(row).map((c) => c.className)).toEqual(["mark listening", "main"]);
    expect(row.querySelector(".mark")?.textContent).toBe("●");
    expect(row.querySelector(".mark")?.getAttribute("aria-hidden")).toBe("true");
    expect(cells(row)).toEqual([
      "pr@3=localhost:3000",
      "line-name=foundation-apps / next-server",
      "line-detail=outside kitterm · node",
      "state=http",
      "binds@2=all hosts",
      "since@4=25d",
    ]);
    expect(row.querySelector(".line-name")?.title).toBe("foundation-apps / next-server");
  });

  it("links a server that answers HTTP, underlined through the mark like PR #N, with a focus key; a tcp server is plain text", () => {
    const link = rows()[0].querySelector("a")!;
    const anchor = link as FakeElement & { target?: string; rel?: string };
    expect([link.className, link.href, anchor.target, anchor.rel, link.getAttribute("data-focus")]).toEqual(["pr-link", "http://localhost:3000/", "_blank", "noopener", "servers:440:3000"]);
    expect(kids(link).map((c) => `${c.className}=${c.textContent}`)).toEqual(["mark link wide=localhost:3000"]);
    const postgres = rows()[2];
    expect(postgres.querySelectorAll("a")).toEqual([]);
    expect(cells(postgres)).toEqual([
      "pr@3=localhost:5432",
      "line-name=postgres",
      "line-detail=kitterm pane lume-cafe postgres (local)",
      "state=tcp",
      "binds@2=loopback",
      "since@4=5d",
    ]);
    expect(cells(rows()[1])[2]).toBe("line-detail=claude in foreman");
  });

  it("opens the fold to the folded rows of the same shape, and keeps it open across a repaint", async () => {
    button().click();
    expect(rows().map((row) => row.querySelector(".pr")?.textContent)).toEqual(["localhost:3000", "localhost:3003", "localhost:5432", "localhost:6379", "localhost:7000"]);
    expect(button().getAttribute("aria-expanded")).toBe("true");
    expect(button().textContent).toBe("▼");
    expect(cells(rows()[3])).toEqual(["pr@3=localhost:6379", "line-name=homebrew / redis-server", "line-detail=outside kitterm", "state=tcp", "binds@2=loopback", "since@4=12d"]);
    // A repaint with a changed fleet keeps the fold open.
    routes["/api/sessions"] = { ok: true, sessions: [{ id: "s1", name: "shell", cwd: "/Users/an", state: "idle", mergedState: "idle", marks: 0 }] };
    await page.poll();
    expect(button().getAttribute("aria-expanded")).toBe("true");
    expect(rows().length).toBe(5);
    button().click();
    expect(rows().length).toBe(3);
  });

  it("holds no control but the one disclosure button", () => {
    expect(block().querySelectorAll("button").map((b) => b.className)).toEqual(["mark disclosure"]);
    expect(block().querySelectorAll("input")).toEqual([]);
  });
});

describe("the empty sentence and a daemon with no reader", () => {
  it("prints one sentence with no server, and no rows", async () => {
    routes["/api/servers"] = { ok: true, supported: true, readAt: NOW, ageSeconds: 0, servers: [] };
    await new Promise((resolve) => setTimeout(resolve, 0));
    vi.spyOn(Date, "now").mockReturnValue(NOW + 6000);
    await page.poll();
    vi.restoreAllMocks();
    expect(block().hidden).toBe(false);
    expect(head().textContent).toBe("No server is listening.");
    expect(lines()).toEqual([]);
  });

  it("keeps the last answer when a request fails, and hides the section on supported: false", async () => {
    routes["/api/servers"] = fakeThrow();
    vi.spyOn(Date, "now").mockReturnValue(NOW + 12_000);
    await page.poll();
    vi.restoreAllMocks();
    expect(head().textContent).toBe("No server is listening.");
    routes["/api/servers"] = { ok: true, supported: false, reason: "reading /proc is not implemented on Linux", servers: [] };
    vi.spyOn(Date, "now").mockReturnValue(NOW + 18_000);
    await page.poll();
    vi.restoreAllMocks();
    expect(block().hidden).toBe(true);
    expect(head().textContent).toBe("");
  });

  it("stops asking on a 403", async () => {
    routes["/api/servers"] = fakeStatus(403, { ok: false });
    const before = requests("/api/servers").length;
    vi.spyOn(Date, "now").mockReturnValue(NOW + 24_000);
    await page.poll();
    vi.spyOn(Date, "now").mockReturnValue(NOW + 30_000);
    await page.poll();
    vi.restoreAllMocks();
    expect(requests("/api/servers").length).toBe(before + 1);
    expect(block().hidden).toBe(true);
  });
});
