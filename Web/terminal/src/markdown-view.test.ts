import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { FakeElement } from "./fake-page";
import {
  cannotRead,
  cutFooter,
  cutHeader,
  daemonAnswered,
  emptyFile,
  imageResolver,
  isMarkdownName,
  isRelativePath,
  loadView,
  renderedView,
  resolveRelative,
  saveView,
  scrollToFragment,
  splitFragment,
  VIEW_KEY,
  viewToggle,
} from "./markdown-view";

// The shared part of the two Markdown views (`markdown-preview` round 3):
// the choice kept per viewer, the words of `corpus/01-approved-design.md`
// rule 6, the path rules a link and an image resolve by, and the rendered
// body's own link handling.

beforeAll(() => {
  vi.stubGlobal("document", {
    createElement: (tag: string) => new FakeElement(tag),
    createDocumentFragment: () => new FakeElement("#fragment"),
    createTextNode: (text: string) => text,
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.stubGlobal("document", {
    createElement: (tag: string) => new FakeElement(tag),
    createDocumentFragment: () => new FakeElement("#fragment"),
    createTextNode: (text: string) => text,
  });
});

const storage = (): Map<string, string> => {
  const map = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
  });
  return map;
};

describe("the view choice", () => {
  it("is rendered until the viewer picks source, and is kept under one key", () => {
    const map = storage();
    expect(loadView()).toBe("rendered");
    saveView("source");
    expect(map.get(VIEW_KEY)).toBe("source");
    expect(loadView()).toBe("source");
    saveView("rendered");
    expect(loadView()).toBe("rendered");
  });

  it("reads any other stored value, and a storage that throws, as rendered", () => {
    const map = storage();
    map.set(VIEW_KEY, "html");
    expect(loadView()).toBe("rendered");
    vi.stubGlobal("localStorage", {
      getItem: () => {
        throw new Error("denied");
      },
      setItem: () => {
        throw new Error("denied");
      },
    });
    expect(loadView()).toBe("rendered");
    expect(() => saveView("source")).not.toThrow();
  });

  it("prints the choice as a radio group of bracketed words", () => {
    const changes: string[] = [];
    const group = viewToggle("rendered", (view) => changes.push(view)) as unknown as FakeElement;
    const [rendered, source] = group.querySelectorAll(".view-choice");
    expect(group.getAttribute("role")).toBe("radiogroup");
    expect([rendered.textContent, source.textContent]).toEqual(["[x] rendered", "[ ] source"]);
    expect([rendered.getAttribute("aria-checked"), source.getAttribute("aria-checked")]).toEqual(["true", "false"]);
    expect([rendered.getAttribute("data-focus"), source.getAttribute("data-focus")]).toEqual(["view:rendered", "view:source"]);
    source.click();
    expect(changes).toEqual(["source"]);
    expect([rendered.textContent, source.textContent]).toEqual(["[ ] rendered", "[x] source"]);
    // A click on the checked one changes nothing.
    source.click();
    expect(changes).toEqual(["source"]);
  });
});

describe("the words of rule 6", () => {
  it("names the real sizes of a cut file in the header and the last line", () => {
    expect(cutHeader(1.2 * 1024 * 1024, 256 * 1024)).toBe("1.2 MB · the first 256 KB shown");
    expect(cutFooter(1.2 * 1024 * 1024, 256 * 1024)).toBe("Showing the first 256 KB of 1.2 MB.");
  });

  it("says why a file cannot be read, with the daemon's status and its word when it adds one", () => {
    expect(cannotRead("docs/goals/LOOP.md", daemonAnswered(404, "not found"))).toBe(
      "Cannot read docs/goals/LOOP.md: the daemon answered 404.",
    );
    expect(daemonAnswered(403, "watch-only token")).toBe("the daemon answered 403: watch-only token");
    expect(daemonAnswered(413, "file over 262144 bytes")).toBe("the daemon answered 413: file over 262144 bytes");
    expect(daemonAnswered(500)).toBe("the daemon answered 500");
    expect(daemonAnswered(500, "  ")).toBe("the daemon answered 500");
  });

  it("names an empty file", () => {
    expect(emptyFile("NOTES.md")).toBe("NOTES.md is empty.");
  });
});

