import { describe, expect, it } from "vitest";

import {
  attention,
  cardRecord,
  dismissKey,
  isClosed,
  lineProposals,
  proposedItems,
  proposedLabel,
  withProposed,
  type KnowledgeSummary,
  type ModelRow,
} from "./sessions-model";

// The strip holds only what needs the human (`workspace-ledger` capability
// 6). A proposal on a closed goal, `done` or `stopped`, leaves the strip and
// stands on the goal's own line; a proposal on an `active` or `waiting` goal
// stays, because that goal's next round waits on it.

const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true };
const pipeline = { id: "market-data-pipeline", name: "market-data-pipeline", root: "/w/t/market-data-pipeline", registered: true };

function goal(project: string, slug: string, status: string | undefined, proposals: number, lastRound: number): KnowledgeSummary {
  return {
    project, slug, goal: slug.replace(/-/g, " "), status, proposals, lastRound,
    lastRecord: `${slug}/rounds/${String(lastRound).padStart(3, "0")}.md`, lastDecision: "done.",
  };
}

function row(id: string, extra: Partial<ModelRow> = {}): ModelRow {
  return { id, cwd: "/w/kitterm", ...extra };
}

// The live `docs/goals/` tree on 2026-09-16, as round 5 photographed it:
// eleven `kitterm` goals, ten `done`, nine of them with proposals left in
// `STATE.md`, and the active goal with three.
const kittermGoals: KnowledgeSummary[] = [
  goal("kitterm", "workspace-ledger", "active", 3, 5),
  goal("kitterm", "agent-push", "done", 3, 4),
  goal("kitterm", "contrast-tokens", "done", 0, 7),
  goal("kitterm", "cost-per-round", "done", 1, 4),
  goal("kitterm", "daemon-last-words", "done", 2, 4),
  goal("kitterm", "fleet-catch-up", "done", 1, 4),
  goal("kitterm", "foreman-harness", "done", 1, 5),
  goal("kitterm", "goal-folders", "done", 2, 5),
  goal("kitterm", "green-ci", "done", 2, 2),
  goal("kitterm", "projects-and-knowledge", "done", 9, 8),
  goal("kitterm", "steady-suite", "done", 1, 2),
];
// `market-data-pipeline`: one goal waiting on the human's direction, one done.
const pipelineGoals: KnowledgeSummary[] = [
  goal("market-data-pipeline", "symbol-onboarding", "waiting", 2, 6),
  goal("market-data-pipeline", "session-aware-sink-health", "done", 2, 2),
];
const entries = [
  ...kittermGoals.map((summary) => ({ project: kitterm, summary })),
  ...pipelineGoals.map((summary) => ({ project: pipeline, summary })),
];

describe("isClosed", () => {
  it("is true for done and stopped, the two statuses LOOP.md never schedules again", () => {
    expect(isClosed({ project: "p", status: "done" })).toBe(true);
    expect(isClosed({ project: "p", status: "stopped" })).toBe(true);
    expect(isClosed({ project: "p", status: " Done" })).toBe(true);
  });

  it("is false for active, waiting, and a summary with no status word", () => {
    expect(isClosed({ project: "p", status: "active" })).toBe(false);
    expect(isClosed({ project: "p", status: "waiting" })).toBe(false);
    expect(isClosed({ project: "p" })).toBe(false);
    expect(isClosed({ project: "p", status: "" })).toBe(false);
  });
});

