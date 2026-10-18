import { describe, expect, it } from "vitest";

import {
  editorCommand,
  editorLayoutPlan,
  evalArgument,
  installHint,
  lazygitCommand,
  splitLineSuffix,
} from "./editor-link";

describe("splitLineSuffix", () => {
  it("strips :line and :line:col so the file can be stat'ed", () => {
    expect(splitLineSuffix("src/a.ts:12:3")).toEqual({ path: "src/a.ts", line: 12, column: 3 });
    expect(splitLineSuffix("src/a.ts:12")).toEqual({ path: "src/a.ts", line: 12 });
    expect(splitLineSuffix("./src/app.tsx:12:5")).toEqual({
      path: "./src/app.tsx",
      line: 12,
      column: 5,
    });
  });

  it("leaves a path with no position alone", () => {
    expect(splitLineSuffix("src/a.ts")).toEqual({ path: "src/a.ts" });
    expect(splitLineSuffix("/tmp/a:b")).toEqual({ path: "/tmp/a:b" });
    // Only the trailing digit groups are a position; the rest is the name.
    expect(splitLineSuffix("a.ts:x:3")).toEqual({ path: "a.ts:x", line: 3 });
  });

  it("refuses a zero line and keeps the token whole", () => {
    expect(splitLineSuffix("a.ts:0")).toEqual({ path: "a.ts:0" });
    // A zero column is dropped; the line still counts.
    expect(splitLineSuffix("a.ts:3:0")).toEqual({ path: "a.ts", line: 3 });
  });

  it("never leaves an empty path", () => {
    expect(splitLineSuffix(":12")).toEqual({ path: ":12" });
  });
});

describe("evalArgument", () => {
  it("single-quotes a plain path for eval", () => {
    expect(evalArgument("src/a.ts")).toBe("'src/a.ts'");
  });

  it("escapes what the outer double quotes would read first", () => {
    expect(evalArgument("a$b")).toBe("'a\\$b'");
    expect(evalArgument("a`b")).toBe("'a\\`b'");
    expect(evalArgument('a"b')).toBe("'a\\\"b'");
    expect(evalArgument("a\\b")).toBe("'a\\\\b'");
  });

  it("closes and reopens the single quotes around an apostrophe", () => {
    expect(evalArgument("it's")).toBe("'it'\\''s'");
  });
});

describe("editorCommand", () => {
  it("resolves $EDITOR, else micro, else vi, and checks the first word", () => {
    const line = editorCommand({ path: "src/a.ts" });
    expect(line.startsWith('e=${EDITOR:-micro}; command -v "${e%% *}" >/dev/null 2>&1 || ')).toBe(
      true,
    );
    expect(line).toContain("e=vi; }");
    expect(line).toContain(installHint("micro"));
  });

  it("opens the file through eval, quoted, at its line", () => {
    expect(editorCommand({ path: "src/a.ts", line: 12, column: 3 })).toMatch(
      /; eval "\$e \+12 'src\/a\.ts'"$/,
    );
    expect(editorCommand({ path: "src/a.ts" })).toMatch(/; eval "\$e 'src\/a\.ts'"$/);
  });

  it("quotes a path with spaces, an apostrophe and a dollar", () => {
    expect(editorCommand({ path: "my dir/it's $1.md", line: 2 })).toMatch(
      /; eval "\$e \+2 'my dir\/it'\\''s \\\$1\.md'"$/,
    );
  });

  it("opens the current directory as `.`, except in micro, which refuses one", () => {
    expect(editorCommand({ cwd: true })).toMatch(
      /; case "\$\{e%% \*\}" in micro\) eval "\$e";; \*\) eval "\$e \."\;; esac$/,
    );
  });
});

describe("lazygitCommand", () => {
  it("runs lazygit when it is on PATH and prints the hint otherwise", () => {
    expect(lazygitCommand()).toBe(
      `if command -v lazygit >/dev/null 2>&1; then lazygit; else echo '${installHint("lazygit")}'; fi`,
    );
  });
});

describe("installHint", () => {
  it("names the brew command and the Linux source on one line", () => {
    expect(installHint("micro")).toBe(
      "kitterm: micro is not installed. brew install micro (macOS); micro from apt, dnf or pacman (Linux)",
    );
    expect(installHint("lazygit")).toContain("brew install lazygit (macOS)");
    expect(installHint("lazygit")).not.toContain("\n");
  });
});

describe("editorLayoutPlan", () => {
  it("splits the focused pane twice: the editor right, lazygit below", () => {
    const plan = editorLayoutPlan();
    expect(plan.map((step) => step.dir)).toEqual(["row", "column"]);
    expect(plan[0].command).toBe(editorCommand({ cwd: true }));
    expect(plan[1].command).toBe(lazygitCommand());
  });

  it("leaves the shell about a third of the width and half the height", () => {
    const [editor, git] = editorLayoutPlan();
    expect(editor.ratio).toBeCloseTo(0.38);
    expect(git.ratio).toBe(0.5);
  });
});
