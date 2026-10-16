import { describe, expect, it } from "vitest";

import { type KnowledgeSummary, knowledgePageUrl, knowledgeUrl, type ProjectSummary } from "./sessions-model";
import { tree } from "./sessions-tree";

const NOW = Date.UTC(2026, 9, 16, 12);

// `goal.md` of `markdown-preview`, condition 6: the fleet view's goal and
// record links open `/md?project=<id>&path=<knowledge path>`, where the
// page reads the file through the knowledge route, in place of the raw
// `text/plain` the route serves.

describe("knowledgePageUrl", () => {
  it("names the page with the project and the path, the path's slashes kept", () => {
    expect(knowledgePageUrl("kitterm", "markdown-preview/rounds/003.md")).toBe(
      "/md?project=kitterm&path=markdown-preview/rounds/003.md",
    );
  });

  it("encodes each segment, like the raw route it replaces", () => {
    expect(knowledgePageUrl("a b", "x y/z&q.md")).toBe("/md?project=a%20b&path=x%20y/z%26q.md");
    expect(knowledgeUrl("a b", "x y/z&q.md")).toBe("/api/projects/a%20b/knowledge/x%20y/z%26q.md");
  });
});

describe("the tree's goal line", () => {
  const project: ProjectSummary = { id: "kitterm", name: "kitterm", root: "/w/kitterm", registered: true, knowledge: "docs/goals" };
  const build = (goals: KnowledgeSummary[]) =>
    tree({ rows: [], projects: [project], goalsOf: () => goals, approvals: [], proposed: [], usage: null, now: NOW });
  const goalLines = (goals: KnowledgeSummary[]) =>
    build(goals).sections.flatMap((section) => section.lines.filter((line) => line.kind === "goal"));

  it("links the latest record on the page, else STATE.md", () => {
    const [goal] = goalLines([{ project: "kitterm", slug: "markdown-preview", status: "active", lastRecord: "markdown-preview/rounds/002.md" }]);
    expect(goal.kind === "goal" && goal.href).toBe("/md?project=kitterm&path=markdown-preview/rounds/002.md");
    const [fresh] = goalLines([{ project: "kitterm", slug: "fresh-goal", status: "active" }]);
    expect(fresh.kind === "goal" && fresh.href).toBe("/md?project=kitterm&path=fresh-goal/STATE.md");
  });

  it("never links the raw knowledge route", () => {
    const lines = goalLines([{ project: "kitterm", slug: "a", status: "active", lastRecord: "a/rounds/001.md" }, { project: "kitterm", slug: "b", status: "done" }]);
    expect(lines).toHaveLength(2);
    for (const line of lines) {
      expect(line.kind === "goal" && line.href).toMatch(/^\/md\?project=kitterm&path=/);
      expect(line.kind === "goal" && line.href).not.toContain("/api/");
    }
  });
});
