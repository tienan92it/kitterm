import "./tokens.css";
import "./sessions.css";
import { resolveFontFamily } from "./fonts";
import { summarize, waitedLabel } from "./approval-format";
import {
  attention,
  crews as crewsOf,
  filter as applyFilter,
  group,
  NO_PROJECT,
  pickForeman,
  stateOf,
  tally,
  type Approval,
  type AttentionItem,
  type Filter,
  type Group,
  type MergedState,
  type ModelRow,
  type ProjectRef,
  type ProjectSummary,
} from "./sessions-model";
import { loadSettings } from "./settings-store";
import { applyThemeTokens } from "./theme-tokens";
import { findThemeById } from "./themes";

/**
 * The fleet view: every live shell grouped by project, what needs the human
 * first, and the actions a supervisor takes from a phone — answer, spawn,
 * archive, kill. Polls `/api/projects`, `/api/sessions`, `/api/approvals`
 * and `/api/archives`, and links each row back to `/?session=<id>`.
 *
 * Three layers at one URL: the attention strip, one card per project, and
 * the rows inside a card. The pure model (`sessions-model.ts`) decides what
 * goes where; this file only paints it.
 *
 * Deliberately its own page, not the terminal: `/` stays "open a tab, get a
 * shell".
 */

type SessionState = "running" | "idle" | "unknown";

type AgentStatus = { status: "needs-input" | "completed"; message?: string; at: number };

type SessionRow = ModelRow & {
  shell: string;
  pid: number;
  attached: boolean;
  observers: number;
  state: SessionState;
  marks: number;
  profile?: string;
  /** Free-text status note set by a program or a person. */
  note?: string;
  /** The session's latest Claude Code hook report. */
  agent?: AgentStatus;
  /** A tool call in this session is blocked on a human. */
  pendingApproval?: boolean;
  /** When the linger clock first kept this session past a window (epoch ms). */
  heldSince?: number;
  /** The program that took the terminal from the shell, by name. */
  foregroundProgram?: string;
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
const CHOICE_KEY = "kitterm.sessions.filter";
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
    render();
  } catch {
    renderError();
  } finally {
    inFlight = false;
  }
}

// --- layout skeleton --------------------------------------------------------
// The page has four fixed regions. Each poll replaces the children of the
// ones that changed; the search box lives in `filters` and is built once, so
// a repaint never steals the caret from under a typing thumb.

const strip = document.createElement("section");
strip.className = "strip";
strip.setAttribute("aria-label", "Needs you");
const pinned = document.createElement("section");
pinned.className = "pinned";
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
const cards = document.createElement("div");
cards.className = "cards";
let skeletonMounted = false;

