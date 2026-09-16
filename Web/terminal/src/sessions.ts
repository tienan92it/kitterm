import "./tokens.css";
import "./sessions.css";
import { resolveFontFamily } from "./fonts";
import { summarize, waitedLabel } from "./approval-format";
import {
  actionName,
  applicationServerKey,
  approvalName,
  attention,
  cardRecord,
  cardRows,
  crews as crewsOf,
  dismissKey,
  dismissName,
  doneLabel,
  filter as applyFilter,
  fleetLine,
  focusKey,
  folderOf,
  goalLines,
  headingLine,
  goalTitle,
  group,
  knowledgeUrl,
  needsYouMessage,
  NO_PROJECT,
  pickForeman,
  proposalsName,
  proposedItems,
  proposedLabel,
  pushToggle,
  recordLabel,
  recordName,
  restartDismissName,
  restartNotice,
  rowLine,
  rowName,
  sameServerKey,
  stateLabel,
  stateName,
  stateOf,
  stripWhere,
  tally,
  withProposed,
  type Approval,
  type AttentionItem,
  type DaemonStarted,
  type Filter,
  type GoalLine,
  type Group,
  type KnowledgeAnswer,
  type KnowledgeSummary,
  type MergedState,
  type ModelRow,
  type ProfileWidth,
  type ProjectRef,
  type ProjectSummary,
  type ProposedItem,
  type PushFacts,
  type PushSupport,
  type PushToggle,
  type StampFormat,
} from "./sessions-model";
import { loadSettings } from "./settings-store";
import { applyThemeTokens } from "./theme-tokens";
import { findThemeById } from "./themes";

/**
 * The fleet view: every live shell grouped by project, what needs the human
 * first, and the actions a supervisor takes from a phone — answer, spawn,
 * archive, kill. Polls `/api/projects`, `/api/sessions`, `/api/approvals`
 * and `/api/archives`, plus `/api/projects/<id>/knowledge` for each
 * registered project, and links each row back to `/?session=<id>`.
 *
 * The page reads top to bottom in the order a returning reader needs: the
 * title, what needs them (the strip), what broke (the failed items and the
 * restart line), one line of counts, then one card per project with its
 * rows, its open goals and its folds. The tools, the search, the chips and
 * the push switch, sit under the projects. The pure model
 * (`sessions-model.ts`) decides what goes where; this file only paints it.
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

type Kind = "human" | "crew";

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

/** The chip and search choice. Kept in `sessionStorage` so a reload on the
 * same tab keeps the view; a new tab starts clean. */
type Choice = {
  states: MergedState[];
  projects: string[];
  crews: string[];
  kind: Kind | null;
  query: string;
};

const POLL_MS = 2000;
const KNOWLEDGE_RETRY_POLLS = 30;
const CHOICE_KEY = "kitterm.sessions.filter";
/** The proposals the human dismissed, `dismissKey`s in `localStorage`, so
 * a read proposal stays out of the strip and the title count across reloads
 * until the project's next round. */
const DISMISSED_KEY = "kitterm.sessions.dismissed";
/** The runs whose restart line the human dismissed, `restartDismissKey`s in
 * `localStorage` beside the proposals above: the same pattern, its own key,
 * so one list does not have to hold two kinds of entry. A dismissal keys on
 * the epoch, so it dies with the run it answers. */
const RESTART_DISMISSED_KEY = "kitterm.sessions.restart-dismissed";
const STATE_ORDER: MergedState[] = [
  "needs-approval",
  "needs-input",
  "failed",
  "working",
  "completed",
  "idle",
  "exited",
  "unknown",
];

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
/** The profile picked in each card's spawn select, by project id. A repaint
 * rebuilds the select, so the choice lives here, not in the DOM. */
const spawnProfile = new Map<string, string>();
/** The knowledge summary of each registered project, by id, with the ETag
 * the daemon gave it: an unchanged package answers 304 and repaints nothing. */
const knowledge = new Map<string, KnowledgeEntry>();
let choice: Choice = loadChoice();

function loadChoice(): Choice {
  const empty: Choice = { states: [], projects: [], crews: [], kind: null, query: "" };
  try {
    const raw = sessionStorage.getItem(CHOICE_KEY);
    if (!raw) return empty;
    const parsed = JSON.parse(raw) as Partial<Choice>;
    return {
      states: Array.isArray(parsed.states) ? parsed.states : [],
      projects: Array.isArray(parsed.projects) ? parsed.projects : [],
      crews: Array.isArray(parsed.crews) ? parsed.crews : [],
      kind: parsed.kind === "human" || parsed.kind === "crew" ? parsed.kind : null,
      query: typeof parsed.query === "string" ? parsed.query : "",
    };
  } catch {
    return empty;
  }
}

