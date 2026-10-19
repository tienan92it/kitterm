import { describe, expect, it, vi } from "vitest";

import { gitWrite } from "./edit-fetch";
import {
  branchOptions,
  commitEnabled,
  type GitEntry,
  type GitStatus,
  inFlightWord,
  NEW_BRANCH,
  NO_WRITES,
  parseStatus,
  pushLabel,
  stageState,
  stageToggle,
  toggleWrite,
  wellLines,
} from "./edit-git";
import { gitWriteUrl } from "./edit-model";

// The git writes' pure parts (`code-editor` round 6; rules 7, 8, 13 and 14
// of the `Editor components` frame): the stage toggle's state from the two
// columns, the commit and push controls, the in-flight words, the branch
// switcher's options, the well, and the fetch of one write.

const entry = (path: string, xy: string, kind: GitEntry["kind"] = "ordinary"): GitEntry => ({
  path,
  index: xy[0],
  worktree: xy[1],
  kind,
});

const status = (extra: Partial<GitStatus> = {}): GitStatus => ({
  root: "/w/kitterm",
  branch: "goal/code-editor",
  upstream: "origin/goal/code-editor",
  ahead: 1,
  behind: 0,
  detached: false,
  files: [],
  counts: { changed: 3, staged: 2, unstaged: 1, untracked: 0, conflicts: 0 },
  branches: ["goal/code-editor", "main", "chore/readme"],
  writes: true,
  ...extra,
});

describe("the stage toggle", () => {
  it("reads [x] with no working-tree change, [ ] with no index change, [~] with both", () => {
    expect(stageState(entry("a.ts", "M."))).toBe("staged");
    expect(stageState(entry("a.ts", "A."))).toBe("staged");
    expect(stageState(entry("a.ts", "D."))).toBe("staged");
    expect(stageState(entry("a.ts", ".M"))).toBe("unstaged");
    expect(stageState(entry("a.ts", ".D"))).toBe("unstaged");
    expect(stageState(entry("a.ts", "MM"))).toBe("partial");
    expect(stageState(entry("a.ts", "AM"))).toBe("partial");
    expect(stageToggle("staged")).toBe("[x]");
    expect(stageToggle("unstaged")).toBe("[ ]");
    expect(stageToggle("partial")).toBe("[~]");
  });

  it("reads an untracked and a conflicted file as unstaged, and a rename by its columns", () => {
    expect(stageState(entry("new.ts", "??", "untracked"))).toBe("unstaged");
    expect(stageState(entry("x.ts", "UU", "unmerged"))).toBe("unstaged");
    expect(stageState(entry("new.ts", "R.", "renamed"))).toBe("staged");
    expect(stageState(entry("new.ts", "RM", "renamed"))).toBe("partial");
  });

  it("stages everything but a staged file, which it unstages (rule 8)", () => {
    expect(toggleWrite(entry("a.ts", "M."))).toBe("unstage");
    expect(toggleWrite(entry("a.ts", ".M"))).toBe("stage");
    expect(toggleWrite(entry("a.ts", "MM"))).toBe("stage");
    expect(toggleWrite(entry("new.ts", "??", "untracked"))).toBe("stage");
  });
});

describe("the commit and push controls", () => {
  it("lets [ commit ] answer only with a staged file and a message with a word", () => {
    const counts = { changed: 3, staged: 2, unstaged: 1, untracked: 0, conflicts: 0 };
    expect(commitEnabled("fix: the thing", counts)).toBe(true);
    expect(commitEnabled("   \n", counts)).toBe(false);
    expect(commitEnabled("", counts)).toBe(false);
    expect(commitEnabled("fix", { ...counts, staged: 0 })).toBe(false);
    expect(commitEnabled("fix", null)).toBe(false);
  });

  it("puts the ahead count inside [ push ] while the branch is ahead", () => {
    expect(pushLabel(status({ ahead: 1 }))).toBe("[ push ↑1 ]");
    expect(pushLabel(status({ ahead: 12 }))).toBe("[ push ↑12 ]");
    expect(pushLabel(status({ ahead: 0 }))).toBe("[ push ]");
    expect(pushLabel(null)).toBe("[ push ]");
  });

  it("names the in-flight states with the turning mark (rule 14)", () => {
    expect(inFlightWord("commit")).toEqual({ mark: "◐", word: "committing" });
    expect(inFlightWord("push")).toEqual({ mark: "◐", word: "pushing" });
  });

  it("keeps the last eight lines for the well", () => {
    const lines = Array.from({ length: 12 }, (_, i) => `line ${i + 1}`);
    expect(wellLines(lines)).toEqual(lines.slice(4));
    expect(wellLines(["one"])).toEqual(["one"]);
    expect(wellLines([])).toEqual([]);
  });

  it("has the one sentence for a daemon without --agent-control", () => {
    expect(NO_WRITES).toBe("Commit, push and branch need the daemon started with --agent-control; use lazygit in a pane.");
  });
});

