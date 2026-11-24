import { describe, expect, it } from "vitest";

import { attention, type ModelRow, needsYouMessage, ownJobDetail, rowLine } from "./sessions-model";

/**
 * A session that ended its turn with a background job of its own still
 * running is `completed`, as any ended turn is. The daemon sends
 * `agent.ownJobs`; the row prints `done` with the count as its detail.
 */
const NOW = 1_795_000_000_000;

function row(overrides: Partial<ModelRow>): ModelRow {
  return { id: "r", cwd: "/w/kitterm", name: "crew", lastOutputAt: NOW, ...overrides };
}

describe("a row whose turn ended with a job of its own running", () => {
  it("prints done with the detail for one job", () => {
    const line = rowLine(row({ mergedState: "completed", agent: { ownJobs: 1 } }), NOW);
    expect(line.state).toBe("[done]");
    expect(line.what).toBe("1 job running");
  });

  it("counts more than one job", () => {
    expect(ownJobDetail(row({ mergedState: "completed", agent: { ownJobs: 3 } }))).toBe("3 jobs running");
  });

  it("puts the count before a note and the last command", () => {
    const line = rowLine(
      row({ mergedState: "completed", agent: { ownJobs: 1 }, note: "round 2", lastCommand: "claude" }),
      NOW,
    );
    expect(line.what).toBe("1 job running");
  });

  it("does not need a person", () => {
    const done = row({ mergedState: "completed", agent: { ownJobs: 1 } });
    expect(attention([done], [])).toEqual([]);
    expect(needsYouMessage(attention([done], []).length)).toBe("Nothing needs you");
  });

  it("prints no detail on a row that is not completed, or with no job", () => {
    expect(ownJobDetail(row({ mergedState: "completed" }))).toBeNull();
    expect(ownJobDetail(row({ mergedState: "completed", agent: { ownJobs: 0 } }))).toBeNull();
    expect(ownJobDetail(row({ mergedState: "working", agent: { ownJobs: 1 } }))).toBeNull();
    const asked = rowLine(row({ mergedState: "needs-input", agent: { message: "Which branch?", ownJobs: 1 } }), NOW);
    expect(asked.state).toBe("[needs you]");
    expect(asked.what).toBe("Which branch?");
  });
});
