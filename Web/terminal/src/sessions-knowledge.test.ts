import { describe, expect, it } from "vitest";

import {
  attention,
  cardRecord,
  dismissKey,
  dismissName,
  focusKey,
  doneLabel,
  goalLine,
  goalLines,
  goalOf,
  goalTitle,
  isUnwritten,
  hasKnowledge,
  knowledgeUrl,
  nextLine,
  proposalsName,
  proposedItems,
  proposedLabel,
  recordLabel,
  recordName,
  recordPath,
  roundLabel,
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

describe("goalLines", () => {
  const active: KnowledgeSummary = {
    project: "kitterm", slug: "fleet-catch-up", goal: "the fleet view reads like a terminal", status: "active",
    round: 2, budget: 3, lastFloor: "green (2026-09-15, round 2)",
    nextAction: "Round 3: `catch-up-first` from `plan.md` row 3; proof: the 390 px screenshot.\nCapability 4 may run alongside.",
  };
  const waiting: KnowledgeSummary = { project: "kitterm", slug: "later", goal: "a goal that waits", status: "waiting", round: 3, budget: 3 };
  const stopped: KnowledgeSummary = { project: "kitterm", slug: "dropped", status: "stopped", lastRound: 2 };
  const done: KnowledgeSummary = { project: "kitterm", slug: "projects-and-knowledge", goal: "projects on the fleet view", status: "done", lastRound: 8 };
  // `kitterm goal new` copied `examples/goals/goal/` and nobody filled it in.
  const template: KnowledgeSummary = {
    project: "kitterm", slug: "cost-per-round", goal: "<one line that names the outcome>", status: "active", round: 0, budget: 3,
    lastFloor: "green | red (<check>) (<ISO date>, round <n>)",
    nextAction: "Round 1: `<item>` from `plan.md` row 1; proof: `<test or screenshot>`.",
  };

  it("prints an active goal as one line: title, round, first line of the next action, no floor word, no slug", () => {
    expect(goalLine(active)).toEqual({
      summary: active, title: "the fleet view reads like a terminal", unwritten: false, status: null,
      round: "round 2 of 3", next: "Round 3: `catch-up-first` from `plan.md` row 3; proof: the 390 px screenshot.",
    });
  });

  it("prints a goal whose files still hold the template as \"not written yet\", named by its slug", () => {
    expect(goalLine(template)).toEqual({ summary: template, title: "cost-per-round", unwritten: true, status: null, round: null, next: null });
    expect(isUnwritten(template)).toBe(true);
    expect(isUnwritten({ ...template, goal: "a real title" })).toBe(true);
    expect(isUnwritten({ ...template, goal: "a real title", lastFloor: "green" })).toBe(true);
    expect(isUnwritten({ project: "kitterm", slug: "fresh", goal: "<one line that names the outcome>" })).toBe(true);
  });

  it("does not take a written next action's own angle brackets for the template", () => {
    const real: KnowledgeSummary = { ...active, nextAction: "Round 2: a route test for `GET /api/sessions/<id>/cost`." };
    expect(isUnwritten(real)).toBe(false);
    expect(goalLine(real).next).toBe("Round 2: a route test for `GET /api/sessions/<id>/cost`.");
    expect(isUnwritten({ project: "kitterm", slug: "bare" })).toBe(false);
  });

  it("prints the status word only when the goal is not active", () => {
    expect(goalLine(waiting)).toMatchObject({ title: "a goal that waits", status: "waiting", round: "round 3 of 3", next: null });
    expect(goalLine(stopped)).toMatchObject({ title: "dropped", status: "stopped", round: null, next: null });
    expect(goalLine({ ...active, status: " Active " }).status).toBeNull();
    expect(goalLine({ ...active, status: "paused" }).status).toBe("paused");
  });

  it("folds the done goals behind one line and keeps the rest open, in the order given", () => {
    const lines = goalLines([active, waiting, done, stopped, template, { ...done, slug: "goal-folders", status: " Done " }]);
    expect(lines.open.map((line) => line.title)).toEqual([
      "the fleet view reads like a terminal", "a goal that waits", "dropped", "cost-per-round",
    ]);
    expect(lines.done.map((summary) => summary.slug)).toEqual(["projects-and-knowledge", "goal-folders"]);
    expect(doneLabel(lines.done.length)).toBe("2 done");
    expect(doneLabel(7)).toBe("7 done");
    expect(doneLabel(1)).toBe("1 done");
  });

  it("shows nothing for an empty package, no answer, or a summary with no field", () => {
    expect(goalLines([])).toEqual({ open: [], done: [] });
    expect(goalLines(null)).toEqual({ open: [], done: [] });
    expect(goalLines(undefined)).toEqual({ open: [], done: [] });
    expect(goalLines([{ project: "kitterm" }, active]).open).toHaveLength(1);
  });

  it("reads the round counter with or without a budget, and the next action's first line", () => {
    expect(roundLabel({ project: "p", round: 4 })).toBe("round 4");
    expect(roundLabel({ project: "p", round: 4, budget: 6 })).toBe("round 4 of 6");
    expect(roundLabel({ project: "p", budget: 6 })).toBeNull();
    expect(nextLine("  first line \nsecond line")).toBe("first line");
    expect(nextLine("\nafter a blank line")).toBeNull();
    expect(nextLine(undefined)).toBeNull();
    expect(nextLine("   ")).toBeNull();
  });
});

describe("goalTitle", () => {
  it("names the goal by its title, else its slug, else the word", () => {
    expect(goalTitle(summary)).toBe("projects on the fleet view");
    expect(goalTitle({ project: "kitterm", slug: "goal-folders" })).toBe("goal-folders");
    expect(goalTitle({ project: "kitterm" })).toBe("goal");
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

  it("tells the strip's record link from the card's link to the same record", () => {
    const path = "goal-folders/rounds/002.md";
    expect(focusKey("strip-knowledge", "kitterm", path)).not.toBe(focusKey("card-knowledge", "kitterm", path));
    expect(focusKey("card-knowledge", "kitterm", path)).toBe("card-knowledge:kitterm:goal-folders/rounds/002.md");
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
  const proposing: KnowledgeSummary = { ...summary, lastRound: 3, proposals: 1, lastDecision: "propose (`plan.md`: x)" };

  it("lists a goal whose STATE.md counts proposals, with the record and the decision line", () => {
    const items = proposedItems([
      { project: kitterm, summary },
      { project: other, summary: proposing },
    ]);
    expect(items).toEqual([{
      kind: "proposed", project: other, summary: proposing, round: 3, count: 1,
      record: "rounds/003.md", path: "rounds/003.md", decision: "propose (`plan.md`: x)",
    }]);
  });

  it("lists a goal with three proposals in STATE.md and a decision of done, once", () => {
    // foreman-harness round 4: the record closes with `done`; the foreman
    // wrote the proposal into STATE.md at close.
    const stateOnly: KnowledgeSummary = {
      project: "kitterm", slug: "foreman-harness", goal: "the foreman's own tools stop lying to it",
      status: "waiting", round: 4, budget: 6, proposals: 3, lastRound: 4,
      lastRecord: "foreman-harness/rounds/004.md", lastDecision: "done.",
    };
    const items = proposedItems([{ project: kitterm, summary: stateOnly }]);
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ count: 3, round: 4, record: "foreman-harness/rounds/004.md", decision: null });
    expect(items[0].path).toBe("foreman-harness/rounds/004.md");
  });

  it("links STATE.md itself for a goal with proposals and no round record yet", () => {
    const fresh: KnowledgeSummary = { project: "kitterm", slug: "fresh", status: "active", round: 0, proposals: 2 };
    const items = proposedItems([{ project: kitterm, summary: fresh }]);
    expect(items[0]).toMatchObject({ count: 2, round: 0, record: null, path: "fresh/STATE.md", decision: null });
  });

  it("links the record by the name the daemon read, rounds/7.md included", () => {
    const seven: KnowledgeSummary = { ...proposing, lastRound: 7, lastRecord: "rounds/7.md" };
    expect(proposedItems([{ project: other, summary: seven }])[0].path).toBe("rounds/7.md");
  });

  it("takes the decision as the text only when it proposes, in any case, after blanks", () => {
    const loud: KnowledgeSummary = { ...proposing, lastDecision: "  Propose: something" };
    expect(proposedItems([{ project: kitterm, summary: loud }])[0].decision).toBe("Propose: something");
    const done: KnowledgeSummary = { ...proposing, lastDecision: "done. propose (x) later" };
    expect(proposedItems([{ project: kitterm, summary: done }])[0].decision).toBeNull();
  });

  it("yields nothing for a goal whose STATE.md lists no proposal, whatever the decision says", () => {
    // The human pruned STATE.md: the record still proposes, the item leaves.
    expect(proposedItems([{ project: kitterm, summary: { ...proposing, proposals: 0 } }])).toEqual([]);
    expect(proposedItems([{ project: kitterm, summary: { ...proposing, proposals: undefined } }])).toEqual([]);
    expect(proposedItems([{ project: kitterm, summary: { project: "kitterm", lastDecision: "propose" } }])).toEqual([]);
    expect(proposedItems([])).toEqual([]);
  });

  it("leaves out a dismissed round and keeps the goal's next one", () => {
    const dismissed = new Set([dismissKey("kitterm", "projects-and-knowledge", 3)]);
    expect(dismissKey("kitterm", "projects-and-knowledge", 3)).toBe("kitterm:projects-and-knowledge:3");
    expect(proposedItems([{ project: kitterm, summary: proposing }], dismissed)).toEqual([]);
    const next: KnowledgeSummary = { ...proposing, lastRound: 4 };
    expect(proposedItems([{ project: kitterm, summary: next }], dismissed)).toHaveLength(1);
    expect(proposedItems([{ project: other, summary: proposing }], dismissed)).toHaveLength(1);
  });

  it("lists every proposing goal of one project and dismisses them one by one", () => {
    const second: KnowledgeSummary = {
      project: "kitterm", slug: "goal-folders", status: "waiting", lastRound: 3, proposals: 2,
      lastRecord: "goal-folders/rounds/003.md", lastDecision: "propose (`LOOP.md`: y)",
    };
    const quiet: KnowledgeSummary = { project: "kitterm", slug: "done-goal", status: "done", lastRound: 8, lastDecision: "done." };
    const entries = [proposing, second, quiet].map((goal) => ({ project: kitterm, summary: goal }));
    expect(proposedItems(entries).map((item) => [item.summary.slug, item.count, item.path])).toEqual([
      ["projects-and-knowledge", 1, "rounds/003.md"],
      ["goal-folders", 2, "goal-folders/rounds/003.md"],
    ]);
    // The same round number on another goal is another key.
    const dismissed = new Set([dismissKey("kitterm", "goal-folders", 3)]);
    expect(proposedItems(entries, dismissed).map((item) => item.summary.slug)).toEqual(["projects-and-knowledge"]);
    expect(dismissKey("kitterm", "", 3)).toBe("kitterm::3");
    expect(proposedItems([{ project: kitterm, summary: { ...proposing, slug: undefined } }], new Set(["kitterm::3"]))).toEqual([]);
  });

  it("names the count in one word and the STATE.md link by whose it is", () => {
    expect(proposedLabel(1)).toBe("1 proposal");
    expect(proposedLabel(3)).toBe("3 proposals");
    expect(statePath(summary)).toBe("projects-and-knowledge/STATE.md");
    expect(statePath({ project: "kitterm" })).toBe("STATE.md");
    expect(proposalsName(12, "kitterm")).toBe("12 proposals waiting on the human in STATE.md of kitterm");
    expect(proposalsName(1, "kitterm", "one folder per goal")).toBe(
      "1 proposal waiting on the human in STATE.md of one folder per goal in kitterm",
    );
  });
});

describe("withProposed", () => {
  const proposing: KnowledgeSummary = { ...summary, lastRound: 3, proposals: 1, lastDecision: "propose (x)" };
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

describe("the record names", () => {
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
});

describe("cardRecord", () => {
  const proposing: KnowledgeSummary = { ...summary, lastRound: 3, proposals: 1, lastDecision: "propose (x)" };
  // Proposals in STATE.md alone: the decision reads done, the item still shows.
  const also: KnowledgeSummary = {
    project: "kitterm", slug: "goal-folders", status: "waiting", lastRound: 3, proposals: 2,
    lastRecord: "goal-folders/rounds/003.md", lastDecision: "done.",
  };
  const entries = [proposing, also].map((goal) => ({ project: kitterm, summary: goal }));

  it("yields one strip item per proposal, and no card link for the same record", () => {
    const proposed = proposedItems(entries);
    expect(proposed.map((item) => [item.summary.slug, item.path])).toEqual([
      ["projects-and-knowledge", "rounds/003.md"],
      ["goal-folders", "goal-folders/rounds/003.md"],
    ]);
    expect(cardRecord("kitterm", proposing, proposed)).toBeNull();
    expect(cardRecord("kitterm", also, proposed)).toBeNull();
  });

  it("links the record on the card when the strip does not carry it", () => {
    expect(cardRecord("kitterm", summary, proposedItems(entries))).toBe("rounds/002.md");
    expect(cardRecord("kitterm", proposing, [])).toBe("rounds/003.md");
    expect(cardRecord("kitterm", { project: "kitterm", slug: "fresh" }, [])).toBeNull();
  });

  it("gives the link back to the card once the proposal is dismissed", () => {
    const dismissed = new Set([dismissKey("kitterm", "projects-and-knowledge", 3)]);
    const proposed = proposedItems(entries, dismissed);
    expect(proposed.map((item) => item.summary.slug)).toEqual(["goal-folders"]);
    expect(cardRecord("kitterm", proposing, proposed)).toBe("rounds/003.md");
    expect(cardRecord("kitterm", also, proposed)).toBeNull();
  });

  it("keeps the same record of another project on its own card", () => {
    const proposed = proposedItems([{ project: other, summary: proposing }]);
    expect(cardRecord("kitterm", proposing, proposed)).toBe("rounds/003.md");
    expect(cardRecord("other", proposing, proposed)).toBeNull();
  });
});
