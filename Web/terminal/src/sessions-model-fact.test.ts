import { beforeAll, describe, expect, it } from "vitest";

import { FakeElement, installFakePage } from "./fake-page";
import { type ModelRow, rowModel } from "./sessions-model";

/**
 * Every agent says its model (`agent-dashboard`, capability 6;
 * `design-foundation.md`, "The model"). The daemon reads the id from the
 * transcript and derives the name; the page prints the name as a fact on
 * the session's line, before the time, and prints nothing for a session
 * that has none. The first block tests the pure fact; the second renders
 * the page through `sessions.ts` against a fleet holding an agent on a
 * model, an agent with no assistant turn yet, and a plain shell.
 */

const NOW = 1_758_000_000_000;

const row = (id: string, extra: Partial<ModelRow> = {}): ModelRow => ({ id, cwd: "/w/kitterm", ...extra });

describe("rowModel", () => {
  it("prints the name the daemon derived", () => {
    expect(rowModel(row("a", { agentModel: "claude-fable-5-1", agentModelName: "Fable 5.1" }))).toBe("Fable 5.1");
    expect(rowModel(row("b", { agentModel: "claude-opus-5[1m]", agentModelName: "Opus 5 · 1M" }))).toBe("Opus 5 · 1M");
  });

  it("prints nothing for a session with no model", () => {
    expect(rowModel(row("shell"))).toBeNull();
    expect(rowModel(row("no-turn-yet", { agentModel: undefined, agentModelName: undefined }))).toBeNull();
    expect(rowModel(row("blank", { agentModelName: "  " }))).toBeNull();
  });

  it("prints the id unchanged when no name came with it, which is the rule's last step", () => {
    expect(rowModel(row("c", { agentModel: "us.anthropic.claude-fable-5-1" }))).toBe("us.anthropic.claude-fable-5-1");
  });
});

/** A crew mid-turn on Fable, `claude` on the tty, transcript read. */
const onFable = {
  id: "s-fable",
  name: "agent-model round 5",
  cwd: "/Users/antran/Workspace/kitterm",
  state: "running",
  mergedState: "working",
  marks: 0,
  labels: { crew: "agent-dashboard", goal: "agent-dashboard", round: "5" },
  foregroundProgram: "claude",
  agent: { status: "working", message: "Reading the transcript tail", at: NOW - 5_000 },
  agentSessionId: "11111111-1111-4111-8111-111111111111",
  agentTranscript: "/Users/antran/.claude/projects/-w-kitterm/11111111.jsonl",
  agentModel: "claude-fable-5-1",
  agentModelName: "Fable 5.1",
  lastOutputAt: NOW - 5_000,
  orchestrated: true,
};

/** An agent that has started and not answered yet: a transcript, no model. */
const noTurnYet = {
  ...onFable,
  id: "s-fresh",
  name: "fresh crew",
  agent: { status: "working", message: "Starting", at: NOW - 1_000 },
  agentSessionId: "22222222-2222-4222-8222-222222222222",
  agentTranscript: "/Users/antran/.claude/projects/-w-kitterm/22222222.jsonl",
  agentModel: undefined,
  agentModelName: undefined,
};

/** A shell that never ran `claude`. */
const shell = {
  id: "s-shell",
  cwd: "/Users/antran/Workspace/kitterm",
  state: "idle",
  mergedState: "idle",
  marks: 1,
  lastCommand: "git status",
  lastExit: 0,
  lastOutputAt: NOW - 120_000,
};

const routes: Record<string, unknown> = {
  "/api/sessions": { ok: true, sessions: [onFable, noTurnYet, shell] },
  "/api/projects": { projects: [] },
  "/api/approvals": { approvals: [] },
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

const mainOf = (id: string): FakeElement => {
  const open = root.querySelectorAll("a").find((a) => a.href === `/?session=${encodeURIComponent(id)}`);
  if (!open) throw new Error(`no row for ${id}`);
  const main = open.querySelectorAll(".main")[0];
  if (!main) throw new Error(`no line for ${id}`);
  return main;
};

const cellsOf = (main: FakeElement): string[] =>
  main.children.filter((child): child is FakeElement => typeof child !== "string").map((child) => child.className);

describe("the model on a session's line", () => {
  it("is a fact before the time on the line of an agent that has answered", () => {
    const main = mainOf("s-fable");
    const cells = cellsOf(main);
    expect(cells).toContain("model");
    expect(cells.indexOf("model")).toBe(cells.indexOf("since") - 1);
    expect(cells.indexOf("model")).toBeGreaterThan(cells.indexOf("what"));
    const fact = main.querySelectorAll(".model")[0];
    expect(fact.textContent).toBe("Fable 5.1");
    expect(fact.title, "the id is on the title, so a reader can see what the name stands for").toBe("claude-fable-5-1");
  });

  it("is absent from an agent with no assistant turn yet, and from a plain shell", () => {
    expect(cellsOf(mainOf("s-fresh"))).not.toContain("model");
    expect(cellsOf(mainOf("s-shell"))).not.toContain("model");
    expect(root.querySelectorAll(".model")).toHaveLength(1);
  });

  it("prints the name, never the id, on the page", () => {
    expect(root.textContent).toContain("Fable 5.1");
    expect(root.textContent).not.toContain("claude-fable-5-1");
  });
});
