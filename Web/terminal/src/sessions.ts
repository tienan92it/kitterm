import "./tokens.css";
import "./sessions.css";
import { resolveFontFamily } from "./fonts";
import { summarize, waitedLabel } from "./approval-format";
import {
  actionName,
  agentMark,
  applicationServerKey,
  approvalName,
  attention,
  bucketLabel,
  cardRecord,
  cardRows,
  costLabel,
  dayLabel,
  dismissKey,
  dismissName,
  doneLabel,
  fleetLine,
  focusKey,
  folderOf,
  headingLine,
  goalCost,
  goalTitle,
  group,
  knowledgeUrl,
  levels,
  needsYouMessage,
  NESTED_INDENT_PX,
  NO_PROJECT,
  pickForeman,
  lineProposals,
  proposalsName,
  proposedItems,
  proposedLabel,
  projectUsage,
  pushToggle,
  readUsageChoice,
  receiptStands,
  recordLabel,
  recordName,
  restartDismissName,
  replyControl,
  replyName,
  restartNotice,
  rowLine,
  rowName,
  sameServerKey,
  stateLabel,
  stateOf,
  stripWhere,
  usageAmount,
  usageChartName,
  usagePanel,
  usageRange,
  withProposed,
  workspaceHome,
  workspaceUsage,
  type Approval,
  type AttentionItem,
  type DaemonStarted,
  type GoalEntry,
  type GoalLine,
  type Heading,
  type KnowledgeAnswer,
  type KnowledgeSummary,
  type MergedState,
  type ModelRow,
  type ProfileWidth,
  type ProjectRef,
  type ProjectSection,
  type ProjectSummary,
  type LineProposals,
  type ProposedItem,
  type ReplySent,
  type PushFacts,
  type PushSupport,
  type PushToggle,
  quotaPanel,
  type QuotaPanel,
  type StampFormat,
  type UsageChoice,
  type UsageDaily,
  type UsageLimits,
  type UsagePanel,
  type WorkspaceSection,
} from "./sessions-model";
import { loadSettings } from "./settings-store";
import { applyThemeTokens } from "./theme-tokens";
import { findThemeById } from "./themes";

/**
 * The fleet view: every live shell grouped by project, what needs the human
 * first, and the actions a supervisor takes from a phone — answer, spawn,
 * archive, kill, and answer a foreman or a crew by typing a line under its
 * row, which `POST /api/sessions/<id>/input?enter=1` types into its pane
 * (`replyControl` decides when the field sends). Polls `/api/projects`, `/api/sessions`, `/api/approvals`,
 * `/api/archives` and `/api/usage/limits`, plus `/api/projects/<id>/knowledge` for each
 * registered project and `/api/usage/daily` for the chosen range, and links
 * each row back to `/?session=<id>`.
 *
 * The page reads top to bottom in the order a returning reader needs: the
 * title, what needs them (the strip), what broke (the failed items and the
 * restart line), the usage panel (the range's total at the full API rate,
 * the per-day chart, the quota bars), one line of counts, then the work in
 * three levels: a workspace, its projects, and each project's goals by
 * state (working, pending, done), each heading with what it cost and how
 * much of its input came from cache. There is no search and no filter; the
 * grouping is the navigation. The push switch sits under the sections. The
 * pure model (`sessions-model.ts`) decides what goes where; this file only
 * paints it.
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

type Profile = { name: string; command: string; cwd?: string };

/** Archived sessions: finished work whose evidence was kept. */
type ArchivedRow = {
  id: string;
  name?: string;
  cwd?: string;
  archivedAt?: number;
  exitCode?: number;
  project?: ProjectRef;
};

/** What the strip lists: the model's attention items plus a proposal that
 * waits on the human in a project's knowledge package. */
type StripItem = AttentionItem<SessionRow> | ProposedItem;

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
/** The proposals the human dismissed, `dismissKey`s in `localStorage`, so
 * a read proposal stays out of the strip and the title count across reloads
 * until the project's next round. */
const DISMISSED_KEY = "kitterm.sessions.dismissed";
/** The runs whose restart line the human dismissed, `restartDismissKey`s in
 * `localStorage` beside the proposals above: the same pattern, its own key,
 * so one list does not have to hold two kinds of entry. A dismissal keys on
 * the epoch, so it dies with the run it answers. */
const RESTART_DISMISSED_KEY = "kitterm.sessions.restart-dismissed";

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
/** Named session profiles (~/.kitterm/profiles.json), fetched once. */
let profiles: Profile[] = [];
/** This client's token is watch-only (the daemon 403s the profiles route for
 * it). Watch clients cannot start, end, or answer anything, so those buttons
 * are hidden rather than shown and refused. */
let watchOnly = false;
/** Ids being acted on right now, so a second tap cannot double-post. */
const busy = new Set<string>();
/** The archive folds the user opened, by group key; a rebuild keeps them. */
const archivedOpen = new Set<string>();
/** The last action that failed, shown until the next action. */
let notice: string | null = null;
/** The row whose action menu is open on a phone. Kept across repaints, so a
 * poll between the two taps does not close the menu under the thumb. */
let openMenu: string | null = null;
/** The line typed under each row and not yet sent, by session id. A repaint
 * rebuilds the field, so the draft lives here, like the spawn choice. */
const drafts = new Map<string, string>();
/** The last line each row sent, by session id: when, and the agent's report
 * then, so the receipt beside `[send]` knows when the agent has moved on. */
const sent = new Map<string, ReplySent>();
/** The daemon refused a send for want of `--agent-control`. The flag cannot
 * change while the daemon runs, so every reply field is held with that
 * reason from the first refusal until the daemon starts again. */
let agentControlOff = false;
/** The profile picked in each card's spawn select, by project id. A repaint
 * rebuilds the select, so the choice lives here, not in the DOM. */
const spawnProfile = new Map<string, string>();
/** The knowledge summary of each registered project, by id, with the ETag
 * the daemon gave it: an unchanged package answers 304 and repaints nothing. */
const knowledge = new Map<string, KnowledgeEntry>();

let dismissed: Set<string> = loadDismissed(DISMISSED_KEY);
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
    const res = await fetch(`/api/usage/daily?${query}`, { headers: { accept: "application/json" } });
    usage = res.ok ? ((await res.json()) as UsageDaily) : null;
  } catch {
    // A failed request keeps the last answer; the next poll asks again.
    usageAsked = "";
  }
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

function dismissProposal(key: string): void {
  dismissed.add(key);
  saveDismissed(DISMISSED_KEY, dismissed);
  render();
}

function dismissRestart(key: string): void {
  restartDismissed.add(key);
  saveDismissed(RESTART_DISMISSED_KEY, restartDismissed);
  render();
}

