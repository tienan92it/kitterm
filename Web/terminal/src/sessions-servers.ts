import { spanLabel, type ProjectRef } from "./sessions-model";
import { homePath, NO_FACT } from "./sessions-tree";

/**
 * The SERVERS section's data (`running-servers`, capability 3): from
 * the answer of `GET /api/servers` to the lines the page paints, by the
 * rules of `docs/goals/running-servers/corpus/01-approved-design.md`.
 * Pure: no clock, no DOM; the page hands in `now` and where it came from.
 */

/** One row of `GET /api/servers`. */
export type ServerRow = {
  port: number;
  addresses: string[];
  pid: number;
  program?: string;
  /** The process start, epoch milliseconds. */
  startedAt?: number;
  cwd?: string;
  project?: ProjectRef;
  /** The pane that started it, through a program (`claude`) or not. */
  session?: { id: string; name?: string; through?: string };
  /** The id of a pane that ended, carried in the server's environment,
   * when no live session has it. */
  endedSession?: string;
  /** The top ancestor below launchd, for a server outside kitterm. */
  launcher?: string;
  parent?: string;
  /** Whether the loopback address answers HTTP; absent while the probe
   * has no verdict, or for a server bound to another interface alone. */
  http?: boolean;
};

/** The route's answer. */
export type ServersAnswer = {
  ok: boolean;
  supported: boolean;
  readAt?: number;
  ageSeconds?: number;
  reason?: string;
  servers: ServerRow[];
};

/** Where the page came from: a loopback origin links `localhost`; any
 * other host links its own name for a server that binds every host. */
export type PageHost = { loopback: boolean; hostname: string };

/** One line of the section, listed or folded. */
export type ServerLine = {
  /** `servers:<pid>:<port>`, the focus key of its link. */
  key: string;
  pid: number;
  port: number;
  /** `localhost:3000`. */
  address: string;
  /** The link when the server answers HTTP and the page can reach it. */
  href: string | null;
  /** The tooltip of a plain address that answers HTTP the page cannot
   * reach: a loopback bind read from another host. */
  addressTitle: string | null;
  /** `<project> / <program>`, or the program alone. */
  where: string;
  /** Who started it: the pane, `claude in <pane>`, or outside kitterm. */
  who: string;
  kind: "http" | "tcp";
  binds: "all hosts" | "loopback";
  /** `25d`, `46m`; the dash with no start time. */
  age: string;
  /** A pane started it, or its project's root is under home (rule 4). */
  listed: boolean;
};

export type ServersSection = {
  listed: ServerLine[];
  folded: ServerLine[];
  /** `5 listening · 4 HTTP · 17 other`; null with no server. */
  head: { listening: number; http: number; other: number } | null;
};

/** The sentence with no server (rule 6). */
export const SERVERS_NONE = "No server is listening.";
/** The tooltip of an HTTP server a remote page cannot open. */
export const LISTENS_HERE_ONLY = "listens on this machine only";

/** Whether the addresses hold a wildcard bind. */
function bindsAllHosts(addresses: readonly string[]): boolean {
  return addresses.includes("0.0.0.0") || addresses.includes("::");
}

/** The program's first word, as the frame prints it: `next-server` from
 * `next-server (v15)`; the dash with no program. */
function programWord(program: string | undefined): string {
  const word = program?.trim().split(/\s+/)[0];
  return word ? word : NO_FACT;
}

/** The link of a server that answers HTTP (rule 1, and the human's
 * link rule): `http://localhost:<port>/` on a loopback page; on another
 * host, the page's own hostname when the server binds every host, else
 * none, because a loopback bind is not reachable from there. */
export function serverHref(row: ServerRow, page: PageHost): string | null {
  if (row.http !== true) return null;
  if (page.loopback) return `http://localhost:${row.port}/`;
  if (bindsAllHosts(row.addresses)) return `http://${hostForUrl(page.hostname)}:${row.port}/`;
  return null;
}

