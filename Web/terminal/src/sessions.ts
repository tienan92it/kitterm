import "./tokens.css";
import "./sessions.css";
import { resolveFontFamily } from "./fonts";
import { summarize, waitedLabel } from "./approval-format";
import { loadSettings } from "./settings-store";
import { applyThemeTokens } from "./theme-tokens";
import { findThemeById } from "./themes";

/**
 * The fleet view: every live shell, its mark-derived state, and what it last
 * ran — the supervision surface for watching agents from any device. Polls
 * `/api/sessions` and links each row back to `/?session=<id>`.
 *
 * Deliberately its own page, not the terminal: `/` stays "open a tab, get a
 * shell". This is a read-only dashboard.
 */

type SessionState = "running" | "idle" | "unknown";

type SessionRow = {
  id: string;
  shell: string;
  cwd: string;
  pid: number;
  attached: boolean;
  observers: number;
  state: SessionState;
  marks: number;
  lastCommand?: string;
  lastExit?: number;
  profile?: string;
};

type Profile = { name: string; command: string; cwd?: string };

/** A tool call an agent is blocked on, waiting for a human to decide. */
type Approval = {
  id: string;
  tool: string;
  input: string;
  session?: string;
  waitingMs: number;
};

const POLL_MS = 2000;

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
let lastSessions: SessionRow[] = [];
/** One request at a time: a response slower than the poll interval must not
 * overlap the next tick, or an older snapshot could repaint over a newer one. */
let inFlight = false;
/** Named session profiles (~/.kitterm/profiles.json), fetched once — they are
 * the user's own config and change only by editing the file. */
let profiles: Profile[] = [];
/** This client's token is watch-only (the daemon 403s the profiles route for
 * it). Watch clients cannot start shells at all, so the launcher is hidden
 * rather than shown with buttons that would be refused. */
let watchOnly = false;
let approvals: Approval[] = [];
/** Ids being answered right now, so a second tap cannot double-post. */
const answering = new Set<string>();

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
    // Repaint with the launcher on the next poll even if sessions unchanged.
    lastSignature = "";
  } catch {
    // No profiles is a fine state; the launcher just shows "new shell".
  }
}

async function poll(): Promise<void> {
  if (inFlight || document.hidden) return;
  inFlight = true;
  try {
    const [sessionsRes, approvalsRes] = await Promise.all([
      fetch("/api/sessions", { headers: { accept: "application/json" } }),
      fetch("/api/approvals", { headers: { accept: "application/json" } }),
    ]);
    if (!sessionsRes.ok) throw new Error(String(sessionsRes.status));
    const data = (await sessionsRes.json()) as { ok: boolean; sessions: SessionRow[] };
    // A daemon too old to know about approvals is not an error; it just has
    // none. Same for a watch client, which is refused the listing.
    approvals = approvalsRes.ok
      ? (((await approvalsRes.json()) as { approvals?: Approval[] }).approvals ?? [])
      : [];
    render(data.sessions ?? []);
  } catch {
    renderError();
  } finally {
    inFlight = false;
  }
}

function render(sessions: SessionRow[]): void {
  if (!root) return;
  // Skip DOM churn when nothing changed — this repaints every 2s.
  // Approvals are part of the signature: a new one must repaint immediately.
  const signature = JSON.stringify([sessions, approvals.map((a) => a.id)]);
  if (signature === lastSignature) return;
  lastSignature = signature;
  lastSessions = sessions;

  root.replaceChildren();
  root.append(header(sessions.length));
  // Above everything: an agent is stopped until this is answered.
  if (approvals.length > 0) root.append(approvalPanel());
  if (!watchOnly) root.append(launcher());

  if (sessions.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = watchOnly
      ? "No live sessions to watch."
      : "No live sessions. Open a tab to start a shell.";
    root.append(empty);
    return;
  }

  const list = document.createElement("ul");
  list.className = "list";
  for (const s of sessions) list.append(row(s));
  root.append(list);
}

function header(count: number): HTMLElement {
  const h = document.createElement("header");
  const title = document.createElement("h1");
  title.textContent = "Sessions";
  const badge = document.createElement("span");
  badge.className = "count";
  badge.textContent = String(count);
  h.append(title, badge);
  return h;
}

/** One-click session starters: a plain shell, plus one per profile. */
function launcher(): HTMLElement {
  const bar = document.createElement("nav");
  bar.className = "launcher";
  bar.append(launchLink("new shell", "/", "Open a local shell"));
  for (const p of profiles) {
    bar.append(
      launchLink(`+ ${p.name}`, `/?profile=${encodeURIComponent(p.name)}`, p.command),
    );
  }
  return bar;
}

function launchLink(label: string, href: string, title: string): HTMLAnchorElement {
  const a = document.createElement("a");
  a.className = "launch";
  a.href = href;
  a.target = "_blank";
  a.rel = "noopener";
  a.textContent = label;
  a.title = title;
  return a;
}

