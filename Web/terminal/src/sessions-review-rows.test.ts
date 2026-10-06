import { describe, expect, it } from "vitest";

import { reviewLine, reviewWait, sizeLabel, type PullRequest, type PullsAnswer, type StagedSummary } from "./sessions-stage";

/**
 * The data of the REVIEW rows (`sessions-workflow` round 7,
 * `corpus/02-review-rows.md`): each row's title, state words, size and
 * wait, and the order of the rows, the longest wait first.
 * `sessions-stage.test.ts` keeps the mapping of a pull request to its goal.
 */

const NOW = new Date(2026, 9, 6, 15, 0).getTime();
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const project = { id: "kitterm", name: "kitterm", root: "/Users/antran/Workspace/kitterm", registered: true };
const goal: StagedSummary = { project: "kitterm", slug: "sessions-workflow", status: "active" };
const at = (ms: number): string => new Date(ms).toISOString();

const pull = (over: Partial<PullRequest> = {}): PullRequest => ({
  number: 186, title: "the REVIEW section is one row per pull request", state: "open", draft: false, headRefName: "goal/sessions-workflow",
  url: "https://github.com/tienan92it/kitterm/pull/186", additions: 120, deletions: 8, createdAt: at(NOW - 2 * DAY), updatedAt: at(NOW - 2 * HOUR), ...over,
});
const answer = (pulls: PullRequest[]): PullsAnswer => ({ ok: true, readAt: NOW, pulls });
const line = (pulls: PullRequest[]) => reviewLine([{ project, goals: [goal], rows: [], pulls: answer(pulls) }]);

describe("a row's facts", () => {
  it("carries the title, the state words, the one phone word, the size and the wait's start", () => {
    const [row] = line([pull({ ci: "passing" })]).ready;
    expect(row).toMatchObject({
      number: 186, title: "the REVIEW section is one row per pull request", draft: false,
      words: ["ready", "CI ✓"], word: "CI ✓", size: "+120 −8", since: NOW - 2 * HOUR,
    });
  });

  it("counts a ready pull request's wait from updatedAt, because gh's list does not say when it left draft", () => {
    const [row] = line([pull({ createdAt: at(NOW - 5 * DAY), updatedAt: at(NOW - 3 * HOUR) })]).ready;
    expect(row.since).toBe(NOW - 3 * HOUR);
    expect(reviewWait(row.since, NOW)).toBe("3h");
  });

  it("gives a draft its words and the word `draft`", () => {
    const [row] = line([pull({ draft: true, ci: "pending" })]).drafts;
    expect(row).toMatchObject({ draft: true, words: ["draft", "CI …"], word: "draft" });
  });

  it("has no time with no updatedAt, or one that does not parse, and no size with no counts", () => {
    const none = pull({ updatedAt: undefined, createdAt: undefined, additions: undefined, deletions: undefined });
    expect(line([none]).ready[0]).toMatchObject({ since: null, size: null });
    expect(line([pull({ updatedAt: "yesterday" })]).ready[0].since).toBeNull();
    expect(line([pull({ title: undefined })]).ready[0].title).toBe("");
  });
});

describe("sizeLabel", () => {
  it("prints +A −D with the minus sign, and a zero for one missing count", () => {
    expect(sizeLabel({ additions: 120, deletions: 8 })).toBe("+120 −8");
    expect(sizeLabel({ additions: 0, deletions: 0 })).toBe("+0 −0");
    expect(sizeLabel({ additions: 40 })).toBe("+40 −0");
    expect(sizeLabel({})).toBeNull();
  });
});

describe("reviewWait", () => {
  it("prints one unit rounded down, <1m under a minute, and nothing with no time or a time after now", () => {
    expect(reviewWait(NOW - 2 * HOUR - 20 * MINUTE, NOW)).toBe("2h");
    expect(reviewWait(NOW - DAY - 5 * HOUR, NOW)).toBe("1d");
    expect(reviewWait(NOW - 40 * MINUTE, NOW)).toBe("40m");
    expect(reviewWait(NOW - 30_000, NOW)).toBe("<1m");
    expect(reviewWait(null, NOW)).toBeNull();
    expect(reviewWait(NOW + MINUTE, NOW)).toBeNull();
  });
});

describe("the order of the rows", () => {
  it("puts the longest wait first in each list, a row with no time last, and keeps gh's order between equals", () => {
    const section = line([
      pull({ number: 1, updatedAt: at(NOW - 2 * HOUR) }),
      pull({ number: 2, updatedAt: undefined }),
      pull({ number: 3, updatedAt: at(NOW - DAY) }),
      pull({ number: 4, updatedAt: at(NOW - 2 * HOUR) }),
      pull({ number: 5, draft: true, updatedAt: at(NOW - HOUR) }),
      pull({ number: 6, draft: true, updatedAt: at(NOW - 3 * DAY) }),
      pull({ number: 7, draft: true, updatedAt: undefined }),
    ]);
    expect(section.ready.map((row) => row.number)).toEqual([3, 1, 4, 2]);
    expect(section.drafts.map((row) => row.number)).toEqual([6, 5, 7]);
    expect(section.ready.map((row) => reviewWait(row.since, NOW))).toEqual(["1d", "2h", "2h", null]);
  });

  it("orders across projects by wait, not by project", () => {
    const backend = { id: "backend", name: "backend" };
    const section = reviewLine([
      { project, goals: [goal], rows: [], pulls: answer([pull({ number: 186, updatedAt: at(NOW - HOUR) })]) },
      { project: backend, goals: [], rows: [], pulls: answer([pull({ number: 2900, headRefName: "feat/accounts", updatedAt: at(NOW - DAY) })]) },
    ]);
    expect(section.ready.map((row) => [row.project.id, row.number, row.label])).toEqual([["backend", 2900, "feat accounts"], ["kitterm", 186, "sessions-workflow"]]);
  });
});
