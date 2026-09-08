import { describe, expect, it } from "vitest";

import {
  actionName,
  approvalName,
  attention,
  crews,
  needsYouMessage,
  filter,
  group,
  pickForeman,
  sortInGroup,
  stateOf,
  tally,
  type Approval,
  type MergedState,
  type ModelRow,
  type ProjectSummary,
} from "./sessions-model";

const kitterm = { id: "p-kitterm", name: "kitterm", root: "/w/kitterm", registered: false };
const workspace = { id: "p-workspace", name: "Workspace", root: "/w", registered: true };

function row(id: string, extra: Partial<ModelRow> = {}): ModelRow {
  return { id, cwd: "/w/kitterm", ...extra };
}

function state(id: string, mergedState: MergedState, extra: Partial<ModelRow> = {}): ModelRow {
  return row(id, { mergedState, ...extra });
}

describe("stateOf", () => {
  it("reads mergedState when the daemon sends it", () => {
    expect(stateOf(state("a", "needs-input"))).toBe("needs-input");
  });

  it("synthesizes a state for a daemon too old to send one", () => {
    expect(stateOf(row("a", { state: "running" }))).toBe("working");
    expect(stateOf(row("a", { state: "idle", lastExit: 130 }))).toBe("failed");
    expect(stateOf(row("a", { state: "idle", lastExit: 0 }))).toBe("idle");
    expect(stateOf(row("a"))).toBe("unknown");
  });
});

describe("group", () => {
  it("returns nothing for no rows and no projects", () => {
    expect(group([], [])).toEqual([]);
  });

  it("lists a registered project with no session as an empty group", () => {
    const groups = group([], [workspace]);
    expect(groups).toHaveLength(1);
    expect(groups[0].key).toBe("p-workspace");
    expect(groups[0].rows).toEqual([]);
    expect(groups[0].sections).toEqual([{ crew: null, rows: [] }]);
  });

  it("puts each row under its project, projects in name order, no-project last", () => {
    const a = row("a", { project: kitterm });
    const b = row("b", { cwd: "/w", project: workspace });
    const c = row("c", { cwd: "/tmp" });
    const groups = group([c, b, a], [workspace, kitterm]);
    expect(groups.map((g) => g.key)).toEqual(["p-kitterm", "p-workspace", ""]);
    expect(groups[0].rows).toEqual([a]);
    expect(groups[1].rows).toEqual([b]);
    expect(groups[2].project).toBeNull();
    expect(groups[2].rows).toEqual([c]);
  });

  it("adds a group for a project a row names that the project list lacks", () => {
    const a = row("a", { project: kitterm });
    const groups = group([a], []);
    expect(groups).toHaveLength(1);
    expect(groups[0].project).toEqual(kitterm);
  });

  it("omits the no-project group when every row has a project", () => {
    const groups = group([row("a", { project: kitterm })], [kitterm]);
    expect(groups.map((g) => g.key)).toEqual(["p-kitterm"]);
  });

  it("splits crews into sections when the crew labels differ", () => {
    const human = row("h", { project: kitterm });
    const demo = row("d", { project: kitterm, labels: { crew: "demo", task: "one" } });
    const alpha = row("x", { project: kitterm, labels: { crew: "alpha" } });
    const [g] = group([demo, human, alpha], [kitterm]);
    expect(g.sections.map((s) => s.crew)).toEqual([null, "alpha", "demo"]);
    expect(g.sections[0].rows).toEqual([human]);
    expect(g.sections[2].rows).toEqual([demo]);
  });

  it("keeps one section when every row shares the crew label", () => {
    const one = row("1", { project: kitterm, labels: { crew: "demo" } });
    const two = row("2", { project: kitterm, labels: { crew: "demo" } });
    const [g] = group([one, two], [kitterm]);
    expect(g.sections).toHaveLength(1);
    expect(g.sections[0].crew).toBeNull();
    expect(g.sections[0].rows).toHaveLength(2);
  });

  it("sorts the rows inside a group and its sections", () => {
    const quiet = state("q", "working", { project: kitterm, lastOutputAt: 10 });
    const loud = state("l", "needs-input", { project: kitterm, lastOutputAt: 1 });
    const [g] = group([quiet, loud], [kitterm]);
    expect(g.rows.map((r) => r.id)).toEqual(["l", "q"]);
    expect(g.sections[0].rows.map((r) => r.id)).toEqual(["l", "q"]);
  });
});

