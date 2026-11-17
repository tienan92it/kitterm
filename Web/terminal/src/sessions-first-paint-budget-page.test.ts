import { beforeAll, describe, expect, it, vi } from "vitest";

import { type FakeElement, installFakePage, type FakePage } from "./fake-page";
import { NOW, paintFirstRoutes } from "./paint-first-fixture";

/**
 * The first-paint budget (`fleet-first-paint`, round 3; `goal.md`
 * condition 5). The daemon here holds 600 archives and a yield that never
 * answers. It answers four routes and no other: `/api/sessions`,
 * `/api/projects`, `/api/approvals` and `/api/usage/limits`. The page must
 * paint the sessions, the projects and the approvals from those four. The
 * archives then answer, and the fold paints while the yield still waits.
 */

const FLEET = ["/api/sessions", "/api/projects", "/api/approvals", "/api/usage/limits"];
const ARCHIVES = 600;

const routes = paintFirstRoutes();
let page: FakePage;
/** The paths the daemon answered, in order. */
const answered: string[] = [];
/** How many times the page asked for the archives, answered or not. */
let archiveAsks = 0;
let releaseArchives: () => void = () => {};

const tree = (): FakeElement => page.root.querySelector(".tree")!;
const foldNames = (): string[] =>
  page.root.querySelector(".folds")!.querySelectorAll(".line-name").map((n) => n.textContent);

beforeAll(async () => {
  // The size of the list of 2026-11-17: each row with a name, a cwd, labels,
  // a transcript path and its project.
  routes["/api/archives"] = {
    archives: Array.from({ length: ARCHIVES }, (_, i) => ({
      id: `arch-${i}`, name: `crew-${i}`, cwd: `/w/kitterm/.claude/worktrees/goal-${i}`, shell: "/bin/zsh",
      archivedAt: NOW - i * 60_000, exitCode: 0, labels: { goal: `goal-${i}`, round: String(i % 9), crew: "worker" },
      agentSessionId: `agent-${i}`, agentTranscript: `/home/dev/.claude/projects/-w-kitterm/agent-${i}.jsonl`,
      project: { id: "kitterm", name: "kitterm", root: "/w/kitterm" },
    })),
  };
  vi.spyOn(Date, "now").mockReturnValue(NOW);
  page = installFakePage(routes);
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener(): void {} }));
  const answer = globalThis.fetch;
  vi.stubGlobal("fetch", async (input: string | URL, init?: RequestInit) => {
    const path = String(input).replace(/\?.*$/, "");
    if (path === "/api/archives") {
      archiveAsks += 1;
      await new Promise<void>((resolve) => { releaseArchives = resolve; });
    }
    // Every other route but the four never answers: the yield, the usage,
    // the bills, the profiles, the knowledge and the event feed.
    else if (!FLEET.includes(path)) await new Promise<never>(() => {});
    answered.push(path);
    return answer(input, init);
  });
  await import("./sessions");
  await page.settle();
});

describe("600 archives and a yield that never answers", () => {
  it("paints the sessions, the projects and the approvals after four answers and no other", () => {
    expect([...answered].sort()).toEqual([...FLEET].sort());
    expect(tree().querySelector(".line-project")?.querySelector(".line-name")?.textContent).toBe("kitterm");
    expect(tree().querySelector(".row-line")?.querySelector(".line-name")?.textContent).toBe("crew");
    expect(tree().querySelector(".line-approval")?.textContent).toContain("approve Bash");
  });

  it("asked for the archives once and shows that they wait", () => {
    expect(archiveAsks).toBe(1);
    expect(foldNames()).toEqual(["Archived …"]);
  });

  it("keeps the fleet over three more polls, with one more answer for each of the four", async () => {
    for (let i = 0; i < 3; i += 1) await page.poll();
    expect(new Set(answered)).toEqual(new Set(FLEET));
    expect(archiveAsks).toBe(1);
    expect(tree().querySelector(".row-line")?.querySelector(".line-name")?.textContent).toBe("crew");
  });

  it("paints the fold when the archives answer, while the yield still waits", async () => {
    releaseArchives();
    await page.settle();
    expect(foldNames()).toEqual([`Archived (${ARCHIVES})`]);
    expect(answered.filter((path) => !FLEET.includes(path))).toEqual(["/api/archives"]);
    expect(tree().querySelector(".row-line")?.querySelector(".line-name")?.textContent).toBe("crew");
  });
});
