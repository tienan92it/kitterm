import { describe, expect, it } from "vitest";

import type { ILink, ILinkProvider, Terminal } from "@xterm/xterm";

import { PathLinks, type PathStat } from "./path-links";

/**
 * A terminal of one row, enough for the provider: `onRender` reports the row,
 * `registerLinkProvider` keeps the provider, and the buffer answers the line.
 */
function fakeTerminal(line: string): {
  terminal: Terminal;
  render: () => void;
  linksOn: (row: number) => Promise<ILink[] | undefined>;
} {
  let onRender: ((event: { start: number; end: number }) => void) | null = null;
  let provider: ILinkProvider | null = null;
  const terminal = {
    onRender: (listener: (event: { start: number; end: number }) => void) => {
      onRender = listener;
      return { dispose: () => undefined };
    },
    registerLinkProvider: (candidate: ILinkProvider) => {
      provider = candidate;
      return { dispose: () => undefined };
    },
    buffer: {
      active: {
        viewportY: 0,
        getLine: (row: number) =>
          row === 0 ? { isWrapped: false, translateToString: () => line } : undefined,
      },
    },
  } as unknown as Terminal;
  return {
    terminal,
    render: () => onRender?.({ start: 0, end: 0 }),
    linksOn: (row) =>
      new Promise((resolve) => provider?.provideLinks(row + 1, (links) => resolve(links))),
  };
}

const found: PathStat = { exists: true, dir: false, resolved: "/repo/src/a.ts" };

describe("a path link that carries a position", () => {
  it("asks the daemon about the file, not the token", async () => {
    const asked: string[][] = [];
    const page = fakeTerminal("ERROR in ./src/a.ts:12:3 and src/a.ts:7");
    new PathLinks(page.terminal, {
      stat: async (paths) => {
        asked.push([...paths]);
        return new Map(paths.map((path) => [path, found]));
      },
      onOpen: () => undefined,
      cwd: () => "/repo",
    });
    page.render();
    await Promise.resolve();
    // Both tokens name the same file, asked once.
    expect(asked).toEqual([["./src/a.ts", "src/a.ts"]]);
  });

  it("links the whole token and hands the click the token and the modifier", async () => {
    const opened: { text: string; inEditor: boolean; resolved: string }[] = [];
    const page = fakeTerminal("see src/a.ts:12:3 now");
    new PathLinks(page.terminal, {
      stat: async (paths) => new Map(paths.map((path) => [path, found])),
      onOpen: (stat, text, inEditor) => opened.push({ text, inEditor, resolved: stat.resolved }),
      cwd: () => "/repo",
    });
    page.render();
    await Promise.resolve();
    await Promise.resolve();
    const links = await page.linksOn(0);
    expect(links?.map((link) => link.text)).toEqual(["src/a.ts:12:3"]);
    const [link] = links ?? [];
    link.activate(
      { preventDefault: () => undefined, metaKey: true, ctrlKey: false } as MouseEvent,
      link.text,
    );
    link.activate(
      { preventDefault: () => undefined, metaKey: false, ctrlKey: false } as MouseEvent,
      link.text,
    );
    expect(opened).toEqual([
      { text: "src/a.ts:12:3", inEditor: true, resolved: "/repo/src/a.ts" },
      { text: "src/a.ts:12:3", inEditor: false, resolved: "/repo/src/a.ts" },
    ]);
  });

  it("links a bare file name with a position too", async () => {
    const page = fakeTerminal("main.ts:12 - error TS2304");
    new PathLinks(page.terminal, {
      stat: async (paths) => new Map(paths.map((path) => [path, found])),
      onOpen: () => undefined,
      cwd: () => "/repo",
    });
    page.render();
    await Promise.resolve();
    await Promise.resolve();
    const links = await page.linksOn(0);
    expect(links?.map((link) => link.text)).toEqual(["main.ts:12"]);
  });
});
