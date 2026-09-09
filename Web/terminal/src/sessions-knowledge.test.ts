import { describe, expect, it } from "vitest";

import {
  attention,
  dismissKey,
  dismissName,
  focusKey,
  goalBlocks,
  goalGroups,
  goalOf,
  goalTitle,
  hasKnowledge,
  knowledgeUrl,
  proposalsName,
  proposedItems,
  recordLabel,
  recordName,
  recordPath,
  roundOf,
  roundPath,
  statePath,
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

  it("puts the rows labelled with a goal's slug under it, a stray label in unmatched, and keeps the rest", () => {
    const { goals, unmatched, rest } = goalGroups([human, foreign, crew], [summary]);
    expect(goals).toEqual([{ slug: "projects-and-knowledge", rows: [crew] }]);
    expect(unmatched).toEqual([{ slug: "another-goal", rows: [foreign] }]);
    expect(rest.map((r) => r.id)).toEqual(["human"]);
  });

  it("has no goal group when no row carries the slug", () => {
    const { goals, unmatched, rest } = goalGroups([human, foreign], [summary]);
    expect(goals).toEqual([]);
    expect(unmatched.map((g) => g.slug)).toEqual(["another-goal"]);
    expect(rest.map((r) => r.id)).toEqual(["human"]);
  });

  it("puts every labelled row in unmatched without a summary or a slug", () => {
    expect(goalGroups([crew, human], null).goals).toEqual([]);
    expect(goalGroups([crew, human], undefined).unmatched).toEqual([{ slug: "projects-and-knowledge", rows: [crew] }]);
    expect(goalGroups([crew, human], undefined).rest.map((r) => r.id)).toEqual(["human"]);
    expect(goalGroups([crew, human], [{ project: "kitterm" }]).goals).toEqual([]);
    expect(goalGroups([crew, human], []).unmatched.map((g) => g.slug)).toEqual(["projects-and-knowledge"]);
    expect(goalGroups([crew, human], []).rest.map((r) => r.id)).toEqual(["human"]);
  });

  it("has nothing at all for an empty card", () => {
    expect(goalGroups([], [summary])).toEqual({ goals: [], unmatched: [], rest: [] });
    expect(goalGroups([], [])).toEqual({ goals: [], unmatched: [], rest: [] });
  });

  it("lists the unmatched labels in name order, one group each, sorted like a card", () => {
    const zed = row("zed", { goal: "zed-goal" }, { mergedState: "idle" });
    const alpha = row("alpha", { goal: "alpha-goal" });
    const alphaAsks = row("alpha-asks", { goal: "alpha-goal" }, { mergedState: "needs-input" });
    const { goals, unmatched, rest } = goalGroups([zed, alpha, alphaAsks, crew, human], [summary]);
    expect(goals.map((g) => g.slug)).toEqual(["projects-and-knowledge"]);
    expect(unmatched.map((g) => [g.slug, g.rows.map((r) => r.id)])).toEqual([
      ["alpha-goal", ["alpha-asks", "alpha"]],
      ["zed-goal", ["zed"]],
    ]);
    expect(rest.map((r) => r.id)).toEqual(["human"]);
  });

  it("groups under every goal of the answer, in the daemon's order, and keeps the rest", () => {
    const done: KnowledgeSummary = { project: "kitterm", slug: "another-goal", status: "done", lastRound: 8 };
    const { goals, rest } = goalGroups([human, foreign, crew], [summary, done]);
    expect(goals).toEqual([
      { slug: "projects-and-knowledge", rows: [crew] },
      { slug: "another-goal", rows: [foreign] },
    ]);
    expect(rest.map((r) => r.id)).toEqual(["human"]);
    expect(goalGroups([human, crew], [done, summary]).goals.map((g) => g.slug)).toEqual(["projects-and-knowledge"]);
    expect(goalGroups([human, foreign, crew], [summary, done]).unmatched).toEqual([]);
  });

  it("sorts inside the goal group like a card: attention first", () => {
    const idle = row("idle", { goal: "projects-and-knowledge" }, { mergedState: "idle" });
    const asks = row("asks", { goal: "projects-and-knowledge" }, { mergedState: "needs-input" });
    const { goals } = goalGroups([idle, asks], [summary]);
    expect(goals[0].rows.map((r) => r.id)).toEqual(["asks", "idle"]);
  });
});

describe("goalBlocks", () => {
  const active: KnowledgeSummary = { project: "kitterm", slug: "goal-folders", goal: "one folder per goal", status: "active", round: 3, budget: 3 };
  const waiting: KnowledgeSummary = { project: "kitterm", slug: "later", status: "waiting", round: 3, budget: 3 };
  const stopped: KnowledgeSummary = { project: "kitterm", slug: "dropped", status: "stopped", lastRound: 2 };
  const done: KnowledgeSummary = { project: "kitterm", slug: "projects-and-knowledge", status: "done", lastRound: 8 };

  it("expands an active or waiting goal and folds a stopped or done one, in the order given", () => {
    expect(goalBlocks([active, waiting, stopped, done])).toEqual([
      { summary: active, expanded: true },
      { summary: waiting, expanded: true },
      { summary: stopped, expanded: false },
      { summary: done, expanded: false },
    ]);
  });

  it("reads the status word in any case, after blanks", () => {
    expect(goalBlocks([{ ...done, status: " Done " }])[0].expanded).toBe(false);
    expect(goalBlocks([{ ...stopped, status: "STOPPED" }])[0].expanded).toBe(false);
  });

  it("expands a goal with no status or one the loop does not name", () => {
    expect(goalBlocks([{ project: "kitterm", slug: "fresh" }])[0].expanded).toBe(true);
    expect(goalBlocks([{ project: "kitterm", slug: "odd", status: "paused" }])[0].expanded).toBe(true);
  });

  it("shows nothing for an empty package, no answer, or a summary with no field", () => {
    expect(goalBlocks([])).toEqual([]);
    expect(goalBlocks(null)).toEqual([]);
    expect(goalBlocks(undefined)).toEqual([]);
    expect(goalBlocks([{ project: "kitterm" }, active])).toEqual([{ summary: active, expanded: true }]);
  });
});

