import { describe, expect, it } from "vitest";

import {
  attention,
  dismissKey,
  dismissName,
  focusKey,
  goalGroups,
  goalOf,
  knowledgeUrl,
  proposedItems,
  recordPath,
  roundOf,
  roundPath,
  withProposed,
  type KnowledgeSummary,
  type ModelRow,
} from "./sessions-model";

const kitterm = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true };
const other = { id: "other", name: "other", root: "/w/other", registered: true };

function row(id: string, labels?: Record<string, string>, extra: Partial<ModelRow> = {}): ModelRow {
  return { id, cwd: "/w/kitterm", labels, ...extra };
}

const summary: KnowledgeSummary = {
  project: "kitterm",
  slug: "projects-and-knowledge",
  goal: "projects on the fleet view",
  round: 2,
  budget: 3,
  lastRound: 2,
  lastDecision: "done.",
};

describe("goalOf and roundOf", () => {
  it("read the goal and round labels", () => {
    expect(goalOf(row("a", { goal: "x" }))).toBe("x");
    expect(goalOf(row("a", { goal: "" }))).toBeNull();
    expect(goalOf(row("a"))).toBeNull();
    expect(roundOf(row("a", { round: "2" }))).toBe(2);
    expect(roundOf(row("a", { round: "12" }))).toBe(12);
  });

  it("round is null when the label is absent or not a whole number", () => {
    expect(roundOf(row("a"))).toBeNull();
    expect(roundOf(row("a", { round: "two" }))).toBeNull();
    expect(roundOf(row("a", { round: "2.5" }))).toBeNull();
    expect(roundOf(row("a", { round: "-1" }))).toBeNull();
  });
});

describe("goalGroups", () => {
  const crew = row("crew", { crew: "projects-and-knowledge", goal: "projects-and-knowledge", round: "2" });
  const foreign = row("foreign", { goal: "another-goal", round: "1" });
  const human = row("human");

  it("puts the rows labelled with the package's slug under it and keeps the rest", () => {
    const { goals, rest } = goalGroups([human, foreign, crew], summary);
    expect(goals).toEqual([{ slug: "projects-and-knowledge", rows: [crew] }]);
    expect(rest.map((r) => r.id)).toEqual(["human", "foreign"]);
  });

  it("has no goal group when no row carries the slug", () => {
    const { goals, rest } = goalGroups([human, foreign], summary);
    expect(goals).toEqual([]);
    expect(rest.map((r) => r.id)).toEqual(["human", "foreign"]);
  });

  it("keeps every row in rest without a summary or a slug", () => {
    expect(goalGroups([crew, human], null).goals).toEqual([]);
    expect(goalGroups([crew, human], undefined).rest.map((r) => r.id)).toEqual(["crew", "human"]);
    expect(goalGroups([crew, human], { project: "kitterm" }).goals).toEqual([]);
  });

  it("sorts inside the goal group like a card: attention first", () => {
    const idle = row("idle", { goal: "projects-and-knowledge" }, { mergedState: "idle" });
    const asks = row("asks", { goal: "projects-and-knowledge" }, { mergedState: "needs-input" });
    const { goals } = goalGroups([idle, asks], summary);
    expect(goals[0].rows.map((r) => r.id)).toEqual(["asks", "idle"]);
  });
});

describe("roundPath and knowledgeUrl", () => {
  it("names the round record with three digits", () => {
    expect(roundPath(2)).toBe("rounds/002.md");
    expect(roundPath(1000)).toBe("rounds/1000.md");
  });

  it("builds the knowledge route with each segment encoded", () => {
    expect(knowledgeUrl("kitterm", "rounds/002.md")).toBe("/api/projects/kitterm/knowledge/rounds/002.md");
    expect(knowledgeUrl("a b", "x y/z.md")).toBe("/api/projects/a%20b/knowledge/x%20y/z.md");
  });
});

