import { describe, expect, it } from "vitest";

import {
  bucketLabel,
  goalBuckets,
  HEADING_LINE_PX,
  headingLine,
  levels,
  NESTED_INDENT_PX,
  NO_PROJECT,
  NO_PROJECT_NAME,
  noGoalsLine,
  rowLine,
  workspaceHome,
  workspaceOf,
  type KnowledgeSummary,
  type ModelRow,
  type ProjectSummary,
  type WorkspaceSection,
} from "./sessions-model";

/**
 * The three levels of the fleet view (`workspace-ledger`, capability 1):
 * a workspace, its projects, and each project's goals by state. The tree
 * is the corpus fixture `01-where-did-it-go`: `kitterm` alone under
 * `Workspace`, and three projects under `NgheNhanTrading`, one of them a
 * discovered checkout.
 */
const W = "/Users/antran/Workspace";
const NNT = `${W}/NgheNhanTrading`;

const kitterm: ProjectSummary = { id: "kitterm", name: "kitterm", root: `${W}/kitterm`, registered: true, knowledge: "docs/goals" };
const mdp: ProjectSummary = { id: "mdp", name: "market-data-pipeline", root: `${NNT}/market-data-pipeline`, registered: true, knowledge: "docs/goals" };
const mt5: ProjectSummary = { id: "mt5", name: "nghenhan-mt5", root: `${NNT}/nghenhan-mt5`, registered: true, knowledge: "docs/goals" };
const tda: ProjectSummary = { id: "tda", name: "trading-data-api", root: `${NNT}/trading-data-api`, registered: false };
const projects = [kitterm, mdp, mt5, tda];

function row(id: string, cwd: string, extra: Partial<ModelRow> = {}): ModelRow {
  return { id, cwd, mergedState: "idle", ...extra };
}

const goal = (slug: string, status: string, extra: Partial<KnowledgeSummary> = {}): KnowledgeSummary => ({
  project: "mdp", slug, goal: `the ${slug} goal`, status, round: 1, budget: 3, ...extra,
});

const onboarding = goal("symbol-onboarding", "active");
const sinkHealth = goal("session-aware-sink-health", "done", { lastRound: 3 });
const ingest = goal("ingest-rate", "waiting", { round: 2 });

const foreman = row("foreman", NNT, { name: "foreman", labels: { crew: "foreman" }, mergedState: "completed" });
const crew = row("crew", mdp.root!, {
  name: "symbol-onboarding round 1",
  project: mdp,
  mergedState: "working",
  labels: { crew: "symbol-onboarding", goal: "symbol-onboarding", round: "1" },
});
const shell = row("shell", mdp.root!, { project: mdp });
const postman = row("postman", `${tda.root}/docs/postman`, { project: tda });
const scratch = row("scratch", "/tmp/scratch");
const atWorkspace = row("at-workspace", W);

const knowledge: Record<string, KnowledgeSummary[] | null | undefined> = {
  kitterm: [goal("agent-push", "done", { project: "kitterm", lastRound: 4 })],
  mdp: [onboarding, sinkHealth, ingest],
  mt5: [],
};
const goalsOf = (id: string): KnowledgeSummary[] | null | undefined => knowledge[id];

const names = (sections: WorkspaceSection<ModelRow>[]): Array<[string | null, string[]]> =>
  sections.map((s) => [s.heading?.name ?? null, s.projects.map((p) => p.heading.name)]);

describe("workspaceOf and workspaceHome", () => {
  it("read the parent directory of a root as the workspace", () => {
    expect(workspaceOf(`${NNT}/market-data-pipeline`)).toBe(NNT);
    expect(workspaceOf(`${W}/kitterm/`)).toBe(W);
  });

  it("find no workspace for a project with no root or no parent", () => {
    expect(workspaceOf(undefined)).toBeNull();
    expect(workspaceOf("/kitterm")).toBeNull();
    expect(workspaceOf("kitterm")).toBeNull();
  });

  it("send a shell to the headed workspace that is or holds its cwd, the deepest of two", () => {
    expect(workspaceHome(NNT, [NNT])).toBe(NNT);
    expect(workspaceHome(`${NNT}/notes/`, [NNT])).toBe(NNT);
    expect(workspaceHome(`${NNT}/deep/x`, [W, NNT])).toBe(NNT);
    expect(workspaceHome(`${W}/NgheNhanTrading-old`, [NNT])).toBeNull();
    expect(workspaceHome("/tmp/scratch", [NNT])).toBeNull();
  });
});

