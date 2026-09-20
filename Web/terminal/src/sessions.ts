import "./tokens.css";
import "./sessions.css";
import { resolveFontFamily } from "./fonts";
import { summarize, waitedLabel } from "./approval-format";
import {
  applicationServerKey,
  attention,
  band,
  focusKey,
  folderOf,
  idleShellsLabel,
  keptFacts,
  markFamily,
  markGlyph,
  needsYouMessage,
  NEEDS_YOU_ID,
  proposalsName,
  proposedItems,
  proposedLabel,
  pushToggle,
  quotaPanel,
  readUsageChoice,
  recordName,
  restartDismissName,
  restartNotice,
  rowLine,
  rowModel,
  rowName,
  sameServerKey,
  stateOf,
  stateTag,
  usageAmount,
  usageChartName,
  usagePanel,
  usageRange,
  type DayRange,
  VOCABULARY,
  withProposed,
  dayLabel,
  goalTitle,
  type Approval,
  type AttentionItem,
  type Band,
  type BandCell,
  type DaemonStarted,
  type KnowledgeAnswer,
  type KnowledgeSummary,
  type MarkFamily,
  type ModelRow,
  type ProjectRef,
  type ProjectSummary,
  type ProposedItem,
  type PushFacts,
  type PushSupport,
  type PushToggle,
  type QuotaPanel,
  type StampFormat,
  type UsageChoice,
  type UsageDaily,
  type UsageLimits,
  type UsagePanel,
} from "./sessions-model";
import {
  apportionedNote,
  leakLines,
  modelsPanel,
  readWhereGrouping,
  usageHead,
  valuePanel,
  wherePanel,
  type LeakLine,
  type ModelsPanel,
  type UsageHead,
  type ValuePanel,
  type WhereGrouping,
  type WherePanel,
  type YieldReport,
} from "./sessions-value";
import { isOpen, sessionFactColumns, tree, visibleLines, type TreeLine, type TreeSection } from "./sessions-tree";
import { FRAME_MS, frameAt, QUADRANT } from "./spinner";
import { loadSettings } from "./settings-store";
import { applyThemeTokens } from "./theme-tokens";
import { findThemeById } from "./themes";

/**
 * The fleet view: the page the frames `Dashboard 1200` and `Dashboard
 * 390` of `corpus/dashboard.pen` draw (`agent-dashboard`, round 10). Polls
 * `/api/projects`, `/api/sessions`, `/api/approvals`, `/api/archives` and
 * `/api/usage/limits`, plus `/api/projects/<id>/knowledge` for each
 * registered project and `/api/usage/daily` and `/api/yield` for the
 * chosen range, and links each session back to `/?session=<id>`.
 *
 * Top to bottom: **the band**, the brand at the left and four counts at
 * the right, each a headline-size number with a body-size noun, in one
 * fixed-height row; **the panels**, each a label in an 84 px gutter beside
 * its content — `USAGE` (the range's dollars, tokens and model hours, the
 * two toggle groups, one bar per day, the axis, the apportioned note),
 * `QUOTA` (one bar per window with its percentage and its reset, caution
 * from 80 %), `MODELS` (the top three by cost and `Others`), one hairline
 * divider, `VALUE` (four tiles: what the spend bought and what one unit
 * cost), `WHERE` (the spend by project, goal, task or role, with the
 * counted checkouts' summary at the selector's right) and `LEAKS` (two
 * lines); **the tree**, under `SESSIONS` and the state vocabulary, as flat
 * lines with fixed fact columns (`sessions-tree.ts`): a workspace, its
 * projects, their goals, tasks and sessions, the most recent done goal
 * open and the rest behind `N done`, a project's and a goal's triangle
 * folding what sits under it; then **the folds** on one line: the
 * archives, the idle shells, and the push switch. On a phone the gutters,
 * `WHERE`, `LEAKS` and the vocabulary go, the counts wrap to two rows of
 * two, the tiles to two by two, and every line keeps its state word and
 * one fact. The page presents and monitors: it accepts no typed work and
 * holds no action (round 11: no `[new]`, no `[Dismiss]`, no `[Allow]` or
 * `[Deny]`, no `⋯` menu), and `Open the pane` is the way to act on an
 * agent. The pure models (`sessions-model.ts`, `sessions-value.ts`,
 * `sessions-tree.ts`) decide what goes where; this file only paints it.
 *
 * Deliberately its own page, not the terminal: `/` stays "open a tab, get a
 * shell".
 */

type SessionState = "running" | "idle" | "unknown";

type AgentStatus = { status: "needs-input" | "completed"; message?: string; at: number };

type SessionRow = ModelRow & {
  state: SessionState;
  marks: number;
  /** The session's latest Claude Code hook report. */
  agent?: AgentStatus;
  /** A tool call in this session is blocked on a human. */
  pendingApproval?: boolean;
  exited?: boolean;
  exitCode?: number;
};

/** Archived sessions: finished work whose evidence was kept. */
type ArchivedRow = {
  id: string;
  name?: string;
  cwd?: string;
  archivedAt?: number;
  exitCode?: number;
  project?: ProjectRef;
};

/** What needs a person: the model's attention items plus a proposal that
 * waits on the human in a project's knowledge package. The band counts
 * them; the tree marks them. */
type NeedsItem = AttentionItem<SessionRow> | ProposedItem;

/** One project's knowledge as last fetched: every goal summary the daemon
 * listed, in its order, each with the project's id; empty for a package
 * with no goal folder. `goals` is null when the daemon answered 404 (no
 * knowledge directory); the page asks again after `KNOWLEDGE_RETRY_POLLS`
 * polls, so a `kitterm project init` shows up without a reload. */
type KnowledgeEntry = {
  etag: string | null;
  goals: KnowledgeSummary[] | null;
  missesLeft: number;
};

const POLL_MS = 2000;
const KNOWLEDGE_RETRY_POLLS = 30;
/** The runs whose restart line the human dismissed, `restartDismissKey`s in
 * `localStorage`. A dismissal keys on the epoch, so it dies with the run it
 * answers. A proposal has no dismissal (round 11): the page holds no
 * action, so a proposal counts until the goal's next round. */
const RESTART_DISMISSED_KEY = "kitterm.sessions.restart-dismissed";
/** The brand at the band's left. */
const BRAND = "kitterm";

const settings = loadSettings();
const activeTheme = findThemeById(settings.themeId);
applyThemeTokens(activeTheme.colors, {
  accent: activeTheme.accent,
  // Same font the terminal is using, so command text on this page matches
  // what it looks like in a session.
  fontFamily: resolveFontFamily(settings.fontId, settings.localFontFamily),
});

const root = document.getElementById("sessions");

let lastSignature = "";
let sessions: SessionRow[] = [];
let projects: ProjectSummary[] = [];
let approvals: Approval[] = [];
let archives: ArchivedRow[] = [];
/** One request at a time: a response slower than the poll interval must not
 * overlap the next tick, or an older snapshot could repaint over a newer one. */
let inFlight = false;
/** The summary requests run after the fleet painted; never two batches. */
let knowledgeInFlight = false;
/** Polls that failed in a row. One is a blip and keeps the last snapshot on
 * the page; the second replaces the page with the error. */
let failedPolls = 0;
/** This client's token is watch-only (the daemon 403s the profiles route for
 * it). A watch client cannot subscribe to push, so the switch is hidden
 * rather than shown and refused. */
let watchOnly = false;
/** The folds the user opened, by key; a rebuild keeps them. */
const foldsOpen = new Set<string>();
/** The projects and goals whose triangle the reader clicked, by the tree
 * line's key (`visibleLines`, `isOpen`); a rebuild keeps them. Every row
 * starts open, as the frame draws it, but a done goal inside the `N done`
 * fold, which starts closed; a key here flips its line's default. */
const toggledRows = new Set<string>();
/** The knowledge summary of each registered project, by id, with the ETag
 * the daemon gave it: an unchanged package answers 304 and repaints nothing. */
const knowledge = new Map<string, KnowledgeEntry>();

let restartDismissed: Set<string> = loadDismissed(RESTART_DISMISSED_KEY);
/** The last `daemon.started` the event feed carried: the run's epoch and the
 * previous run's summary on it. Null until the feed answers, and on a daemon
 * whose ring no longer holds the event. */
let started: DaemonStarted | null = null;
/** The daily rollup for the chosen range (`GET /api/usage/daily`), or null
 * when the daemon refused or has no route: a watch token sees no numbers. */
let usage: UsageDaily | null = null;
/** The reader's mode and span, kept across loads like the dismissals. */
const USAGE_KEY = "kitterm.sessions.usage";
let usageChoice: UsageChoice = readUsageChoice(readStorage(USAGE_KEY));
/** The range last asked for and when, so the rollup, which refreshes every
 * five minutes, is asked every `USAGE_REFRESH_MS` and at once on a toggle
 * rather than on every 2 s poll: a 90-day answer is tens of kilobytes. */