describe("proposedItems on the live tree", () => {
  it("lists two items where the page showed twelve: the active goal and the waiting one", () => {
    const items = proposedItems(entries);
    expect(items.map((item) => [item.project.id, item.summary.slug, item.count])).toEqual([
      ["kitterm", "workspace-ledger", 3],
      ["market-data-pipeline", "symbol-onboarding", 2],
    ]);
  });

  it("drops a stopped goal's proposals like a done goal's", () => {
    const stopped = goal("kitterm", "dropped", "stopped", 2, 3);
    expect(proposedItems([{ project: kitterm, summary: stopped }])).toEqual([]);
  });

  it("keeps a proposing goal whose summary carries no status word", () => {
    const bare: KnowledgeSummary = { project: "kitterm", slug: "old-daemon", proposals: 1, lastRound: 2 };
    expect(proposedItems([{ project: kitterm, summary: bare }])).toHaveLength(1);
  });

  it("reads the count from STATE.md whole: the page has no per-proposal state", () => {
    const [ledger] = proposedItems(entries);
    expect(proposedLabel(ledger.count)).toBe("3 proposals");
  });
});

describe("withProposed after the closed goals go", () => {
  it("keeps the order: needs input, the live proposals, then what failed", () => {
    const asks = row("asks", { mergedState: "needs-input" });
    const broke = row("broke", { mergedState: "failed", lastExit: 1 });
    const items = withProposed(attention([broke, asks], []), proposedItems(entries));
    expect(items.map((item) => item.kind)).toEqual(["needs-input", "proposed", "proposed", "failed"]);
  });
});

describe("lineProposals", () => {
  const proposed = proposedItems(entries);

  it("gives a closed goal's count and its STATE.md to the goal's own line", () => {
    const [, , , , , , , , , knowledge] = kittermGoals;
    expect(lineProposals("kitterm", knowledge, proposed)).toEqual({ count: 9, path: "projects-and-knowledge/STATE.md" });
    const [, sink] = pipelineGoals;
    expect(lineProposals("market-data-pipeline", sink, proposed)).toEqual({ count: 2, path: "session-aware-sink-health/STATE.md" });
    const stopped = goal("kitterm", "dropped", "stopped", 1, 3);
    expect(lineProposals("kitterm", stopped, proposedItems([{ project: kitterm, summary: stopped }]))).toEqual({
      count: 1, path: "dropped/STATE.md",
    });
  });

  it("gives nothing to a line whose proposals the strip carries, so a proposal appears once", () => {
    const [ledger] = kittermGoals;
    expect(lineProposals("kitterm", ledger, proposed)).toBeNull();
    const [onboarding] = pipelineGoals;
    expect(lineProposals("market-data-pipeline", onboarding, proposed)).toBeNull();
  });

  it("gives nothing to a goal whose STATE.md lists no proposal", () => {
    const [, , contrast] = kittermGoals;
    expect(lineProposals("kitterm", contrast, proposed)).toBeNull();
    expect(lineProposals("kitterm", { project: "kitterm", slug: "x", status: "done" }, proposed)).toBeNull();
  });

  it("moves the count to the line once the human dismisses the strip item", () => {
    const [ledger] = kittermGoals;
    const dismissed = new Set([dismissKey("kitterm", "workspace-ledger", 5)]);
    const after = proposedItems(entries, dismissed);
    expect(after.map((item) => item.summary.slug)).toEqual(["symbol-onboarding"]);
    expect(lineProposals("kitterm", ledger, after)).toEqual({ count: 3, path: "workspace-ledger/STATE.md" });
  });

  it("tells the same slug apart by project, and links the root STATE.md for a summary with no slug", () => {
    const same = goal("kitterm", "symbol-onboarding", "active", 1, 1);
    expect(lineProposals("kitterm", same, proposed)).toEqual({ count: 1, path: "symbol-onboarding/STATE.md" });
    expect(lineProposals("kitterm", { project: "kitterm", proposals: 2 }, [])).toEqual({ count: 2, path: "STATE.md" });
  });
});

describe("the done fold after the change", () => {
  it("links a done goal's record on its card, because the strip no longer carries it", () => {
    const proposed = proposedItems(entries);
    const [, , , , , , , , , knowledge] = kittermGoals;
    expect(cardRecord("kitterm", knowledge, proposed)).toBe("projects-and-knowledge/rounds/008.md");
  });
});
