import { describe, expect, it } from "vitest";

/**
 * The terminal page's entry does not import the preview statically.
 *
 * Rollup puts every module the entry reaches through a static import into
 * chunks that `index.html` loads before the first paint. The file preview,
 * the Markdown view, the Markdown parser and the highlighter are not needed
 * for a terminal, so they must be reachable through `import()` only
 * (`preview-loader.ts`). This walks the static imports from `main.ts` the
 * way the bundler does; `import type` is erased and does not count.
 */
const sources = import.meta.glob<string>("./*.ts", { query: "?raw", import: "default", eager: true });

const LAZY = ["./file-preview.ts", "./markdown-view.ts", "./markdown.ts", "./highlight.ts"];

/** The local modules `source` imports statically, as keys of `sources`. */
function staticImports(source: string): string[] {
  const found: string[] = [];
  // `import x from "./a"`, `import { a, type B } from "./a"`, `import "./a"`,
  // `export { a } from "./a"`, `export * from "./a"`; not `import type`,
  // not `export type`, and not `import("./a")`.
  const statement = /^\s*(import|export)\s+(?!type\s)(?:[^"';]*?\sfrom\s+)?["'](\.\/[^"']+)["']/gm;
  for (const match of source.matchAll(statement)) {
    const target = match[2];
    if (target.endsWith(".css")) continue;
    found.push(target.endsWith(".ts") ? target : `${target}.ts`);
  }
  return found;
}

/** Every module the static graph of `entry` holds. */
function reachable(entry: string): Set<string> {
  const seen = new Set<string>();
  const queue = [entry];
  while (queue.length > 0) {
    const current = queue.pop()!;
    if (seen.has(current)) continue;
    seen.add(current);
    const source = sources[current];
    expect(source, `${current} is imported and is not in src/`).toBeTypeOf("string");
    queue.push(...staticImports(source));
  }
  return seen;
}

describe("the terminal page's entry", () => {
  const graph = reachable("./main.ts");

  it("reaches the terminal", () => {
    // The walk works: a graph that finds nothing proves nothing.
    expect(graph.has("./terminal-app.ts")).toBe(true);
    expect(graph.has("./terminal-pane.ts")).toBe(true);
    expect(graph.has("./preview-loader.ts")).toBe(true);
    expect(graph.size).toBeGreaterThan(30);
  });

  it.each(LAZY)("does not import %s statically", (module) => {
    expect(graph.has(module)).toBe(false);
  });

  it("loads the preview with a dynamic import, in one place", () => {
    expect(sources["./preview-loader.ts"]).toMatch(/import\("\.\/file-preview"\)/);
    const dynamic = Object.entries(sources)
      .filter(([name]) => !name.endsWith(".test.ts"))
      .filter(([, source]) => /[^.\w]import\(["']\.\/file-preview["']\)/.test(source))
      .map(([name]) => name);
    expect(dynamic).toEqual(["./preview-loader.ts"]);
  });

  it("finds a static import where one exists", () => {
    // The `/md` page does import them: the same walk must say so.
    const md = reachable("./md.ts");
    for (const module of LAZY) expect(md.has(module), module).toBe(true);
  });

  it("does not count an erased or a dynamic import", () => {
    const source = [
      'import type { A } from "./a";',
      'export type { B } from "./b";',
      'const c = await import("./c");',
      'import { d, type D } from "./d";',
      'export { e } from "./e";',
      'import "./f";',
      'import "./g.css";',
      "import {",
      "  h,",
      '} from "./h";',
    ].join("\n");
    expect(staticImports(source)).toEqual(["./d.ts", "./e.ts", "./f.ts", "./h.ts"]);
  });
});
