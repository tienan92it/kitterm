import { beforeAll, describe, expect, it } from "vitest";

import { type FakeElement } from "./fake-page";
import { type GatedPage, installGatedPage, paintFirstRoutes } from "./paint-first-fixture";
import { BILL_TITLE, BILL_WAITING_TITLE } from "./sessions-model";

/**
 * The fleet paints first (`fleet-first-paint`, round 1; `goal.md`
 * conditions 1 and 2 and the page half of 4). The page renders the
 * sessions, the projects and the approvals after four answers. The
 * archives, the usage, the yield, the bills and the lifetime read each
 * wait behind a gate here; each shows that it waits and paints by itself
 * when the test opens its gate. The steps run in order on one page.
 */

const routes = paintFirstRoutes();
let gated: GatedPage;

beforeAll(async () => {
  gated = installGatedPage(routes);
  await import("./sessions");
  await gated.page.settle();
});

const root = (): FakeElement => gated.page.root;
const tree = (): FakeElement => root().querySelector(".tree")!;
const folds = (): FakeElement => root().querySelector(".folds")!;
const bandCell = (key: string): string | undefined =>
  root().querySelectorAll(".band-cell").find((c) => c.classList.contains(key))?.querySelector(".band-value")?.textContent;
const costCell = (): FakeElement => tree().querySelector(".row-line")!.querySelector(".cost")!;
const foldNames = (): string[] => folds().querySelectorAll(".line-name").map((n) => n.textContent);

describe("with every slow route stalled", () => {
  it("paints the sessions, the projects, the approvals and the quota after four answers", () => {
    expect(gated.answered()).toEqual([]);
    const fleet = ["/api/sessions", "/api/projects", "/api/approvals", "/api/usage/limits"];
    expect(fleet.every((path) => gated.page.requests.includes(path))).toBe(true);
    expect(tree().querySelector(".line-project")?.querySelector(".line-name")?.textContent).toBe("kitterm");
    expect(tree().querySelector(".row-line")?.querySelector(".line-name")?.textContent).toBe("crew");
    expect(tree().querySelector(".line-approval")?.textContent).toContain("approve Bash");
    expect(gated.panel("quota").hidden).toBe(false);
    expect(bandCell("needs")).toBe("1");
  });

  it("shows that the archives and the usage wait; the parts behind the usage stay off", () => {
    expect(gated.waiting()).toEqual(["Reading the usage…", "Archived …"]);
    expect(gated.panel("usage").hidden).toBe(false);
    expect(["models", "value", "where", "leaks"].map((name) => gated.panel(name).hidden)).toEqual([true, true, true, true]);
    expect(bandCell("spend")).toBe("–");
    // No rollup yet: the session line has no cost column, as with none.
    expect(tree().querySelector(".row-line")!.querySelector(".cost")).toBeNull();
    expect(foldNames()).toEqual(["Archived …"]);
  });

  it("asks each stalled route once over three more polls", async () => {
    for (let i = 0; i < 3; i += 1) await gated.page.poll();
    expect([gated.asked("archives"), gated.asked("usage"), gated.asked("yield"), gated.asked("lifetime")]).toEqual([1, 1, 1, 2]);
    expect(gated.asked("bills")).toBe(0);
  });
});

describe("each section paints by itself when its answer arrives", () => {
  it("the archives: the fold replaces the waiting line, and the usage still waits", async () => {
    await gated.open("archives");
    expect(foldNames()).toEqual(["Archived (2)"]);
    expect(gated.waiting()).toEqual(["Reading the usage…"]);
  });

  it("the usage: USAGE, MODELS, WHERE, LEAKS and the band's spend paint; VALUE and WHERE's summary wait for the yield; the bill waits", async () => {
    await gated.open("usage");
    expect(gated.panel("usage").querySelector(".usage-amount")?.textContent).toBe("$100.00");
    expect(["models", "where", "leaks", "value"].map((name) => gated.panel(name).hidden)).toEqual([false, false, false, false]);
    expect(bandCell("spend")).toBe("$100");
    expect(gated.panel("value").querySelectorAll(".yield-tile")).toEqual([]);
    expect(gated.panel("value").querySelector(".section-waiting")?.textContent).toBe("Reading the repositories…");
    expect(gated.panel("where").querySelector(".panel-summary")?.textContent).toBe("Reading the repositories…");
    expect([costCell().textContent, costCell().title]).toEqual(["…", BILL_WAITING_TITLE]);
    expect(gated.waiting()).toEqual(["Reading the repositories…", "Reading the repositories…"]);
    expect(gated.asked("bills")).toBe(1);
  });

  it("the bills: the cost cell prints the bill while the yield still waits", async () => {
    await gated.open("bills");
    expect([costCell().textContent, costCell().title]).toEqual(["$4.31", BILL_TITLE]);
    expect(gated.panel("value").querySelector(".section-waiting")?.textContent).toBe("Reading the repositories…");
  });

  it("the yield: VALUE prints its tiles and the lifetime line waits in the charts' place", async () => {
    await gated.open("yield");
    expect(gated.panel("value").querySelectorAll(".yield-tile").length).toBe(4);
    expect(gated.panel("where").querySelector(".section-waiting")).toBeNull();
    expect(gated.waiting()).toEqual(["Reading the lifetime totals…"]);
  });

  it("the lifetime: the two charts replace the waiting line, and nothing waits", async () => {
    await gated.open("lifetime");
    expect(gated.panel("value").querySelectorAll(".lifetime-chart-block").length).toBe(2);
    expect(gated.waiting()).toEqual([]);
  });
});

describe("the page asks for the archives only when they can have changed", () => {
  it("not in a poll", async () => {
    expect(gated.asked("archives")).toBe(1);
    for (let i = 0; i < 3; i += 1) await gated.page.poll();
    expect(gated.asked("archives")).toBe(1);
  });

  it("again when a session.archived event arrives, and repaints the fold", async () => {
    routes["/api/archives"] = { archives: [{ id: "arch-1" }, { id: "arch-2" }, { id: "arch-3" }] };
    routes["/api/events"] = { next: 1, epoch: "e1", events: [{ type: "session.archived", session: "s-gone" }] };
    await gated.release("events");
    expect(gated.asked("archives")).toBe(2);
    expect(foldNames()).toEqual(["Archived (3)"]);
  });

  it("not for another event", async () => {
    routes["/api/events"] = { next: 2, epoch: "e1", events: [{ type: "agent.status", session: "s-crew" }] };
    await gated.release("events");
    expect(gated.asked("archives")).toBe(2);
  });

  it("again when the feed says the page missed events", async () => {
    routes["/api/events"] = { next: 3, epoch: "e2", pruned: true, events: [] };
    await gated.release("events");
    expect(gated.asked("archives")).toBe(3);
  });

  it("again when the reader opens the fold, and not when the reader closes it", async () => {
    const fold = folds().querySelector("details") as FakeElement & { open: boolean };
    fold.querySelector("summary")!.click();
    await gated.page.settle();
    expect(gated.asked("archives")).toBe(4);
    fold.open = true;
    fold.querySelector("summary")!.click();
    await gated.page.settle();
    expect(gated.asked("archives")).toBe(4);
  });
});