async function fetchProfiles(): Promise<void> {
  try {
    const res = await fetch("/api/profiles", { headers: { accept: "application/json" } });
    if (res.status === 403) {
      watchOnly = true;
      lastSignature = "";
      return;
    }
    if (!res.ok) return;
    const data = (await res.json()) as { ok: boolean; profiles?: Profile[] };
    profiles = data.profiles ?? [];
    lastSignature = "";
  } catch {
    // No profiles is a fine state; spawn offers a local shell only.
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
  // costs one card and never the sessions or the approvals. Checked by
  // hand: a registered project on an unreadable root leaves the fleet
  // painting (rounds/007.md).
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
        // Keep what the card shows, on a timeout too; the next poll asks again.
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
 * projects' then the route's order, for the strip's proposed items. */
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

const strip = document.createElement("section");
strip.className = "strip";
strip.setAttribute("aria-label", "Needs you");
const noticeLine = document.createElement("p");
noticeLine.className = "notice";
noticeLine.hidden = true;
// A failed action is announced at once; the line is built once, so the
// role is set once.
noticeLine.setAttribute("role", "alert");
/** A visually hidden polite announcement of how many items need the human.
 * The strip itself repaints too often to be a live region. */
const announce = document.createElement("p");
announce.className = "sr-only";
announce.setAttribute("aria-live", "polite");
let announcedCount = -1;
/** One line above the cards when the previous run died without recording a
 * reason (`restartNotice`). It paints once per run and its text is fixed, so
 * unlike the strip it can be a live region; `paintRestart` only touches it
 * when the text changes, so a 2 s repaint never announces it twice. */
/** The push line under the head: one switch that subscribes this device to
 * the daemon's notifications, and the reason it cannot when it cannot
 * (`pushToggle`). Hidden for a watch client. Built once; `paintPush` only
 * touches it when the toggle changes. */
const pushLine = document.createElement("p");
pushLine.className = "push";
pushLine.hidden = true;
/** The toggle on the line right now, so an unchanged one is left alone. */
let pushPainted = "";
const restartLine = document.createElement("p");
restartLine.className = "restart";
restartLine.hidden = true;
restartLine.setAttribute("role", "status");
/** The quota: one bar per window the statusline last reported, with its
 * countdown, and one line saying how old the reading is or why there is
 * none (`quotaPanel`). Above the fleet line, because it is the one number
 * that decides whether more work can start. Hidden for a watch client. */
const usageBlock = document.createElement("section");
usageBlock.className = "usage";
usageBlock.hidden = true;
usageBlock.setAttribute("aria-label", "Usage");
let usagePainted = "";
const quotaBlock = document.createElement("section");
quotaBlock.className = "quota";
quotaBlock.hidden = true;
quotaBlock.setAttribute("aria-label", "Quota");
let quotaPainted = "";
/** The text on the line right now, so an unchanged line is left alone. */
let restartPainted = "";
const cards = document.createElement("div");
cards.className = "cards";
let skeletonMounted = false;

function mountSkeleton(): void {
  if (!root || skeletonMounted) return;
  skeletonMounted = true;
  // Status first, the push switch last: it is a thing the reader does, not
  // a thing the reader came to learn.
  root.replaceChildren(header(), announce, strip, noticeLine, restartLine, usageBlock, quotaBlock, cards, pushLine);
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
  const order = group(sessions, projects).flatMap((g) => g.rows.map((r) => r.id));
  // The span a row prints moves once a minute at most, so it is in.
  const now = Date.now();
  const spans = sessions.map((s) => rowLine(s, now).since);
  // The quota's text moves once a minute at most, like a row's span; the
  // usage panel's age line too, and its numbers when the rollup refreshes.
  const quota = quotaPanel(limits, now);
  const panel = usagePanel(usage, usageChoice, now);
  const signature = JSON.stringify([
    rendered,
    order,
    spans,
    projects,
    approvals.map((a) => a.id),
    archives.map((a) => a.id),
    [...knowledge].map(([id, entry]) => [id, entry.etag, entry.goals === null]),
    [...dismissed],
    [...restartDismissed],
    started,
    watchOnly,
    profiles.map((p) => p.name),
    notice,
    agentControlOff,
    // A receipt goes when the agent reports again; that report is out of
    // `rendered`, so the receipt's standing is in.
    sessions.map((s) => receiptStands(sent.get(s.id), s)),
    quota,
    panel,
  ]);
  if (signature === lastSignature) return;
  lastSignature = signature;
  paint();
}

/** Paint from the current snapshot. Called by `render` when the snapshot
 * changed.
 *
 * Every control carries a `data-focus` key (row id and action, fold, spawn
 * control, approval button), so the control that had focus before the four
 * regions were rebuilt gets it back by key afterwards. Without this a poll
 * that repainted while a keyboard user sat on Kill sent focus to `body`. */
function paint(): void {
  if (!root) return;
  mountSkeleton();
  const active = document.activeElement;
  const focusKey = active instanceof HTMLElement ? active.dataset.focus : undefined;
  const { foreman } = pickForeman(sessions);
  const proposed = proposedItems(knowledgeEntries(), dismissed);
  const items: StripItem[] = withProposed(attention(sessions, approvals), proposed);
  // What the strip shows, the sections do not list again (`cardRows`). The
  // foreman is a row of its own project or workspace, first among them
  // (`sortInGroup`).
  const listed = cardRows(sessions, items);

  // Title badge: how many items want the human right now, so a phone's tab
  // or home-screen label says "come back" without a push notification.
  const count = items.filter((item) => item.kind !== "failed").length;
  document.title = count > 0 ? `(${count}) kitterm — sessions` : "kitterm — sessions";
  if (count !== announcedCount) {
    announcedCount = count;
    announce.textContent = needsYouMessage(count);
  }
  const badge = root.querySelector(".count")!;
  badge.textContent = String(sessions.length);
  badge.setAttribute("aria-label", `${sessions.length} sessions`);

  strip.replaceChildren(...stripContent(items, foreman !== null));
  noticeLine.hidden = notice === null;
  noticeLine.replaceChildren(...(notice === null ? [] : [noticeContent(notice)]));
  paintRestart();
  paintUsage(usagePanel(usage, usageChoice, Date.now()));
  paintQuota(quotaPanel(limits, Date.now()));
  paintPush();
  cards.replaceChildren(fleetCounts(listed), ...sectionList(listed, sessions, proposed));
  if (focusKey) restoreFocus(focusKey);
}

function restoreFocus(key: string): void {
  const target = root?.querySelector<HTMLElement>(`[data-focus="${CSS.escape(key)}"]`);
  // The control is gone when its row was ended; focus then stays where the
  // browser put it.
  target?.focus({ preventScroll: true });
}

function header(): HTMLElement {
  const h = document.createElement("header");
  const title = document.createElement("h1");
  title.textContent = "Sessions";
  const badge = document.createElement("span");
  badge.className = "count";
  badge.textContent = "0";
  h.append(title, badge);
  const launch = document.createElement("a");
  launch.className = "launch";
  launch.href = "/";
  launch.target = "_blank";
  launch.rel = "noopener";
  launch.textContent = "Open a shell";
  launch.title = "Open a local shell in a new tab";
  h.append(launch);
  return h;
}

function noticeContent(text: string): DocumentFragment {
  const fragment = document.createDocumentFragment();
  const span = document.createElement("span");
  span.textContent = text;
  const dismiss = document.createElement("button");
  dismiss.type = "button";
  dismiss.className = "quiet";
  dismiss.textContent = "Dismiss";
  dismiss.dataset.focus = "dismiss";
  dismiss.addEventListener("click", () => {
    notice = null;
    lastSignature = "";
    render();
  });
  fragment.append(span, dismiss);
  return fragment;
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

// --- push notifications -----------------------------------------------------

/** Show, hide, or leave the usage panel; rebuilt only when its content
 * changes, so a toggle a keyboard user sits on survives the polls. */
function paintUsage(panel: UsagePanel | null): void {
  const signature = JSON.stringify(panel);
  if (signature === usagePainted) return;
  usagePainted = signature;
  usageBlock.hidden = panel === null;
  usageBlock.replaceChildren(...(panel === null ? [] : usageContent(panel)));
}

/**
 * The panel: the title line with the two toggle groups, the headline and
 * what it is, the chart, its axis, then the note and the rollup's age.
 * The chart is one bar per day in an SVG, `currentColor` on the body, so
 * it adds no colour pair; a silent day is a gap. It is hidden from a
 * screen reader behind one sentence (`usageChartName`), and each bar
 * carries its day and amount as a tooltip. A toggle prints `[ ]`/`[x]`
 * like the push switch and is a radio to a screen reader.
 */
function usageContent(panel: UsagePanel): Node[] {
  const head = document.createElement("div");
  head.className = "usage-head";
  const title = document.createElement("h2");
  title.className = "usage-title";
  title.textContent = panel.title;
  head.append(title, usageToggles("mode", panel), usageToggles("span", panel));

  const headline = document.createElement("p");
  headline.className = "usage-headline";
  const amount = span("usage-amount", panel.headline);
  const qualifier = span("usage-qualifier", panel.qualifier);
  headline.append(amount, " ", qualifier);

  const chart = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  chart.setAttribute("class", "usage-chart");
  chart.setAttribute("role", "img");
  chart.setAttribute("aria-label", usageChartName(panel));
  chart.setAttribute("preserveAspectRatio", "none");
  const n = Math.max(1, panel.series.length);
  chart.setAttribute("viewBox", `0 0 ${n} 100`);
  const top = panel.peak?.value ?? 0;
  panel.series.forEach((value, i) => {
    if (value <= 0 || top <= 0) return;
    const rect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
    const height = Math.max(1, (value / top) * 100);
    rect.setAttribute("x", `${i + 0.1}`);
    rect.setAttribute("width", "0.8");
    rect.setAttribute("y", `${100 - height}`);
    rect.setAttribute("height", `${height}`);
    const tip = document.createElementNS("http://www.w3.org/2000/svg", "title");
    tip.textContent = `${panel.days[i]}: ${usageAmount(value, panel.mode)}`;
    rect.append(tip);
    chart.append(rect);
  });

  const axis = document.createElement("p");
  axis.className = "usage-axis";
  axis.append(span("usage-from", panel.days[0] ? dayLabel(panel.days[0]) : ""));
  if (panel.peak) axis.append(span("usage-peak", `most ${usageAmount(panel.peak.value, panel.mode)} on ${dayLabel(panel.peak.day)}`));
  axis.append(span("usage-to", panel.days.length > 1 ? dayLabel(panel.days[panel.days.length - 1]) : ""));

  const note = document.createElement("p");
  note.className = "usage-note";
  note.textContent = panel.note;
  const age = document.createElement("p");
  age.className = "usage-age";
  age.textContent = panel.age;
  return [head, headline, chart, axis, note, age];
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

/** Show, hide, or leave the quota block; rebuilt only when its text
 * changes, so the bars do not flicker on every poll. */
function paintQuota(panel: QuotaPanel | null): void {
  const signature = JSON.stringify(panel);
  if (signature === quotaPainted) return;
  quotaPainted = signature;
  quotaBlock.hidden = panel === null;
  quotaBlock.replaceChildren(...(panel === null ? [] : quotaContent(panel)));
}

/** One line per bar, then the note. The bar is the terminal's own:
 * `[#####···············]`, the fill and the track two runs of text so the
 * fill can wear the text colour and the track the muted one; the cells
 * are hidden from a screen reader, which gets the label, the number and
 * the countdown as words. */
function quotaContent(panel: QuotaPanel): Node[] {
  const nodes: Node[] = [];
  if (panel.bars.length > 0) {
    const list = document.createElement("ul");
    list.className = "quota-bars";
    for (const bar of panel.bars) {
      const item = document.createElement("li");
      item.className = `quota-bar ${bar.state}`;
      const label = document.createElement("span");
      label.className = "quota-label";
      label.textContent = bar.label;
      const cells = document.createElement("span");
      cells.className = "quota-cells";
      cells.setAttribute("aria-hidden", "true");
      const fill = document.createElement("span");
      fill.className = "quota-fill";
      fill.textContent = bar.cells.slice(0, bar.filled);
      const track = document.createElement("span");
      track.className = "quota-track";
      track.textContent = bar.cells.slice(bar.filled);
      cells.append("[", fill, track, "]");
      const percent = document.createElement("span");
      percent.className = "quota-percent";
      percent.textContent = bar.percent;
      const reset = document.createElement("span");
      reset.className = "quota-reset";
      reset.textContent = bar.reset;
      item.append(label, cells, percent, reset);
      list.append(item);
    }
    nodes.push(list);
  }
  const note = document.createElement("p");
  note.className = "quota-note";
  note.textContent = panel.note;
  nodes.push(note);
  return nodes;
}

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

// --- the attention strip ----------------------------------------------------

function stripContent(items: StripItem[], hasForeman: boolean): Node[] {
  const nodes: Node[] = [];
  if (items.length === 0) {
    const quiet = document.createElement("p");
    quiet.className = "strip-quiet";
    quiet.textContent = "Nothing needs you.";
    nodes.push(quiet);
  } else {
    const list = document.createElement("ul");
    list.className = "strip-list";
    for (const item of items) list.append(stripItem(item));
    nodes.push(list);
  }
  if (!hasForeman) {
    const line = document.createElement("p");
    line.className = "strip-foreman";
    line.textContent = "no foreman running";
    nodes.push(line);
  }
  return nodes;
}

function stripItem(item: StripItem): HTMLElement {
  const li = document.createElement("li");
  li.className = `strip-item ${item.kind}`;
  // The gutter mark: `!` for a failure, `?` for anything that waits on a
  // person. The item's first word says which; the mark is decoration.
  li.append(mark(item.kind === "failed" ? "failed" : item.kind === "approval" ? "approval" : "attention"));
  if (item.kind === "approval") {
    li.append(approvalContent(item.approval, item.row));
    return li;
  }
  if (item.kind === "proposed") {
    li.append(proposedContent(item));
    return li;
  }
  const row = item.row;
  const top = stripTop(item.kind === "needs-input" ? "needs input" : stateLabel(row), headlineOf(row), stripWhere(row));
  // How long it has waited, or how long ago it failed: the row's own span,
  // since the last output (`rowLine`).
  const since = rowLine(row, Date.now()).since;
  if (since) top.append(span("strip-waited", since));
  li.append(top);
  const detail = row.agent?.message ?? (row.lastCommand ? `$ ${row.lastCommand}` : null);
  if (detail) {
    const line = document.createElement("div");
    line.className = "strip-detail";
    line.textContent = detail;
    li.append(line);
  }
  // A row that needs input is in the strip and not in its card, so the
  // field that answers it is here.
  const reply = replyForm(row);
  if (reply) li.append(reply);
  li.append(openLink(row.id, "Open the pane"));
  return li;
}

/** One waiting tool call: what it wants to run, where, and the two answers.
 * The loudest thing on the page, because an agent is stopped until it is
 * answered and on a phone only the top of the page gets read. */
function approvalContent(approval: Approval, row: SessionRow | null): DocumentFragment {
  const fragment = document.createDocumentFragment();
  const who = row ? headlineOf(row) : (approval.session?.slice(0, 8) ?? "");
  const top = stripTop(`approve ${approval.tool}`, who, row ? stripWhere(row) : null);
  const waited = document.createElement("span");
  waited.className = "strip-waited";
  waited.textContent = waitedLabel(approval.waitingMs);
  top.append(waited);
  fragment.append(top);

  // The arguments are what you are approving, so they are the body of the
  // item rather than a tooltip.
  const detail = document.createElement("pre");
  detail.className = "approval-input";
  detail.textContent = summarize(approval.input);
  fragment.append(detail);

  if (approval.session) fragment.append(openLink(approval.session, "Open the pane"));
  // A watch token cannot decide, and the daemon would refuse it anyway.
  if (!watchOnly) {
    const actions = document.createElement("div");
    actions.className = "approval-actions";
    const deny = button("Deny", "approval-deny", () => void decide(approval.id, "deny"));
    const allow = button("Allow", "approval-allow", () => void decide(approval.id, "allow"));
    deny.dataset.focus = `approval:${approval.id}:deny`;
    allow.dataset.focus = `approval:${approval.id}:allow`;
    deny.setAttribute("aria-label", approvalName("Deny", approval.tool, who));
    allow.setAttribute("aria-label", approvalName("Allow", approval.tool, who));
    actions.append(deny, allow);
    fragment.append(actions);
  }
  return fragment;
}

/** A goal whose `STATE.md` lists proposals: how many, the goal, the
 * project, the record's decision line when it proposes, and the record
 * itself through the knowledge route, else the `STATE.md` the proposals
 * wait in. The one place on the page a proposal appears. */
function proposedContent(item: ProposedItem): DocumentFragment {
  const fragment = document.createDocumentFragment();
  const goal = goalTitle(item.summary);
  fragment.append(stripTop(proposedLabel(item.count), goal, item.project.name));
  if (item.decision) {
    const line = document.createElement("div");
    line.className = "strip-detail decision";
    line.textContent = item.decision;
    fragment.append(line);
  }
  const actions = document.createElement("div");
  actions.className = "proposed-actions";
  const open = item.record
    ? knowledgeLink(item.project.id, item.record, `Open record ${recordLabel(item.record)}`, "strip-knowledge")
    : knowledgeLink(item.project.id, item.path, "Open STATE.md", "strip-knowledge");
  open.setAttribute(
    "aria-label",
    item.record ? recordName(item.record, item.project.name, goal) : proposalsName(item.count, item.project.name, goal),
  );
  actions.append(open);
  // Read it, decided in STATE.md: the item leaves the strip and the count
  // until the goal's next round.
  const key = dismissKey(item.project.id, item.summary.slug ?? "", item.round);
  const dismiss = button("Dismiss", "quiet", () => dismissProposal(key));
  dismiss.dataset.focus = focusKey("dismiss", key);
  dismiss.setAttribute("aria-label", dismissName(item.round, item.project.name, goal));
  actions.append(dismiss);
  fragment.append(actions);
  return fragment;
}

/** The first line of a strip item: what, who, and where when the name
 * does not say it (`stripWhere`). */
function stripTop(what: string, who: string, where: string | null): HTMLElement {
  const top = document.createElement("div");
  top.className = "strip-top";
  top.append(span("strip-what", what), span("strip-who", who));
  if (where) top.append(span("strip-where", where));
  return top;
}

/** Post one decision. The agent is unblocked by the daemon's response to its
 *  own held request, so there is nothing to do here but report failure. */
async function decide(id: string, decision: "allow" | "deny"): Promise<void> {
  if (busy.has(id)) return;
  busy.add(id);
  // Drop it locally at once: the poll is 2 s away and a button that stays
  // live after a tap invites a second one.
  approvals = approvals.filter((a) => a.id !== id);
  render();
  try {
    const res = await fetch(`/api/approvals/${encodeURIComponent(id)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ decision }),
    });
    // 404 means it expired or someone else answered: not worth alarming over.
    if (!res.ok && res.status !== 404) throw new Error(String(res.status));
  } catch (error) {
    fail(`Could not ${decision} the tool call: ${describe(error)}`);
  } finally {
    busy.delete(id);
  }
}

// --- the fleet line ---------------------------------------------------------

/** The one line above the projects: how many sessions are working, and
 * how many are done, idle or gone (`fleetLine`), over the rows the projects
 * list. The strip's sessions are counted in the strip. */
function fleetCounts(rows: SessionRow[]): HTMLElement {
  const line = document.createElement("p");
  line.className = "fleet";
  line.textContent = fleetLine(rows);
  return line;
}

// --- the three levels -------------------------------------------------------

/** The sections under the fleet line: `rows` is what they list (the strip's
 * sessions left out), `owned` is every session, so a project can tell no
 * session from sessions that are all in the strip. `levels` decides the
 * tree; this paints one workspace section or one lone project per entry,
 * then homes the archives whose section is not on the page. */
function sectionList(rows: SessionRow[], owned: SessionRow[], proposed: ProposedItem[]): Node[] {
  const sections = levels(rows, owned, projects, (id) => knowledge.get(id)?.goals);
  const headed = sections.flatMap((s) => (s.heading?.path ? [s.heading.path] : []));
  const nodes: Node[] = [];
  const homed = new Set<string>();
  for (const s of sections) {
    if (s.heading === null) {
      const p = s.projects[0];
      homed.add(p.key);
      nodes.push(card(p, archivesOf(p.key, headed, null), proposed, 2));
      continue;
    }
    for (const p of s.projects) homed.add(p.key);
    nodes.push(workspace(s, headed, proposed));
  }
  if (nodes.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = watchOnly ? "No live sessions to watch." : "No live sessions. Open a shell to start one.";
    nodes.push(empty);
  }
  // Archives whose section is not on the page still need a home: a project
  // the daemon no longer lists, or shells outside every project when no
  // "No project" section and no workspace holds them.
  const orphaned = archives.filter((a) => {
    const key = a.project?.id ?? NO_PROJECT;
    if (key !== NO_PROJECT) return !homed.has(key);
    return workspaceHome(a.cwd ?? "", headed) === null && !homed.has(NO_PROJECT);
  });
  if (orphaned.length > 0) nodes.push(archivedFold("__orphaned", orphaned));
  return nodes;
}

/** The archives of one section: a project's by its id; for the shells
 * outside every project, the ones whose cwd `home` holds (a headed
 * workspace directory), or the ones no headed workspace holds when `home`
 * is null, the same rule `levels` applies to the live rows. */
function archivesOf(key: string, headed: string[], home: string | null): ArchivedRow[] {
  return archives.filter((a) => {
    if ((a.project?.id ?? NO_PROJECT) !== key) return false;
    if (key !== NO_PROJECT) return true;
    return workspaceHome(a.cwd ?? "", headed) === home;
  });
}

/**
 * One workspace: its heading line, the shells that sit in its directory
 * outside every project, its archives, then its projects set in by
 * `NESTED_INDENT_PX`. The heading is a level-2 heading and the projects
 * under it level 3, so a reader who moves by heading gets the tree.
 */
function workspace(s: WorkspaceSection<SessionRow>, headed: string[], proposed: ProposedItem[]): HTMLElement {
  const heading = s.heading!;
  const section = document.createElement("section");
  section.className = "workspace";
  section.setAttribute("aria-label", heading.name);
  const head = document.createElement("div");
  head.className = "head";
  head.append(headingName(heading, 2, usage ? costLabel(workspaceUsage(usage, heading.path, headed)) : null));
  section.append(head);
  if (s.rows.length > 0) section.append(rowList(s.rows, heading.path ?? undefined));
  const archived = archivesOf(NO_PROJECT, headed, heading.path);
  if (archived.length > 0) section.append(archivedFold(`workspace:${heading.path}`, archived));
  const nested = document.createElement("div");
  nested.className = "nested";
  for (const p of s.projects) nested.append(card(p, archivesOf(p.key, headed, null), proposed, 3));
  section.append(nested);
  return section;
}

/** The heading's name as an `h2` or `h3`, with the directory it stands for
 * as its tooltip, and after it what the range cost there with the cache
 * share, `$850.51 · 91% cached` (`costLabel`), when the rollup answered.
 * The two are one heading, so a reader who moves by heading hears the
 * number with the name; the sheet puts the cost on its own line under the
 * name on a phone, where the heading line has no room left. */
function headingName(heading: Heading, level: 2 | 3, cost: string | null): HTMLElement {
  const h = document.createElement(`h${level}`);
  h.className = "name";
  h.textContent = heading.name;
  if (heading.path) h.title = heading.path;
  if (cost !== null) {
    const c = span("cost", cost);
    c.title = `${heading.name}: what the range cost here, at the full API rate, and the cache-read share of its input`;
    h.append(" ", c);
  }
  return h;
}

/**
 * One project, top to bottom: one heading line (the name, "no live
 * session" when it owns none, the spawn control), its rows under no goal,
 * then its goals by state: the working ones each with the crew's row
 * beneath, the pending ones, the done ones folded, or the one line that
 * says why there are none; then the archives folded. The root path is not
 * printed: a row's place is relative to it, and the pane shows it; the
 * heading carries it as a tooltip. The rows come before the goals because
 * a running session is what the reader can act on now; a goal's next
 * action is what the foreman does next. `level` is the heading's: 2 at the
 * top, 3 under a workspace, where `NESTED_INDENT_PX` comes off the line.
 */
function card(p: ProjectSection<SessionRow>, archived: ArchivedRow[], proposed: ProposedItem[], level: 2 | 3): HTMLElement {
  const section = document.createElement("section");
  section.className = "card";
  section.setAttribute("aria-label", p.heading.name);

  const head = document.createElement("div");
  head.className = "head";
  head.append(headingName(p.heading, level, usage && p.project ? costLabel(projectUsage(usage, p.project.root)) : null));
  // The counts live on the fleet line above the projects; the rows say
  // their own state. A project with no session at all says so, once.
  // `headingLine` decides what gives way on a phone; the sheet applies it
  // under its phone media query, so a wider screen shows everything.
  const tallyText = p.owned === 0 ? "no live session" : null;
  const spawnIn = !watchOnly && p.project?.root ? p.project : null;
  const line = headingLine({
    name: p.heading.name,
    tally: tallyText,
    profiles: spawnIn ? [LOCAL_SHELL, ...profiles.map((pr) => pr.name)] : null,
    indent: level === 3 ? NESTED_INDENT_PX : 0,
  });
  if (tallyText) head.append(span(line.tally ? "tally" : "tally gives-way", tallyText));
  if (spawnIn) head.append(spawnControls(spawnIn, line.profile));
  section.append(head);

  if (p.rows.length > 0) section.append(rowList(p.rows));
  if (p.project) {
    const { working, pending, done } = p.goals;
    if (working.length > 0) section.append(bucket("working", working.length, level), goalList(p.project, working, proposed));
    if (pending.length > 0) {
      section.append(bucket("pending", pending.length, level), goalList(p.project, pending.map((line) => ({ line, rows: [] })), proposed));
    }
    if (done.length > 0) section.append(doneFold(p.project, done, proposed));
  }
  if (p.noGoals) {
    const none = document.createElement("p");
    none.className = "goal-none";
    none.textContent = p.noGoals;
    section.append(none);
  }
  if (archived.length > 0) section.append(archivedFold(p.key, archived));
  return section;
}

/** One list of rows in the model's order. `base` is the directory the
 * heading above names when it is not the rows' project root: a workspace
 * directory, for the shells it lists outside every project. */
function rowList(rows: SessionRow[], base?: string): HTMLElement {
  const list = document.createElement("ul");
  list.className = "rows";
  for (const r of rows) list.append(row(r, base));
  return list;
}

/** The label over a bucket of goals, one heading level under the project's:
 * `1 working`, `2 pending`. The done bucket is a fold instead (`doneFold`). */
function bucket(state: "working" | "pending", count: number, level: 2 | 3): HTMLElement {
  const h = document.createElement(`h${level + 1}`);
  h.className = "bucket";
  h.textContent = bucketLabel(state, count);
  return h;
}

/** The goals of one bucket: each its line, then the rows that carry its
 * label, set in under it. `proposed` is what the strip carries, so a line
 * knows whether to carry its own proposals (`lineProposals`). */
function goalList(project: ProjectRef, entries: GoalEntry<SessionRow>[], proposed: ProposedItem[]): HTMLElement {
  const list = document.createElement("ul");
  list.className = "goal-lines";
  for (const entry of entries) {
    const li = document.createElement("li");
    li.className = "goal";
    li.setAttribute("aria-label", `${entry.line.title} in ${project.name}`);
    li.append(goalLineItem(entry.line, project, proposed));
    if (entry.rows.length > 0) li.append(rowList(entry.rows));
    list.append(li);
  }
  return list;
}

/** One goal that is not done, on two lines: the title, the status word
 * when it is not active, the round counter and what its rounds cost
 * (`goalCost`); then the next action on its own line, cut at the line's
 * end, because on one line with the rest it read "Roun…" at 390 px. A
 * goal whose files still hold the template reads "not written yet" after
 * its slug. No floor word, no slug, no record link: the record is history,
 * and the done fold and the strip's proposal carry it (`goalLine`). The
 * proposals `STATE.md` lists stand at the line's end only when the strip
 * does not carry them: a stopped goal's, or a dismissed item's
 * (`lineProposals`). */
function goalLineItem(line: GoalLine, project: ProjectRef, proposed: ProposedItem[]): HTMLElement {
  const li = document.createElement("div");
  li.className = "goal-line";
  li.append(span("goal-name", line.title));
  if (line.unwritten) {
    li.append(span("goal-unwritten", "not written yet"));
    return li;
  }
  if (line.status) li.append(span("goal-status", line.status));
  if (line.round) li.append(span("goal-round", line.round));
  const cost = goalCost(line.summary);
  if (cost !== null) {
    const c = span("goal-cost", cost);
    c.title = "the sum of this goal's round records' Cost lines, at the full API rate, and the cache-read share";
    li.append(c);
  }
  const waiting = lineProposals(project.id, line.summary, proposed);
  if (waiting) li.append(proposalsLink(project, line.summary, waiting, true));
  if (line.next) {
    const next = span("goal-next", line.next);
    next.title = line.next;
    li.append(next);
  }
  return li;
}

/** The done goals behind one line, "7 done": each with its title, the
 * proposals its `STATE.md` still lists (`lineProposals`; a done goal's are
 * never in the strip), and its record link, unless the strip carries the
 * record already (`cardRecord`). Folded, because a done goal is history. */
function doneFold(project: ProjectRef, done: KnowledgeSummary[], proposed: ProposedItem[]): HTMLElement {
  const key = `done:${project.id}`;
  const details = document.createElement("details");
  details.className = "archived done";
  details.open = archivedOpen.has(key);
  details.addEventListener("toggle", () => {
    if (details.open) archivedOpen.add(key);
    else archivedOpen.delete(key);
  });
  const summary = document.createElement("summary");
  summary.textContent = doneLabel(done.length);
  summary.dataset.focus = `archived:${key}`;
  details.append(summary);
  const ul = document.createElement("ul");
  ul.className = "archived-list";
  for (const goal of done) {
    const li = document.createElement("li");
    li.append(span("archived-name", goalTitle(goal)));
    const waiting = lineProposals(project.id, goal, proposed);
    if (waiting) li.append(proposalsLink(project, goal, waiting, false));
    const record = cardRecord(project.id, goal, proposed);
    if (record !== null) {
      const link = knowledgeLink(project.id, record, `record ${recordLabel(record)}`, "card-knowledge");
      link.classList.add("goal-link");
      link.setAttribute("aria-label", recordName(record, project.name, goalTitle(goal)));
      li.append(link);
    }
    ul.append(li);
  }
  details.append(ul);
  return details;
}

/** The proposals a goal's line carries when the strip does not
 * (`lineProposals`): the count, `2 proposals`, linking the `STATE.md` they
 * wait in, named like the strip's own link. `edge` sets it at the line's
 * right end, where the done fold's record link sits; in the fold the
 * record link takes that place and this one stands before it. */
function proposalsLink(project: ProjectRef, goal: KnowledgeSummary, waiting: LineProposals, edge: boolean): HTMLAnchorElement {
  const link = knowledgeLink(project.id, waiting.path, proposedLabel(waiting.count), "card-knowledge");
  if (edge) link.classList.add("goal-link");
  link.setAttribute("aria-label", proposalsName(waiting.count, project.name, goalTitle(goal)));
  return link;
}

/** A link to one file of a project's package, opened in a new tab. Keyed
 * for focus like every other control, so a repaint does not drop a keyboard
 * user off it; `region` tells the strip's link to a record from the card's
 * link to the same record, so the repaint gives focus back to the one the
 * user was on. */
function knowledgeLink(
  projectId: string, path: string, text: string, region: "strip-knowledge" | "card-knowledge",
): HTMLAnchorElement {
  const a = document.createElement("a");
  a.className = "strip-open";
  a.href = knowledgeUrl(projectId, path);
  a.target = "_blank";
  a.rel = "noopener";
  a.textContent = text;
  a.dataset.focus = focusKey(region, projectId, path);
  return a;
}

/** The select's default option: no profile, a plain shell. */
const LOCAL_SHELL = "local shell";

/** Spawn a session in this project's root: a plain shell, or one of the
 * named profiles when the daemon has any. `width` is `headingLine`'s
 * decision for the select on a phone: whole, short, or gone. */
function spawnControls(project: ProjectRef, width: ProfileWidth | null): HTMLElement {
  const box = document.createElement("div");
  box.className = "spawn";
  let select: HTMLSelectElement | null = null;
  if (profiles.length > 0) {
    select = document.createElement("select");
    select.className = width === "whole" ? "spawn-profile" : width === "short" ? "spawn-profile short" : "spawn-profile gives-way";
    select.setAttribute("aria-label", `Profile for the new session in ${project.name}`);
    select.dataset.focus = `spawn:${project.id}:profile`;
    const local = document.createElement("option");
    local.value = "";
    local.textContent = LOCAL_SHELL;
    select.append(local);
    for (const p of profiles) {
      const option = document.createElement("option");
      option.value = p.name;
      option.textContent = p.name;
      option.title = p.command;
      select.append(option);
    }
    // The pick survives the repaint between choosing and tapping New session.
    select.value = spawnProfile.get(project.id) ?? "";
    const picked = select;
    picked.addEventListener("change", () => spawnProfile.set(project.id, picked.value));
    box.append(select);
  }
  // `[new]` on the heading line; the aria-label says what is new and where.
  const b = button("new", "spawn-button", () => {
    void spawn(project, select?.value || undefined, b);
  });
  b.setAttribute("aria-label", `New session in ${project.name}`);
  b.title = `Start a shell in ${project.root ?? project.name}`;
  b.dataset.focus = `spawn:${project.id}:new`;
  box.append(b);
  return box;
}

async function spawn(project: ProjectRef, profile: string | undefined, b: HTMLButtonElement): Promise<void> {
  const key = `spawn:${project.id}`;
  if (busy.has(key) || !project.root) return;
  busy.add(key);
  b.disabled = true;
  try {
    const body: Record<string, string> = { cwd: project.root };
    if (profile) body.profile = profile;
    const res = await fetch("/api/sessions", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(await reasonOf(res));
    notice = null;
    lastSignature = "";
    await poll();
  } catch (error) {
    fail(`Could not start a session in ${project.name}: ${describe(error)}`);
  } finally {
    busy.delete(key);
    b.disabled = false;
  }
}

function archivedFold(key: string, list: ArchivedRow[]): HTMLElement {
  const details = document.createElement("details");
  details.className = "archived";
  details.open = archivedOpen.has(key);
  details.addEventListener("toggle", () => {
    if (details.open) archivedOpen.add(key);
    else archivedOpen.delete(key);
  });
  const summary = document.createElement("summary");
  summary.textContent = `Archived (${list.length})`;
  summary.dataset.focus = `archived:${key}`;
  details.append(summary);
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
    if (typeof a.exitCode === "number") bits.push(`exit ${a.exitCode}`);
    if (a.archivedAt) bits.push(new Date(a.archivedAt).toLocaleString());
    meta.textContent = bits.join(" · ");
    li.append(name, meta);
    ul.append(li);
  }
  details.append(ul);
  return details;
}

// --- rows -------------------------------------------------------------------

function row(s: SessionRow, base?: string): HTMLElement {
  const li = document.createElement("li");
  li.className = "row";

  const link = document.createElement("a");
  link.href = `/?session=${encodeURIComponent(s.id)}`;
  link.className = "open";
  link.dataset.focus = `${s.id}:open`;

  // The state is the text beside it; the gutter mark is decoration.
  const dot = mark(familyOf(stateOf(s)));

  // One line: name, state, place, what, how long. The model decides each
  // field; a null one is not painted.
  const line = rowLine(s, Date.now(), base ?? s.project?.root);
  const main = document.createElement("div");
  main.className = "main";
  const name = document.createElement("span");
  name.className = "folder";
  name.textContent = line.name;
  name.title = s.cwd;
  const state = document.createElement("span");
  state.className = `state ${familyOf(stateOf(s))}`;
  state.textContent = line.state;
  main.append(name, state);
  if (line.place) main.append(span("place", line.place));
  if (line.what) {
    const what = span("what", line.what);
    what.title = line.what;
    main.append(what);
  }
  if (line.since) main.append(span("since", line.since));
  link.append(dot, main);
  li.append(link);
  if (!watchOnly) li.append(rowActions(s));
  const reply = replyForm(s);
  if (reply) li.append(reply);
  return li;
}

/** Name, archive, kill. Inline beside the row on a wide screen; behind one
 * menu button on a phone, where three targets do not fit beside the text.
 * The menu closes on Escape, when focus leaves it, and when an item is
 * chosen; each of those hands focus back to the ⋯ button. */
function rowActions(s: SessionRow): HTMLElement {
  const box = document.createElement("div");
  box.className = "actions";
  const isOpen = openMenu === s.id;
  const menu = document.createElement("div");
  menu.id = `menu-${s.id}`;
  menu.className = isOpen ? "menu open" : "menu";
  const setOpen = (open: boolean): void => {
    menu.classList.toggle("open", open);
    more.setAttribute("aria-expanded", open ? "true" : "false");
    openMenu = open ? s.id : null;
  };
  const more = button("⋯", "more", () => setOpen(!menu.classList.contains("open")));
  more.setAttribute("aria-label", actionName("Actions for", headlineOf(s)));
  more.setAttribute("aria-haspopup", "true");
  more.setAttribute("aria-controls", menu.id);
  more.setAttribute("aria-expanded", isOpen ? "true" : "false");
  more.dataset.focus = `${s.id}:more`;
  // Choosing an item on the phone closes the menu and returns focus to ⋯
  // before the item's own dialog opens, so the poll that follows the dialog
  // finds ⋯ by its key. On a wide screen there is no menu to close and the
  // item keeps focus itself.
  const item = (
    label: "Rename" | "Name" | "Archive" | "Kill",
    className: string,
    key: string,
    action: () => void,
  ): HTMLButtonElement => {
    const b = button(label, className, () => {
      if (menu.classList.contains("open")) {
        setOpen(false);
        more.focus();
      }
      action();
    });
    b.dataset.focus = `${s.id}:${key}`;
    b.setAttribute("aria-label", actionName(label, headlineOf(s)));
    return b;
  };
  menu.append(
    item(s.name ? "Rename" : "Name", "quiet", "rename", () => void renameSession(s)),
    item("Archive", "quiet", "archive", () => void archiveSession(s)),
    item("Kill", "quiet danger", "kill", () => void killSession(s)),
  );
  box.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !menu.classList.contains("open")) return;
    event.preventDefault();
    setOpen(false);
    more.focus();
  });
  box.addEventListener("focusout", (event) => {
    if (!menu.classList.contains("open")) return;
    const to = event.relatedTarget;
    if (to instanceof Node && box.contains(to)) return;
    setOpen(false);
  });
  box.append(more, menu);
  return box;
}

/** Name or rename one session (`PATCH /api/sessions/<id>`). A prompt keeps
 * this dependency-free and works the same on a phone; the next poll paints
 * the result, and observers' tabs follow via the daemon's title push. */
async function renameSession(s: SessionRow): Promise<void> {
  const next = window.prompt("Session name (empty clears it):", s.name ?? "");
  if (next === null) return;
  try {
    const res = await fetch(`/api/sessions/${encodeURIComponent(s.id)}`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ name: next }),
    });
    if (!res.ok) throw new Error(await reasonOf(res));
    notice = null;
  } catch (error) {
    fail(`Could not rename ${headlineOf(s)}: ${describe(error)}`);
  }
  lastSignature = "";
  void poll();
}

/** Keep the session's evidence, then end it. One confirm, then the row moves
 * under the card's archived list on the next poll. */
async function archiveSession(s: SessionRow): Promise<void> {
  if (!window.confirm(`Archive ${headlineOf(s)}? The shell ends; its output is kept.`)) return;
  await endSession(s, "archive", `/api/sessions/${encodeURIComponent(s.id)}/archive`, "POST");
}

/** End the session and its shell now. One confirm, then the row is gone. */
async function killSession(s: SessionRow): Promise<void> {
  if (!window.confirm(`Kill ${headlineOf(s)}? The shell ends and nothing is kept.`)) return;
  await endSession(s, "kill", `/api/sessions/${encodeURIComponent(s.id)}`, "DELETE");
}

async function endSession(s: SessionRow, verb: string, url: string, method: string): Promise<void> {
  if (busy.has(s.id)) return;
  busy.add(s.id);
  // Drop the row at once, so a second tap has nothing to hit; the poll
  // reconciles either way.
  sessions = sessions.filter((r) => r.id !== s.id);
  render();
  try {
    const res = await fetch(url, { method });
    // 404: already gone, which is the result asked for.
    if (!res.ok && res.status !== 404) throw new Error(await reasonOf(res));
    notice = null;
  } catch (error) {
    fail(`Could not ${verb} ${headlineOf(s)}: ${describe(error)}`);
  } finally {
    busy.delete(s.id);
    lastSignature = "";
    void poll();
  }
}

// --- answering an agent -----------------------------------------------------

/**
 * One line under a row with a live agent: a text field and `[send]`, which
 * types the line into the pane through `POST /api/sessions/<id>/input?enter=1`,
 * as if typed. Null when `replyControl` says the control is absent (a watch
 * client, or no live agent). A held control keeps the field and prints the
 * reason where `[send]` was: a working agent loses a line typed mid-turn
 * (`docs/goals/facts.md`), so the send waits for the reader, not a queue.
 * After a send, `sent 14:32` stands beside `[send]` until the agent's next
 * report (`receiptStands`).
 *
 * The draft lives in `drafts`, because every poll that changes the page
 * rebuilds the field; the field's `data-focus` key gets focus back.
 */
function replyForm(s: SessionRow): HTMLFormElement | null {
  const control = replyControl(s, { watchOnly, agentControlOff });
  if (control.kind === "absent") return null;
  const form = document.createElement("form");
  form.className = "reply";
  const field = document.createElement("input");
  field.type = "text";
  field.className = "reply-input";
  field.autocomplete = "off";
  field.spellcheck = false;
  field.enterKeyHint = "send";
  field.placeholder = replyName(s);
  field.setAttribute("aria-label", replyName(s));
  field.value = drafts.get(s.id) ?? "";
  field.dataset.focus = `${s.id}:reply`;
  field.addEventListener("input", () => {
    if (field.value) drafts.set(s.id, field.value);
    else drafts.delete(s.id);
  });
  form.append(field);
  if (control.kind === "held") {
    form.append(span("reply-hold", control.reason));
  } else {
    const send = button("send", "quiet", () => void sendReply(s.id));
    send.dataset.focus = `${s.id}:send`;
    send.setAttribute("aria-label", actionName("Send to", headlineOf(s)));
    form.append(send);
    const receipt = sent.get(s.id);
    if (receiptStands(receipt, s)) {
      const stamp = span("reply-sent", `sent ${clockTime(receipt!.at)}`);
      stamp.setAttribute("role", "status");
      form.append(stamp);
    }
  }
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    void sendReply(s.id);
  });
  return form;
}

/** Type the row's draft into its pane and press Enter. The control is read
 * again here, against the row as last polled, because the state may have
 * moved since the field was painted: a held control refuses with its
 * reason in the notice and keeps the draft. A refusal from the daemon
 * keeps the draft too, and the `--agent-control` one holds every field
 * from then on (`agentControlOff`). */
async function sendReply(id: string): Promise<void> {
  const s = sessions.find((r) => r.id === id);
  const line = drafts.get(id)?.trim() ?? "";
  if (!s || !line || busy.has(id)) return;
  const control = replyControl(s, { watchOnly, agentControlOff });
  if (control.kind !== "ready") {
    fail(`Not sent to ${headlineOf(s)}: ${control.kind === "held" ? control.reason : "no live agent"}`);
    return;
  }
  busy.add(id);
  try {
    const res = await fetch(`/api/sessions/${encodeURIComponent(id)}/input?enter=1`, {
      method: "POST",
      headers: { "content-type": "text/plain; charset=utf-8" },
      body: line,
    });
    if (!res.ok) {
      const reason = await reasonOf(res);
      if (res.status === 403 && reason.includes("--agent-control")) agentControlOff = true;
      throw new Error(reason);
    }
    drafts.delete(id);
    sent.set(id, { at: Date.now(), ...agentMark(s) });
    notice = null;
  } catch (error) {
    fail(`Could not send to ${headlineOf(s)}: ${describe(error)}`);
  } finally {
    busy.delete(id);
    lastSignature = "";
    render();
  }
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

/** The one-character gutter mark of a state family (`familyOf`, or
 * `approval` for a strip approval). A shape in the family's colour that a
 * screen reader skips: the state's word beside it carries the state. */
function mark(family: string): HTMLElement {
  const el = document.createElement("span");
  el.className = `mark ${family}`;
  el.setAttribute("aria-hidden", "true");
  return el;
}

function openLink(id: string, text: string): HTMLAnchorElement {
  const a = document.createElement("a");
  a.className = "strip-open";
  a.href = `/?session=${encodeURIComponent(id)}`;
  a.textContent = text;
  a.dataset.focus = focusKey("open", id);
  return a;
}

function headlineOf(s: SessionRow): string {
  return rowName(s);
}

/** The visual family (dot and label colour) of a merged state. */
function familyOf(state: MergedState): string {
  switch (state) {
    case "working":
      return "running";
    case "needs-approval":
    case "needs-input":
      return "attention";
    case "completed":
      return "done";
    case "failed":
      return "failed";
    case "idle":
      return "idle";
    default:
      return "unknown";
  }
}

function fail(text: string): void {
  notice = text;
  lastSignature = "";
  render();
}

function describe(error: unknown): string {
  return error instanceof Error && error.message ? error.message : "no answer from the daemon";
}

/** The daemon's own reason when it sent one, else the status code. */
async function reasonOf(res: Response): Promise<string> {
  try {
    const data = (await res.json()) as { error?: string };
    if (typeof data.error === "string" && data.error) return data.error;
  } catch {
    // Not JSON; the status is the reason.
  }
  if (res.status === 403) return "refused (watch-only token, or the daemon runs without --agent-control)";
  return `HTTP ${res.status}`;
}

/** A wall-clock label for a moment that stays fixed once set, so the row's
 * text is stable between polls (a duration would go stale between repaints). */
function clockTime(epochMs: number): string {
  return new Date(epochMs).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

/** A label for a moment that can be old: the time alone when `stampFormat`
 * says the moment falls on today, else the date and the time, the convention
 * `archivedFold` already follows. The short styles drop the seconds that a
 * bare `toLocaleString()` prints: the daemon writes the previous run's clock
 * on a heartbeat, so the seconds are false precision, and the line has one
 * line above the cards at 390 px. */
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

// A tap anywhere outside an open menu closes it.
document.addEventListener("click", (event) => {
  if (openMenu === null) return;
  if (event.target instanceof Element && event.target.closest(".actions")) return;
  openMenu = null;
  for (const menu of document.querySelectorAll(".menu.open")) menu.classList.remove("open");
  for (const more of document.querySelectorAll(".more[aria-expanded=\"true\"]")) {
    more.setAttribute("aria-expanded", "false");
  }
});

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
    if (event.type !== "daemon.started") continue;
    // A new run may carry `--agent-control`; the next send finds out.
    if (started?.epoch !== epoch) agentControlOff = false;
    started = { epoch, data: event.data ?? {} };
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