describe("focusKey", () => {
  it("names a link by its kind and what it opens, so a repaint restores focus to it", () => {
    expect(focusKey("knowledge", "kitterm", "rounds/005.md")).toBe("knowledge:kitterm:rounds/005.md");
    expect(focusKey("open", "abc-123")).toBe("open:abc-123");
    expect(focusKey("knowledge", "a", "x")).not.toBe(focusKey("knowledge", "b", "x"));
  });
});

describe("recordPath", () => {
  it("is the name the daemon read, else the three-digit name, else null", () => {
    expect(recordPath({ project: "p", lastRound: 7, lastRecord: "rounds/7.md" })).toBe("rounds/7.md");
    expect(recordPath({ project: "p", lastRound: 7 })).toBe("rounds/007.md");
    expect(recordPath({ project: "p" })).toBeNull();
  });
});

describe("proposedItems", () => {
  it("lists a project whose latest round record proposes", () => {
    const proposing: KnowledgeSummary = { ...summary, lastRound: 3, lastDecision: "propose (`plan.md`: x)" };
    const items = proposedItems([
      { project: kitterm, summary },
      { project: other, summary: proposing },
    ]);
    expect(items).toEqual([{ kind: "proposed", project: other, summary: proposing, round: 3, path: "rounds/003.md" }]);
  });

  it("links the record by the name the daemon read, rounds/7.md included", () => {
    const seven: KnowledgeSummary = { ...summary, lastRound: 7, lastRecord: "rounds/7.md", lastDecision: "propose (x)" };
    expect(proposedItems([{ project: other, summary: seven }])[0].path).toBe("rounds/7.md");
  });

  it("matches the decision word alone, in any case, after blanks", () => {
    const loud: KnowledgeSummary = { ...summary, lastDecision: "  Propose: something" };
    expect(proposedItems([{ project: kitterm, summary: loud }])).toHaveLength(1);
    const done: KnowledgeSummary = { ...summary, lastDecision: "done. propose (x) later" };
    expect(proposedItems([{ project: kitterm, summary: done }])).toEqual([]);
  });

  it("leaves out a dismissed round and keeps the project's next one", () => {
    const proposing: KnowledgeSummary = { ...summary, lastRound: 3, lastDecision: "propose (x)" };
    const dismissed = new Set([dismissKey("kitterm", 3)]);
    expect(dismissKey("kitterm", 3)).toBe("kitterm:3");
    expect(proposedItems([{ project: kitterm, summary: proposing }], dismissed)).toEqual([]);
    const next: KnowledgeSummary = { ...proposing, lastRound: 4 };
    expect(proposedItems([{ project: kitterm, summary: next }], dismissed)).toHaveLength(1);
    expect(proposedItems([{ project: other, summary: proposing }], dismissed)).toHaveLength(1);
  });

  it("yields nothing without a round record or a decision", () => {
    expect(proposedItems([{ project: kitterm, summary: { project: "kitterm", lastDecision: "propose" } }])).toEqual([]);
    expect(proposedItems([{ project: kitterm, summary: { project: "kitterm", lastRound: 1 } }])).toEqual([]);
    expect(proposedItems([])).toEqual([]);
  });
});

describe("withProposed", () => {
  const proposing: KnowledgeSummary = { ...summary, lastRound: 3, lastDecision: "propose (x)" };
  const proposed = proposedItems([{ project: kitterm, summary: proposing }]);

  it("puts a proposal after the approvals and needs-input rows and before the failed ones", () => {
    const asks = row("asks", undefined, { mergedState: "needs-input" });
    const broke = row("broke", undefined, { mergedState: "failed", lastExit: 1 });
    const items = withProposed(attention([broke, asks], []), proposed);
    expect(items.map((item) => item.kind)).toEqual(["needs-input", "proposed", "failed"]);
  });

  it("appends the proposals when nothing failed", () => {
    expect(withProposed(attention([], []), proposed).map((item) => item.kind)).toEqual(["proposed"]);
    expect(withProposed(attention([], []), [])).toEqual([]);
  });
});

describe("dismissName", () => {
  it("names the round and the project", () => {
    expect(dismissName(5, "kitterm")).toBe("Dismiss the proposal of round 5 of kitterm");
  });
});