function mountSkeleton(): void {
  if (!root || skeletonMounted) return;
  skeletonMounted = true;
  root.replaceChildren(header(), strip, pinned, filters, noticeLine, cards);
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
  const signature = JSON.stringify([
    rendered,
    order,
    projects,
    approvals.map((a) => a.id),
    archives.map((a) => a.id),
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
  const { foreman, rest } = pickForeman(sessions);
  const items = attention(sessions, approvals);

  // Title badge: how many items want the human right now, so a phone's tab
  // or home-screen label says "come back" without a push notification.
  const count = items.filter((item) => item.kind !== "failed").length;
  document.title = count > 0 ? `(${count}) kitterm — sessions` : "kitterm — sessions";
  root.querySelector(".count")!.textContent = String(sessions.length);

  strip.replaceChildren(...stripContent(items, foreman !== null));
  pinned.replaceChildren(...(foreman ? [foremanRow(foreman)] : []));
  chips.replaceChildren(...chipGroups(rest));
  noticeLine.hidden = notice === null;
  noticeLine.replaceChildren(...(notice === null ? [] : [noticeContent(notice)]));
  cards.replaceChildren(...cardList(rest));
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

// --- the attention strip ----------------------------------------------------

function stripContent(items: AttentionItem<SessionRow>[], hasForeman: boolean): Node[] {
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

function stripItem(item: AttentionItem<SessionRow>): HTMLElement {
  const li = document.createElement("li");
  li.className = `strip-item ${item.kind}`;
  if (item.kind === "approval") {
    li.append(approvalContent(item.approval, item.row));
    return li;
  }
  const row = item.row;
  const top = document.createElement("div");
  top.className = "strip-top";
  const what = document.createElement("span");
  what.className = "strip-what";
  what.textContent = item.kind === "needs-input" ? "needs input" : stateLabel(row);
  const who = document.createElement("span");
  who.className = "strip-who";
  who.textContent = headlineOf(row);
  const where = document.createElement("span");
  where.className = "strip-where";
  where.textContent = row.project?.name ?? folderOf(row.cwd);
  top.append(what, who, where);
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
  const top = document.createElement("div");
  top.className = "strip-top";
  const what = document.createElement("span");
  what.className = "strip-what";
  what.textContent = `approve ${approval.tool}`;
  const who = document.createElement("span");
  who.className = "strip-who";
  who.textContent = row ? headlineOf(row) : (approval.session?.slice(0, 8) ?? "");
  const where = document.createElement("span");
  where.className = "strip-where";
  where.textContent = row ? (row.project?.name ?? folderOf(row.cwd)) : "";
  const waited = document.createElement("span");
  waited.className = "strip-waited";
  waited.textContent = waitedLabel(approval.waitingMs);
  top.append(what, who, where, waited);
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
    actions.append(deny, allow);
    fragment.append(actions);
  }
  return fragment;
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

// --- the foreman ------------------------------------------------------------

function foremanRow(foreman: SessionRow): HTMLElement {
  const box = document.createElement("div");
  box.className = "foreman";
  const label = document.createElement("div");
  label.className = "foreman-label";
  label.textContent = "Foreman";
  const list = document.createElement("ul");
  list.className = "rows";
  list.append(row(foreman));
  box.append(label, list);
  return box;
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
    projectChips.push(projectChip(NO_PROJECT, "no project"));
  }
  if (projectChips.length > 1) nodes.push(chipGroup("Project", projectChips));

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
  box.setAttribute("aria-label", label);
  const name = document.createElement("span");
  name.className = "chip-label";
  name.textContent = label;
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

function cardList(rows: SessionRow[]): Node[] {
  const shown = applyFilter(rows, currentFilter());
  const groups = group(shown, projects);
  const narrowed = isNarrowed();
  const nodes: Node[] = [];
  for (const g of groups) {
    // A registered project with no session is a card only on the full view;
    // a narrowed view lists what matched and nothing else.
    if (narrowed && g.rows.length === 0) continue;
    if (choice.projects.length > 0 && !choice.projects.includes(g.key)) continue;
    nodes.push(card(g, archivesFor(g.key)));
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

function card(g: Group<SessionRow>, archived: ArchivedRow[]): HTMLElement {
  const section = document.createElement("section");
  section.className = "card";
  section.setAttribute("aria-label", g.project?.name ?? "No project");

  const head = document.createElement("div");
  head.className = "card-head";
  const title = document.createElement("div");
  title.className = "card-title";
  const name = document.createElement("h2");
  name.textContent = g.project?.name ?? "No project";
  title.append(name);
  if (g.project?.root) {
    const path = document.createElement("span");
    path.className = "card-root";
    path.textContent = g.project.root;
    path.title = g.project.root;
    title.append(path);
  }
  head.append(title);

  const counts = document.createElement("div");
  counts.className = "tallies";
  const t = tally(g.rows);
  for (const state of STATE_ORDER) {
    const n = t[state] ?? 0;
    if (n === 0) continue;
    const item = document.createElement("span");
    item.className = `tally ${familyOf(state)}`;
    const dot = document.createElement("span");
    dot.className = `dot ${familyOf(state)}`;
    item.append(dot, document.createTextNode(`${n} ${stateName(state)}`));
    counts.append(item);
  }
  if (g.rows.length === 0) {
    const none = document.createElement("span");
    none.className = "tally quiet";
    none.textContent = "no live session";
    counts.append(none);
  }
  head.append(counts);
  if (!watchOnly && g.project?.root) head.append(spawnControls(g.project));
  section.append(head);

  if (g.rows.length > 0) {
    for (const sec of g.sections) {
      // A labelled rule above each crew; the rows without a crew label
      // come first and need none.
      if (sec.crew !== null) {
        const sub = document.createElement("div");
        sub.className = "crew-head";
        sub.textContent = `crew: ${sec.crew}`;
        section.append(sub);
      }
      const list = document.createElement("ul");
      list.className = "rows";
      for (const r of sec.rows) list.append(row(r));
      section.append(list);
    }
  }
  if (archived.length > 0) section.append(archivedFold(g.key, archived));
  return section;
}

/** Spawn a session in this project's root: a plain shell, or one of the
 * named profiles when the daemon has any. */
function spawnControls(project: ProjectRef): HTMLElement {
  const box = document.createElement("div");
  box.className = "spawn";
  let select: HTMLSelectElement | null = null;
  if (profiles.length > 0) {
    select = document.createElement("select");
    select.className = "spawn-profile";
    select.setAttribute("aria-label", "Profile for the new session");
    select.dataset.focus = `spawn:${project.id}:profile`;
    const local = document.createElement("option");
    local.value = "";
    local.textContent = "local shell";
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
  const b = button("New session", "spawn-button", () => {
    void spawn(project, select?.value || undefined, b);
  });
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

  const dot = document.createElement("span");
  dot.className = `dot ${familyOf(stateOf(s))}`;
  dot.title = stateLabel(s);

  const main = document.createElement("div");
  main.className = "main";

  const top = document.createElement("div");
  top.className = "top";
  // The server-side name is the headline when one is set; the folder stays
  // visible as a chip so the row still says where the shell is.
  const headline = document.createElement("span");
  headline.className = "folder";
  headline.textContent = headlineOf(s);
  headline.title = s.cwd;
  const state = document.createElement("span");
  state.className = `state ${familyOf(stateOf(s))}`;
  state.textContent = stateLabel(s);
  top.append(headline, state);
  if (s.name) top.append(tag(folderOf(s.cwd)));
  if (s.profile) top.append(tag(s.profile));
  // What holds the terminal: a pane running `claude` and a bare shell look
  // the same otherwise. The daemon omits the field at a shell prompt.
  if (s.foregroundProgram) {
    const program = tag(s.foregroundProgram);
    program.classList.add("program");
    program.title = "Reading the terminal";
    top.append(program);
  }
  const task = s.labels?.task;
  if (task) top.append(tag(`task: ${task}`));

  const sub = document.createElement("div");
  sub.className = "sub";
  sub.textContent = s.lastCommand ? `$ ${s.lastCommand}` : `${shellName(s.shell)} · ${s.cwd}`;
  sub.title = s.cwd;

  // What the agent last said (a Notification's message), shown when it is the
  // reason the session wants attention. A note set by a person takes the line
  // otherwise.
  const noteText = s.agent?.message ?? s.note;
  const note = noteText ? document.createElement("div") : null;
  if (note && noteText) {
    note.className = "note";
    note.textContent = noteText;
  }

  const meta = document.createElement("div");
  meta.className = "meta";
  const bits: string[] = [];
  bits.push(s.attached ? "attached" : "detached");
  if (typeof s.heldSince === "number") bits.push(`held since ${clockTime(s.heldSince)}`);
  if (s.observers > 0) bits.push(`${s.observers} watching`);
  if (typeof s.lastExit === "number") bits.push(`exit ${s.lastExit}`);
  bits.push(`pid ${s.pid}`);
  meta.textContent = bits.join(" · ");

  if (note) main.append(top, sub, note, meta);
  else main.append(top, sub, meta);
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
  more.setAttribute("aria-label", "Session actions");
  more.setAttribute("aria-haspopup", "true");
  more.setAttribute("aria-controls", menu.id);
  more.setAttribute("aria-expanded", isOpen ? "true" : "false");
  more.dataset.focus = `${s.id}:more`;
  // Choosing an item on the phone closes the menu and returns focus to ⋯
  // before the item's own dialog opens, so the poll that follows the dialog
  // finds ⋯ by its key. On a wide screen there is no menu to close and the
  // item keeps focus itself.
  const item = (label: string, className: string, key: string, action: () => void): HTMLButtonElement => {
    const b = button(label, className, () => {
      if (menu.classList.contains("open")) {
        setOpen(false);
        more.focus();
      }
      action();
    });
    b.dataset.focus = `${s.id}:${key}`;
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

function tag(text: string): HTMLElement {
  const span = document.createElement("span");
  span.className = "tag";
  span.textContent = text;
  return span;
}

function openLink(id: string, text: string): HTMLAnchorElement {
  const a = document.createElement("a");
  a.className = "strip-open";
  a.href = `/?session=${encodeURIComponent(id)}`;
  a.textContent = text;
  return a;
}

function headlineOf(s: SessionRow): string {
  return s.name || folderOf(s.cwd);
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

/** The state's name as the chips and tallies print it. */
function stateName(state: MergedState): string {
  switch (state) {
    case "needs-approval":
      return "needs approval";
    case "needs-input":
      return "needs input";
    case "completed":
      return "done";
    case "unknown":
      return "no integration";
    default:
      return state;
  }
}

function stateLabel(s: SessionRow): string {
  switch (stateOf(s)) {
    case "failed":
      return typeof s.lastExit === "number" ? `failed (${s.lastExit})` : "failed";
    case "exited":
      return typeof s.lastExit === "number" ? `exited (${s.lastExit})` : "exited";
    default:
      return stateName(stateOf(s));
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

function folderOf(cwd: string): string {
  const trimmed = cwd.replace(/\/+$/, "");
  const base = trimmed.slice(trimmed.lastIndexOf("/") + 1);
  return base || cwd;
}

function shellName(shell: string): string {
  return shell.slice(shell.lastIndexOf("/") + 1) || shell;
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

void fetchProfiles().then(() => poll());
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
        events?: unknown[];
      };
      if (typeof data.next === "number") eventCursor = data.next;
      if (typeof data.epoch === "string") eventEpoch = data.epoch;
      if (data.pruned || (data.events?.length ?? 0) > 0) void poll();
    } catch {
      // Network blip or daemon restart: back off, then resume the watch.
      await new Promise((r) => setTimeout(r, POLL_MS));
    }
  }
}
void watchEvents();