describe("sortInGroup", () => {
  it("returns an empty list for no rows", () => {
    expect(sortInGroup([])).toEqual([]);
  });

  it("puts attention first: needs-approval, needs-input, failed", () => {
    const rows = [
      state("w", "working", { lastOutputAt: 100 }),
      state("f", "failed", { lastOutputAt: 90 }),
      state("i", "needs-input", { lastOutputAt: 80 }),
      state("a", "needs-approval", { lastOutputAt: 70 }),
    ];
    expect(sortInGroup(rows).map((r) => r.id)).toEqual(["a", "i", "f", "w"]);
  });

  it("orders the rest by last output, newest first", () => {
    const rows = [
      state("old", "working", { lastOutputAt: 1 }),
      state("new", "idle", { lastOutputAt: 3 }),
      state("mid", "completed", { lastOutputAt: 2 }),
    ];
    expect(sortInGroup(rows).map((r) => r.id)).toEqual(["new", "mid", "old"]);
  });

  it("is stable and puts rows with no output last", () => {
    const rows = [state("a", "working"), state("b", "working"), state("c", "working", { lastOutputAt: 5 })];
    expect(sortInGroup(rows).map((r) => r.id)).toEqual(["c", "a", "b"]);
  });

  it("does not mutate its input", () => {
    const rows = [state("a", "working", { lastOutputAt: 1 }), state("b", "failed")];
    sortInGroup(rows);
    expect(rows.map((r) => r.id)).toEqual(["a", "b"]);
  });
});

describe("filter", () => {
  const human = row("h", { project: kitterm, mergedState: "idle", lastCommand: "git status" });
  const crew = row("c", {
    project: kitterm,
    mergedState: "working",
    orchestrated: true,
    labels: { crew: "demo" },
    name: "crew one",
  });
  const loose = row("l", { cwd: "/tmp/scratch", mergedState: "failed" });
  const all = [human, crew, loose];

  it("returns nothing for no rows", () => {
    expect(filter([], { states: ["working"] })).toEqual([]);
  });

  it("keeps every row when no criterion is set", () => {
    expect(filter(all, {})).toEqual(all);
    expect(filter(all, { states: [], projects: [], crews: [], query: "" })).toEqual(all);
  });

  it("filters by state", () => {
    expect(filter(all, { states: ["failed", "working"] }).map((r) => r.id)).toEqual(["c", "l"]);
  });

  it("filters by project, with \"\" for the rows outside every project", () => {
    expect(filter(all, { projects: ["p-kitterm"] }).map((r) => r.id)).toEqual(["h", "c"]);
    expect(filter(all, { projects: [""] }).map((r) => r.id)).toEqual(["l"]);
  });

  it("filters by crew label", () => {
    expect(filter(all, { crews: ["demo"] }).map((r) => r.id)).toEqual(["c"]);
    expect(filter(all, { crews: ["other"] })).toEqual([]);
  });

  it("reads orchestrated for human or crew", () => {
    expect(filter(all, { kind: "crew" }).map((r) => r.id)).toEqual(["c"]);
    expect(filter(all, { kind: "human" }).map((r) => r.id)).toEqual(["h", "l"]);
  });

  it("matches the query against name, cwd, and last command, ignoring case", () => {
    expect(filter(all, { query: "ONE" }).map((r) => r.id)).toEqual(["c"]);
    expect(filter(all, { query: "scratch" }).map((r) => r.id)).toEqual(["l"]);
    expect(filter(all, { query: "git st" }).map((r) => r.id)).toEqual(["h"]);
    expect(filter(all, { query: "  " })).toEqual(all);
    expect(filter(all, { query: "nothing here" })).toEqual([]);
  });

  it("combines criteria", () => {
    expect(filter(all, { projects: ["p-kitterm"], kind: "human" }).map((r) => r.id)).toEqual(["h"]);
    expect(filter(all, { projects: ["p-kitterm"], states: ["failed"] })).toEqual([]);
  });
});

