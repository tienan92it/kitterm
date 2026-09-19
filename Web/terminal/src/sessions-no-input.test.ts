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
 *
 * Round 11 extends it: the page holds no action either. No `[new]`, no
 * `[Dismiss]`, no `[Allow]` or `[Deny]`, no `⋯` menu, no actions cell on
 * any line; `Open the pane` is the one way to act on an agent, and the
 * band's `need you` link goes to the first marked line.
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

/** A registered project with a goal whose proposals wait, so every line
 * that once carried an action is on the page: a project (`[new]`), a
 * goal that needs the human (`[Dismiss]`), a session (`⋯`), an approval
 * (`[Deny]` `[Allow]`). */
const kitterm = { id: "kitterm", name: "kitterm", root: "/Users/antran/Workspace/kitterm", registered: true, knowledge: "docs/goals" };
const proposing = {
  project: "kitterm", slug: "agent-dashboard", goal: "agent-dashboard", status: "active", round: 3, budget: 3, proposals: 2, lastRound: 3,
  lastRecord: "agent-dashboard/rounds/003.md", tasks: [{ slug: "the-approved-adjustments", state: "pending" }],
};

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [foreman, crew, waiting, blocked].map((s) => ({ ...s, cwd: kitterm.root, project: { id: kitterm.id, name: kitterm.name, root: kitterm.root, registered: true } })) },
  "/api/projects": { projects: [kitterm] },
  "/api/projects/kitterm/knowledge": { ok: true, project: "kitterm", goals: [proposing] },
  "/api/approvals": { approvals: [approval] },
  "/api/archives": { archives: [{ id: "arch-1", name: "old", cwd: kitterm.root }] },
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
    expect(text).toContain("[needs you]");
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

describe("the fleet view holds no action", () => {
  it("rendered every line that once carried one: the project, the goal that needs the human, the sessions, the approval", () => {
    expect(root.querySelectorAll(".line-project").map((l) => l.querySelector(".line-name")?.textContent)).toEqual(["kitterm"]);
    expect(root.querySelectorAll('[data-needs="proposed"]').map((l) => l.querySelector(".state")?.textContent)).toEqual(["[needs you]"]);
    expect(root.querySelectorAll(".row-line").length).toBeGreaterThanOrEqual(4);
    expect(root.querySelectorAll(".line-approval").map((l) => l.querySelector("[data-name]")?.textContent)).toEqual(["approve Bash"]);
  });

  it("has no actions cell on any line, and no [new], [Dismiss], [Allow], [Deny], ⋯ or menu anywhere", () => {
    expect(root.querySelectorAll(".actions")).toEqual([]);
    for (const cls of [".spawn-button", ".more", ".menu", ".line-actions", ".approval-allow", ".approval-deny", ".notice"]) {
      expect(root.querySelectorAll(cls), cls).toEqual([]);
    }
    const words = root.querySelectorAll("button").map((b) => b.textContent.trim());
    for (const word of ["new", "Dismiss", "Allow", "Deny", "⋯", "Rename", "Name", "Archive", "Kill"]) {
      expect(words, `a [${word}] button`).not.toContain(word);
    }
    expect(root.textContent).not.toContain("⋯");
  });

  it("keeps every button a toggle, a switch or a disclosure: nothing that drives the daemon", () => {
    // A radio chooses what the page shows, the switch subscribes this
    // device, and a triangle folds a row's children. Each moves the page
    // and nothing else.
    const kinds = root.querySelectorAll("button").map((b) => b.getAttribute("role") ?? (b.classList.contains("disclosure") ? "disclosure" : `other:${b.className}`));
    expect(kinds.filter((k) => !["radio", "switch", "disclosure"].includes(k))).toEqual([]);
    expect(kinds.filter((k) => k === "disclosure").length, "the project and the goal fold").toBe(2);
    expect(kinds).toContain("switch");
  });

  it("keeps the two ways to move: Open the pane on the approval, and the band's need-you link", () => {
    const approvalLine = root.querySelector(".line-approval")!;
    expect(approvalLine.querySelectorAll("a").map((a) => [a.textContent, a.href])).toEqual([["Open the pane", "/?session=s-blocked"]]);
    const needs = root.querySelectorAll(".band-cell").find((c) => c.classList.contains("needs"))!;
    expect([needs.tagName, needs.href]).toEqual(["A", "#needs-you"]);
    expect(root.querySelector('[id="needs-you"]')).not.toBeNull();
  });
});