describe("the branch switcher", () => {
  it("lists the local branches with the current one marked, then new branch…", () => {
    const options = branchOptions(status());
    expect(options.map((o) => o.value)).toEqual(["goal/code-editor", "main", "chore/readme", NEW_BRANCH]);
    expect(options.map((o) => o.current)).toEqual([true, false, false, false]);
  });

  it("puts a current branch the list lacks first, and lists only new branch… when detached", () => {
    expect(branchOptions(status({ branch: "side", branches: ["main"] })).map((o) => o.value)).toEqual(["side", "main", NEW_BRANCH]);
    expect(branchOptions(status({ branch: null, detached: true, branches: [] })).map((o) => o.value)).toEqual([NEW_BRANCH]);
  });

  it("reads branches and writes from the status body, and their absence as none", () => {
    const parsed = parseStatus({ root: "/w", branches: ["main", 3, "side"], writes: true, files: [] });
    expect(parsed.branches).toEqual(["main", "side"]);
    expect(parsed.writes).toBe(true);
    const bare = parseStatus({ root: "/w", files: [] });
    expect(bare.branches).toBeUndefined();
    expect(bare.writes).toBeUndefined();
    expect(parseStatus({ root: "/w", files: [], writes: false }).writes).toBeUndefined();
  });
});

describe("gitWrite", () => {
  const json = (status: number, body: unknown): Response =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

  it("posts the body with the editor header and hands back the lines", async () => {
    const fetch = vi.fn(async () => json(200, { ok: true, oid: "abc", lines: ["pre-commit: ok", "[main abc] m"] }));
    const result = await gitWrite(fetch, gitWriteUrl("commit"), { path: "/w/a.ts", message: "m" });
    expect(result).toEqual({ kind: "ok", body: { ok: true, oid: "abc", lines: ["pre-commit: ok", "[main abc] m"] }, lines: ["pre-commit: ok", "[main abc] m"] });
    const [url, init] = fetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("/api/git/commit");
    expect(init.method).toBe("POST");
    expect(init.credentials).toBe("same-origin");
    expect((init.headers as Record<string, string>)["X-Kitterm-Editor"]).toBe("1");
    expect((init.headers as Record<string, string>)["Content-Type"]).toBe("application/json");
    expect(JSON.parse(init.body as string)).toEqual({ path: "/w/a.ts", message: "m" });
  });

  it("keeps the daemon's own sentence and the lines on a refusal", async () => {
    const fetch = vi.fn(async () => json(502, { ok: false, error: "git push exited 1: ! [rejected] main -> main (fetch first)", lines: ["To /r.git"] }));
    const result = await gitWrite(fetch, gitWriteUrl("push"), { path: "/w/a.ts" });
    expect(result).toEqual({ kind: "error", status: 502, reason: "git push exited 1: ! [rejected] main -> main (fetch first)", lines: ["To /r.git"] });
    const locked = await gitWrite(vi.fn(async () => json(409, { ok: false, error: "index.lock is held" })), gitWriteUrl("stage"), { path: "/w/a.ts" });
    expect(locked).toEqual({ kind: "error", status: 409, reason: "index.lock is held", lines: [] });
    const bare = await gitWrite(vi.fn(async () => new Response("", { status: 500 })), gitWriteUrl("stage"), { path: "/w/a.ts" });
    expect(bare).toEqual({ kind: "error", status: 500, reason: "the daemon answered 500", lines: [] });
    const gone = await gitWrite(vi.fn(async () => Promise.reject(new TypeError("fetch failed"))), gitWriteUrl("stage"), { path: "/w/a.ts" });
    expect(gone).toEqual({ kind: "error", status: null, reason: "the daemon did not answer", lines: [] });
  });
});