let usageAsked = "";
let usageAskedAt = 0;
const USAGE_REFRESH_MS = 30_000;
/** What the repositories' own history delivered over the same range
 * (`GET /api/yield`), asked beside the rollup; null when the daemon has
 * no route or refused. */
let yieldReport: YieldReport | null = null;
/** The `WHERE` panel's grouping, kept across loads like the usage choice. */
const WHERE_KEY = "kitterm.sessions.where";
let whereGrouping: WhereGrouping = readWhereGrouping(readStorage(WHERE_KEY));
/** The newest quota reading the daemon holds (`GET /api/usage/limits`), or
 * null when the route did not answer: a daemon too old to have it, or a
 * watch token, which it refuses. */
let limits: UsageLimits | null = null;

/** One key of `localStorage`, or null where storage is blocked or empty. */
function readStorage(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function setUsageChoice(change: Partial<UsageChoice>): void {
  usageChoice = { ...usageChoice, ...change };
  try {
    localStorage.setItem(USAGE_KEY, JSON.stringify(usageChoice));
  } catch {
    // Storage blocked: the choice lives for this page only.
  }
  // A new span is a new range: ask the route now, then repaint.
  usageAsked = "";
  lastSignature = "";
  void fetchUsage(Date.now()).then(render);
}

/** Ask the route for the chosen range when the range changed or the last
 * answer is `USAGE_REFRESH_MS` old. A 403 (watch), a 404 (old daemon) or a
 * 503 (no rollup) leaves `usage` null, so the panel and every heading's
 * number stay off the page rather than on it as zeros. */
async function fetchUsage(now: number): Promise<void> {
  const { from, to } = usageRange(usageChoice.span, now);
  const query = `from=${from}&to=${to}`;
  if (query === usageAsked && now - usageAskedAt < USAGE_REFRESH_MS) return;
  usageAsked = query;
  usageAskedAt = now;
  try {
    const headers = { accept: "application/json" };
    const [res, yielded] = await Promise.all([
      fetch(`/api/usage/daily?${query}`, { headers }),
      fetch(`/api/yield?${query}`, { headers }),
    ]);
    usage = res.ok ? ((await res.json()) as UsageDaily) : null;
    yieldReport = yielded.ok ? ((await yielded.json()) as YieldReport) : null;
  } catch {
    // A failed request keeps the last answer; the next poll asks again.
    usageAsked = "";
  }
}

/** The days every figure on the page counts over: the range the rollup
 * answered for the toggles' span, or, before it answers or on a daemon
 * that refuses it, the same span counted back from today on this clock. */
function chosenRange(now: number): DayRange {
  return usage?.ok ? { from: usage.from, to: usage.to } : usageRange(usageChoice.span, now);
}

function setWhereGrouping(grouping: WhereGrouping): void {
  whereGrouping = grouping;
  try {
    localStorage.setItem(WHERE_KEY, grouping);
  } catch {
    // Storage blocked: the choice lives for this page only.
  }
  lastSignature = "";
  render();
}

function loadDismissed(storageKey: string): Set<string> {
  try {
    const parsed = JSON.parse(localStorage.getItem(storageKey) ?? "[]") as unknown;
    return new Set(Array.isArray(parsed) ? parsed.filter((k): k is string => typeof k === "string") : []);
  } catch {
    return new Set();
  }
}

function saveDismissed(storageKey: string, keys: Set<string>): void {
  try {
    localStorage.setItem(storageKey, JSON.stringify([...keys]));
  } catch {
    // Storage blocked: the dismissal holds for this page life.
  }
}

function dismissRestart(key: string): void {
  restartDismissed.add(key);
  saveDismissed(RESTART_DISMISSED_KEY, restartDismissed);
  render();
}

/** The profiles route answers 403 to a watch token, which is how the page
 * learns it may not act (the push switch); the profiles themselves are
 * not offered, because the page starts no shell. */
async function fetchProfiles(): Promise<void> {
  try {
    const res = await fetch("/api/profiles", { headers: { accept: "application/json" } });
    if (res.status === 403) {
      watchOnly = true;
      lastSignature = "";
    }
  } catch {
    // No answer is a fine state; the next poll paints what it can.
  }
}

async function poll(): Promise<void> {
  if (inFlight || document.hidden) return;
  inFlight = true;
  try {
    const headers = { accept: "application/json" };
    const [sessionsRes, projectsRes, approvalsRes, archivesRes, limitsRes] = await Promise.all([
      fetch("/api/sessions", { headers }),
      fetch("/api/projects", { headers }),
      fetch("/api/approvals", { headers }),
      fetch("/api/archives", { headers }),
      fetch("/api/usage/limits", { headers }),
    ]);
    if (!sessionsRes.ok) throw new Error(String(sessionsRes.status));
    const data = (await sessionsRes.json()) as { ok: boolean; sessions: SessionRow[] };
    // A daemon too old to know projects, approvals, or archives is not an
    // error; it has none. Watch clients can read all four: seeing what an
    // agent is about to do is observation. They get no buttons.
    projects = projectsRes.ok
      ? (((await projectsRes.json()) as { projects?: ProjectSummary[] }).projects ?? [])
      : [];
    approvals = approvalsRes.ok
      ? (((await approvalsRes.json()) as { approvals?: Approval[] }).approvals ?? [])
      : [];
    archives = archivesRes.ok
      ? (((await archivesRes.json()) as { archives?: ArchivedRow[] }).archives ?? [])
      : [];
    // The quota is the account's accounting: full grade only, so a watch
    // client's 403 leaves the panel off the page rather than on it empty.
    limits = limitsRes.ok ? ((await limitsRes.json()) as UsageLimits) : null;
    sessions = data.sessions ?? [];
    await fetchUsage(Date.now());
    failedPolls = 0;
    render();
  } catch {
    failedPolls += 1;
    if (failedPolls >= 2 || !skeletonMounted) renderError();
    return;
  } finally {
    inFlight = false;
  }
  // The summaries come after the fleet has painted, bounded by the poll
  // interval each and outside `inFlight`, so a package on a stalled disk
  // costs one section and never the sessions or the approvals.
  if (knowledgeInFlight) return;
  knowledgeInFlight = true;
  try {
    await fetchKnowledge();
    render();
  } finally {
    knowledgeInFlight = false;
  }
}

/** One summary request per registered project with a knowledge directory,
 * conditional on the ETag from the last answer and aborted after `POLL_MS`.
 * A project the daemon answered 404 for is asked again every
 * `KNOWLEDGE_RETRY_POLLS` polls. A failed or aborted request keeps the last
 * summary; the next poll asks again. */
async function fetchKnowledge(): Promise<void> {
  const wanted = projects.filter((p) => p.registered && p.knowledge);
  const ids = new Set(wanted.map((p) => p.id));
  for (const id of knowledge.keys()) if (!ids.has(id)) knowledge.delete(id);
  await Promise.all(
    wanted.map(async (project) => {
      const entry = knowledge.get(project.id);
      if (entry && entry.goals === null && entry.missesLeft > 0) {
        entry.missesLeft -= 1;
        return;
      }
      try {
        const headers: Record<string, string> = { accept: "application/json" };
        if (entry?.etag) headers["if-none-match"] = entry.etag;
        const res = await fetch(`/api/projects/${encodeURIComponent(project.id)}/knowledge`, {
          headers,
          signal: AbortSignal.timeout(POLL_MS),
        });
        if (res.status === 304) return;
        if (res.status === 404) {
          knowledge.set(project.id, { etag: null, goals: null, missesLeft: KNOWLEDGE_RETRY_POLLS });
          return;
        }
        if (!res.ok) return;
        const answer = (await res.json()) as KnowledgeAnswer;
        knowledge.set(project.id, {
          etag: res.headers.get("etag"),
          goals: knowledgeGoals(answer),
          missesLeft: 0,
        });
      } catch {
        // Keep what the page shows, on a timeout too; the next poll asks again.
      }
    }),
  );
}

/** The goal summaries of one answer, each carrying the project's id, in
 * the daemon's order. */
function knowledgeGoals(answer: KnowledgeAnswer): KnowledgeSummary[] {
  return (answer.goals ?? []).map((goal) => ({ ...goal, project: answer.project }));
}

/** Every goal of every project with a package, one entry each in the
 * projects' then the route's order, for the proposed items. */
function knowledgeEntries(): { project: ProjectRef; summary: KnowledgeSummary }[] {
  const entries: { project: ProjectRef; summary: KnowledgeSummary }[] = [];
  for (const project of projects) {
    for (const summary of knowledge.get(project.id)?.goals ?? []) entries.push({ project, summary });
  }
  return entries;
}

// --- layout skeleton --------------------------------------------------------
// The page has fixed regions. Each poll replaces the children of the ones
// that changed.

/** The band: the brand, then four counts in one fixed-height row (`band`).
 * Built once; `paintBand` replaces its cells when they change. */
const bandBlock = document.createElement("section");
bandBlock.className = "band";
bandBlock.setAttribute("aria-label", "Fleet");
const bandCells = document.createElement("div");
bandCells.className = "band-cells";
let bandPainted = "";
/** A visually hidden polite announcement of how many items need the human.
 * The band's cell repaints too often to be a live region. */
const announce = document.createElement("p");
announce.className = "sr-only";
announce.setAttribute("aria-live", "polite");
let announcedCount = -1;
/** One line above the panels when the previous run died without recording
 * a reason (`restartNotice`). It paints once per run and its text is fixed,
 * so unlike the band it can be a live region; `paintRestart` only touches
 * it when the text changes, so a 2 s repaint never announces it twice. */
const restartLine = document.createElement("p");
restartLine.className = "restart";
restartLine.hidden = true;
restartLine.setAttribute("role", "status");
/** The text on the line right now, so an unchanged line is left alone. */
let restartPainted = "";
/** The push line in the folds: one switch that subscribes this device to
 * the daemon's notifications, and the reason it cannot when it cannot
 * (`pushToggle`). Hidden for a watch client. Built once; `paintPush` only
 * touches it when the toggle changes. */
const pushLine = document.createElement("p");
pushLine.className = "push";
pushLine.hidden = true;
/** The toggle on the line right now, so an unchanged one is left alone. */
let pushPainted = "";
/** The panels between the band and the tree (`design-foundation.md`, "The
 * panels"): each a label in an 84 px gutter and its content. Built once;
 * each `paint*` replaces its content when its model changes. */
function panelBlock(name: string, label: string): HTMLElement {
  const block = document.createElement("section");
  block.className = `panel ${name}`;
  block.hidden = true;
  block.setAttribute("aria-label", label);
  return block;
}
const usageBlock = panelBlock("usage", "Usage");
const quotaBlock = panelBlock("quota", "Quota");
const modelsBlock = panelBlock("models", "MODELS");
/** The one divider in the stack, between MODELS and VALUE (the frames). */
const panelDivider = document.createElement("hr");
panelDivider.className = "panel-divider";
const valueBlock = panelBlock("value", "VALUE");
const whereBlock = panelBlock("where", "WHERE");
const leaksBlock = panelBlock("leaks", "LEAKS");
let usagePainted = "";
let quotaPainted = "";
let valuePainted = "";
let wherePainted = "";
let modelsPainted = "";
let leaksPainted = "";
/** The tree's header: `SESSIONS` in the gutter, then the whole state
 * vocabulary, each mark beside the bracketed word it always appears with,
 * so a reader never has to infer a mark (`design-foundation.md`,
 * Hierarchy). The working mark here stands still; only a line whose agent
 * holds the tty turns. */
const treeHead = document.createElement("div");
treeHead.className = "tree-head";
function treeLegend(): Node[] {
  const keys = document.createElement("div");
  keys.className = "tree-keys";
  for (const entry of VOCABULARY) {
    const key = document.createElement("span");
    key.className = "tree-key";
    key.append(mark(entry.family, true), span(`tag-state ${entry.family}`, entry.tag));
    keys.append(key);
  }
  return [span("tree-label", "SESSIONS"), keys];
}
/** The tree itself: one section per workspace or lone project, each a
 * list of lines. */
const treeBlock = document.createElement("div");
treeBlock.className = "tree";
/** The folds at the foot: the archives, the idle shells, the push switch. */
const foldsBlock = document.createElement("div");
foldsBlock.className = "folds";
let skeletonMounted = false;

function mountSkeleton(): void {
  if (!root || skeletonMounted) return;
  skeletonMounted = true;
  treeHead.replaceChildren(...treeLegend());
  root.replaceChildren(
    announce, bandBlock, restartLine, usageBlock, quotaBlock, modelsBlock,
    panelDivider, valueBlock, whereBlock, leaksBlock, treeHead, treeBlock, foldsBlock,
  );
}

function render(): void {
  if (!root) return;
  // Skip DOM churn when nothing changed: this runs every 2 s. `lastOutputAt`
  // and `agent.at` tick on every PTY read, so they are out of the signature;
  // the sorted order of ids is in it, so a row that moved still repaints.
  const rendered = sessions.map(({ lastOutputAt: _t, agent, ...rest }) => ({
    ...rest,
    agent: agent ? { status: agent.status, message: agent.message } : undefined,
  }));
  const now = Date.now();
  // The span a line prints moves once a minute at most, so it is in; so
  // is the tree's order.
  const built = tree({ rows: sessions, projects, goalsOf: (id) => knowledge.get(id)?.goals, approvals, proposed: [], usage, now });
  const shape = built.sections.map((s) => s.lines.map((l) => [l.key, l.facts.map((f) => f.text)]));
  // The quota's text moves once a minute at most, like a line's span; the
  // usage panel's numbers when the rollup refreshes.
  const quota = quotaPanel(limits, now);
  const panel = usagePanel(usage, usageChoice, now);
  const signature = JSON.stringify([
    rendered,
    shape,
    projects,
    approvals.map((a) => a.id),
    archives.map((a) => a.id),
    [...knowledge].map(([id, entry]) => [id, entry.etag, entry.goals === null]),
    [...restartDismissed],
    [...toggledRows],
    started,
    watchOnly,
    quota,
    panel,
    yieldReport,
    whereGrouping,
  ]);
  if (signature === lastSignature) return;
  lastSignature = signature;
  paint();
}

/** Paint from the current snapshot. Called by `render` when the snapshot
 * changed.
 *
 * Every control carries a `data-focus` key (a toggle, a fold, a triangle,
 * a link), so the control that had focus before the regions were rebuilt
 * gets it back by key afterwards. Without this a poll that repainted while
 * a keyboard user sat on a toggle sent focus to `body`. */
function paint(): void {
  if (!root) return;
  mountSkeleton();
  const active = document.activeElement;
  const focusKey = active instanceof HTMLElement ? active.dataset.focus : undefined;
  const proposed = proposedItems(knowledgeEntries(), new Set());
  const items: NeedsItem[] = withProposed(attention(sessions, approvals), proposed);
  const now = Date.now();
  const cells = band(sessions, items, usage, usageChoice, limits, now);

  // Title badge: how many items want the human right now, so a phone's tab
  // or home-screen label says "come back" without a push notification. The
  // band's own count: a failed session counts, because no agent moves it.
  const count = cells.needs;
  document.title = count > 0 ? `(${count}) kitterm — sessions` : "kitterm — sessions";
  if (count !== announcedCount) {
    announcedCount = count;
    announce.textContent = needsYouMessage(count);
  }

  paintBand(cells);
  paintRestart();
  paintUsage(usageHead(usage, usageChoice), usagePanel(usage, usageChoice, now));
  paintQuota(quotaPanel(limits, now));
  const goals = knowledgeEntries();
  // Every figure follows the one range (round 13): the rollup and the
  // yield were asked for it, the tree reads it off the rollup, and the
  // round records are filtered to it here.
  const range = chosenRange(now);
  paintValue(valuePanel(usage, yieldReport, usageChoice.span));
  paintWhere(wherePanel(whereGrouping, { report: usage, yield: yieldReport, projects, goals, range }));
  paintModels(modelsPanel(usage));
  paintLeaks(leakLines(usage, goals, range));
  // Every session is a line once: in the tree, or in the idle fold.
  const built = tree({ rows: sessions, projects, goalsOf: (id) => knowledge.get(id)?.goals, approvals, proposed, usage, now });
  if (built.sections.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = watchOnly ? "No live sessions to watch." : "No live sessions. Open a shell to start one.";
    treeBlock.replaceChildren(empty);
  } else {
    treeBlock.replaceChildren(...built.sections.map(sectionElement));
  }
  paintFolds(built.idle);
  paintPush();
  // The first marked line, in the page's own order, is where the band's
  // "need you" cell lands. One id, set after the tree is built, so the
  // cell's link is a plain fragment.
  treeBlock.querySelector("[data-needs]")?.setAttribute("id", NEEDS_YOU_ID);
  fitLines();
  syncSpinner();
  if (focusKey) restoreFocus(focusKey);
}

// --- a fact that does not fit drops -------------------------------------------
//
// The tree's facts sit in fixed columns and never drop; the one line with a
// fact that does is an approval's, whose arguments are cut whole when the
// line is too narrow for them. CSS cannot hide a flex item that does not
// fit without cutting it, so the page measures: with every fact shown and
// every cell at its content width (`.measure`), how far the line's cells
// run past its content edge is what the facts must give back, and
// `keptFacts` says how many stay. Facts carry `data-drop`, their place in
// the drop order (0 first); the name carries `data-name`. Two passes over
// the page, one read and one write, so the layout runs twice, not once per
// line.

/** One measured line: its facts in drop order and what they must free. */
type Fit = { facts: HTMLElement[]; widths: number[]; need: number; gap: number };

function fitLines(): void {
  if (!root) return;
  const lines = [...root.querySelectorAll<HTMLElement>(".line")].filter((line) => line.querySelector("[data-drop]") !== null);
  if (lines.length === 0 || typeof lines[0].getBoundingClientRect !== "function") return;
  // Show every fact and let nothing shrink, so the overflow is the truth.
  for (const line of lines) {
    line.classList.add("measure");
    for (const fact of line.querySelectorAll<HTMLElement>("[data-drop]")) fact.hidden = false;
  }
  const fits: Fit[] = lines.map((line) => {
    const facts = [...line.querySelectorAll<HTMLElement>("[data-drop]")].sort(
      (a, b) => Number(a.dataset.drop) - Number(b.dataset.drop),
    );
    // The content edge: a cell past it is a cell the line has no room for.
    const edge = line.getBoundingClientRect().right - (Number.parseFloat(getComputedStyle(line).paddingRight) || 0);
    let right = edge;
    for (const cell of line.querySelectorAll<HTMLElement>("*")) right = Math.max(right, cell.getBoundingClientRect().right);
    const gap = Number.parseFloat(getComputedStyle(line).columnGap) || 0;
    return { facts, widths: facts.map((f) => f.getBoundingClientRect().width), need: right - edge, gap };
  });
  lines.forEach((line, i) => {
    line.classList.remove("measure");
    const { facts, widths, need, gap } = fits[i];
    const kept = keptFacts(widths, need, gap);
    facts.forEach((fact, j) => {
      fact.hidden = j < facts.length - kept;
    });
  });
}

function restoreFocus(key: string): void {
  const target = root?.querySelector<HTMLElement>(`[data-focus="${CSS.escape(key)}"]`);
  // The control is gone when its row was ended; focus then stays where the
  // browser put it.
  target?.focus({ preventScroll: true });
}

/** Show, hide, or leave the restart line. The line is rebuilt only when its
 * text changes, so the live region announces one restart once, and the focus
 * a keyboard user has on Dismiss survives every poll between the two taps. */
function paintRestart(): void {
  const item = restartNotice(started, restartDismissed, pastTime, Date.now());
  const text = item?.text ?? "";
  if (text === restartPainted) return;
  restartPainted = text;
  restartLine.hidden = item === null;
  restartLine.replaceChildren(...(item === null ? [] : [restartContent(item.text, item.key)]));
}

function restartContent(text: string, key: string): DocumentFragment {
  const fragment = document.createDocumentFragment();
  const span = document.createElement("span");
  span.textContent = text;
  const dismiss = button("Dismiss", "quiet", () => dismissRestart(key));
  dismiss.dataset.focus = focusKey("dismiss", "restart", key);
  dismiss.setAttribute("aria-label", restartDismissName());
  fragment.append(mark("failed"), span, dismiss);
  return fragment;
}

// --- the panels ---------------------------------------------------------------

/** The label in a panel's gutter, a heading so a reader who moves by
 * heading finds the panel. */
function panelLabel(text: string, title?: string): HTMLElement {
  const h = document.createElement("h2");
  h.className = "panel-label";
  h.textContent = text;
  if (title) h.title = title;
  return h;
}

/** One note line under a panel's content, in a long form and a short one
 * the phone prints in its place. */
function noteLine(long: string, short: string = long): HTMLElement {
  const p = document.createElement("p");
  p.className = "panel-note";
  p.append(span("note-long", long), span("note-short", short));
  return p;
}

/** Show, hide, or leave one panel; rebuilt only when its model changes,
 * so a toggle a keyboard user sits on survives the polls. */
function paintPanel(block: HTMLElement, painted: string, model: unknown, content: () => Node[]): string {
  const signature = JSON.stringify(model ?? null);
  if (signature === painted) return painted;
  const empty = model === null;
  block.hidden = empty;
  block.replaceChildren(...(empty ? [] : content()));
  return signature;
}

/**
 * `USAGE`: the headline row — the amount at the headline size, the tokens
 * and the model hours beside it, the span the phone prints in their place,
 * and the two toggle groups at the right — then the chart, its axis, and
 * the apportioned note. The chart is one bar per day in an SVG,
 * `currentColor` on the body, so it adds no colour pair; a silent day is
 * a gap. It is hidden from a screen reader behind one sentence
 * (`usageChartName`), and each bar carries its day and amount as a
 * tooltip. A toggle prints `[ ]`/`[x]` like the push switch and is a radio
 * to a screen reader. The rollup's age rides on the label's tooltip and
 * the long note on the note's.
 */
function paintUsage(head: UsageHead | null, panel: UsagePanel | null): void {
  const model = head && panel ? { head, panel } : null;
  usagePainted = paintPanel(usageBlock, usagePainted, model, () => {
    const row = document.createElement("div");
    row.className = "usage-head";
    const amount = span("usage-amount", head!.amount);
    amount.title = head!.title;
    row.append(amount);
    for (const fact of head!.facts) row.append(span("usage-fact", fact));
    row.append(span("usage-span", head!.span));
    const toggles = document.createElement("div");
    toggles.className = "usage-toggle-groups";
    toggles.append(usageToggles("mode", panel!), usageToggles("span", panel!));
    row.append(toggles);

    const chart = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    chart.setAttribute("class", "usage-chart");
    chart.setAttribute("role", "img");
    chart.setAttribute("aria-label", usageChartName(panel!));
    chart.setAttribute("preserveAspectRatio", "none");
    const n = Math.max(1, panel!.series.length);
    chart.setAttribute("viewBox", `0 0 ${n} 100`);
    const top = panel!.peak?.value ?? 0;
    panel!.series.forEach((value, i) => {
      if (value <= 0 || top <= 0) return;
      const rect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
      const height = Math.max(1, (value / top) * 100);
      rect.setAttribute("x", `${i + 0.1}`);
      rect.setAttribute("width", "0.8");
      rect.setAttribute("y", `${100 - height}`);
      rect.setAttribute("height", `${height}`);
      const tip = document.createElementNS("http://www.w3.org/2000/svg", "title");
      tip.textContent = `${panel!.days[i]}: ${usageAmount(value, panel!.mode)}`;
      rect.append(tip);
      chart.append(rect);
    });

    const axis = document.createElement("p");
    axis.className = "usage-axis";
    axis.append(span("usage-from", panel!.days[0] ? dayLabel(panel!.days[0]) : ""));
    if (panel!.peak) axis.append(span("usage-peak", `most ${usageAmount(panel!.peak.value, panel!.mode)} on ${dayLabel(panel!.peak.day)}`));
    axis.append(span("usage-to", panel!.days.length > 1 ? dayLabel(panel!.days[panel!.days.length - 1]) : ""));

    const body = document.createElement("div");
    body.className = "panel-body";
    body.append(row, chart, axis);
    const apportioned = apportionedNote(usage?.totals, panel!.mode);
    if (apportioned !== null) {
      const note = document.createElement("p");
      note.className = "usage-note";
      note.textContent = apportioned;
      note.title = `${panel!.note}. A session across midnight is split by each day's token share, not measured.`;
      body.append(note);
    }
    return [panelLabel("USAGE", panel!.age), body];
  });
}

/** One radio group of the panel: cost or tokens, 7, 30 or 90 days. */
function usageToggles(kind: "mode" | "span", panel: UsagePanel): HTMLElement {
  const group = document.createElement("div");
  group.className = "usage-toggles";
  group.setAttribute("role", "radiogroup");
  group.setAttribute("aria-label", kind === "mode" ? "Plot" : "Range");
  for (const toggle of kind === "mode" ? panel.modes : panel.spans) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "usage-toggle";
    b.setAttribute("role", "radio");
    b.setAttribute("aria-checked", String(toggle.checked));
    b.setAttribute("aria-label", toggle.name);
    b.textContent = toggle.label;
    b.dataset.focus = focusKey("usage", kind, toggle.label);
    b.addEventListener("click", () => {
      if (toggle.checked) return;
      if (kind === "mode") setUsageChoice({ mode: toggle.label as UsageChoice["mode"] });
      else setUsageChoice({ span: Number(toggle.label.replace(/d$/, "")) as UsageChoice["span"] });
    });
    group.append(b);
  }
  return group;
}