describe("paths", () => {
  it("knows a Markdown file by its name", () => {
    expect(isMarkdownName("README.md")).toBe(true);
    expect(isMarkdownName("/a/b/notes.markdown")).toBe(true);
    expect(isMarkdownName("README.MD")).toBe(true);
    expect(isMarkdownName("main.ts")).toBe(false);
    expect(isMarkdownName("Makefile")).toBe(false);
  });

  it("splits a fragment off a link target", () => {
    expect(splitFragment("docs/a.md#the-mcp-bridge")).toEqual({ path: "docs/a.md", fragment: "the-mcp-bridge" });
    expect(splitFragment("#top")).toEqual({ path: "", fragment: "top" });
    expect(splitFragment("docs/a.md")).toEqual({ path: "docs/a.md", fragment: "" });
  });

  it("resolves a relative link against the file's own directory", () => {
    expect(resolveRelative("/w/kitterm/README.md", "docs/foreman.md")).toBe("/w/kitterm/docs/foreman.md");
    expect(resolveRelative("/w/kitterm/docs/goals/LOOP.md", "../../README.md")).toBe("/w/kitterm/README.md");
    expect(resolveRelative("/w/kitterm/README.md", "./docs/./x.md")).toBe("/w/kitterm/docs/x.md");
    // A knowledge path is relative to its root and stays relative.
    expect(resolveRelative("markdown-preview/goal.md", "plan.md")).toBe("markdown-preview/plan.md");
    expect(resolveRelative("markdown-preview/rounds/001.md", "../STATE.md")).toBe("markdown-preview/STATE.md");
    expect(resolveRelative("markdown-preview/goal.md", "../LOOP.md")).toBe("LOOP.md");
    // Above the root: an absolute path stays at its root, a relative one
    // keeps the `..` for the daemon to refuse.
    expect(resolveRelative("/README.md", "../../x.md")).toBe("/x.md");
    expect(resolveRelative("goal.md", "../../x.md")).toBe("../../x.md");
    // An absolute link is taken as it is.
    expect(resolveRelative("/w/README.md", "/etc/notes.md")).toBe("/etc/notes.md");
  });

  it("lets only a relative path through as an image, resolved and wrapped by the given route", () => {
    const url = imageResolver("/w/kitterm/docs/a.md", (p) => `/api/files/content?path=${encodeURIComponent(p)}`);
    expect(url("img/x.png")).toBe("/api/files/content?path=%2Fw%2Fkitterm%2Fdocs%2Fimg%2Fx.png");
    expect(url("../design/exports/y.png")).toBe("/api/files/content?path=%2Fw%2Fkitterm%2Fdesign%2Fexports%2Fy.png");
    for (const src of ["https://example.com/a.png", "data:image/png;base64,AAAA", "//cdn/x.png", "\\\\host\\x.png", "javascript:alert(1)", " HTTP://x/y.png", "#a", ""]) {
      expect(url(src), src).toBeNull();
      expect(isRelativePath(src), src).toBe(false);
    }
  });
});

describe("the rendered body", () => {
  it("opens a relative .md link through the caller and scrolls a fragment itself", () => {
    const opened: Array<[string, string]> = [];
    const body = renderedView("# Top\n\n[a](docs/a.md#x) [b](#top) [c](https://x.y)", {
      onOpen: (path, fragment) => opened.push([path, fragment]),
    }) as unknown as FakeElement;
    expect(body.className).toBe("md-body");
    const links = body.querySelectorAll("[data-markdown]");
    expect(links.map((a) => a.getAttribute("data-markdown"))).toEqual(["docs/a.md#x", "#top"]);
    let prevented = 0;
    const click = (el: FakeElement): void => {
      for (const fn of el.listeners.get("click") ?? []) fn({ preventDefault: () => void (prevented += 1), stopPropagation() {}, target: el });
    };
    click(links[0]);
    expect(opened).toEqual([["docs/a.md", "x"]]);
    expect(prevented).toBe(1);
    // The fragment link finds `md-top` on the page and scrolls; nothing opens.
    const heading = body.querySelector("h1");
    const scrolled = vi.fn();
    (heading as FakeElement).scrollIntoView = scrolled;
    click(links[1]);
    expect(opened).toHaveLength(1);
    expect(scrolled).toHaveBeenCalledTimes(1);
    expect(prevented).toBe(2);
    // The external link has no handler of its own: it is the renderer's `_blank`.
    expect(body.querySelector("[target]")?.getAttribute("rel")).toBe("noopener noreferrer");
  });

  it("scrolls to the prefixed heading id and says when there is none", () => {
    const body = renderedView("## The MCP bridge\n\ntext");
    const heading = (body as unknown as FakeElement).querySelector("h2") as FakeElement;
    const scrolled = vi.fn();
    heading.scrollIntoView = scrolled;
    expect(heading.getAttribute("id")).toBe("md-the-mcp-bridge");
    expect(scrollToFragment(body, "the-mcp-bridge")).toBe(true);
    expect(scrollToFragment(body, "#the-mcp-bridge")).toBe(true);
    expect(scrollToFragment(body, "nowhere")).toBe(false);
    expect(scrollToFragment(body, "")).toBe(false);
    expect(scrolled).toHaveBeenCalledTimes(2);
  });

  it("shows an image only where the resolver gives a URL", () => {
    const body = renderedView("![alt](a.png) ![far](https://x/y.png)", {
      resolveImage: imageResolver("/d/f.md", (p) => `/c?path=${encodeURIComponent(p)}`),
    }) as unknown as FakeElement;
    const img = body.querySelector("img");
    expect(img?.getAttribute("src")).toBe("/c?path=%2Fd%2Fa.png");
    expect(body.querySelector('[class="md-image-text"]')?.textContent).toBe("far (https://x/y.png)");
  });
});
