import "./tokens.css";
import "./sessions.css";
import { resolveFontFamily } from "./fonts";
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
    const res = await fetch("/api/sessions", { headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(String(res.status));
    const data = (await res.json()) as { ok: boolean; sessions: SessionRow[] };
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
  const signature = JSON.stringify(sessions);
  if (signature === lastSignature) return;
  lastSignature = signature;

  root.replaceChildren();
  root.append(header(sessions.length));
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
