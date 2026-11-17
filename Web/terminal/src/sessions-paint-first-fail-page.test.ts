import { beforeAll, describe, expect, it } from "vitest";

import { type FakeElement, fakeThrow } from "./fake-page";
import { type GatedPage, installGatedPage, paintFirstRoutes } from "./paint-first-fixture";
import { BILL_TITLE } from "./sessions-model";

/**
 * A failed answer of one section leaves the other sections on the page
 * (`fleet-first-paint`, round 1; `goal.md` condition 2). Each of the five
 * slow reads fails once here, in turn, with a network error; the section
 * stops waiting, the fleet and the other sections stay, and a later poll
 * asks the failed route again. The steps run in order on one page.
 */

const good = paintFirstRoutes();
const routes = paintFirstRoutes();
let gated: GatedPage;

beforeAll(async () => {
  gated = installGatedPage(routes);
  await import("./sessions");
  await gated.page.settle();
});

const root = (): FakeElement => gated.page.root;
const tree = (): FakeElement => root().querySelector(".tree")!;
const foldNames = (): string[] => root().querySelector(".folds")!.querySelectorAll(".line-name").map((n) => n.textContent);
const costCell = (): FakeElement => tree().querySelector(".row-line")!.querySelector(".cost")!;
/** The fleet is on the page: the project, the session, the approval. */
const fleet = (): Array<string | undefined> => [
  tree().querySelector(".line-project")?.querySelector(".line-name")?.textContent,
  tree().querySelector(".row-line")?.querySelector(".line-name")?.textContent,
  tree().querySelector(".line-approval") === null ? undefined : "approval",
];
const FLEET = ["kitterm", "crew", "approval"];

/** Fail the held requests of a section, then let the route answer again. */
async function fail(gate: Parameters<GatedPage["release"]>[0], paths: string[]): Promise<void> {
  for (const path of paths) routes[path] = fakeThrow();
  await gated.release(gate);
  for (const path of paths) routes[path] = good[path];
}

describe("a failed answer costs only its section", () => {
  it("the archives: the waiting line goes, the fleet stays, the usage still waits", async () => {
    await fail("archives", ["/api/archives"]);
    expect(foldNames()).toEqual([]);
    expect(fleet()).toEqual(FLEET);
    expect(gated.waiting()).toEqual(["Reading the usage…"]);
  });

  it("the archives are asked again by the next poll, and the fold paints", async () => {
    await gated.page.poll();
    await gated.open("archives");
    expect(gated.asked("archives")).toBe(2);
    expect(foldNames()).toEqual(["Archived (2)"]);
  });

  it("the usage: the waiting line goes and the panel is off, as with no rollup; the fleet and the fold stay", async () => {
    await fail("usage", ["/api/usage/daily"]);
    expect(gated.panel("usage").hidden).toBe(true);
    expect(gated.waiting()).toEqual([]);
    expect(fleet()).toEqual(FLEET);
    expect(foldNames()).toEqual(["Archived (2)"]);
  });

  it("the usage is asked again by the next poll and paints; the yield of that ask fails and leaves the usage parts on the page", async () => {
    await gated.page.poll();
    expect(gated.asked("usage")).toBe(2);
    await gated.release("usage");
    expect(gated.panel("usage").querySelector(".usage-amount")?.textContent).toBe("$100.00");
    expect(gated.panel("value").querySelector(".section-waiting")?.textContent).toBe("Reading the repositories…");
    await fail("yield", ["/api/yield"]);
    expect(gated.panel("usage").querySelector(".usage-amount")?.textContent).toBe("$100.00");
    expect(["models", "where", "leaks", "value"].map((name) => gated.panel(name).hidden)).toEqual([false, false, false, false]);
    // VALUE stops waiting and prints its tiles with no repository counts,
    // as it does on a daemon with no yield route.
    expect(gated.panel("value").querySelectorAll(".yield-tile").length).toBe(4);
    expect(gated.panel("where").querySelector(".section-waiting")).toBeNull();
    expect(fleet()).toEqual(FLEET);
  });

  it("the bills: the cost cell prints the dash, the other sections stay, and the next poll asks again", async () => {
    expect(costCell().textContent).toBe("…");
    await fail("bills", ["/api/sessions/s-crew/cost"]);
    expect([costCell().textContent, costCell().title]).toEqual(["–", BILL_TITLE]);
    expect(gated.panel("usage").hidden).toBe(false);
    expect(fleet()).toEqual(FLEET);
    await gated.open("bills");
    await gated.page.poll();
    expect(costCell().textContent).toBe("$4.31");
  });

  it("the lifetime: the waiting line goes and no chart paints; the tiles and the fleet stay", async () => {
    expect(gated.waiting()).toEqual(["Reading the lifetime totals…"]);
    await fail("lifetime", ["/api/usage/daily", "/api/yield/daily"]);
    expect(gated.waiting()).toEqual([]);
    expect(gated.panel("value").querySelectorAll(".lifetime-chart-block")).toEqual([]);
    expect(gated.panel("value").querySelectorAll(".yield-tile").length).toBe(4);
    expect(gated.panel("usage").hidden).toBe(false);
    expect(fleet()).toEqual(FLEET);
  });
});