function row(s: SessionRow): HTMLElement {
  const li = document.createElement("li");
  li.className = "row";

  const link = document.createElement("a");
  link.href = `/?session=${encodeURIComponent(s.id)}`;
  link.className = "open";

  const dot = document.createElement("span");
  dot.className = `dot ${stateClass(s)}`;
  dot.title = stateLabel(s);

  const main = document.createElement("div");
  main.className = "main";

  const top = document.createElement("div");
  top.className = "top";
  const folder = document.createElement("span");
  folder.className = "folder";
  folder.textContent = folderOf(s.cwd);
  const state = document.createElement("span");
  state.className = `state ${stateClass(s)}`;
  state.textContent = stateLabel(s);
  top.append(folder, state);
  if (s.profile) {
    const chip = document.createElement("span");
    chip.className = "chip";
    chip.textContent = s.profile;
    top.append(chip);
  }

  const sub = document.createElement("div");
  sub.className = "sub";
  sub.textContent = s.lastCommand
    ? `$ ${s.lastCommand}`
    : `${shellName(s.shell)} · ${s.cwd}`;
  sub.title = s.cwd;

  const meta = document.createElement("div");
  meta.className = "meta";
  const bits: string[] = [];
  bits.push(s.attached ? "attached" : "detached");
  if (s.observers > 0) bits.push(`${s.observers} watching`);
  if (typeof s.lastExit === "number") bits.push(`exit ${s.lastExit}`);
  bits.push(`pid ${s.pid}`);
  meta.textContent = bits.join(" · ");

  main.append(top, sub, meta);
  link.append(dot, main);
  li.append(link);
  return li;
}

/**
 * Tool calls waiting on a human.
 *
 * These sit above the session list because an agent is *stopped* until one is
 * answered — and because the whole point is answering from a phone, where
 * whatever is at the top of the page is what gets read.
 */
function approvalPanel(): HTMLElement {
  const section = document.createElement("section");
  section.className = "approvals";

  const heading = document.createElement("h2");
  heading.textContent =
    approvals.length === 1 ? "1 agent is waiting" : `${approvals.length} agents are waiting`;
  section.append(heading);

  const list = document.createElement("ul");
  list.className = "approval-list";
  for (const approval of approvals) list.append(approvalRow(approval));
  section.append(list);
  return section;
}

function approvalRow(approval: Approval): HTMLElement {
  const li = document.createElement("li");
  li.className = "approval";

  const top = document.createElement("div");
  top.className = "approval-top";
  const tool = document.createElement("span");
  tool.className = "approval-tool";
  tool.textContent = approval.tool;
  const waited = document.createElement("span");
  waited.className = "approval-waited";
  waited.textContent = waitedLabel(approval.waitingMs);
  top.append(tool, waited);

  // The arguments are what you are actually approving, so they are the body of
  // the row rather than a tooltip.
  const detail = document.createElement("pre");
  detail.className = "approval-input";
  detail.textContent = summarize(approval.input);

  li.append(top, detail);

  if (approval.session) {
    const open = document.createElement("a");
    open.className = "approval-open";
    open.href = `/?session=${encodeURIComponent(approval.session)}`;
    open.textContent = "Open the pane";
    li.append(open);
  }

  // A watch token cannot decide, and the daemon would refuse it anyway —
  // showing buttons that always fail would be a lie.
  if (!watchOnly) li.append(approvalActions(approval));
  return li;
}

function approvalActions(approval: Approval): HTMLElement {
  const actions = document.createElement("div");
  actions.className = "approval-actions";

  const deny = document.createElement("button");
  deny.type = "button";
  deny.className = "approval-deny";
  deny.textContent = "Deny";
  deny.addEventListener("click", () => void decide(approval.id, "deny"));

  const allow = document.createElement("button");
  allow.type = "button";
  allow.className = "approval-allow";
  allow.textContent = "Allow";
  allow.addEventListener("click", () => void decide(approval.id, "allow"));

  actions.append(deny, allow);
  return actions;
}

/** Post one decision. The agent is unblocked by the daemon's response to its
 *  own held request, so there is nothing to do here but report failure. */
async function decide(id: string, decision: "allow" | "deny"): Promise<void> {
  if (answering.has(id)) return;
  answering.add(id);
  // Drop it locally at once: the poll is 2s away and a button that stays live
  // after a tap invites a second one.
  approvals = approvals.filter((a) => a.id !== id);
  render(lastSessions);
  try {
    const res = await fetch(`/api/approvals/${encodeURIComponent(id)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ decision }),
    });
    // 404 means it expired or someone else answered — not worth alarming over.
    if (!res.ok && res.status !== 404) throw new Error(String(res.status));
  } catch {
    // Put it back so the next poll can reconcile rather than silently losing it.
    answering.delete(id);
    void poll();
  }
}

function stateClass(s: SessionRow): string {
  if (s.state === "running") return "running";
  if (typeof s.lastExit === "number" && s.lastExit !== 0) return "failed";
  if (s.state === "idle") return "idle";
  return "unknown";
}

function stateLabel(s: SessionRow): string {
  if (s.state === "running") return "running";
  if (typeof s.lastExit === "number" && s.lastExit !== 0) return `failed (${s.lastExit})`;
  if (s.state === "idle") return "idle";
  return "no integration";
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
  root.replaceChildren();
  const p = document.createElement("p");
  p.className = "empty";
  p.textContent = "Can't reach the daemon.";
  root.append(p);
}


void fetchProfiles().then(() => poll());
setInterval(() => void poll(), POLL_MS);
// Hidden tabs skip polling (see poll); refresh immediately on return.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) void poll();
});
