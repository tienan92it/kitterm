import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, type FakePage, fakeStatus, installFakePage } from "./fake-page";
import { NOW, paintFirstRoutes } from "./paint-first-fixture";

/**
 * The paint before the grade (`fleet-first-paint`, round 3, the foreman's
 * correction). The first paint does not wait for `/api/profiles`, which is
 * how the page learns that its token is watch-only. Until that answer the
 * page paints no control a watch client does not get: the push switch,
 * and the link to open a shell on an empty fleet. The rows, the projects,
 * the approvals and the quota paint after the four answers. A 200 brings
 * the controls; a 403 never does.
 */

type Loaded = { page: FakePage; answerProfiles: () => Promise<void> };

/** Load the page with `/api/profiles` held until `answerProfiles`. Only
 * the profiles read and the four fleet routes answer; nothing else does. */
async function load(routes: Record<string, unknown>): Promise<Loaded> {
  vi.resetModules();
  vi.spyOn(Date, "now").mockReturnValue(NOW);
  const page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  const answer = globalThis.fetch;
  const fleet = ["/api/sessions", "/api/projects", "/api/approvals", "/api/usage/limits"];
  let release: () => void = () => {};
  vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
    const path = String(input).replace(/\?.*$/, "");
    if (path === "/api/profiles") await new Promise<void>((resolve) => { release = resolve; });
    else if (!fleet.includes(path)) await new Promise<never>(() => {});
    return answer(input, init);
  });
  await import("./sessions");
  await page.settle();
  return {
    page,
    answerProfiles: async () => {
      release();
      await page.settle();
    },
  };
}

const tree = (page: FakePage): FakeElement => page.root.querySelector(".tree")!;
const pushSwitches = (page: FakePage): number => page.root.querySelectorAll(".push-switch").length;
const shellLinks = (page: FakePage): number =>
  page.root.querySelectorAll("a").filter((a) => a.dataset.focus === "open-shell").length;
const emptyText = (page: FakePage): string | undefined => page.root.querySelector(".empty")?.textContent;

describe("the profiles stall, then answer 200", () => {
  let loaded: Loaded;
  beforeAll(async () => {
    loaded = await load(paintFirstRoutes());
  });

  it("paints the rows, the project, the approval and the quota after the four answers", () => {
    const { page } = loaded;
    expect(tree(page).querySelector(".line-project")?.querySelector(".line-name")?.textContent).toBe("kitterm");
    expect(tree(page).querySelector(".row-line")?.querySelector(".line-name")?.textContent).toBe("crew");
    expect(tree(page).querySelector(".line-approval")?.textContent).toContain("approve Bash");
    expect(page.root.querySelectorAll(".panel").find((p) => p.classList.contains("quota"))?.hidden).toBe(false);
  });

  it("paints no push switch while the grade is unknown, over more polls too", async () => {
    expect(pushSwitches(loaded.page)).toBe(0);
    for (let i = 0; i < 3; i += 1) await loaded.page.poll();
    expect(pushSwitches(loaded.page)).toBe(0);
  });

  it("paints the push switch by itself when the profiles answer 200", async () => {
    await loaded.answerProfiles();
    expect(pushSwitches(loaded.page)).toBe(1);
    expect(tree(loaded.page).querySelector(".row-line")?.querySelector(".line-name")?.textContent).toBe("crew");
  });
});

describe("the profiles stall, then answer 403", () => {
  let loaded: Loaded;
  beforeAll(async () => {
    loaded = await load({ ...paintFirstRoutes(), "/api/profiles": fakeStatus(403) });
  });

  it("paints the rows and no push switch before the answer", () => {
    expect(tree(loaded.page).querySelector(".row-line")?.querySelector(".line-name")?.textContent).toBe("crew");
    expect(pushSwitches(loaded.page)).toBe(0);
  });

  it("never paints the push switch after the 403", async () => {
    await loaded.answerProfiles();
    for (let i = 0; i < 3; i += 1) await loaded.page.poll();
    expect(pushSwitches(loaded.page)).toBe(0);
    expect(tree(loaded.page).querySelector(".row-line")?.querySelector(".line-name")?.textContent).toBe("crew");
  });
});

describe("an empty fleet", () => {
  let loaded: Loaded;
  beforeAll(async () => {
    loaded = await load({ ...paintFirstRoutes(), "/api/sessions": { ok: true, sessions: [] }, "/api/projects": { projects: [] }, "/api/approvals": { approvals: [] } });
  });

  it("offers no link to open a shell while the grade is unknown", () => {
    expect(emptyText(loaded.page)).toBe("No live sessions to watch.");
    expect(shellLinks(loaded.page)).toBe(0);
  });

  it("offers the link when the profiles answer 200", async () => {
    await loaded.answerProfiles();
    expect(shellLinks(loaded.page)).toBe(1);
  });
});