/**
 * `QUOTA`: one line per window — the label in the shared name column, a
 * bar of fixed width drawn as a track on the surface with its fill a mark,
 * the percentage, the reset — and the reading's age after the last line's
 * reset, `· read just now`. Under 80 % the fill wears the accent; at 80 %
 * and over the fill and the percentage wear the caution and the label and
 * the reset keep their colour (`quotaLevel`); a stale reading's fill is
 * grey, and a window past its reset draws its fill and its percentage in
 * the faint grey at the last value, with `reset · read 1d 19h ago` in the
 * reset cell. The track is hidden from a screen reader, which gets the label,
 * the number and the countdown as words. With no bar the panel's content
 * is the sentence that says why (`quotaPanel`).
 */
function paintQuota(panel: QuotaPanel | null): void {
  quotaPainted = paintPanel(quotaBlock, quotaPainted, panel, () => {
    const body = document.createElement("div");
    body.className = "panel-body";
    if (panel!.bars.length === 0) {
      const note = document.createElement("p");
      note.className = "quota-note";
      note.textContent = panel!.note;
      body.append(note);
      return [panelLabel("QUOTA"), body];
    }
    const list = document.createElement("ul");
    list.className = "quota-bars";
    panel!.bars.forEach((bar, i) => {
      const item = document.createElement("li");
      item.className = `quota-bar ${bar.state}`;
      const label = document.createElement("span");
      label.className = "quota-label";
      // `Session (5h)`: the window in parentheses goes on a phone.
      const at = bar.label.indexOf(" (");
      if (at > 0) label.append(bar.label.slice(0, at), span("quota-window", bar.label.slice(at)));
      else label.textContent = bar.label;
      const track = document.createElement("span");
      track.className = "quota-track";
      track.setAttribute("aria-hidden", "true");
      // The fill is a mark with no character: a shape whose length is the
      // share, in the accent, the caution, or the grey of a stale reading
      // and of a window past its reset.
      const fill = document.createElement("span");
      // No `running` here: `.mark.bar` is the accent, and the spinner's
      // ticker writes its frame into every `.mark.running`.
      fill.className = `mark bar quota-fill${bar.state !== "fresh" ? " idle" : bar.level === "caution" ? " caution" : ""}`;
      fill.style.width = `${Math.round(bar.fill * 1000) / 10}%`;
      track.append(fill);
      const percent = document.createElement("span");
      percent.className = "quota-percent";
      // The percentage is a run of text that carries the caution, and is
      // plain text under it; past the reset it wears the faint grey of an
      // idle mark, at the last value, like its fill.
      if (bar.state === "reset") percent.append(span("mark idle wide", bar.percent));
      else if (bar.level === "caution") percent.append(span("mark caution wide", bar.percent));
      else percent.textContent = bar.percent;
      const reset = document.createElement("span");
      reset.className = "quota-reset";
      reset.textContent = bar.reset;
      item.append(label, track, percent, reset);
      if (i === panel!.bars.length - 1) item.append(span("quota-age", `· ${panel!.note}`));
      list.append(item);
    });
    body.append(list);
    return [panelLabel("QUOTA"), body];
  });
}