describe("levels", () => {
  const all = [foreman, crew, shell, postman, scratch, atWorkspace];
  const sections = levels(all, all, projects, goalsOf);

  it("heads a workspace of several projects and none over a lone one, in one name order", () => {
    expect(names(sections)).toEqual([
      [null, ["kitterm"]],
      ["NgheNhanTrading", ["market-data-pipeline", "nghenhan-mt5", "trading-data-api"]],
      [null, [NO_PROJECT_NAME]],
    ]);
    expect(sections[1].heading).toEqual({ name: "NgheNhanTrading", path: NNT });
    expect(sections[0].projects[0].heading).toEqual({ name: "kitterm", path: kitterm.root });
  });

  it("lists a shell outside every project under the workspace that holds it, and the rest under No project", () => {
    expect(sections[1].rows.map((r) => r.id)).toEqual(["foreman"]);
    const none = sections[2].projects[0];
    expect(none.key).toBe(NO_PROJECT);
    expect(none.project).toBeNull();
    expect(none.heading).toEqual({ name: NO_PROJECT_NAME, path: null });
    // The shell at `Workspace` sits above a lone project, which has no
    // heading to sit under, so it is a shell with no project.
    expect(none.rows.map((r) => r.id)).toEqual(["scratch", "at-workspace"]);
    expect(none.owned).toBe(2);
    expect(none.noGoals).toBeNull();
  });

  it("sorts a project's goals into working, pending and done, and nests the crew's row under its goal", () => {
    const section = sections[1].projects[0];
    expect(section.goals.working.map((e) => e.line.title)).toEqual(["the symbol-onboarding goal"]);
    expect(section.goals.working[0].rows.map((r) => r.id)).toEqual(["crew"]);
    expect(section.goals.pending.map((l) => [l.title, l.status])).toEqual([["the ingest-rate goal", "waiting"]]);
    expect(section.goals.done.map((g) => g.slug)).toEqual(["session-aware-sink-health"]);
    // The crew's row is under its goal and not among the project's rows.
    expect(section.rows.map((r) => r.id)).toEqual(["shell"]);
    expect(section.owned).toBe(2);
  });

  it("prints the two kinds of no goals apart: a registered package with none, and a discovered checkout", () => {
    const [, mt5Section, tdaSection] = sections[1].projects;
    expect(mt5Section.noGoals).toBe("no goal folder");
    expect(mt5Section.goals).toEqual({ working: [], pending: [], done: [] });
    expect(mt5Section.owned).toBe(0);
    expect(tdaSection.noGoals).toBe("not registered");
    expect(tdaSection.rows.map((r) => r.id)).toEqual(["postman"]);
    expect(noGoalsLine({ ...kitterm }, undefined)).toBeNull();
    expect(noGoalsLine(null, [])).toBeNull();
  });

  it("omits the No project section when every loose shell has a workspace", () => {
    const rows = [foreman, crew];
    const out = levels(rows, rows, projects, goalsOf);
    expect(names(out).map(([name]) => name)).toEqual([null, "NgheNhanTrading"]);
    expect(out[1].rows.map((r) => r.id)).toEqual(["foreman"]);
  });

  it("counts a crew in the strip as owned and keeps its goal working, without listing its row", () => {
    const listed = [shell];
    const owned = [shell, crew];
    const [section] = levels(listed, owned, [mdp], goalsOf)[0].projects;
    expect(section.owned).toBe(2);
    expect(section.goals.working[0].rows).toEqual([]);
    expect(section.rows.map((r) => r.id)).toEqual(["shell"]);
  });

  it("returns nothing for no rows and no projects", () => {
    expect(levels([], [], [], goalsOf)).toEqual([]);
  });

  it("stands a project with no root at the top level", () => {
    const rootless: ProjectSummary = { id: "x", name: "x", registered: true };
    const out = levels([], [], [rootless, mdp, mt5], goalsOf);
    expect(names(out)).toEqual([
      ["NgheNhanTrading", ["market-data-pipeline", "nghenhan-mt5"]],
      [null, ["x"]],
    ]);
    expect(out[1].projects[0].heading.path).toBeNull();
  });
});

