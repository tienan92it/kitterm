import { describe, expect, it } from "vitest";

import type { ProjectCheckout, ProjectEntry } from "./edit-model";
import {
  absolutePath,
  moreFilesLine,
  movePaletteSelection,
  PALETTE_MAX_FILES,
  paletteGroups,
  paletteRows,
  paletteRowUrl,
} from "./palette-model";

const PROJECTS: ProjectEntry[] = [
  { id: "kitterm", name: "kitterm", root: "/Users/t/kitterm", registered: true },
  { id: "docs-site", name: "docs-site", root: "/Users/t/docs-site", registered: true },
];
const STATUSES = new Map<string, ProjectCheckout>([
  ["/Users/t/kitterm", { branch: "main", changed: 3 }],
  ["/Users/t/docs-site", { branch: "main", changed: 0 }],
]);

describe("paletteGroups", () => {
  it("has no FILES group with no repository, whatever the query", () => {
    const groups = paletteGroups(null, PROJECTS, STATUSES, "kit");
    expect(groups.files).toEqual([]);
    expect(groups.fileCount).toBe(0);
    expect(groups.projects.map((p) => p.line.name)).toEqual(["kitterm"]);
    expect(groups.empty).toBe(false);
  });

  it("is empty when neither a file nor a project matches", () => {
    const groups = paletteGroups({ root: "/r", files: ["a.ts", "b.ts"] }, PROJECTS, STATUSES, "zzzzz");
    expect(groups.files).toEqual([]);
    expect(groups.projects).toEqual([]);
    expect(groups.empty).toBe(true);
  });

  it("matches a file on its whole relative path and builds its absolute path, tag and directory", () => {
    const groups = paletteGroups({ root: "/Users/t/kitterm", files: ["Tests/KittermCLITests/GoalsLayoutDocsTests.swift"] }, [], new Map(), "doc");
    expect(groups.files).toHaveLength(1);
    const row = groups.files[0];
    expect(row.path).toBe("/Users/t/kitterm/Tests/KittermCLITests/GoalsLayoutDocsTests.swift");
    expect(row.directory).toBe("Tests/KittermCLITests");
    expect(row.tag?.text).toBe("sw");
    expect(row.runs.map((r) => r.text).join("")).toBe("GoalsLayoutDocsTests.swift");
    expect(row.runs.filter((r) => r.matched).map((r) => r.text)).toEqual(["Doc"]);
  });

  it("caps the file rows at PALETTE_MAX_FILES but counts every match", () => {
    const files = Array.from({ length: 20 }, (_, i) => `file${i}.ts`);
    const groups = paletteGroups({ root: "/r", files }, [], new Map(), "file");
    expect(groups.files).toHaveLength(PALETTE_MAX_FILES);
    expect(groups.fileCount).toBe(20);
  });

  it("orders matches by score, best first, with a deterministic tie-break", () => {
    // "ab" at a word start in "ab.ts" and "ab.go" ties; alphabetical order
    // then decides, same as the project tie-break by name.
    const groups = paletteGroups({ root: "/r", files: ["ab.go", "ab.ts"] }, [], new Map(), "ab");
    expect(groups.files.map((f) => f.path)).toEqual(["/r/ab.go", "/r/ab.ts"]);
  });

  it("matches a project on its name alone, the same way as a file", () => {
    const groups = paletteGroups(null, PROJECTS, STATUSES, "docs");
    expect(groups.projects.map((p) => p.line.name)).toEqual(["docs-site"]);
    expect(groups.projects[0].line.branch).toBe("main");
    expect(groups.projects[0].line.changed).toBeNull();
  });

  it("matches every file and project with an empty query, in a stable order", () => {
    const groups = paletteGroups({ root: "/r", files: ["b.ts", "a.ts"] }, PROJECTS, STATUSES, "");
    expect(groups.fileCount).toBe(2);
    expect(groups.files.map((f) => f.path)).toEqual(["/r/a.ts", "/r/b.ts"]);
    expect(groups.projects).toHaveLength(2);
    expect(groups.empty).toBe(false);
  });
});

describe("moreFilesLine", () => {
  it("names how many matches do not show", () => {
    expect(moreFilesLine(20)).toBe("12 more files: type more of the name");
  });

  it("is null while every match already shows", () => {
    expect(moreFilesLine(0)).toBeNull();
    expect(moreFilesLine(PALETTE_MAX_FILES)).toBeNull();
  });
});

describe("paletteRows and movePaletteSelection", () => {
  it("lists every file row before every project row", () => {
    const groups = paletteGroups({ root: "/r", files: ["a.ts"] }, PROJECTS, STATUSES, "");
    const rows = paletteRows(groups);
    expect(rows.map((r) => r.kind)).toEqual(["file", "project", "project"]);
  });

  it("moves down from no selection to the first row, and clamps at the ends", () => {
    expect(movePaletteSelection(3, -1, "down")).toBe(0);
    expect(movePaletteSelection(3, 2, "down")).toBe(2);
    expect(movePaletteSelection(3, -1, "up")).toBe(2);
    expect(movePaletteSelection(3, 0, "up")).toBe(0);
  });

  it("has no row to select when there are none", () => {
    expect(movePaletteSelection(0, -1, "down")).toBe(-1);
  });
});

describe("absolutePath and paletteRowUrl", () => {
  it("joins a root and a relative path, the root alone at the filesystem root", () => {
    expect(absolutePath("/Users/t/kitterm", "src/a.ts")).toBe("/Users/t/kitterm/src/a.ts");
    expect(absolutePath("/", "src/a.ts")).toBe("/src/a.ts");
  });

  it("opens a file row at its path through the session, and a project row at its root with no session", () => {
    const groups = paletteGroups({ root: "/r", files: ["a.ts"] }, PROJECTS, STATUSES, "");
    const [file, project] = paletteRows(groups);
    expect(paletteRowUrl(file, "sess-1")).toBe("/edit?path=%2Fr%2Fa.ts&session=sess-1");
    // Tied at score 0 (an empty query), the projects sort by name: "docs-site"
    // before "kitterm".
    expect(paletteRowUrl(project, "sess-1")).toBe(`/edit?path=${encodeURIComponent(PROJECTS[1].root)}`);
  });
});
