import { describe, expect, it } from "vitest";

import {
  AGENT_CONTROL_OFF,
  agentMark,
  hasLiveAgent,
  receiptStands,
  replyControl,
  replyName,
  type ModelRow,
  type ReplyFacts,
} from "./sessions-model";

/**
 * The reply control under a row (`workspace-ledger`, capability 2): absent
 * for a watch client and for a row without a live agent, ready for an
 * agent that waits, held with a reason for one that is working. The rows
 * are the corpus fixture's foreman and crew, as `GET /api/sessions` lists
 * them on 2026-09-16, with `foregroundProgram` as the daemon reads it.
 */
const FULL: ReplyFacts = { watchOnly: false, agentControlOff: false };
const WATCH: ReplyFacts = { watchOnly: true, agentControlOff: false };
const NO_FLAG: ReplyFacts = { watchOnly: false, agentControlOff: true };
const NOW = 1_758_000_000_000;

/** The foreman at its prompt after a turn: a `Stop` report and `claude` on the tty. */
const foreman: ModelRow = {
  id: "s-foreman",
  name: "foreman",
  cwd: "/Users/antran/Workspace/NgheNhanTrading",
  state: "idle",
  mergedState: "completed",
  labels: { crew: "foreman" },
  foregroundProgram: "claude",
  agent: { status: "completed", message: "Round 1 closed", at: NOW - 60_000 },
  orchestrated: true,
};

/** The crew mid-turn: a `PreToolUse` report and `claude` on the tty. */
const crew: ModelRow = {
  ...foreman,
  id: "s-crew",
  name: "symbol-onboarding round 1",
  state: "running",
  mergedState: "working",
  labels: { crew: "symbol-onboarding", goal: "symbol-onboarding", round: "1" },
  agent: { status: "working", message: "Adding the symbol registry route", at: NOW - 5_000 },
};

const waiting: ModelRow = {
  ...foreman,
  id: "s-waiting",
  mergedState: "needs-input",
  agent: { status: "needs-input", message: "Claude needs your input", at: NOW - 120_000 },
};

describe("who has a live agent", () => {
  it("is a hook report with a program on the tty", () => {
    expect(hasLiveAgent(foreman)).toBe(true);
    expect(hasLiveAgent(crew)).toBe(true);
  });

  it("is not a shell whose agent quit: the report stays, the program is gone", () => {
    const { foregroundProgram: _p, ...quit } = foreman;
    expect(hasLiveAgent({ ...quit, mergedState: "idle" })).toBe(false);
  });

  it("is not a sleep with no report", () => {
    const { agent: _a, ...shell } = foreman;
    expect(hasLiveAgent({ ...shell, foregroundProgram: "sleep", mergedState: "working" })).toBe(false);
  });

  it("is not a row whose shell ended", () => {
    expect(hasLiveAgent({ ...foreman, exited: true })).toBe(false);
  });
});

describe("the reply control", () => {
  it("is absent for a watch client, whatever the row", () => {
    expect(replyControl(foreman, WATCH)).toEqual({ kind: "absent" });
    expect(replyControl(waiting, WATCH)).toEqual({ kind: "absent" });
    expect(replyControl(crew, WATCH)).toEqual({ kind: "absent" });
  });

  it("is absent for a plain shell", () => {
    const shell: ModelRow = { id: "s-shell", cwd: "/tmp", state: "idle", mergedState: "idle" };
    expect(replyControl(shell, FULL)).toEqual({ kind: "absent" });
  });

  it("is ready for an agent that waits for input, and for one at its prompt after a turn", () => {
    expect(replyControl(waiting, FULL)).toEqual({ kind: "ready" });
    expect(replyControl(foreman, FULL)).toEqual({ kind: "ready" });
  });

  it("is held while the agent works, and says so", () => {
    const control = replyControl(crew, FULL);
    expect(control.kind).toBe("held");
    if (control.kind === "held") expect(control.reason).toBe("working, wait for the turn to end");
  });

  it("is held while the agent waits on an approval, which the strip answers", () => {
    const blocked: ModelRow = { ...crew, mergedState: "needs-approval" };
    expect(replyControl(blocked, FULL)).toEqual({ kind: "held", reason: "answer the approval first" });
  });

  it("is held on every row once the daemon refused for want of --agent-control", () => {
    expect(replyControl(waiting, NO_FLAG)).toEqual({ kind: "held", reason: AGENT_CONTROL_OFF });
    expect(replyControl(foreman, NO_FLAG)).toEqual({ kind: "held", reason: AGENT_CONTROL_OFF });
    expect(AGENT_CONTROL_OFF).toContain("--agent-control");
  });

  it("stays absent for a watch client even when the flag is known to be off", () => {
    expect(replyControl(waiting, { watchOnly: true, agentControlOff: true })).toEqual({ kind: "absent" });
  });

  it("names the field after the row, as its buttons are named", () => {
    expect(replyName(foreman)).toBe("Answer foreman");
    expect(replyName(crew)).toBe("Answer symbol-onboarding round 1");
  });
});

describe("the receipt after a send", () => {
  const receipt = { at: NOW, ...agentMark(waiting) };

  it("stands while the agent's report is the one the line was sent against", () => {
    expect(receiptStands(receipt, waiting)).toBe(true);
  });

  it("goes with the agent's next report: a tool call, or the end of the turn", () => {
    const working: ModelRow = { ...waiting, mergedState: "working", agent: { status: "working", at: NOW + 3_000 } };
    expect(receiptStands(receipt, working)).toBe(false);
    const done: ModelRow = { ...waiting, mergedState: "completed", agent: { status: "completed", at: NOW + 9_000 } };
    expect(receiptStands(receipt, done)).toBe(false);
  });

  it("goes when the agent quits and the row has no report", () => {
    const { agent: _a, ...quit } = waiting;
    expect(receiptStands(receipt, quit)).toBe(false);
  });

  it("is nothing for a row that never sent", () => {
    expect(receiptStands(undefined, waiting)).toBe(false);
  });
});