/** An IPv6 literal goes in brackets in a URL. */
function hostForUrl(hostname: string): string {
  return hostname.includes(":") && !hostname.startsWith("[") ? `[${hostname}]` : hostname;
}

/** The words of a server whose pane ended. */
export const PANE_ENDED = "kitterm pane that ended";

/** Who started the server, in the words round 3 pins: `kitterm pane
 * <name>` (the session's name, else its short id), `<through> in <name>`,
 * `kitterm pane that ended` for an exported id no live session has,
 * `outside kitterm · <launcher>`, or `outside kitterm`. */
export function startedBy(row: ServerRow): string {
  if (row.session) {
    const name = row.session.name || row.session.id.slice(0, 8);
    return row.session.through ? `${row.session.through} in ${name}` : `kitterm pane ${name}`;
  }
  if (row.endedSession) return PANE_ENDED;
  return row.launcher ? `outside kitterm · ${row.launcher}` : "outside kitterm";
}

/** Rule 4: a server is listed when a pane started it (a pane that ended
 * too), or when its project's root lies under the reader's home
 * (`homePath` rewrites such a root to `~/…`); every other server folds,
 * Homebrew's `/opt/homebrew` included. */
export function isListed(row: ServerRow): boolean {
  if (row.session || row.endedSession) return true;
  const root = row.project?.root;
  return root !== undefined && homePath(root) !== root;
}

/** The line of one row. */
export function serverLine(row: ServerRow, page: PageHost, now: number): ServerLine {
  const href = serverHref(row, page);
  const program = programWord(row.program);
  return {
    key: `servers:${row.pid}:${row.port}`,
    pid: row.pid,
    port: row.port,
    address: `localhost:${row.port}`,
    href,
    addressTitle: row.http === true && href === null ? LISTENS_HERE_ONLY : null,
    where: row.project ? `${row.project.name} / ${program}` : program,
    who: startedBy(row),
    kind: row.http === true ? "http" : "tcp",
    binds: bindsAllHosts(row.addresses) ? "all hosts" : "loopback",
    age: row.startedAt === undefined || row.startedAt > now ? NO_FACT : spanLabel(now - row.startedAt),
    listed: isListed(row),
  };
}

/** The section: the listed lines, the folded lines, each by port then
 * pid, and the header's three counts; `head` is null with no server, and
 * the page prints `SERVERS_NONE`. */
export function serversSection(answer: ServersAnswer | null, page: PageHost, now: number): ServersSection {
  const rows = [...(answer?.servers ?? [])].sort((a, b) => a.port - b.port || a.pid - b.pid);
  const lines = rows.map((row) => serverLine(row, page, now));
  const listed = lines.filter((line) => line.listed);
  const folded = lines.filter((line) => !line.listed);
  if (lines.length === 0) return { listed, folded, head: null };
  return { listed, folded, head: { listening: listed.length, http: listed.filter((line) => line.kind === "http").length, other: folded.length } };
}

/** The header's text: `5 listening · 4 HTTP · 17 other`. */
export function serversHead(head: NonNullable<ServersSection["head"]>): string {
  return `${head.listening} listening · ${head.http} HTTP · ${head.other} other`;
}

/** The fold's label: `17 other servers`, `1 other server`. */
export function othersLabel(count: number): string {
  return count === 1 ? "1 other server" : `${count} other servers`;
}

/** Where the page came from, from its `location`: `localhost`, a
 * loopback literal and `*.localhost` are loopback; with no `location`
 * (a test runner) the page is loopback. */
export function pageHostOf(hostname: string | undefined): PageHost {
  if (!hostname) return { loopback: true, hostname: "localhost" };
  const bare = hostname.replace(/^\[|\]$/g, "");
  const loopback = bare === "localhost" || bare.endsWith(".localhost") || bare === "127.0.0.1" || bare.startsWith("127.") || bare === "::1";
  return { loopback, hostname: bare };
}