describe("rowLine under a workspace heading", () => {
  it("prints no place for a named shell at the workspace directory, and the path under it away from it", () => {
    expect(rowLine(foreman, 0, NNT).place).toBeNull();
    expect(rowLine(foreman, 0).place).toBe("NgheNhanTrading");
    const notes = row("n", `${NNT}/notes/q3`, { name: "notes" });
    expect(rowLine(notes, 0, NNT).place).toBe("notes/q3");
  });
});

describe("goalBuckets", () => {
  it("reads working from a live label, not from the status word", () => {
    const active = goal("idle-goal", "active");
    const waitingWithCrew = goal("crewed", "waiting");
    const crewed = row("c", mdp.root!, { project: mdp, labels: { goal: "crewed" } });
    const out = goalBuckets([active, waitingWithCrew], [crewed], [crewed]);
    expect(out.working.map((e) => e.line.summary.slug)).toEqual(["crewed"]);
    expect(out.working[0].line.status).toBe("waiting");
    expect(out.pending.map((l) => l.summary.slug)).toEqual(["idle-goal"]);
  });

  it("keeps a done goal done when a live session still carries its label", () => {
    const lingering = row("l", mdp.root!, { project: mdp, labels: { goal: "session-aware-sink-health" } });
    const out = goalBuckets([sinkHealth], [lingering], [lingering]);
    expect(out.working).toEqual([]);
    expect(out.done.map((g) => g.slug)).toEqual(["session-aware-sink-health"]);
  });

  it("leaves a row whose label names no goal folder out of every bucket", () => {
    const stray = row("s", mdp.root!, { project: mdp, labels: { goal: "nowhere" } });
    const out = goalBuckets([onboarding], [stray], [stray]);
    expect(out.working).toEqual([]);
    expect(out.pending.map((l) => l.summary.slug)).toEqual(["symbol-onboarding"]);
  });

  it("buckets nothing for no goals", () => {
    expect(goalBuckets(undefined, [], [])).toEqual({ working: [], pending: [], done: [] });
    expect(goalBuckets([], [crew], [crew])).toEqual({ working: [], pending: [], done: [] });
  });

  it("labels a bucket by its count and its state", () => {
    expect(bucketLabel("working", 1)).toBe("1 working");
    expect(bucketLabel("pending", 2)).toBe("2 pending");
    expect(bucketLabel("done", 10)).toBe("10 done");
  });
});

describe("a nested project heading at 390 px", () => {
  const bundled = ["local shell", "box", "zbox", "ubash"];

  it("loses the indent from its line and gives way sooner than a top-level one", () => {
    const top = headingLine({ name: "market-data-pipeline", tally: null, profiles: bundled });
    const nested = headingLine({ name: "market-data-pipeline", tally: null, profiles: bundled, indent: NESTED_INDENT_PX });
    expect(top.profile).toBe("whole");
    expect(nested.profile).toBe("short");
    expect(nested.px).toBeLessThanOrEqual(HEADING_LINE_PX);
    expect(nested.fits).toBe(true);
    // The same shape is the indent wider on the nested line.
    const shape = headingLine({ name: "market-data-pipeline", tally: null, profiles: [] });
    const nestedShape = headingLine({ name: "market-data-pipeline", tally: null, profiles: [], indent: NESTED_INDENT_PX });
    expect(nestedShape.px - shape.px).toBe(NESTED_INDENT_PX);
  });

  it("keeps the name whole with no profile to give away", () => {
    const line = headingLine({ name: "nghenhan-mt5", tally: "no live session", profiles: [], indent: NESTED_INDENT_PX });
    expect(line.tally).toBe("no live session");
    expect(line.fits).toBe(true);
  });
});
