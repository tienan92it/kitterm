import { describe, expect, it } from "vitest";

import { attention, type ModelRow, needsYouMessage, ownJobDetail, rowLine } from "./sessions-model";

/**
 * A session that ended its turn with a background job of its own still
 * running is `working`, not `done` and not `needs you`. The daemon keeps the
 * state and sends `agent.ownJobs`; the row prints the wait as its detail.
 */
const NOW = 1_795_000_000_000;

function row(overrides: Partial<ModelRow>): ModelRow {
  return { id: "r", cwd: "/w/kitterm", name: "crew", lastOutputAt: NOW, ...overrides };
}

describe("a row that waits on its own job", () => {
  it("prints working with the detail", () => {
    const line = rowLine(row({ mergedState: "working", agent: { ownJobs: 1 } }), NOW);
    expect(line.state).toBe("[working]");
    expect(line.what).toBe("waiting on its own job");
  });

  it("counts more than one job", () => {
    expect(ownJobDetail(row({ mergedState: "working", agent: { ownJobs: 3 } }))).toBe("waiting on its own 3 jobs");
  });

  it("puts the wait before a note and the last command", () => {
    const line = rowLine(
      row({ mergedState: "working", agent: { ownJobs: 1 }, note: "round 2", lastCommand: "claude" }),
      NOW,
    );
    expect(line.what).toBe("waiting on its own job");
  });

  it("does not need a person", () => {
    const waiting = row({ mergedState: "working", agent: { ownJobs: 1 } });
    expect(attention([waiting], [])).toEqual([]);
    expect(needsYouMessage(attention([waiting], []).length)).toBe("Nothing needs you");
  });

  it("prints no detail on a row that is not working, or with no job", () => {
    expect(ownJobDetail(row({ mergedState: "working" }))).toBeNull();
    expect(ownJobDetail(row({ mergedState: "working", agent: { ownJobs: 0 } }))).toBeNull();
    expect(ownJobDetail(row({ mergedState: "completed", agent: { ownJobs: 1 } }))).toBeNull();
    const asked = rowLine(row({ mergedState: "needs-input", agent: { message: "Which branch?", ownJobs: 1 } }), NOW);
    expect(asked.state).toBe("[needs you]");
    expect(asked.what).toBe("Which branch?");
  });
});
