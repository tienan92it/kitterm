import { describe, expect, it } from "vitest";

import { summarize, waitedLabel } from "./approval-format";

describe("waitedLabel", () => {
  it("counts seconds while the wait is short", () => {
    expect(waitedLabel(0)).toBe("waiting 0s");
    expect(waitedLabel(4_400)).toBe("waiting 4s");
    expect(waitedLabel(59_000)).toBe("waiting 59s");
  });

  it("switches to minutes once seconds stop being useful", () => {
    expect(waitedLabel(60_000)).toBe("waiting 1m");
    expect(waitedLabel(305_000)).toBe("waiting 5m");
  });

  it("never reports a negative wait when clocks disagree", () => {
    expect(waitedLabel(-5_000)).toBe("waiting 0s");
  });
});

describe("summarize", () => {
  it("leads with the command, which is what you are approving", () => {
    expect(summarize('{"command":"rm -rf build","description":"clean"}')).toBe("rm -rf build");
  });

  it("falls back to the path for file tools", () => {
    expect(summarize('{"file_path":"/etc/hosts","content":"…"}')).toBe("/etc/hosts");
    expect(summarize('{"path":"/tmp/x"}')).toBe("/tmp/x");
  });

  it("shows the whole object when no field stands out", () => {
    expect(summarize('{"pattern":"TODO"}')).toContain("pattern");
  });

  /// A truncated payload must still be readable rather than becoming an error.
  it("passes through anything that is not JSON", () => {
    expect(summarize('{"command":"rm -rf bu')).toBe('{"command":"rm -rf bu');
    expect(summarize("")).toBe("");
  });

  it("ignores a command that is not a string", () => {
    expect(summarize('{"command":42}')).toContain("42");
  });
});