describe("attention", () => {
  const approval: Approval = { id: "ap1", tool: "Bash", input: "{}", session: "c", waitingMs: 10 };

  it("returns nothing for no rows and no approvals", () => {
    expect(attention([], [])).toEqual([]);
  });

  it("lists approvals, then needs-input, then failed", () => {
    const rows = [
      state("f", "failed", { lastOutputAt: 5 }),
      state("i", "needs-input"),
      state("c", "needs-approval"),
      state("w", "working"),
    ];
    const items = attention(rows, [approval]);
    expect(items.map((item) => item.kind)).toEqual(["approval", "needs-input", "failed"]);
    expect(items[0].kind === "approval" && items[0].row?.id).toBe("c");
    expect(items[1].row?.id).toBe("i");
    expect(items[2].row?.id).toBe("f");
  });

  it("keeps an approval whose session is not listed, with no row", () => {
    const items = attention([], [approval]);
    expect(items).toEqual([{ kind: "approval", approval, row: null }]);
  });

  it("orders several failed rows by last output, newest first", () => {
    const rows = [state("a", "failed", { lastOutputAt: 1 }), state("b", "failed", { lastOutputAt: 2 })];
    expect(attention(rows, []).map((item) => item.row?.id)).toEqual(["b", "a"]);
  });
});

describe("pickForeman", () => {
  it("finds nothing in an empty list", () => {
    expect(pickForeman([])).toEqual({ foreman: null, rest: [] });
  });

  it("pins the row labelled crew:foreman and keeps the rest in order", () => {
    const a = row("a");
    const f = row("f", { labels: { crew: "foreman" } });
    const b = row("b", { labels: { crew: "demo" } });
    expect(pickForeman([a, f, b])).toEqual({ foreman: f, rest: [a, b] });
  });
});

describe("tally and crews", () => {
  it("count nothing for no rows", () => {
    expect(tally([])).toEqual({});
    expect(crews([])).toEqual([]);
  });

  it("count rows by merged state and list crew names in order", () => {
    const rows = [
      state("a", "working", { labels: { crew: "zeta" } }),
      state("b", "working", { labels: { crew: "alpha" } }),
      state("c", "failed", { labels: { task: "x" } }),
    ];
    expect(tally(rows)).toEqual({ working: 2, failed: 1 });
    expect(crews(rows)).toEqual(["alpha", "zeta"]);
  });

  it("read an unlisted project list as one group per row project", () => {
    const projects: ProjectSummary[] = [{ ...kitterm, knowledge: "docs/goals" }];
    expect(group([], projects)[0].project).toEqual(kitterm);
  });
});

describe("accessible names", () => {
  it("names a row action after its row", () => {
    expect(actionName("Kill", "kitterm")).toBe("Kill kitterm");
    expect(actionName("Actions for", "build 3")).toBe("Actions for build 3");
  });

  it("names an approval answer after the tool and the session", () => {
    expect(approvalName("Allow", "Bash", "kitterm")).toBe("Allow Bash in kitterm");
    expect(approvalName("Deny", "Write", "")).toBe("Deny Write");
  });

  it("counts the items that need the human in one sentence", () => {
    expect(needsYouMessage(0)).toBe("Nothing needs you");
    expect(needsYouMessage(1)).toBe("1 item needs you");
    expect(needsYouMessage(3)).toBe("3 items need you");
  });
});
