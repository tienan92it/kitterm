import { describe, expect, it } from "vitest";

import {
  goalGroups,
  goalOf,
  knowledgeUrl,
  proposedItems,
  recordPath,
  roundOf,
  roundPath,
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

  it("yields nothing without a round record or a decision", () => {
    expect(proposedItems([{ project: kitterm, summary: { project: "kitterm", lastDecision: "propose" } }])).toEqual([]);
    expect(proposedItems([{ project: kitterm, summary: { project: "kitterm", lastRound: 1 } }])).toEqual([]);
    expect(proposedItems([])).toEqual([]);
  });
});