/** `VALUE`: four tiles, each behind a 2 px accent rule — a count at the
 * headline size, its noun, what one unit cost — and one note that names
 * the scope, the span and the caveat. A tile with no source prints a
 * dash. */
function paintValue(panel: ValuePanel | null): void {
  valuePainted = paintPanel(valueBlock, valuePainted, panel, () => {
    const tiles = document.createElement("div");
    tiles.className = "yield";
    for (const tile of panel!.tiles) {
      const cell = document.createElement("div");
      cell.className = `yield-tile ${tile.key}`;
      cell.title = tile.title;
      // The rule is a mark, not a border: a shape in the accent.
      const rule = document.createElement("span");
      rule.className = "mark bar rule";
      rule.setAttribute("aria-hidden", "true");
      cell.append(rule, span("yield-count", tile.count), span("yield-noun", tile.noun), span("yield-noun-short", tile.shortNoun), span("yield-rate", tile.rate));
      tiles.append(cell);
    }
    const body = document.createElement("div");
    body.className = "panel-body";
    body.append(tiles, noteLine(panel!.note, panel!.shortNote));
    return [panelLabel("VALUE"), body];
  });
}

/** One cell of a split row: its class, its text, and whether it wears the
 * amber as a mark (the remainder's name and spend). */
type SplitCell = { className: string; text: string; amber?: boolean };

