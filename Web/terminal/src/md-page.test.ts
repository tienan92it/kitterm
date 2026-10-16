import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { FakeElement } from "./fake-page";
import { VIEW_KEY } from "./markdown-view";

// The `/md` page (`markdown-preview` round 3, `goal.md` condition 6): both
// query forms, the words of rule 6 for a 403, a 413 and a 404, the empty
// file, a path that is not Markdown, and a `.md` link that keeps `?project=`.

let storage: Map<string, string>;
let fetched: string[];
let routes: Record<string, { status?: number; headers?: Record<string, string>; body: string }>;
let fakeDocument: { title: string; getElementById: (id: string) => FakeElement | null };

beforeEach(() => {
  storage = new Map();
  fetched = [];
  routes = {};
  fakeDocument = {
    title: "",
    getElementById: () => null,
  };
  vi.stubGlobal("document", {
    ...fakeDocument,
    createElement: (tag: string) => new FakeElement(tag),
    createDocumentFragment: () => new FakeElement("#fragment"),
    createTextNode: (text: string) => text,
    querySelector: () => null,
    documentElement: new FakeElement("html"),
  });
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => void storage.set(key, value),
  });
  vi.stubGlobal("location", { search: "", hash: "", assign: vi.fn() });
  vi.stubGlobal("fetch", async (input: string) => {
    fetched.push(input);
    const route = routes[input];
    if (!route) return new Response(JSON.stringify({ ok: false, error: "not found" }), { status: 404 });
    return new Response(route.body, { status: route.status ?? 200, headers: route.headers ?? {} });
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

const settle = async (): Promise<void> => {
  for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

const md = () => import("./md");

const fileHeaders = (total: number, truncated = false): Record<string, string> => ({
  "X-Kitterm-Kind": "text",
  "X-Kitterm-Total-Bytes": String(total),
  "X-Kitterm-Truncated": truncated ? "1" : "0",
});

/** Boot the page for `search` into a fresh root, with the fetch settled. */
async function boot(search: string, hash = "") {
  const { bootMarkdownPage } = await md();
  const root = new FakeElement("main");
  const navigate = vi.fn();
  await bootMarkdownPage(root as unknown as HTMLElement, search, hash, navigate);
  await settle();
  return { root, navigate };
}

const click = (el: FakeElement): void => {
  for (const fn of el.listeners.get("click") ?? []) fn({ preventDefault() {}, stopPropagation() {}, target: el });
};

const textOf = (root: FakeElement, selector: string): string | undefined => root.querySelector(selector)?.textContent;

describe("the query forms", () => {
  it("reads ?path= through the preview route and renders the file in the column", async () => {
    const { pageTarget, sourceUrl, pageLabel } = await md();
    expect(pageTarget("?path=/w/kitterm/README.md")).toEqual({ kind: "file", path: "/w/kitterm/README.md" });
    expect(sourceUrl({ kind: "file", path: "/w/a b.md" })).toBe("/api/files/content?path=%2Fw%2Fa%20b.md");
    expect(pageLabel({ kind: "file", path: "/w/README.md" })).toBe("/w/README.md");

    routes["/api/files/content?path=%2Fw%2Fkitterm%2FREADME.md"] = { body: "# kitterm\n\nhello", headers: fileHeaders(16) };
    const { root } = await boot("?path=/w/kitterm/README.md");
    expect(fetched).toEqual(["/api/files/content?path=%2Fw%2Fkitterm%2FREADME.md"]);
    expect(textOf(root, ".md-page-path")).toBe("/w/kitterm/README.md");
    expect(textOf(root, ".md-page-size")).toBe("16 B");
    expect(root.querySelector(".md-page-main .md-body") ?? root.querySelector(".md-body")).not.toBeNull();
    expect(root.querySelector("h1")?.textContent).toBe("kitterm");
    expect(root.querySelectorAll(".view-choice").map((c) => c.textContent)).toEqual(["[x] rendered", "[ ] source"]);
  });

  it("reads ?project=&path= through the knowledge route and names the project in the header", async () => {
    const { pageTarget, sourceUrl, pageLabel, pageUrl } = await md();
    const target = pageTarget("?project=kitterm&path=markdown-preview/goal.md");
    expect(target).toEqual({ kind: "knowledge", project: "kitterm", path: "markdown-preview/goal.md" });
    expect(sourceUrl(target!)).toBe("/api/projects/kitterm/knowledge/markdown-preview/goal.md");
    expect(pageLabel(target!)).toBe("kitterm / markdown-preview/goal.md");
    expect(pageUrl(target!)).toBe("/md?project=kitterm&path=markdown-preview/goal.md");

    routes["/api/projects/kitterm/knowledge/markdown-preview/goal.md"] = { body: "# Goal: Markdown\n\ntext" };
    const { root } = await boot("?project=kitterm&path=markdown-preview/goal.md");
    expect(textOf(root, ".md-page-path")).toBe("kitterm / markdown-preview/goal.md");
    // No size header on that route: the body's own length.
    expect(textOf(root, ".md-page-size")).toBe("22 B");
    expect(root.querySelector("h1")?.textContent).toBe("Goal: Markdown");
  });

  it("prints a path under the home directory as ~/…, with the full path as the title", async () => {
    const { pageHeading } = await md();
    expect(pageHeading({ kind: "file", path: "/Users/antran/Workspace/kitterm/README.md" })).toBe("~/Workspace/kitterm/README.md");
    expect(pageHeading({ kind: "file", path: "/home/an/notes.md" })).toBe("~/notes.md");
    expect(pageHeading({ kind: "file", path: "/opt/x/notes.md" })).toBe("/opt/x/notes.md");
    expect(pageHeading({ kind: "knowledge", project: "kitterm", path: "g/goal.md" })).toBe("kitterm / g/goal.md");
    routes["/api/files/content?path=%2FUsers%2Fantran%2FREADME.md"] = { body: "# a\n", headers: fileHeaders(4) };
    const { root } = await boot("?path=/Users/antran/README.md");
    const path = root.querySelector(".md-page-path");
    expect([path?.textContent, path?.title]).toEqual(["~/README.md", "/Users/antran/README.md"]);
  });

  it("says when the query names no file", async () => {
    const { pageTarget, NO_TARGET } = await md();
    expect(pageTarget("")).toBeNull();
    expect(pageTarget("?project=kitterm")).toBeNull();
    const { root } = await boot("");
    expect(textOf(root, ".preview-note")).toBe(NO_TARGET);
    expect(fetched).toEqual([]);
  });
});

describe("the words of rule 6", () => {
  it("prints the 403 a watch token gets on the preview route", async () => {
    routes["/api/files/content?path=%2Fw%2FREADME.md"] = { status: 403, body: JSON.stringify({ ok: false, error: "watch-only token" }) };
    const { root } = await boot("?path=/w/README.md");
    expect(textOf(root, ".preview-note")).toBe("Cannot read /w/README.md: the daemon answered 403: watch-only token.");
    expect(root.querySelector(".view-toggle")).toBeNull();
  });

  it("prints the 413 of a knowledge file over the cap, with the reason", async () => {
    routes["/api/projects/kitterm/knowledge/big/STATE.md"] = { status: 413, body: JSON.stringify({ ok: false, error: "file over 262144 bytes" }) };
    const { root } = await boot("?project=kitterm&path=big/STATE.md");
    expect(textOf(root, ".preview-note")).toBe("Cannot read kitterm / big/STATE.md: the daemon answered 413: file over 262144 bytes.");
  });

  it("prints the 404 as the approved sentence", async () => {
    const { root } = await boot("?project=kitterm&path=docs/goals/LOOP.md");
    expect(textOf(root, ".preview-note")).toBe("Cannot read kitterm / docs/goals/LOOP.md: the daemon answered 404.");
  });

  it("says when the daemon does not answer", async () => {
    vi.stubGlobal("fetch", async () => {
      throw new TypeError("network");
    });
    const { root } = await boot("?path=/w/x.md");
    expect(textOf(root, ".preview-note")).toBe("Cannot read /w/x.md: the daemon did not answer.");
  });

  it("names an empty file", async () => {
    routes["/api/files/content?path=%2Fw%2FNOTES.md"] = { body: "", headers: fileHeaders(0) };
    const { root } = await boot("?path=/w/NOTES.md");
    expect(textOf(root, ".preview-note")).toBe("NOTES.md is empty.");
    expect(textOf(root, ".md-page-size")).toBe("0 B");
    expect(root.querySelector(".view-toggle")).not.toBeNull();
  });

  it("says a cut file is cut, in the header and on the last line", async () => {
    routes["/api/files/content?path=%2Fw%2FCHANGELOG.md"] = { body: "# v1\n\n" + "y".repeat(1018), headers: fileHeaders(1.2 * 1024 * 1024, true) };
    const { root } = await boot("?path=/w/CHANGELOG.md");
    expect(textOf(root, ".md-page-size")).toBe("1.2 MB · the first 1.0 KB shown");
    const main = root.querySelector(".md-page-main") as FakeElement;
    const last = main.children[main.children.length - 1] as FakeElement;
    expect([last.className, last.textContent]).toEqual(["preview-note", "Showing the first 1.0 KB of 1.2 MB."]);
  });
});

describe("the views", () => {
  it("opens on the choice the overlay kept, and keeps a new one", async () => {
    storage.set(VIEW_KEY, "source");
    routes["/api/files/content?path=%2Fw%2FREADME.md"] = { body: "# a\n", headers: fileHeaders(4) };
    const { root } = await boot("?path=/w/README.md");
    expect(root.querySelector(".preview-code")).not.toBeNull();
    expect(root.querySelector(".md-body")).toBeNull();
    click(root.querySelectorAll(".view-choice")[0]);
    await settle();
    expect(root.querySelector(".md-body")).not.toBeNull();
    expect(storage.get(VIEW_KEY)).toBe("rendered");
  });

  it("shows a path that is not Markdown as source alone, with no toggle", async () => {
    routes["/api/files/content?path=%2Fw%2Fmain.ts"] = { body: "let a = 1;\n", headers: fileHeaders(11) };
    const { root } = await boot("?path=/w/main.ts");
    expect(root.querySelector(".preview-code")).not.toBeNull();
    expect(root.querySelector(".md-body")).toBeNull();
    expect(root.querySelector(".view-toggle")).toBeNull();
    expect(textOf(root, ".code-gutter")).toBe("1");
  });

  it("shows a kind that is not text as the note", async () => {
    routes["/api/files/content?path=%2Fw%2Fa.png"] = { body: "PNG", headers: { "X-Kitterm-Kind": "image", "X-Kitterm-Total-Bytes": "3", "X-Kitterm-Truncated": "0" } };
    const { root } = await boot("?path=/w/a.png");
    expect(textOf(root, ".preview-note")).toBe("This file has no preview.");
    expect(textOf(root, ".md-page-size")).toBe("3 B");
  });

  it("sets the tab title to the file", async () => {
    routes["/api/files/content?path=%2Fw%2FREADME.md"] = { body: "# a\n", headers: fileHeaders(4) };
    await boot("?path=/w/README.md");
    expect((globalThis as unknown as { document: { title: string } }).document.title).toBe("README.md — kitterm");
  });
});

describe("links", () => {
  it("navigates a .md link within the page, keeping ?project= and moving the fragment under the heading prefix", async () => {
    routes["/api/projects/kitterm/knowledge/markdown-preview/goal.md"] = { body: "See [the plan](plan.md#the-floor) and [LOOP](../LOOP.md).\n" };
    const { root, navigate } = await boot("?project=kitterm&path=markdown-preview/goal.md");
    const [plan, loop] = root.querySelectorAll("[data-markdown]");
    click(plan);
    expect(navigate).toHaveBeenLastCalledWith("/md?project=kitterm&path=markdown-preview/plan.md#md-the-floor");
    click(loop);
    expect(navigate).toHaveBeenLastCalledWith("/md?project=kitterm&path=LOOP.md");
    expect(fetched).toHaveLength(1);
  });

  it("navigates a .md link of a file by path against the file's directory", async () => {
    routes["/api/files/content?path=%2Fw%2Fkitterm%2FREADME.md"] = { body: "[f](docs/foreman.md)", headers: fileHeaders(20) };
    const { root, navigate } = await boot("?path=/w/kitterm/README.md");
    click(root.querySelector("[data-markdown]") as FakeElement);
    expect(navigate).toHaveBeenLastCalledWith("/md?path=/w/kitterm/docs/foreman.md");
  });

  it("scrolls to the hash once the file is in", async () => {
    routes["/api/files/content?path=%2Fw%2FREADME.md"] = { body: "# A\n\n## The floor\n", headers: fileHeaders(20) };
    const scrolled: string[] = [];
    const original = FakeElement.prototype.scrollIntoView;
    FakeElement.prototype.scrollIntoView = function (this: FakeElement) {
      scrolled.push(this.getAttribute("id") ?? "");
    };
    try {
      await boot("?path=/w/README.md", "#md-the-floor");
      await boot("?path=/w/README.md", "#the-floor");
    } finally {
      FakeElement.prototype.scrollIntoView = original;
    }
    expect(scrolled).toEqual(["md-the-floor", "md-the-floor"]);
  });

  it("resolves a relative image to the preview route for a file by path, and to text for a knowledge file", async () => {
    routes["/api/files/content?path=%2Fw%2FREADME.md"] = { body: "![a](img/a.png)", headers: fileHeaders(15) };
    const byPath = await boot("?path=/w/README.md");
    expect(byPath.root.querySelector("img")?.getAttribute("src")).toBe("/api/files/content?path=%2Fw%2Fimg%2Fa.png");
    routes["/api/projects/kitterm/knowledge/g/goal.md"] = { body: "![a](img/a.png)" };
    const knowledge = await boot("?project=kitterm&path=g/goal.md");
    expect(knowledge.root.querySelector("img")).toBeNull();
    expect(knowledge.root.querySelector('[class="md-image-text"]')?.textContent).toBe("a (img/a.png)");
  });
});
