import { beforeAll, describe, expect, it } from "vitest";

import { FakeElement, installFakePage } from "./fake-page";

/**
 * The page presents and monitors; it accepts no typed work
 * (`agent-dashboard`, capability 1; `design-foundation.md`, principle 1).
 * The page is rendered by `sessions.ts` itself against a fleet that holds
 * every row the reply control used to attach to: a working agent, an agent
 * waiting for input, and a pending approval. The rendered tree then holds
 * no `input`, no `textarea`, no `contenteditable` and no `[send]`.
 *
 * `sessions.ts` paints through the DOM on import, and the test runner has
 * no DOM package, so the test lends it one (`fake-page.ts`): a tree of
 * plain elements that records the tag, the attributes and the children the
 * page gives it, and a `fetch` that answers the daemon's routes from the
 * fixture.
 */

const NOW = 1_758_000_000_000;

/** The foreman at its prompt after a turn: a `Stop` report and `claude` on the tty. */
const foreman = {
  id: "s-foreman",
  name: "foreman",
  cwd: "/Users/antran/Workspace/NgheNhanTrading",
  state: "idle",
  mergedState: "completed",
  marks: 0,
  labels: { crew: "foreman" },
  foregroundProgram: "claude",
  agent: { status: "completed", message: "Round 1 closed", at: NOW - 60_000 },
  orchestrated: true,
};

/** The crew mid-turn: a `PreToolUse` report and `claude` on the tty. */
const crew = {
  ...foreman,
  id: "s-crew",
  name: "symbol-onboarding round 1",
  state: "running",
  mergedState: "working",
  labels: { crew: "symbol-onboarding", goal: "symbol-onboarding", round: "1" },
  agent: { status: "working", message: "Adding the symbol registry route", at: NOW - 5_000 },
};

/** An agent that asked a question and waits at its prompt. */
const waiting = {
  ...foreman,
  id: "s-waiting",
  name: "release notes",
  mergedState: "needs-input",
  agent: { status: "needs-input", message: "Claude needs your input", at: NOW - 120_000 },
};

/** An agent stopped on a tool call until a person answers. */
const blocked = {
  ...foreman,
  id: "s-blocked",
  name: "bench round 2",
  mergedState: "needs-approval",
  pendingApproval: true,
  agent: { status: "working", message: "Running the bench", at: NOW - 10_000 },
};

const approval = {
  id: "a-1",
  tool: "Bash",
  input: JSON.stringify({ command: "swift run KittermBench interactive-echo" }),
  session: "s-blocked",
  waitingMs: 45_000,
};

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [foreman, crew, waiting, blocked] },
  "/api/projects": { projects: [] },
  "/api/approvals": { approvals: [approval] },
  "/api/archives": { archives: [] },
  "/api/profiles": { profiles: [] },
};

let root: FakeElement;

beforeAll(async () => {
  const page = installFakePage(routes);
  root = page.root;
  await import("./sessions");
  await page.settle();
});

describe("the fleet view takes no typed work", () => {
  it("rendered the fleet it was given: a working agent, one waiting for input, and an approval", () => {
    const text = root.textContent;
    expect(root.querySelectorAll(".row").length + root.querySelectorAll(".strip-item").length).toBeGreaterThanOrEqual(4);
    expect(text).toContain("needs input");
    expect(text).toContain("approve Bash");
    expect(text).toContain("symbol-onboarding round 1");
    expect(root.querySelectorAll("a").map((a) => a.textContent)).toContain("Open the pane");
  });

  it("holds no input, no textarea and no contenteditable", () => {
    const typed = [...root.descendants()]
      .filter(
        (el) =>
          el.tagName === "INPUT" ||
          el.tagName === "TEXTAREA" ||
          el.hasAttribute("contenteditable") ||
          (el as { contentEditable?: string }).contentEditable !== undefined,
      )
      .map((el) => `${el.tagName.toLowerCase()}.${el.className}`);
    expect(typed, "a place to type on a page that only monitors").toEqual([]);
  });

  it("offers no [send], and no reply line under any row or strip item", () => {
    const send = root.querySelectorAll("button").filter((b) => b.textContent.trim() === "send");
    expect(send.map((b) => b.getAttribute("aria-label"))).toEqual([]);
    expect(root.querySelectorAll(".reply")).toEqual([]);
    expect(root.querySelectorAll("form")).toEqual([]);
  });
});
