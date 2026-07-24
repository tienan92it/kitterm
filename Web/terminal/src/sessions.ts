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
};

const POLL_MS = 2000;

const root = document.getElementById("sessions");
injectStyles();

let lastSignature = "";

async function poll(): Promise<void> {
  try {
    const res = await fetch("/api/sessions", { headers: { accept: "application/json" } });
    if (!res.ok) throw new Error(String(res.status));
    const data = (await res.json()) as { ok: boolean; sessions: SessionRow[] };
    render(data.sessions ?? []);
  } catch {
    renderError();
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

  if (sessions.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "No live sessions. Open a tab to start a shell.";
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

function injectStyles(): void {
  const style = document.createElement("style");
  style.textContent = `
    :root { color-scheme: dark; }
    body {
      margin: 0; background: #0d1117; color: #e6edf3;
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    #sessions { max-width: 760px; margin: 0 auto; padding: 24px 16px 64px; }
    header { display: flex; align-items: center; gap: 10px; margin: 8px 0 20px; }
    h1 { font-size: 20px; margin: 0; font-weight: 600; }
    .count {
      background: #21262d; color: #8b949e; border-radius: 999px;
      padding: 1px 9px; font-size: 12px; font-variant-numeric: tabular-nums;
    }
    .empty { color: #8b949e; padding: 32px 4px; }
    .list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
    .open {
      display: flex; gap: 12px; align-items: flex-start; text-decoration: none;
      color: inherit; background: #161b22; border: 1px solid #30363d;
      border-radius: 10px; padding: 12px 14px; transition: border-color .12s, background .12s;
    }
    .open:hover { border-color: #58a6ff; background: #1c2230; }
    .dot { width: 9px; height: 9px; border-radius: 50%; margin-top: 6px; flex: none; }
    .dot.running { background: #58a6ff; box-shadow: 0 0 0 3px rgba(88,166,255,.18); }
    .dot.idle { background: #3fb950; }
    .dot.failed { background: #f85149; }
    .dot.unknown { background: #6e7681; }
    .main { min-width: 0; flex: 1; }
    .top { display: flex; align-items: baseline; gap: 10px; }
    .folder { font-weight: 600; font-size: 15px; }
    .state { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
    .state.running { color: #58a6ff; }
    .state.idle { color: #3fb950; }
    .state.failed { color: #f85149; }
    .state.unknown { color: #6e7681; }
    .sub {
      color: #adbac7; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12.5px; margin-top: 3px; white-space: nowrap; overflow: hidden;
      text-overflow: ellipsis;
    }
    .meta { color: #6e7681; font-size: 11.5px; margin-top: 4px; }
  `;
  document.head.append(style);
}

void poll();
setInterval(() => void poll(), POLL_MS);
