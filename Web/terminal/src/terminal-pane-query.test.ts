import { describe, expect, it } from "vitest";
import { connectQuery, statPathsQuery } from "./terminal-pane-query";

describe("connectQuery", () => {
  it("encodes a cwd with a space as %20, never +", () => {
    const query = connectQuery({
      sessionId: null,
      hasEverConnected: false,
      outputBytes: 0,
      cwd: "/Users/an/my notes",
      histKey: null,
      profile: null,
    });
    expect(query).toBe("cwd=%2FUsers%2Fan%2Fmy%20notes");
    expect(query).not.toContain("+");
  });

  it("sends fresh=1 on a first connect with a session", () => {
    expect(
      connectQuery({ sessionId: "S1", hasEverConnected: false, outputBytes: 0, cwd: null, histKey: null, profile: null }),
    ).toBe("session=S1&fresh=1");
  });

  it("sends since on a reconnect, never fresh", () => {
    expect(
      connectQuery({ sessionId: "S1", hasEverConnected: true, outputBytes: 4096, cwd: null, histKey: null, profile: null }),
    ).toBe("session=S1&since=4096");
  });

  it("carries cwd, hist and profile alongside a session, in order", () => {
    expect(
      connectQuery({
        sessionId: "S1",
        hasEverConnected: true,
        outputBytes: 0,
        cwd: "/w",
        histKey: "main",
        profile: "vm",
      }),
    ).toBe("session=S1&since=0&cwd=%2Fw&hist=main&profile=vm");
  });

  it("is empty with nothing set", () => {
    expect(connectQuery({ sessionId: null, hasEverConnected: false, outputBytes: 0, cwd: null, histKey: null, profile: null })).toBe(
      "",
    );
  });
});

describe("statPathsQuery", () => {
  it("repeats path for each entry and encodes a space", () => {
    const query = statPathsQuery(["/a b.ts", "/c.ts"], "S1");
    expect(query).toBe("path=%2Fa%20b.ts&path=%2Fc.ts&session=S1");
    expect(query).not.toContain("+");
  });

  it("omits session when there is none", () => {
    expect(statPathsQuery(["/a.ts"], null)).toBe("path=%2Fa.ts");
  });
});
