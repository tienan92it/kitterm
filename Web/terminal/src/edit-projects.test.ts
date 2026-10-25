import { describe, expect, it } from "vitest";

import { type ProjectRef, readProjects } from "./edit-fetch";
import {
  EMPTY_HOME_COMMAND,
  EMPTY_HOME_SENTENCE,
  HOME_NAME,
  HOME_TERMINAL_URL,
  type ProjectCheckout,
  type ProjectEntry,
  projectGroups,
  projectsUrl,
  SWITCH_PROJECT_QUESTION,
} from "./edit-model";

/**
 * The home page and the switcher (`code-editor` rounds 10 and 11,
 * `corpus/07-projects-and-tree.md` rules 1 and 2): the grouping and the
 * line's facts of `projectGroups`, the URLs, the empty home's two runs, and
 * `GET /api/projects` as `edit-fetch.ts` reads it. `edit.ts` wires these
 * into the page and is otherwise covered by the Playwright run of
 * `rounds/012.md`.
 */

const KITTERM: ProjectEntry = { id: "kitterm", name: "kitterm", root: "/Users/an/Workspace/kitterm", registered: true };
const API_SERVER: ProjectEntry = { id: "api-server", name: "api-server", root: "/Users/an/Workspace/acme/api-server", registered: true };
const DOCS_SITE: ProjectEntry = { id: "docs-site", name: "docs-site", root: "/Users/an/Workspace/docs-site", registered: true };
const KITBOX: ProjectEntry = { id: "kitbox", name: "kitbox", root: "/Users/an/Workspace/kitbox", registered: false };

describe("projectGroups (rule 1)", () => {
  it("groups registered projects before discovered ones, in GET /api/projects's own order", () => {
    const groups = projectGroups([KITTERM, KITBOX, API_SERVER], new Map());
    expect(groups.map((g) => [g.label, g.count, g.lines.map((l) => l.id)])).toEqual([
      ["REGISTERED", 2, ["kitterm", "api-server"]],
      ["DISCOVERED", 1, ["kitbox"]],
    ]);
  });

  it("drops a group while it holds no project", () => {
    expect(projectGroups([KITTERM], new Map()).map((g) => g.label)).toEqual(["REGISTERED"]);
    expect(projectGroups([KITBOX], new Map()).map((g) => g.label)).toEqual(["DISCOVERED"]);
    expect(projectGroups([], new Map())).toEqual([]);
  });

  it("gives every line its root under ~ and its own absolute root", () => {
    const [group] = projectGroups([KITTERM], new Map());
    expect(group.lines[0]).toMatchObject({ id: "kitterm", name: "kitterm", root: "/Users/an/Workspace/kitterm", home: "~/Workspace/kitterm" });
  });

  it("reads the branch and the changed count from a checkout's status", () => {
    const statuses = new Map<string, ProjectCheckout>([[KITTERM.root, { branch: "main", changed: 2 }]]);
    const [group] = projectGroups([KITTERM], statuses);
    expect(group.lines[0]).toMatchObject({ branch: "main", changed: 2 });
  });

  it("drops the changed count at zero, never printing M 0", () => {
    const statuses = new Map<string, ProjectCheckout>([[KITTERM.root, { branch: "main", changed: 0 }]]);
    const [group] = projectGroups([KITTERM], statuses);
    expect(group.lines[0]).toMatchObject({ branch: "main", changed: null });
  });

  it("falls back to HEAD for a detached checkout, whose branch the daemon leaves absent", () => {
    const statuses = new Map<string, ProjectCheckout>([[KITTERM.root, { branch: null, changed: 0 }]]);
    const [group] = projectGroups([KITTERM], statuses);
    expect(group.lines[0].branch).toBe("HEAD");
  });

  it("prints a dash for a root with no checkout", () => {
    const statuses = new Map<string, ProjectCheckout>([[DOCS_SITE.root, null]]);
    const [group] = projectGroups([DOCS_SITE], statuses);
    expect(group.lines[0]).toMatchObject({ branch: "-", changed: null });
  });

  it("prints no branch and no count while the read has not landed", () => {
    const [group] = projectGroups([KITTERM], new Map());
    expect(group.lines[0]).toMatchObject({ branch: "", changed: null });
  });
});

describe("the URLs and the empty home (rules 1 and 2)", () => {
  it("names the one route the home page and the switcher read", () => {
    expect(projectsUrl()).toBe("/api/projects");
  });

  it("carries the empty home as two runs, the command in the text colour after two spaces", () => {
    expect(EMPTY_HOME_SENTENCE).toBe("No project is registered and no pane sits in a checkout.");
    expect(EMPTY_HOME_COMMAND).toBe("kitterm project add <path>");
  });

  it("names the home page and its plain terminal link", () => {
    expect(HOME_NAME).toBe("Projects");
    expect(HOME_TERMINAL_URL).toBe("/");
  });

  it("asks before the switcher's choice drops typed work", () => {
    expect(SWITCH_PROJECT_QUESTION).toBe("Discard your edits and open another project?");
  });
});

describe("readProjects", () => {
  const fake = (body: unknown, status = 200) => {
    const sent: string[] = [];
    const fetch = async (url: string): Promise<Response> => {
      sent.push(url);
      return new Response(JSON.stringify(body), { status });
    };
    return { fetch, sent };
  };

  it("reads every project with an id, a name and a root", async () => {
    const projects = [
      { id: "kitterm", name: "kitterm", root: "/h/kitterm", registered: true },
      { id: "kitbox", name: "kitbox", root: "/h/kitbox", registered: false },
    ];
    const { fetch, sent } = fake({ ok: true, projects });
    const result = await readProjects(fetch, "/api/projects");
    expect(sent).toEqual(["/api/projects"]);
    expect(result).toEqual({ kind: "ok", projects });
  });

  it("drops a project missing an id, a name or a root, and defaults registered to false", async () => {
    const { fetch } = fake({
      ok: true,
      projects: [
        { id: "a", name: "a", root: "/a" },
        { id: "b", root: "/b", registered: true },
        { name: "c", root: "/c" },
        { id: "d", name: "d" },
      ],
    });
    const result = await readProjects(fetch, "/api/projects");
    expect(result).toEqual({ kind: "ok", projects: [{ id: "a", name: "a", root: "/a", registered: false }] satisfies ProjectRef[] });
  });

  it("answers an empty list with no projects field, and names an unreachable daemon", async () => {
    const { fetch } = fake({ ok: true });
    expect(await readProjects(fetch, "/api/projects")).toEqual({ kind: "ok", projects: [] });
    const gone = async (): Promise<Response> => {
      throw new Error("network");
    };
    expect(await readProjects(gone, "/api/projects")).toEqual({ kind: "error", status: null, reason: "the daemon did not answer" });
  });

  it("names a refusal with the daemon's word", async () => {
    const { fetch } = fake({ ok: false, error: "watch-only token" }, 403);
    expect(await readProjects(fetch, "/api/projects")).toEqual({ kind: "error", status: 403, reason: "the daemon answered 403: watch-only token" });
  });
});