/** One `split` row: the name, the bar as a mark that wears the accent or
 * the amber (the bar is not text, so the owned colour may paint it), then
 * the cells, right-aligned. The remainder's name and spend are marks too:
 * text that wears the amber, as the frame draws them. */
function splitRow(key: string, name: string, remainder: boolean, fill: number, cells: SplitCell[], title: string): HTMLElement {
  const li = document.createElement("li");
  li.className = remainder ? "split-row remainder" : "split-row";
  li.dataset.key = key;
  li.title = title;
  const amberText = (className: string, text: string, amber: boolean): HTMLElement => {
    const cell = document.createElement("span");
    cell.className = className;
    if (amber) cell.append(span("mark attention wide", text));
    else cell.textContent = text;
    return cell;
  };
  li.append(amberText("split-name", name, remainder));
  const track = document.createElement("span");
  track.className = "split-bar";
  track.setAttribute("aria-hidden", "true");
  // The bar is a mark with no character: a shape whose length is the value.
  const bar = document.createElement("span");
  bar.className = remainder ? "mark bar attention" : "mark bar";
  bar.setAttribute("aria-hidden", "true");
  bar.style.width = `${Math.round(fill * 1000) / 10}%`;
  track.append(bar);
  li.append(track);
  for (const cell of cells) li.append(amberText(cell.className, cell.text, cell.amber === true));
  return li;
}

/** `WHERE`: the grouping selector with the counted checkouts' summary at
 * its right, one row per group with four columns, the note. The selector
 * is a radio group that prints `[ ]`/`[x]` like the usage toggles; the
 * grouping is kept in storage. */
function paintWhere(panel: WherePanel | null): void {
  wherePainted = paintPanel(whereBlock, wherePainted, panel, () => {
    const head = document.createElement("div");
    head.className = "panel-head";
    head.append(span("panel-by", "by"));
    const group = document.createElement("div");
    group.className = "usage-toggles";
    group.setAttribute("role", "radiogroup");
    group.setAttribute("aria-label", "Group the spend by");
    for (const toggle of panel!.toggles) {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "panel-toggle";
      b.setAttribute("role", "radio");
      b.setAttribute("aria-checked", String(toggle.checked));
      b.setAttribute("aria-label", toggle.name);
      b.textContent = toggle.label;
      b.dataset.focus = focusKey("where", toggle.label);
      b.addEventListener("click", () => {
        if (!toggle.checked) setWhereGrouping(toggle.label);
      });
      group.append(b);
    }
    head.append(group);
    if (panel!.summary !== null) head.append(span("panel-summary", panel!.summary));
    const list = document.createElement("ul");
    list.className = "split";
    for (const row of panel!.rows) {
      list.append(splitRow(row.key, row.name, row.remainder, row.fill, [
        { className: "split-spend", text: row.spend, amber: row.remainder },
        { className: "split-count", text: row.count },
        { className: "split-units", text: row.units },
        { className: "split-rate", text: row.rate },
      ], row.title));
    }
    const body = document.createElement("div");
    body.className = "panel-body";
    body.append(head, list, noteLine(panel!.note));
    return [panelLabel("WHERE"), body];
  });
}

/** `MODELS`: one bar per named model and one for the rest summed, scaled
 * to the longest, with the spend and the session count; the phone prints
 * the spend in whole dollars and no count. */
function paintModels(panel: ModelsPanel | null): void {
  modelsPainted = paintPanel(modelsBlock, modelsPainted, panel, () => {
    const list = document.createElement("ul");
    list.className = "split";
    for (const row of panel!.rows) {
      list.append(splitRow(row.key, row.name, false, row.fill, [
        { className: "split-spend", text: row.spend },
        { className: "split-short", text: row.short },
        { className: "split-units", text: row.sessions },
      ], row.title));
    }
    const body = document.createElement("div");
    body.className = "panel-body";
    body.append(list);
    if (panel!.note) body.append(noteLine(panel!.note));
    return [panelLabel("MODELS"), body];
  });
}

/** `LEAKS`: two marked lines. */
function paintLeaks(lines: LeakLine[]): void {
  const model = lines.length === 0 ? null : lines;
  leaksPainted = paintPanel(leaksBlock, leaksPainted, model, () => {
    const list = document.createElement("ul");
    list.className = "leak-lines";
    for (const line of model!) {
      const li = document.createElement("li");
      li.className = `leak-line ${line.key}`;
      li.title = line.title;
      li.append(mark(line.mark), span("leak-text", line.text));
      list.append(li);
    }
    const body = document.createElement("div");
    body.className = "panel-body";
    body.append(list);
    return [panelLabel("LEAKS"), body];
  });
}

// --- push notifications -----------------------------------------------------

/** What the page knows about push, less `watchOnly`, which `fetchProfiles`
 * owns and `paintPush` reads at paint time. */
let pushFacts: Omit<PushFacts, "watchOnly"> = {
  support: "ok",
  permission: "default",
  subscribed: false,
  busy: false,
  error: null,
};

function setPush(change: Partial<Omit<PushFacts, "watchOnly">>): void {
  pushFacts = { ...pushFacts, ...change };
  paintPush();
}

/** Whether this page can subscribe at all. An insecure origin is reported
 * before a missing API, because `navigator.serviceWorker` is absent on
 * http and the fix there is the origin, not the browser. */
function pushSupport(): PushSupport {
  if (!window.isSecureContext) return "insecure";
  if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
    return "unsupported";
  }
  return "ok";
}