describe("goalTitle and statePath", () => {
  it("name the goal by its title, else its slug, else the word", () => {
    expect(goalTitle(summary)).toBe("projects on the fleet view");
    expect(goalTitle({ project: "kitterm", slug: "goal-folders" })).toBe("goal-folders");
    expect(goalTitle({ project: "kitterm" })).toBe("goal");
  });

  it("point the proposals chip at the goal's own STATE.md", () => {
    expect(statePath(summary)).toBe("projects-and-knowledge/STATE.md");
    expect(statePath({ project: "kitterm" })).toBe("STATE.md");
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

describe("hasKnowledge", () => {
  it("is false for a summary that carries only the project", () => {
    expect(hasKnowledge({ project: "kitterm" })).toBe(false);
    expect(hasKnowledge({ project: "kitterm", slug: undefined })).toBe(false);
    expect(hasKnowledge({ ok: true, project: "kitterm" } as KnowledgeSummary)).toBe(false);
    expect(hasKnowledge({ project: "kitterm", proposals: 0 })).toBe(true);
    expect(hasKnowledge(summary)).toBe(true);
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

  it("leaves out a dismissed round and keeps the goal's next one", () => {
    const proposing: KnowledgeSummary = { ...summary, lastRound: 3, lastDecision: "propose (x)" };
    const dismissed = new Set([dismissKey("kitterm", "projects-and-knowledge", 3)]);
    expect(dismissKey("kitterm", "projects-and-knowledge", 3)).toBe("kitterm:projects-and-knowledge:3");
    expect(proposedItems([{ project: kitterm, summary: proposing }], dismissed)).toEqual([]);
    const next: KnowledgeSummary = { ...proposing, lastRound: 4 };
    expect(proposedItems([{ project: kitterm, summary: next }], dismissed)).toHaveLength(1);
    expect(proposedItems([{ project: other, summary: proposing }], dismissed)).toHaveLength(1);
  });

  it("lists every proposing goal of one project and dismisses them one by one", () => {
    const first: KnowledgeSummary = { ...summary, lastRound: 3, lastDecision: "propose (x)" };
    const second: KnowledgeSummary = {
      project: "kitterm", slug: "goal-folders", status: "waiting", lastRound: 3,
      lastRecord: "goal-folders/rounds/003.md", lastDecision: "propose (`LOOP.md`: y)",
    };
    const quiet: KnowledgeSummary = { project: "kitterm", slug: "done-goal", status: "done", lastRound: 8, lastDecision: "done." };
    const entries = [first, second, quiet].map((goal) => ({ project: kitterm, summary: goal }));
    expect(proposedItems(entries).map((item) => [item.summary.slug, item.path])).toEqual([
      ["projects-and-knowledge", "rounds/003.md"],
      ["goal-folders", "goal-folders/rounds/003.md"],
    ]);
    // The same round number on another goal is another key.
    const dismissed = new Set([dismissKey("kitterm", "goal-folders", 3)]);
    expect(proposedItems(entries, dismissed).map((item) => item.summary.slug)).toEqual(["projects-and-knowledge"]);
    expect(dismissKey("kitterm", "", 3)).toBe("kitterm::3");
    expect(proposedItems([{ project: kitterm, summary: { ...first, slug: undefined } }], new Set(["kitterm::3"]))).toEqual([]);
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
  it("names the round and the project, and the goal when given", () => {
    expect(dismissName(5, "kitterm")).toBe("Dismiss the proposal of round 5 of kitterm");
    expect(dismissName(3, "kitterm", "one folder per goal")).toBe("Dismiss the proposal of round 3 of one folder per goal in kitterm");
  });
});

describe("the record and proposals names", () => {
  it("name the record by its file and its project, apart from the round counter", () => {
    expect(recordLabel("rounds/005.md")).toBe("005");
    expect(recordLabel("rounds/7.md")).toBe("7");
    expect(recordName("rounds/005.md", "kitterm")).toBe("Open round record 005 of kitterm");
    expect(recordName("rounds/002.md", "kitterm-fixture")).toBe("Open round record 002 of kitterm-fixture");
  });

  it("drop the goal folder from the label and name the goal when given", () => {
    expect(recordLabel("goal-folders/rounds/003.md")).toBe("003");
    expect(recordLabel("projects-and-knowledge/rounds/8.md")).toBe("8");
    expect(recordName("goal-folders/rounds/003.md", "kitterm", "one folder per goal")).toBe(
      "Open round record 003 of one folder per goal in kitterm",
    );
  });

  it("say where the proposals wait and whose they are", () => {
    expect(proposalsName(12, "kitterm")).toBe("12 proposals waiting on the human in STATE.md of kitterm");
    expect(proposalsName(1, "other")).toBe("1 proposal waiting on the human in STATE.md of other");
    expect(proposalsName(1, "kitterm", "one folder per goal")).toBe(
      "1 proposal waiting on the human in STATE.md of one folder per goal in kitterm",
    );
  });
});
