import { describe, expect, it } from "vitest";

import {
  isListed,
  LISTENS_HERE_ONLY,
  othersLabel,
  pageHostOf,
  serverHref,
  serverLine,
  serversHead,
  serversSection,
  startedBy,
  type ServerRow,
  type ServersAnswer,
} from "./sessions-servers";

/**
 * The SERVERS section's data (`running-servers` round 3, `corpus/
 * 01-approved-design.md`): the listed and folded split (rule 4), the
 * link rule, the words of who started it, the header counts, the age and
 * the empty case. `sessions-servers-page.test.ts` pins the DOM.
 */

const NOW = new Date(2026, 9, 13, 16, 0).getTime();
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const LOOPBACK = pageHostOf("localhost");
const REMOTE = pageHostOf("mac.tailnet.ts.net");

const apps = { id: "foundation-apps", name: "foundation-apps", root: "/Users/antran/Workspace/foundation-apps", registered: false };
const homebrew = { id: "homebrew", name: "homebrew", root: "/opt/homebrew", registered: false };

const row = (over: Partial<ServerRow> = {}): ServerRow => ({
  port: 3000, addresses: ["0.0.0.0", "::"], pid: 440, program: "next-server (v15.1.0)", startedAt: NOW - 25 * DAY,
  cwd: "/Users/antran/Workspace/foundation-apps/apps/memo", project: apps, launcher: "node", parent: "node", http: true, ...over,
});
const pane: ServerRow["session"] = { id: "7F3C2A10-9B1D-4E8F-A2C3-0D1E2F3A4B5C", name: "lume-cafe postgres (local)" };
const answer = (servers: ServerRow[]): ServersAnswer => ({ ok: true, supported: true, readAt: NOW, ageSeconds: 1, servers });

describe("what the main list holds (rule 4)", () => {
  it("lists a server a pane started, whatever its project", () => {
    expect(isListed(row({ project: undefined, session: pane }))).toBe(true);
    expect(isListed(row({ project: homebrew, session: pane }))).toBe(true);
  });

  it("lists a server whose project root is under the reader's home, and folds Homebrew's redis under /opt/homebrew", () => {
    expect(isListed(row())).toBe(true);
    expect(isListed(row({ project: { ...apps, root: "/home/an/apps" } }))).toBe(true);
    expect(isListed(row({ project: homebrew }))).toBe(false);
    expect(isListed(row({ project: { ...apps, root: undefined } }))).toBe(false);
  });

  it("folds a server with no pane and no project", () => {
    expect(isListed(row({ project: undefined }))).toBe(false);
  });
});

describe("the link", () => {
  it("opens localhost on a loopback page", () => {
    expect(serverHref(row(), LOOPBACK)).toBe("http://localhost:3000/");
    expect(serverHref(row({ addresses: ["127.0.0.1"] }), LOOPBACK)).toBe("http://localhost:3000/");
    expect(serverHref(row(), pageHostOf("kitterm.localhost"))).toBe("http://localhost:3000/");
    expect(serverHref(row(), pageHostOf("127.0.0.1"))).toBe("http://localhost:3000/");
  });

  it("opens the page's own host on a remote page when the server binds every host", () => {
    expect(serverHref(row(), REMOTE)).toBe("http://mac.tailnet.ts.net:3000/");
    expect(serverHref(row({ addresses: ["::"] }), REMOTE)).toBe("http://mac.tailnet.ts.net:3000/");
    expect(serverHref(row(), pageHostOf("[fd7a::1]"))).toBe("http://[fd7a::1]:3000/");
  });

  it("is plain text with the title on a remote page when the server binds loopback alone", () => {
    const line = serverLine(row({ addresses: ["127.0.0.1", "::1"] }), REMOTE, NOW);
    expect(line.href).toBeNull();
    expect(line.addressTitle).toBe(LISTENS_HERE_ONLY);
    expect(line.kind).toBe("http");
  });

  it("is plain text, with no title, when http is false or absent", () => {
    for (const http of [false, undefined]) {
      const line = serverLine(row({ http }), LOOPBACK, NOW);
      expect([line.href, line.addressTitle, line.kind]).toEqual([null, null, "tcp"]);
    }
  });
});

describe("where it belongs and who started it", () => {
  it("prints the project and the program's first word, or the first word alone, or the dash with no program", () => {
    expect(serverLine(row(), LOOPBACK, NOW).where).toBe("foundation-apps / next-server");
    expect(serverLine(row({ project: undefined, program: "postgres" }), LOOPBACK, NOW).where).toBe("postgres");
    expect(serverLine(row({ project: undefined, program: undefined }), LOOPBACK, NOW).where).toBe("–");
    expect(serverLine(row({ program: undefined }), LOOPBACK, NOW).where).toBe("foundation-apps / –");
  });

  it("names the pane, the program in the pane, or the launcher outside kitterm", () => {
    expect(startedBy(row({ session: pane }))).toBe("kitterm pane lume-cafe postgres (local)");
    expect(startedBy(row({ session: { id: pane.id } }))).toBe("kitterm pane 7F3C2A10");
    expect(startedBy(row({ session: { id: pane.id, name: "foreman", through: "claude" } }))).toBe("claude in foreman");
    expect(startedBy(row({ session: { id: pane.id, through: "claude" } }))).toBe("claude in 7F3C2A10");
    expect(startedBy(row({ launcher: "node" }))).toBe("outside kitterm · node");
    expect(startedBy(row({ launcher: undefined }))).toBe("outside kitterm");
  });
});