/** The worker at `/sw.js`, registered once from this page as well as from
 * the terminal page, so a phone that only ever opens `/sessions` still has
 * one to receive the push. Scope `/`, because it is served from the root. */
let workerRegistration: Promise<ServiceWorkerRegistration> | null = null;
function registerWorker(): Promise<ServiceWorkerRegistration> {
  if (!workerRegistration) {
    workerRegistration = navigator.serviceWorker.register("/sw.js").then(() => navigator.serviceWorker.ready);
  }
  return workerRegistration;
}

/** The daemon's `applicationServerKey`, or the reason it has none: a watch
 * token, or a daemon before the route. */
async function fetchServerKey(): Promise<Uint8Array<ArrayBuffer> | "watch" | "old-daemon"> {
  const res = await fetch("/api/push/vapid", { headers: { accept: "application/json" } });
  if (res.status === 403) return "watch";
  if (res.status === 404) return "old-daemon";
  if (!res.ok) throw new Error(`the daemon answered ${res.status} for its key`);
  const data = (await res.json()) as { ok: boolean; publicKey?: string };
  if (typeof data.publicKey !== "string" || !data.publicKey) throw new Error("the daemon sent no key");
  return applicationServerKey(data.publicKey);
}

/** Hand the daemon the browser's subscription. A repeat is an update, not
 * an error (`PushSubscriptionStore.upsert`). */
async function postSubscription(subscription: PushSubscription): Promise<Response> {
  return fetch("/api/push/subscriptions", {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(subscription.toJSON()),
  });
}

function pushError(prefix: string, error: unknown): string {
  const reason = error instanceof Error ? error.message : String(error);
  return `${prefix}: ${reason}`;
}

/**
 * What the page knows on load: the support, the browser's answer, and
 * whether a subscription it already holds is one the daemon still has. The
 * page cannot know the daemon's side, so it posts the subscription it holds
 * on every load; the daemon answers 200 for a repeat.
 */
async function syncPush(): Promise<void> {
  const support = pushSupport();
  setPush({ support, permission: support === "ok" ? Notification.permission : "default" });
  if (support !== "ok" || watchOnly) return;
  try {
    const registration = await registerWorker();
    if (Notification.permission !== "granted") return;
    const subscription = await registration.pushManager.getSubscription();
    if (!subscription) return;
    const res = await postSubscription(subscription);
    if (res.status === 403) {
      watchOnly = true;
      lastSignature = "";
      render();
      return;
    }
    if (res.status === 404) {
      setPush({ support: "old-daemon" });
      return;
    }
    setPush({ subscribed: res.ok, error: res.ok ? null : `The daemon answered ${res.status} for the subscription` });
  } catch (error) {
    setPush({ error: pushError("Could not check notifications", error) });
  }
}

/**
 * Ask, subscribe, and tell the daemon. The permission request goes first,
 * before any await, because the browser only honours it inside the tap.
 * A subscription bound to another key than the daemon's, one left over
 * from a replaced `vapid.json`, is dropped and made again, because the push
 * service would answer 403 to every message signed with the new pair.
 */
async function enablePush(): Promise<void> {
  setPush({ busy: true, error: null });
  try {
    const permission = await Notification.requestPermission();
    setPush({ permission });
    if (permission !== "granted") return;
    const registration = await registerWorker();
    const key = await fetchServerKey();
    if (key === "watch") {
      watchOnly = true;
      lastSignature = "";
      render();
      return;
    }
    if (key === "old-daemon") {
      setPush({ support: "old-daemon" });
      return;
    }
    let subscription = await registration.pushManager.getSubscription();
    if (subscription && !sameServerKey(subscription.options.applicationServerKey, key)) {
      await subscription.unsubscribe();
      subscription = null;
    }
    if (!subscription) {
      subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
    }
    const res = await postSubscription(subscription);
    if (!res.ok) throw new Error(`the daemon answered ${res.status} for the subscription`);
    setPush({ subscribed: true });
  } catch (error) {
    setPush({ error: pushError("Could not turn on notifications", error) });
  } finally {
    setPush({ busy: false });
  }
}

/** Tell the daemon first, while the endpoint is still known, then drop the
 * browser's subscription. A daemon that no longer has it answers 404, which
 * is the state wanted. The browser side is dropped either way: an endpoint
 * the browser gave up answers the daemon 410, and the daemon forgets it. */
async function disablePush(): Promise<void> {
  setPush({ busy: true, error: null });
  try {
    const registration = await registerWorker();
    const subscription = await registration.pushManager.getSubscription();
    if (subscription) {
      let told: Response | null = null;
      try {
        told = await fetch("/api/push/subscriptions", {
          method: "DELETE",
          headers: { "content-type": "application/json", accept: "application/json" },
          body: JSON.stringify({ endpoint: subscription.endpoint }),
        });
      } finally {
        await subscription.unsubscribe();
      }
      if (!told.ok && told.status !== 404) {
        throw new Error(`the daemon answered ${told.status} for the removal`);
      }
    }
    setPush({ subscribed: false });
  } catch (error) {
    setPush({ subscribed: false, error: pushError("Could not turn off notifications", error) });
  } finally {
    setPush({ busy: false });
  }
}

/** The switch had focus when a repaint disabled it. A disabled button
 * cannot take focus back, so the browser parks focus on `body` for the
 * busy state; the repaint that enables the switch again gives it back,
 * unless the reader has moved on to something else meanwhile. */
let pushWantsFocus = false;

/** Show, hide, or leave the push line; rebuilt only when the toggle
 * changes, and the focus a keyboard user has on the switch survives. */
function paintPush(): void {
  const toggle = pushToggle({ ...pushFacts, watchOnly });
  const signature = JSON.stringify(toggle);
  if (signature === pushPainted) return;
  pushPainted = signature;
  const active = document.activeElement;
  const hadFocus =
    (active instanceof HTMLElement && active.dataset.focus === toggle?.key) ||
    (pushWantsFocus && active === document.body);
  pushLine.hidden = toggle === null;
  pushLine.replaceChildren(...(toggle === null ? [] : [pushContent(toggle)]));
  pushWantsFocus = hadFocus && toggle !== null && !toggle.enabled;
  if (hadFocus && toggle?.enabled) restoreFocus(toggle.key);
}

function pushContent(toggle: PushToggle): DocumentFragment {
  const fragment = document.createDocumentFragment();
  const b = document.createElement("button");
  b.type = "button";
  b.className = "push-switch";
  b.setAttribute("role", "switch");
  b.setAttribute("aria-checked", String(toggle.checked));
  b.disabled = !toggle.enabled;
  b.dataset.focus = toggle.key;
  const state = document.createElement("span");
  state.className = "push-state";
  state.setAttribute("aria-hidden", "true");
  state.textContent = toggle.checked ? "on" : "off";
  b.append(toggle.label, state);
  b.addEventListener("click", (event) => {
    event.preventDefault();
    void (toggle.checked ? disablePush() : enablePush());
  });
  fragment.append(b);
  if (toggle.detail) {
    const detail = document.createElement("span");
    detail.className = "push-detail";
    detail.textContent = toggle.detail;
    fragment.append(detail);
  }
  return fragment;
}

// --- the band ---------------------------------------------------------------

/** Replace the band's cells when they change; the cells are rebuilt only
 * then, so the link a keyboard user sits on survives the polls. */
function paintBand(cells: Band): void {
  const signature = JSON.stringify(cells);
  if (signature === bandPainted) return;
  bandPainted = signature;
  bandCells.replaceChildren(...cells.cells.map((cell) => bandCell(cell, cell.key === "needs" ? cells.target : null)));
  bandBlock.replaceChildren(span("band-brand", BRAND), bandCells);
}

/** One cell: the count at the headline size, then its noun. The count of
 * the working and the need-you cells is a mark, so it wears the accent or
 * the amber. The "need you" cell is a link to the first marked line while
 * there is one; otherwise every cell is a plain span, and the band holds
 * four cells either way. */
function bandCell(cell: BandCell, target: string | null): HTMLElement {
  let el: HTMLElement;
  if (target) {
    const a = document.createElement("a");
    a.href = `#${target}`;
    a.dataset.focus = focusKey("band", cell.key);
    a.setAttribute("aria-label", `${cell.value} ${cell.noun}: go to the first`);
    el = a;
  } else {
    el = document.createElement("span");
  }
  el.className = `band-cell ${cell.key}`;
  el.title = cell.title;
  const value = document.createElement("span");
  value.className = "band-value";
  if (cell.family) value.append(span(`mark ${cell.family} wide`, cell.value));
  else value.textContent = cell.value;
  el.append(value, span("band-noun", cell.noun));
  return el;
}

// --- the tree -----------------------------------------------------------------

/** One section: a workspace with its projects, or a lone project. */
function sectionElement(section: TreeSection<SessionRow>): HTMLElement {
  const el = document.createElement("section");
  el.className = "tree-section";
  el.setAttribute("aria-label", section.label);
  el.append(...visibleLines(section.lines, toggledRows).map(lineElement));
  return el;
}

