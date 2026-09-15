import { describe, expect, it } from "vitest";

import {
  actionName,
  approvalName,
  attention,
  cardRows,
  crews,
  needsYouMessage,
  filter,
  fleetLine,
  group,
  pickForeman,
  restartDismissKey,
  restartDismissName,
  restartNotice,
  rowLine,
  rowName,
  sortInGroup,
  spanLabel,
  stripIds,
  stripWhere,
  stampFormat,
  stateLabel,
  stateOf,
  tally,
  type Approval,
  type DaemonStarted,
  type MergedState,
  type ModelRow,
  type ProjectSummary,
  type StampFormat,
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

  it("orders the rest by state: working, done, idle, exited, no integration", () => {
    // The idle shell printed last; the working row that went quiet is
    // still the one the reader is waiting on, so it comes first.
    const rows = [
      state("old", "working", { lastOutputAt: 1 }),
      state("new", "idle", { lastOutputAt: 3 }),
      state("mid", "completed", { lastOutputAt: 2 }),
      state("gone", "exited", { lastOutputAt: 4 }),
      state("none", "unknown", { lastOutputAt: 5 }),
    ];
    expect(sortInGroup(rows).map((r) => r.id)).toEqual(["old", "mid", "new", "gone", "none"]);
  });

  it("orders rows of one state by last output, newest first", () => {
    const rows = [
      state("a", "working", { lastOutputAt: 1 }),
      state("b", "working", { lastOutputAt: 3 }),
      state("c", "idle", { lastOutputAt: 9 }),
      state("d", "working", { lastOutputAt: 2 }),
    ];
    expect(sortInGroup(rows).map((r) => r.id)).toEqual(["b", "d", "a", "c"]);
  });

  it("puts the foreman first among the rows that need nobody, whatever its state", () => {
    const rows = [
      state("w", "working", { lastOutputAt: 9 }),
      state("f", "completed", { labels: { crew: "foreman" }, lastOutputAt: 1 }),
      state("i", "needs-input", { lastOutputAt: 2 }),
    ];
    expect(sortInGroup(rows).map((r) => r.id)).toEqual(["i", "f", "w"]);
    // A foreman that needs the human is an attention row like any other.
    const asks = state("f", "needs-input", { labels: { crew: "foreman" } });
    expect(sortInGroup([state("w", "working"), asks]).map((r) => r.id)).toEqual(["f", "w"]);
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

describe("cardRows", () => {
  // The corpus fixture `01-back-after-lunch`: two sessions that need input,
  // two that failed, a done foreman, and two idle shells.
  const nnt = "/w/NgheNhanTrading";
  const mdp = { id: "mdp", name: "market-data-pipeline", root: `${nnt}/market-data-pipeline`, registered: true };
  const tda = { id: "tda", name: "trading-data-api", root: `${nnt}/trading-data-api`, registered: true };
  const message = "Adopt two active Claude sessions finished";
  const fixture: ModelRow[] = [
    { id: "nnt-input", cwd: nnt, mergedState: "needs-input", agent: { message }, lastOutputAt: 7 },
    { id: "ws-input", cwd: "/w", mergedState: "needs-input", agent: { message }, lastOutputAt: 6 },
    { id: "mdp-failed", cwd: mdp.root, project: mdp, mergedState: "failed", lastExit: 1, lastOutputAt: 8 },
    { id: "ws-failed", cwd: "/w", mergedState: "failed", lastExit: 1, lastOutputAt: 5 },
    { id: "foreman", cwd: nnt, name: "foreman", labels: { crew: "foreman" }, mergedState: "completed", lastOutputAt: 8 },
    { id: "postman", cwd: `${tda.root}/docs/postman`, project: tda, mergedState: "idle", lastOutputAt: 1 },
    { id: "nnt-idle", cwd: nnt, mergedState: "idle", lastOutputAt: 3 },
  ];
  const projects: ProjectSummary[] = [kitterm, mdp, tda];

  it("lists no session in both the strip and a card", () => {
    const items = attention(fixture, []);
    const inStrip = stripIds(items);
    expect([...inStrip].sort()).toEqual(["mdp-failed", "nnt-input", "ws-failed", "ws-input"]);
    const listed = cardRows(fixture, items);
    expect(listed.filter((row) => inStrip.has(row.id))).toEqual([]);
    expect(listed.map((row) => row.id)).toEqual(["foreman", "postman", "nnt-idle"]);
    expect(items.length + listed.length).toBe(fixture.length);
  });

  it("counts on a card only what the card lists", () => {
    const groups = group(cardRows(fixture, attention(fixture, [])), projects);
    const counts = Object.fromEntries(groups.map((g) => [g.key, tally(g.rows)]));
    expect(counts).toEqual({ "p-kitterm": {}, mdp: {}, tda: { idle: 1 }, "": { completed: 1, idle: 1 } });
  });

  it("keeps a needs-approval row in the strip only while its approval is listed", () => {
    const held = state("held", "needs-approval");
    const approval: Approval = { id: "ap", tool: "Bash", input: "{}", session: "held", waitingMs: 1 };
    expect(cardRows([held], attention([held], [approval]))).toEqual([]);
    expect(cardRows([held], attention([held], []))).toEqual([held]);
    const orphan: Approval = { ...approval, session: "gone" };
    expect(stripIds(attention([held], [orphan]))).toEqual(new Set());
  });

  it("lists every row when nothing needs the human", () => {
    const rows = [state("a", "working"), state("b", "idle")];
    expect(cardRows(rows, attention(rows, []))).toEqual(rows);
    expect(cardRows([], [])).toEqual([]);
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

describe("stampFormat", () => {
  const died = new Date(2026, 8, 10, 22, 35).getTime();

  it("prints the time alone for a moment that falls on today", () => {
    expect(stampFormat(died, new Date(2026, 8, 10, 23, 5).getTime())).toBe("time");
  });

  it("prints the time alone across a whole day, because the rule is the date", () => {
    const earlyToday = new Date(2026, 8, 10, 0, 5).getTime();
    expect(stampFormat(earlyToday, new Date(2026, 8, 10, 23, 55).getTime())).toBe("time");
  });

  it("carries the date for a moment that falls on yesterday", () => {
    expect(stampFormat(died, new Date(2026, 8, 11, 9, 0).getTime())).toBe("date-and-time");
  });

  it("carries the date for a moment six days back", () => {
    expect(stampFormat(died, new Date(2026, 8, 16, 9, 0).getTime())).toBe("date-and-time");
  });

  it("carries the date for a moment in another year", () => {
    expect(stampFormat(died, new Date(2027, 8, 10, 22, 35).getTime())).toBe("date-and-time");
  });

  // The case an elapsed span gets wrong: 80 minutes apart, two dates.
  it("carries the date when the clock passed midnight between the two", () => {
    const beforeMidnight = new Date(2026, 8, 10, 23, 50).getTime();
    const afterMidnight = new Date(2026, 8, 11, 0, 10).getTime();
    expect(stampFormat(beforeMidnight, afterMidnight)).toBe("date-and-time");
  });
});

describe("the restart line", () => {
  /** A fixed formatter, so the text under test carries no locale. `T+` is the
   * time alone, `D+` the date and the time. */
  const at = (epochMs: number, format: StampFormat) => `${format === "time" ? "T" : "D"}+${epochMs}`;
  const none = new Set<string>();
  const started = (data: Record<string, string>, epoch = "e1"): DaemonStarted => ({ epoch, data });

  /** 10 Sep 2026, 10:35 PM in the reader's own zone, and a read half an hour
   * later on the same date. Built from local parts, so no zone moves them. */
  const died = new Date(2026, 8, 10, 22, 35).getTime();
  const read = new Date(2026, 8, 10, 23, 5).getTime();

  const unrecorded = {
    previous: "unrecorded",
    previousPid: "4210",
    previousAliveAt: String(died),
    previousSessions: "2",
  };

  it("speaks for a run that ended with no recorded reason", () => {
    expect(restartNotice(started(unrecorded), none, at, read)).toEqual({
      text: `The daemon restarted. The previous run was last alive at T+${died} and lost 2 sessions.`,
      key: "epoch:e1",
    });
  });

  it("carries the date when the previous run did not die today", () => {
    const monday = new Date(2026, 8, 14, 9, 0).getTime();
    const line = restartNotice(started(unrecorded), none, at, monday);
    expect(line?.text).toBe(
      `The daemon restarted. The previous run was last alive at D+${died} and lost 2 sessions.`,
    );
  });

  it("counts one lost session in the singular", () => {
    const one = restartNotice(started({ ...unrecorded, previousSessions: "1" }), none, at, read);
    expect(one?.text).toContain("and lost 1 session.");
  });

  it("says nothing after a clean stop, which ended on purpose", () => {
    const clean = { ...unrecorded, previous: "clean", previousEndedAt: String(died + 1000) };
    expect(restartNotice(started(clean), none, at, read)).toBeNull();
  });

  it("says nothing after a live upgrade, which loses no session", () => {
    expect(restartNotice(started({ ...unrecorded, previous: "takeover" }), none, at, read)).toBeNull();
  });

  it("says nothing when the key is absent, which is no previous run", () => {
    expect(restartNotice(started({ epoch: "e1", version: "0.24.0", pid: "99" }), none, at, read)).toBeNull();
    expect(restartNotice(null, none, at, read)).toBeNull();
  });

  it("says nothing while this run's epoch is dismissed", () => {
    const dismissed = new Set([restartDismissKey("e1")]);
    expect(restartNotice(started(unrecorded), dismissed, at, read)).toBeNull();
    // The next death is a new epoch, so the line comes back.
    expect(restartNotice(started(unrecorded, "e2"), dismissed, at, read)?.key).toBe("epoch:e2");
  });

  it("says nothing when a fact the line claims is missing or not a number", () => {
    const { previousSessions: _drop, ...noCount } = unrecorded;
    expect(restartNotice(started(noCount), none, at, read)).toBeNull();
    expect(restartNotice(started({ ...unrecorded, previousAliveAt: "soon" }), none, at, read)).toBeNull();
  });

  it("names its Dismiss button apart from the other Dismiss buttons", () => {
    expect(restartDismissName()).toBe("Dismiss the restart notice");
  });
});

describe("rowLine", () => {
  const now = new Date(2026, 8, 15, 16, 7).getTime();
  const minute = 60_000;
  const hour = 60 * minute;
  const at = (ago: number): number => now - ago;
  const inKitterm = (extra: Partial<ModelRow>): ModelRow => row("r", { project: kitterm, ...extra });

  it("prints an idle shell at the project root as its folder, the state and the span", () => {
    expect(rowLine(inKitterm({ mergedState: "idle", lastExit: 0, lastOutputAt: at(2 * hour) }), now)).toEqual({
      name: "kitterm",
      state: "idle",
      place: null,
      what: null,
      since: "2h",
    });
  });

  it("prints a working agent with its message, alive now", () => {
    const working = inKitterm({
      name: "crew",
      mergedState: "working",
      lastCommand: "claude",
      agent: { message: "Running the floor" },
      lastOutputAt: at(20_000),
    });
    expect(rowLine(working, now)).toEqual({
      name: "crew",
      state: "working",
      place: null,
      what: "Running the floor",
      since: "now",
    });
  });

  it("prints a failed command with the exit code in the state word only", () => {
    const failed = inKitterm({ mergedState: "failed", lastExit: 1, lastCommand: "swift test", lastOutputAt: at(90 * minute) });
    expect(rowLine(failed, now)).toEqual({
      name: "kitterm",
      state: "failed (1)",
      place: null,
      what: "$ swift test",
      since: "1h",
    });
  });

  it("prints a named session in a subfolder with the path under the root, once", () => {
    const named = inKitterm({ name: "postman", cwd: "/w/kitterm/docs/postman", mergedState: "idle", lastExit: 0, lastOutputAt: at(3 * 24 * hour) });
    expect(rowLine(named, now)).toEqual({
      name: "postman",
      state: "idle",
      place: "docs/postman",
      what: null,
      since: "3d",
    });
  });

  it("names an unnamed session in a subfolder by the path under the root, with no place", () => {
    const line = rowLine(inKitterm({ cwd: "/w/kitterm/docs/postman", mergedState: "idle" }), now);
    expect(line.name).toBe("docs/postman");
    expect(line.place).toBeNull();
  });

  it("falls back to the folder outside every project, and away from the root", () => {
    expect(rowName(row("r", { cwd: "/home/me/scratch" }))).toBe("scratch");
    expect(rowLine(row("r", { name: "spike", cwd: "/home/me/scratch" }), now).place).toBe("scratch");
    expect(rowLine(inKitterm({ name: "spike", cwd: "/elsewhere/tool" }), now).place).toBe("tool");
    expect(rowLine(inKitterm({ name: "spike", cwd: "/w/kitterm/" }), now).place).toBeNull();
  });

  it("prefers the agent's message, then the note, then the last command", () => {
    const base = { lastCommand: "make", note: "Waiting on the human." };
    expect(rowLine(row("r", { ...base, agent: { message: "Done." } }), now).what).toBe("Done.");
    expect(rowLine(row("r", base), now).what).toBe("Waiting on the human.");
    expect(rowLine(row("r", { lastCommand: "make" }), now).what).toBe("$ make");
    expect(rowLine(row("r"), now).what).toBeNull();
  });

  it("prints no span without a last output", () => {
    expect(rowLine(row("r", { mergedState: "idle" }), now).since).toBeNull();
  });
});

describe("stateLabel", () => {
  it("keeps the exit code only when it is not zero", () => {
    expect(stateLabel(row("r", { mergedState: "failed", lastExit: 1 }))).toBe("failed (1)");
    expect(stateLabel(row("r", { mergedState: "failed" }))).toBe("failed");
    expect(stateLabel(row("r", { mergedState: "exited", lastExit: 130 }))).toBe("exited (130)");
    expect(stateLabel(row("r", { mergedState: "exited", lastExit: 0 }))).toBe("exited");
    expect(stateLabel(row("r", { mergedState: "idle", lastExit: 0 }))).toBe("idle");
  });

  it("prints the merged state's name otherwise", () => {
    expect(stateLabel(row("r", { mergedState: "needs-input" }))).toBe("needs input");
    expect(stateLabel(row("r", { mergedState: "completed" }))).toBe("done");
    expect(stateLabel(row("r"))).toBe("no integration");
  });
});

describe("spanLabel", () => {
  it("rounds down to one unit, with no seconds", () => {
    expect(spanLabel(0)).toBe("now");
    expect(spanLabel(59_999)).toBe("now");
    expect(spanLabel(60_000)).toBe("1m");
    expect(spanLabel(59 * 60_000 + 59_000)).toBe("59m");
    expect(spanLabel(60 * 60_000)).toBe("1h");
    expect(spanLabel(23 * 3_600_000 + 59 * 60_000)).toBe("23h");
    expect(spanLabel(24 * 3_600_000)).toBe("1d");
    expect(spanLabel(-5_000)).toBe("now");
  });
});

describe("stripWhere", () => {
  it("prints the project only when the row's name does not say it", () => {
    const nnt = { id: "nnt", name: "NgheNhanTrading", root: "/w/NgheNhanTrading", registered: true };
    // Named after its folder, which is the project's name: the word once.
    expect(stripWhere({ id: "a", cwd: "/w/NgheNhanTrading", project: nnt })).toBeNull();
    expect(stripWhere({ id: "a", cwd: "/w/NgheNhanTrading", name: "NgheNhanTrading", project: nnt })).toBeNull();
    // A named row, or one in a subfolder, still needs the project.
    expect(stripWhere({ id: "a", cwd: "/w/NgheNhanTrading", name: "foreman", project: nnt })).toBe("NgheNhanTrading");
    expect(stripWhere({ id: "a", cwd: "/w/NgheNhanTrading/docs", project: nnt })).toBe("NgheNhanTrading");
  });

  it("prints nothing for a row outside every project, which its folder names", () => {
    expect(stripWhere({ id: "a", cwd: "/Users/antran/Workspace" })).toBeNull();
    expect(stripWhere({ id: "a", cwd: "/Users/antran/Workspace", name: "Workspace" })).toBeNull();
  });
});

describe("fleetLine", () => {
  it("counts the working rows even at zero, and the rest only when there are any", () => {
    // The corpus fixture's rows once the strip has taken its four.
    const listed = [
      state("foreman", "completed", { labels: { crew: "foreman" } }),
      state("postman", "idle"),
      state("nnt-idle", "idle"),
    ];
    expect(fleetLine(listed)).toBe("0 working · 1 done · 2 idle");
    expect(fleetLine([])).toBe("0 working");
    expect(fleetLine([state("a", "working"), state("b", "working"), state("c", "exited"), state("d", "unknown")])).toBe(
      "2 working · 1 exited · 1 no integration",
    );
  });
});