let dismissed: Set<string> = loadDismissed(DISMISSED_KEY);
let restartDismissed: Set<string> = loadDismissed(RESTART_DISMISSED_KEY);
/** The last `daemon.started` the event feed carried: the run's epoch and the
 * previous run's summary on it. Null until the feed answers, and on a daemon
 * whose ring no longer holds the event. */
let started: DaemonStarted | null = null;

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

function saveChoice(): void {
  try {
    sessionStorage.setItem(CHOICE_KEY, JSON.stringify(choice));
  } catch {
    // Storage full or blocked: the choice still applies for this page life.
  }
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
    const [sessionsRes, projectsRes, approvalsRes, archivesRes] = await Promise.all([
      fetch("/api/sessions", { headers }),
      fetch("/api/projects", { headers }),
      fetch("/api/approvals", { headers }),
      fetch("/api/archives", { headers }),
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
    sessions = data.sessions ?? [];
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
// that changed; the search box lives in `filters` and is built once, so a
// repaint never steals the caret from under a typing thumb.

const strip = document.createElement("section");
strip.className = "strip";
strip.setAttribute("aria-label", "Needs you");
const filters = document.createElement("section");
filters.className = "filters";
filters.setAttribute("aria-label", "Filters");
const chips = document.createElement("div");
chips.className = "chips";
const search = document.createElement("input");
search.type = "search";
search.className = "search";
search.placeholder = "Search name, folder, or command";
search.setAttribute("aria-label", "Search sessions");
search.autocomplete = "off";
search.value = choice.query;
search.addEventListener("input", () => {
  choice = { ...choice, query: search.value };
  saveChoice();
  paint();
});
filters.append(search, chips);
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
/** The text on the line right now, so an unchanged line is left alone. */
let restartPainted = "";
const cards = document.createElement("div");
cards.className = "cards";
let skeletonMounted = false;

function mountSkeleton(): void {
  if (!root || skeletonMounted) return;
  skeletonMounted = true;
  // Status first, tools last: the search, the chips and the push switch are
  // things the reader does, not things the reader came to learn.
  root.replaceChildren(header(), announce, strip, noticeLine, restartLine, cards, filters, pushLine);
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
  ]);
  if (signature === lastSignature) return;
  lastSignature = signature;
  paint();
}

/** Paint from the current snapshot and choice. Called by `render` when the
 * snapshot changed and by the chips when the choice changed.
 *
 * Every control carries a `data-focus` key (row id and action, chip, spawn
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
  // What the strip shows, the cards do not list again (`cardRows`); the
  // chips and the search reach only what the cards list. The foreman is a
  // row of its own project, first among them (`sortInGroup`).
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
  chips.replaceChildren(...chipGroups(listed));
  noticeLine.hidden = notice === null;
  noticeLine.replaceChildren(...(notice === null ? [] : [noticeContent(notice)]));
  paintRestart();
  paintPush();
  cards.replaceChildren(fleetCounts(listed), ...cardList(listed, sessions, proposed));
  if (focusKey) restoreFocus(focusKey);
}

function restoreFocus(key: string): void {
  const target = root?.querySelector<HTMLElement>(`[data-focus="${CSS.escape(key)}"]`);
  // The control is gone when its row was ended or its chip left the page;
  // focus then stays where the browser put it.
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

// --- filters ----------------------------------------------------------------

function chipGroups(rows: SessionRow[]): Node[] {
  const nodes: Node[] = [];
  const present = tally(rows);
  const stateChips = STATE_ORDER.filter((s) => (present[s] ?? 0) > 0 || choice.states.includes(s)).map(
    (state) =>
      chip(stateName(state), `state:${state}`, choice.states.includes(state), () => {
        choice = { ...choice, states: toggle(choice.states, state) };
        commitChoice();
      }),
  );
  if (stateChips.length > 0) nodes.push(chipGroup("State", stateChips));

  const projectChips: HTMLElement[] = [];
  const knownIds = new Set<string>();
  const listed = [...projects].sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
  for (const project of listed) {
    knownIds.add(project.id);
    projectChips.push(projectChip(project.id, project.name));
  }
  for (const row of rows) {
    if (row.project && !knownIds.has(row.project.id)) {
      knownIds.add(row.project.id);
      projectChips.push(projectChip(row.project.id, row.project.name));
    }
  }
  if (rows.some((row) => !row.project) || choice.projects.includes(NO_PROJECT)) {
    knownIds.add(NO_PROJECT);
    projectChips.push(projectChip(NO_PROJECT, "no project"));
  }
  // A chosen id whose project left the page still gets a chip, so the
  // filter that hides every card is visible and can be turned off.
  for (const id of choice.projects) if (!knownIds.has(id)) projectChips.push(projectChip(id, id));
  if (projectChips.length > 1 || choice.projects.length > 0) nodes.push(chipGroup("Project", projectChips));

  const crewNames = crewsOf(rows);
  for (const crew of choice.crews) if (!crewNames.includes(crew)) crewNames.push(crew);
  if (crewNames.length > 0) {
    nodes.push(
      chipGroup(
        "Crew",
        crewNames.map((crew) =>
          chip(`crew: ${crew}`, `crew:${crew}`, choice.crews.includes(crew), () => {
            choice = { ...choice, crews: toggle(choice.crews, crew) };
            commitChoice();
          }),
        ),
      ),
    );
  }

  const kinds: Kind[] = ["human", "crew"];
  nodes.push(
    chipGroup(
      "Made by",
      kinds.map((kind) =>
        chip(kind === "human" ? "a person" : "a program", `kind:${kind}`, choice.kind === kind, () => {
          choice = { ...choice, kind: choice.kind === kind ? null : kind };
          commitChoice();
        }),
      ),
    ),
  );

  if (isNarrowed()) {
    const clear = button("Clear filters", "quiet", () => {
      choice = { states: [], projects: [], crews: [], kind: null, query: "" };
      search.value = "";
      commitChoice();
    });
    clear.dataset.focus = "clear-filters";
    nodes.push(clear);
  }
  return nodes;
}

function projectChip(id: string, name: string): HTMLElement {
  return chip(name, `project:${id}`, choice.projects.includes(id), () => {
    choice = { ...choice, projects: toggle(choice.projects, id) };
    commitChoice();
  });
}

function chipGroup(label: string, items: HTMLElement[]): HTMLElement {
  const box = document.createElement("div");
  box.className = "chip-group";
  box.setAttribute("role", "group");
  const name = document.createElement("span");
  name.className = "chip-label";
  name.id = `chips-${label.toLowerCase().replace(/\W+/g, "-")}`;
  name.textContent = label;
  // Named by the visible word, so a screen reader says it once.
  box.setAttribute("aria-labelledby", name.id);
  box.append(name, ...items);
  return box;
}

/** One filter chip. `key` names it across repaints, so the chip a keyboard
 * user toggled keeps focus after the rebuild. */
function chip(label: string, key: string, on: boolean, onToggle: () => void): HTMLElement {
  const b = document.createElement("button");
  b.type = "button";
  b.className = on ? "chip on" : "chip";
  b.setAttribute("aria-pressed", on ? "true" : "false");
  b.dataset.focus = `chip:${key}`;
  b.textContent = label;
  b.addEventListener("click", onToggle);
  return b;
}

function toggle<T>(list: T[], value: T): T[] {
  return list.includes(value) ? list.filter((v) => v !== value) : [...list, value];
}

function commitChoice(): void {
  saveChoice();
  paint();
}

function isNarrowed(): boolean {
  return (
    choice.states.length > 0 ||
    choice.projects.length > 0 ||
    choice.crews.length > 0 ||
    choice.kind !== null ||
    choice.query.trim() !== ""
  );
}

function currentFilter(): Filter {
  return {
    states: choice.states,
    projects: choice.projects,
    crews: choice.crews,
    kind: choice.kind ?? undefined,
    query: choice.query,
  };
}

// --- project cards ----------------------------------------------------------

/** The cards: `rows` is what they list (the strip's sessions left out),
 * `owned` is every session, so a card can tell a project with no session
 * from one whose sessions are all in the strip. */
function cardList(rows: SessionRow[], owned: SessionRow[], proposed: ProposedItem[]): Node[] {
  const shown = applyFilter(rows, currentFilter());
  const groups = group(shown, projects);
  const ownedCount = new Map(group(owned, projects).map((g) => [g.key, g.rows.length]));
  const narrowed = isNarrowed();
  const nodes: Node[] = [];
  for (const g of groups) {
    // A registered project with no session is a card only on the full view;
    // a narrowed view lists what matched and nothing else.
    if (narrowed && g.rows.length === 0) continue;
    if (choice.projects.length > 0 && !choice.projects.includes(g.key)) continue;
    nodes.push(card(g, archivesFor(g.key), ownedCount.get(g.key) ?? 0, proposed));
  }
  if (nodes.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = narrowed
      ? "No session matches these filters."
      : watchOnly
        ? "No live sessions to watch."
        : "No live sessions. Open a shell to start one.";
    nodes.push(empty);
  }
  // Archives whose project card is not on the page still need a home.
  if (!narrowed) {
    const homed = new Set(groups.map((g) => g.key));
    const orphaned = archives.filter((a) => !homed.has(a.project?.id ?? NO_PROJECT));
    if (orphaned.length > 0) nodes.push(archivedFold("__orphaned", orphaned));
  }
  return nodes;
}

function archivesFor(key: string): ArchivedRow[] {
  return archives.filter((a) => (a.project?.id ?? NO_PROJECT) === key);
}

/**
 * One project, top to bottom: one heading line (the name, "no live
 * session" when it owns none, the spawn control), its rows, one line per
 * goal that is not done, the done goals folded, and the archives folded.
 * The root path is not printed: a row's place is relative to it, and the
 * pane shows it; the heading carries it as a tooltip. The rows come before
 * the goals because a running session is what the reader can act on now;
 * a goal's next action is what the foreman does next.
 */
function card(g: Group<SessionRow>, archived: ArchivedRow[], owned: number, proposed: ProposedItem[]): HTMLElement {
  const section = document.createElement("section");
  section.className = "card";
  section.setAttribute("aria-label", g.project?.name ?? "No project");

  const head = document.createElement("div");
  head.className = "head";
  const name = document.createElement("h2");
  const nameText = g.project?.name ?? "No project";
  name.textContent = nameText;
  if (g.project?.root) name.title = g.project.root;
  head.append(name);
  // The counts live on the fleet line above the projects; the rows say
  // their own state. A project with no session at all says so, once.
  // `headingLine` decides what gives way on a phone; the sheet applies it
  // under its phone media query, so a wider screen shows everything.
  const tallyText = owned === 0 ? "no live session" : null;
  const spawnIn = !watchOnly && g.project?.root ? g.project : null;
  const line = headingLine({
    name: nameText,
    tally: tallyText,
    profiles: spawnIn ? [LOCAL_SHELL, ...profiles.map((p) => p.name)] : null,
  });
  if (tallyText) head.append(span(line.tally ? "tally" : "tally gives-way", tallyText));
  if (spawnIn) head.append(spawnControls(spawnIn, line.profile));
  section.append(head);

  if (g.rows.length > 0) {
    // One list in `sortInGroup`'s order: the foreman, then by state, then
    // the newest output. No `goal:` or `crew:` sub-header; a row's name and
    // state say what those said.
    const list = document.createElement("ul");
    list.className = "rows";
    for (const r of g.rows) list.append(row(r));
    section.append(list);
  }
  const entry = g.project ? knowledge.get(g.project.id) : undefined;
  if (g.project) {
    const lines = goalLines(entry?.goals);
    if (lines.open.length > 0) {
      const list = document.createElement("ul");
      list.className = "goal-lines";
      for (const line of lines.open) list.append(goalLineItem(g.project, line));
      section.append(list);
    }
    if (lines.done.length > 0) section.append(doneFold(g.project, lines.done, proposed));
    // A package with no goal folder (an empty `goals`, not the null of a
    // 404) says so, since the foreman skips such a project and the card
    // must show why.
    if (entry?.goals?.length === 0) {
      const none = document.createElement("p");
      none.className = "goal-none";
      none.textContent = "no goal folder";
      section.append(none);
    }
  }
  if (archived.length > 0) section.append(archivedFold(g.key, archived));
  return section;
}

/** One goal that is not done, on one line: the title, the status word
 * when it is not active, the round counter, and the next action cut at
 * the line's end. A goal whose files still hold the template reads "not
 * written yet" after its slug. No floor word, no slug, no record link:
 * the record is history, and the done fold and the strip's proposal carry
 * it (`goalLine`). */
function goalLineItem(project: ProjectRef, line: GoalLine): HTMLElement {
  const li = document.createElement("li");
  li.className = "goal-line";
  li.setAttribute("aria-label", `${line.title} in ${project.name}`);
  li.append(span("goal-name", line.title));
  if (line.unwritten) {
    li.append(span("goal-unwritten", "not written yet"));
    return li;
  }
  if (line.status) li.append(span("goal-status", line.status));
  if (line.round) li.append(span("goal-round", line.round));
  if (line.next) {
    const next = span("goal-next", line.next);
    next.title = line.next;
    li.append(next);
  }
  return li;
}

/** The done goals behind one line, "7 done": each with its title and its
 * record link, unless the strip carries the record already
 * (`cardRecord`). Folded, because a done goal is history. */
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

function row(s: SessionRow): HTMLElement {
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
  const line = rowLine(s, Date.now());
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