/** The `.main` cell of a line: the name, the state word, then the facts in
 * their columns (`data-col`), the phone's one fact marked `data-narrow`. */
function lineMain(line: TreeLine<SessionRow>, name: HTMLElement): HTMLElement {
  const main = document.createElement("div");
  main.className = "main";
  name.classList.add("line-name");
  name.dataset.name = "";
  if (line.title) name.title = line.title;
  main.append(name);
  if (line.state) main.append(span(`state ${line.state.family}`, line.state.tag));
  for (const fact of line.facts) {
    const cell = span(fact.kind, fact.text);
    cell.dataset.col = String(fact.column);
    if (fact.narrow) cell.dataset.narrow = "";
    if (fact.title) cell.title = fact.title;
    main.append(cell);
  }
  return main;
}

/** The shell of a line: the mark and the body, with the depth on the
 * element for the indent. Five cells and no actions cell (the anatomy
 * frame, round 11). */
function lineShell(line: TreeLine<SessionRow>, className: string, markEl: HTMLElement, body: HTMLElement): HTMLElement {
  const el = document.createElement("div");
  el.className = `line ${className}`;
  el.style.setProperty("--depth", String(line.depth));
  el.append(markEl, body);
  return el;
}

/** A blank mark: the cell is there, so the names align; nothing is drawn. */
function blankMark(): HTMLElement {
  const el = document.createElement("span");
  el.className = "mark blank";
  el.setAttribute("aria-hidden", "true");
  return el;
}

/** The disclosure triangle: `▼` open, `▶` closed, in the faint grey,
 * never a state (the Components frame, "Row marks"). */
function disclosureGlyph(open: boolean): string {
  return open ? "▼" : "▶";
}

/** A fold's disclosure glyph, on its summary line. */
function disclosure(open: boolean): HTMLElement {
  const el = document.createElement("span");
  el.className = "mark disclosure";
  el.setAttribute("aria-hidden", "true");
  el.textContent = disclosureGlyph(open);
  return el;
}

/** A project's or a goal's triangle: a button that folds what sits under
 * the line (`visibleLines`) and opens it again, kept in `toggledRows`
 * across repaints. Not an action: it moves nothing but the page. */
function disclosureButton(line: Extract<TreeLine<SessionRow>, { kind: "project" | "goal" }>): HTMLElement {
  const { key, name } = line;
  const open = isOpen(line, toggledRows);
  const b = document.createElement("button");
  b.type = "button";
  b.className = "mark disclosure";
  b.textContent = disclosureGlyph(open);
  b.setAttribute("aria-expanded", String(open));
  b.setAttribute("aria-label", `${open ? "Fold" : "Open"} ${name}`);
  b.dataset.focus = `fold:${key}`;
  b.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (toggledRows.has(key)) toggledRows.delete(key);
    else toggledRows.add(key);
    lastSignature = "";
    render();
  });
  return b;
}

function lineElement(line: TreeLine<SessionRow>): HTMLElement {
  switch (line.kind) {
    case "workspace": {
      // A workspace is always open and wears no mark.
      const name = document.createElement("h2");
      name.textContent = line.name;
      return lineShell(line, "line-workspace", blankMark(), lineMain(line, name));
    }
    case "project": {
      // A heading level per depth, so a reader who moves by heading gets
      // the tree: a workspace or a lone project is an h2, a project under
      // a workspace an h3. Its mark is the triangle alone; a working agent
      // is its `1 agent` fact, not a spinner.
      const name = document.createElement(line.depth === 0 ? "h2" : "h3");
      name.textContent = line.name;
      return lineShell(line, "line-project", line.children ? disclosureButton(line) : blankMark(), lineMain(line, name));
    }
    case "goal": {
      const name = document.createElement("a");
      name.href = line.href;
      name.target = "_blank";
      name.rel = "noopener";
      name.textContent = line.name;
      name.dataset.focus = focusKey("goal", line.project.id, line.summary.slug ?? line.name);
      if (line.proposed) {
        // The name opens the record the proposals wait in; the count and
        // the decision line ride on its tooltip, and its name says so.
        const goal = goalTitle(line.summary);
        name.setAttribute("aria-label", line.proposed.record ? recordName(line.proposed.record, line.project.name, goal) : proposalsName(line.proposed.count, line.project.name, goal));
        name.title = [proposedLabel(line.proposed.count), line.proposed.decision].filter((t): t is string => t !== null).join(": ");
      }
      const el = lineShell(line, "goal-line", line.children ? disclosureButton(line) : blankMark(), lineMain(line, name));
      if (line.proposed) el.dataset.needs = "proposed";
      return el;
    }
    case "task": {
      const name = document.createElement("span");
      name.textContent = line.name;
      return lineShell(line, "line-task", mark(line.mark), lineMain(line, name));
    }
    case "session":
      return row(line);
    case "approval": {
      const wrap = document.createElement("div");
      wrap.className = "row";
      wrap.append(approvalLine(line.approval, line.depth));
      return wrap;
    }
    case "fold":
      // The done goals inside, each closed until its triangle is clicked.
      return foldElement(line.key, line.name, line.depth, () => visibleLines(line.lines, toggledRows).map(lineElement));
  }
}

/** A closed group with a count: `▶ 9 done`, `▶ Archived (61)`, `▶ 3 idle
 * shells`. Its summary is a line at `depth`; `foldsOpen` keeps it open
 * across repaints. */
function foldElement(key: string, label: string, depth: number, content: () => Node[]): HTMLElement {
  const details = document.createElement("details");
  details.className = "fold";
  details.open = foldsOpen.has(key);
  const summary = document.createElement("summary");
  summary.className = "line line-fold";
  summary.style.setProperty("--depth", String(depth));
  const glyph = disclosure(details.open);
  const main = document.createElement("div");
  main.className = "main";
  const name = span("line-name", label);
  name.dataset.name = "";
  main.append(name);
  summary.append(glyph, main);
  summary.dataset.focus = `fold:${key}`;
  details.addEventListener("toggle", () => {
    if (details.open) foldsOpen.add(key);
    else foldsOpen.delete(key);
    glyph.textContent = disclosureGlyph(details.open);
  });
  const body = document.createElement("div");
  body.className = "fold-body";
  body.append(...content());
  details.append(summary, body);
  return details;
}

/** The folds at the page's foot: the archives, the idle shells, and the
 * push switch, on one line. */
function paintFolds(idle: SessionRow[]): void {
  const nodes: Node[] = [];
  if (archives.length > 0) nodes.push(foldElement("archived", `Archived (${archives.length})`, 0, () => [archivedList(archives)]));
  if (idle.length > 0) {
    const now = Date.now();
    nodes.push(foldElement("idle", idleShellsLabel(idle.length), 0, () => idle.map((s) => {
      const family = markFamily(stateOf(s));
      return row({
        kind: "session", key: `session:${s.id}`, depth: 0, name: rowName(s), title: s.cwd,
        state: { family, tag: stateTag(s) }, facts: sessionFactColumns(rowModel(s), s.agentModel, rowLine(s, now).since),
        row: s, mark: family, needs: false, approvals: [],
      }, true);
    })));
  }
  nodes.push(pushLine);
  foldsBlock.replaceChildren(...nodes);
}

function archivedList(list: ArchivedRow[]): HTMLElement {
  const ul = document.createElement("ul");
  ul.className = "archived-list";
  for (const a of list) {
    const li = document.createElement("li");
    const name = document.createElement("span");
    name.className = "archived-name";
    name.textContent = a.name || (a.cwd ? folderOf(a.cwd) : a.id.slice(0, 8));
    const meta = document.createElement("span");
    meta.className = "archived-meta";
    const bits: string[] = [];
    if (a.project) bits.push(a.project.name);
    if (typeof a.exitCode === "number") bits.push(`exit ${a.exitCode}`);
    if (a.archivedAt) bits.push(new Date(a.archivedAt).toLocaleString());
    meta.textContent = bits.join(" · ");
    li.append(name, meta);
    ul.append(li);
  }
  return ul;
}

// --- an approval on its line ------------------------------------------------

/** One waiting tool call as a line under its session's, or alone under
 * "No project" when its session is gone: the amber mark, what it wants to
 * run, the arguments cut at the line's end with the whole summary as the
 * tooltip, how long it has waited, and the pane link when it has one. The
 * loudest thing in the tree, because an agent is stopped until it is
 * answered, and the pane is where it is answered (round 11). */
function approvalLine(approval: Approval, depth: number): HTMLElement {
  const line = document.createElement("div");
  line.className = "line line-approval";
  line.style.setProperty("--depth", String(depth));
  line.dataset.needs = "approval";
  const what = span("line-name line-approval-what", `approve ${approval.tool}`);
  what.dataset.name = "";
  line.append(mark("attention"), what);
  // The arguments are the line's one fact: whole in the title, dropped
  // when the line is too narrow for them.
  const input = span("line-approval-input", summarize(approval.input));
  input.title = summarize(approval.input);
  input.dataset.drop = "0";
  line.append(input, span("line-waited", waitedLabel(approval.waitingMs)));
  // The pane is the one way to act on it: the answer is given there.
  if (approval.session) line.append(openLink(approval.session, "Open the pane"));
  return line;
}