describe("the facts", () => {
  it("says http or tcp, all hosts or loopback, and the age in the page's short form", () => {
    const line = serverLine(row(), LOOPBACK, NOW);
    expect([line.address, line.kind, line.binds, line.age]).toEqual(["localhost:3000", "http", "all hosts", "25d"]);
    const local = serverLine(row({ addresses: ["127.0.0.1"], http: false, startedAt: NOW - 46 * MINUTE, port: 5432, pid: 200 }), LOOPBACK, NOW);
    expect([local.address, local.kind, local.binds, local.age, local.key]).toEqual(["localhost:5432", "tcp", "loopback", "46m", "servers:200:5432"]);
    expect(serverLine(row({ addresses: ["::1"] }), LOOPBACK, NOW).binds).toBe("loopback");
    expect(serverLine(row({ addresses: ["::"] }), LOOPBACK, NOW).binds).toBe("all hosts");
  });

  it("prints the dash for a server with no start time, and for one that started after now", () => {
    expect(serverLine(row({ startedAt: undefined }), LOOPBACK, NOW).age).toBe("–");
    expect(serverLine(row({ startedAt: NOW + MINUTE }), LOOPBACK, NOW).age).toBe("–");
    expect(serverLine(row({ startedAt: NOW - 30_000 }), LOOPBACK, NOW).age).toBe("now");
    expect(serverLine(row({ startedAt: NOW - 5 * HOUR }), LOOPBACK, NOW).age).toBe("5h");
  });
});

describe("the section", () => {
  const servers = [
    row({ port: 6379, pid: 500, program: "redis-server", project: homebrew, http: false, addresses: ["127.0.0.1", "::1"] }),
    row({ port: 5432, pid: 200, program: "postgres", project: undefined, session: pane, http: false, addresses: ["127.0.0.1"] }),
    row({ port: 3000 }),
    row({ port: 7000, pid: 9, program: "ControlCenter", project: undefined, launcher: undefined, http: false }),
    row({ port: 3003, pid: 310, program: "kubectl", project: { id: "pipeline", name: "market-data-pipeline", root: "/Users/antran/Workspace/pipeline", registered: true }, session: { id: pane.id, name: "foreman", through: "claude" }, addresses: ["127.0.0.1"] }),
  ];

  it("splits the lines, each list by port, and counts the listed, the HTTP among them and the folded", () => {
    const section = serversSection(answer(servers), LOOPBACK, NOW);
    expect(section.listed.map((line) => line.address)).toEqual(["localhost:3000", "localhost:3003", "localhost:5432"]);
    expect(section.folded.map((line) => line.address)).toEqual(["localhost:6379", "localhost:7000"]);
    expect(section.head).toEqual({ listening: 3, http: 2, other: 2 });
    expect(serversHead(section.head!)).toBe("3 listening · 2 HTTP · 2 other");
    expect(section.listed[1]).toMatchObject({ where: "market-data-pipeline / kubectl", who: "claude in foreman", kind: "http", binds: "loopback" });
  });

  it("counts the HTTP servers among the listed alone: a folded HTTP server is not in the count", () => {
    const section = serversSection(answer([row({ project: homebrew, http: true })]), LOOPBACK, NOW);
    expect(section.head).toEqual({ listening: 0, http: 0, other: 1 });
  });

  it("orders two servers on one port by pid", () => {
    const section = serversSection(answer([row({ pid: 20 }), row({ pid: 10 })]), LOOPBACK, NOW);
    expect(section.listed.map((line) => line.pid)).toEqual([10, 20]);
  });

  it("has no head with no server, and with no answer", () => {
    expect(serversSection(answer([]), LOOPBACK, NOW)).toEqual({ listed: [], folded: [], head: null });
    expect(serversSection(null, LOOPBACK, NOW).head).toBeNull();
  });

  it("labels the fold by its count", () => {
    expect(othersLabel(17)).toBe("17 other servers");
    expect(othersLabel(1)).toBe("1 other server");
  });
});

describe("the page's host", () => {
  it("reads localhost, a loopback literal and *.localhost as loopback, and anything else as remote", () => {
    expect(pageHostOf("localhost")).toEqual({ loopback: true, hostname: "localhost" });
    expect(pageHostOf("kitterm.localhost").loopback).toBe(true);
    expect(pageHostOf("127.0.0.1").loopback).toBe(true);
    expect(pageHostOf("[::1]")).toEqual({ loopback: true, hostname: "::1" });
    expect(pageHostOf("mac.tailnet.ts.net")).toEqual({ loopback: false, hostname: "mac.tailnet.ts.net" });
    expect(pageHostOf("192.168.1.20").loopback).toBe(false);
    expect(pageHostOf(undefined)).toEqual({ loopback: true, hostname: "localhost" });
  });
});
