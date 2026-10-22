import { describe, expect, it } from "vitest";

import { cwdUrl, headerName, OPEN_FROM_TREE, pageTarget, pageTitle, readmeIn, terminalUrl } from "./edit-model";
import { foldersToOpen } from "./edit-tree";

// The folder form of `/edit` (`code-editor` round 7, `corpus/04-quick-open.md`
// item 1): the page keeps one target shape, the daemon says whether it is
// a folder, and the pure parts here decide what opens: the folder's
// `README.md` when it holds one, else the tree down to the folder and the
// one sentence in the editor area.

describe("the page target", () => {
  it("is the path and the session, for a file and for a folder alike", () => {
    expect(pageTarget("?path=%2Fw%2Fkitterm&session=abc")).toEqual({ path: "/w/kitterm", session: "abc" });
    expect(pageTarget("?path=%2Fw%2Fkitterm%2Fsrc%2Fa.ts")).toEqual({ path: "/w/kitterm/src/a.ts", session: null });
    expect(pageTarget("?path=&session=abc")).toBeNull();
    expect(pageTarget("")).toBeNull();
  });
});

describe("the folder decision", () => {
  const entries = [
    { name: "Web", dir: true },
    { name: "readme.md", dir: true },
    { name: "Package.swift", dir: false },
    { name: "ReadMe.md", dir: false },
    { name: "README.md", dir: false },
  ];

  it("opens the folder's README.md, by name regardless of case, the first file in the listing's order", () => {
    expect(readmeIn("/w/kitterm", entries)).toBe("/w/kitterm/ReadMe.md");
    expect(readmeIn("/", [{ name: "README.md", dir: false }])).toBe("/README.md");
  });

  it("opens nothing from a folder without one, and a folder named readme.md is not one", () => {
    expect(readmeIn("/w/kitterm/src", [{ name: "a.ts", dir: false }, { name: "readme.md", dir: true }])).toBeNull();
    expect(readmeIn("/w/kitterm/src", [])).toBeNull();
    expect(OPEN_FROM_TREE).toBe("Open a file from the tree.");
  });

  it("opens the tree down to the folder: its ancestors under the root, then the folder, the root alone for the root", () => {
    expect(foldersToOpen("/w/kitterm", "/w/kitterm")).toEqual(["/w/kitterm"]);
    expect(foldersToOpen("/w/kitterm", "/w/kitterm/Web/terminal/src")).toEqual([
      "/w/kitterm",
      "/w/kitterm/Web",
      "/w/kitterm/Web/terminal",
      "/w/kitterm/Web/terminal/src",
    ]);
    // A folder outside the root opens nothing: the tree says there is no project.
    expect(foldersToOpen("/w/kitterm", "/w/other/src")).toEqual([]);
  });

  it("heads a folder page with the project and the folder, the project alone at its root", () => {
    expect(headerName({ name: "kitterm", relative: "Web/terminal/src" }, "/w/kitterm/Web/terminal/src")).toEqual({
      project: "kitterm",
      path: "Web/terminal/src",
    });
    expect(headerName({ name: "kitterm", relative: "" }, "/w/kitterm")).toEqual({ project: "kitterm", path: "" });
    // The README the folder opened keeps the folder as its directory.
    expect(headerName({ name: "kitterm", relative: "README.md" }, "/w/kitterm/README.md")).toEqual({
      project: "kitterm",
      path: "README.md",
    });
  });

  it("titles the page with the folder's name and opens the terminal in the folder itself", () => {
    expect(pageTitle("/w/kitterm/Web/terminal/src")).toBe("src — kitterm");
    expect(pageTitle("/w/kitterm")).toBe("kitterm — kitterm");
    expect(cwdUrl("/w/kitterm/Web terminal")).toBe("/?cwd=%2Fw%2Fkitterm%2FWeb%20terminal");
    // A file's terminal link is still its directory.
    expect(terminalUrl("/w/kitterm/src/a.ts")).toBe("/?cwd=%2Fw%2Fkitterm%2Fsrc");
  });
});