// --- rows -------------------------------------------------------------------

/** One session, one line: the mark, the name, the state as a bracketed
 * word, its model and how long since its output in their columns. The
 * line is the link; a pending tool call is a line of its own under it, in
 * the same row. `folded` is a row in the idle fold, which lists no
 * approval. */
function row(line: Extract<TreeLine<SessionRow>, { kind: "session" }>, folded = false): HTMLElement {
  const s = line.row;
  const wrap = document.createElement("div");
  wrap.className = "row";
  const link = document.createElement("a");
  link.href = `/?session=${encodeURIComponent(s.id)}`;
  link.className = "open";
  link.dataset.focus = `${s.id}:open`;
  const name = document.createElement("span");
  name.className = "folder";
  name.textContent = line.name;
  link.append(lineMain(line, name));
  const lineEl = lineShell(line, "row-line", mark(line.mark), link);
  wrap.append(lineEl);
  // A waiting or failed row is a marked line the band's cell can land on;
  // a pending tool call is a line of its own under the row.
  if (line.needs) wrap.dataset.needs = "row";
  if (!folded) for (const approval of line.approvals) wrap.append(approvalLine(approval, line.depth + 1));
  return wrap;
}

// --- small pieces -----------------------------------------------------------

function button(label: string, className: string, onClick: () => void): HTMLButtonElement {
  const b = document.createElement("button");
  b.type = "button";
  b.className = className;
  b.textContent = label;
  b.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    onClick();
  });
  return b;
}

function span(className: string, text: string): HTMLElement {
  const el = document.createElement("span");
  el.className = className;
  el.textContent = text;
  return el;
}

/** The one-character gutter mark of a state family (`markFamily`; an
 * approval and a proposal wear `attention`). One character in the family's
 * colour that a screen reader skips: the state's word beside it carries
 * the state. A working mark prints the spinner's current frame, and the
 * ticker keeps it turning; `rest` is a mark that stands still, the
 * vocabulary's. */
function mark(family: MarkFamily, rest = false): HTMLElement {
  const el = document.createElement("span");
  el.className = rest ? `mark ${family} rest` : `mark ${family}`;
  el.setAttribute("aria-hidden", "true");
  el.textContent = family === "running" ? workingGlyph(rest) : markGlyph(family);
  return el;
}

// --- the working mark turns ---------------------------------------------------
//
// The one thing on the page that moves (`design-foundation.md`, principle
// 4): a character cycle at `FRAME_MS`, not a CSS transition. The cycle is
// the quadrants the design draws (`QUADRANT`), and the mark rests on `◐`
// under `prefers-reduced-motion`, where the ticker does not run.

const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)";
let tick = 0;
let ticker: ReturnType<typeof setInterval> | null = null;

function reducedMotion(): boolean {
  return typeof matchMedia === "function" ? matchMedia(REDUCED_MOTION_QUERY).matches : false;
}

/** What a working mark prints now: the current frame, or the rest glyph
 * when motion is reduced or the mark is one that stands still. */
function workingGlyph(rest: boolean): string {
  return rest || reducedMotion() ? QUADRANT.rest : frameAt(QUADRANT, tick);
}

/** Start or stop the ticker to match the motion preference. Every working
 * mark on the page takes the frame on each tick; a repaint paints the
 * same frame, so the marks never disagree. */
function syncSpinner(): void {
  const run = !reducedMotion();
  if (run && ticker === null) {
    ticker = setInterval(() => {
      tick += 1;
      const frame = frameAt(QUADRANT, tick);
      for (const el of root?.querySelectorAll(".mark.running:not(.rest):not(.wide)") ?? []) el.textContent = frame;
    }, FRAME_MS);
  } else if (!run && ticker !== null) {
    clearInterval(ticker);
    ticker = null;
    for (const el of root?.querySelectorAll(".mark.running:not(.wide)") ?? []) el.textContent = workingGlyph(false);
  }
}

function openLink(id: string, text: string): HTMLAnchorElement {
  const a = document.createElement("a");
  a.className = "line-link";
  a.href = `/?session=${encodeURIComponent(id)}`;
  a.textContent = text;
  a.dataset.focus = focusKey("open", id);
  return a;
}

/** A wall-clock label for a moment that stays fixed once set, so the row's
 * text is stable between polls (a duration would go stale between repaints). */
function clockTime(epochMs: number): string {
  return new Date(epochMs).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

/** A label for a moment that can be old: the time alone when `stampFormat`
 * says the moment falls on today, else the date and the time, the convention
 * the archived list already follows. The short styles drop the seconds that
 * a bare `toLocaleString()` prints: the daemon writes the previous run's
 * clock on a heartbeat, so the seconds are false precision, and the line
 * has one line above the panels at 390 px. */
function pastTime(epochMs: number, format: StampFormat): string {
  if (format === "time") return clockTime(epochMs);
  return new Date(epochMs).toLocaleString([], { dateStyle: "short", timeStyle: "short" });
}

function renderError(): void {
  if (!root || lastSignature === "__error__") return;
  lastSignature = "__error__";
  skeletonMounted = false;
  root.replaceChildren();
  const p = document.createElement("p");
  p.className = "empty";
  p.textContent = "Can't reach the daemon.";
  root.append(p);
}

// A change in the motion preference stops or starts the mark.
if (typeof matchMedia === "function") {
  matchMedia(REDUCED_MOTION_QUERY).addEventListener("change", syncSpinner);
}
// A narrower window drops an approval's arguments; a wider one brings them back.
if (typeof addEventListener === "function") {
  let queued = false;
  addEventListener("resize", () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      fitLines();
    });
  });
}

void fetchProfiles().then(() => {
  void poll();
  void syncPush();
});
// The 2 s poll is the safety net; the event long-poll below repaints the
// instant something changes, so "needs input" surfaces without a 2 s wait.
setInterval(() => void poll(), POLL_MS);
// Hidden tabs skip polling (see poll); refresh immediately on return.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) void poll();
});

/**
 * Watch the daemon-wide event feed. One parked request replaces polling every
 * session, and any control-plane change (a status, an approval, a spawn, a
 * note) triggers an immediate repaint. A daemon too old to serve `/api/events`
 * answers 404 once and the watcher stops; the 2 s poll still covers it.
 */
/** One event of `GET /api/events`. The page reads the type and the data of
 * `daemon.started` and nothing else; the rest are a signal to repaint. */
type FeedEvent = { type?: string; data?: Record<string, string> };

/**
 * Keep the run's own `daemon.started`, the event that carries how the run
 * before this one ended. The page opens with `since=0`, so the first answer
 * replays the epoch from its head and the event is in it, unless 1024 events
 * have already pushed it out of the daemon's ring — an old daemon then simply
 * shows no line.
 *
 * The last one in the batch wins: a live upgrade appends a second
 * `daemon.started` inside the same epoch, and that one (`previous:
 * takeover`) is the truth about the process now running.
 */
function readStarted(events: FeedEvent[], epoch: string | undefined): void {
  if (epoch === undefined) return;
  for (const event of events) {
    if (event.type === "daemon.started") started = { epoch, data: event.data ?? {} };
  }
}

let eventCursor = 0;
/** The daemon's epoch from the last answer. Sent back so a cursor from before
 * a restart is answered `pruned` (and repaints) instead of silently reused. */
let eventEpoch: string | null = null;
async function watchEvents(): Promise<void> {
  for (;;) {
    if (document.hidden) {
      // Don't hold a request open in a backgrounded tab; the visibility
      // handler repaints on return and the loop resumes then.
      await new Promise((r) => setTimeout(r, POLL_MS));
      continue;
    }
    try {
      const epochParam = eventEpoch ? `&epoch=${encodeURIComponent(eventEpoch)}` : "";
      const res = await fetch(`/api/events?since=${eventCursor}&timeout=25${epochParam}`, {
        headers: { accept: "application/json" },
      });
      if (res.status === 404) return; // old daemon; the poll covers it
      if (!res.ok) throw new Error(String(res.status));
      const data = (await res.json()) as {
        next?: number;
        epoch?: string;
        pruned?: boolean;
        events?: FeedEvent[];
      };
      if (typeof data.next === "number") eventCursor = data.next;
      if (typeof data.epoch === "string") eventEpoch = data.epoch;
      readStarted(data.events ?? [], data.epoch);
      if (data.pruned || (data.events?.length ?? 0) > 0) void poll();
    } catch {
      // Network blip or daemon restart: back off, then resume the watch.
      await new Promise((r) => setTimeout(r, POLL_MS));
    }
  }
}
void watchEvents();
