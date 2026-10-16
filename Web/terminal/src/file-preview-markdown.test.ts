import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { FakeElement } from "./fake-page";
import { fullWidthUrl, metaFromHeaders, showPreview, type PreviewMeta } from "./file-preview";
import { VIEW_KEY } from "./markdown-view";

// The pane overlay on a Markdown file (`markdown-preview` round 3): rendered
// by default with `[x] rendered [ ] source`, the choice kept per viewer, the
// cut notice from the route's headers, `open full width` to `/md`, a
// relative `.md` link opened in the same overlay, a fragment scrolled to.

const SOURCE = "# Top\n\nSee [the plan](docs/plan.md#floor) and [top](#top).\n\n![shot](img/a.png)\n";

let storage: Map<string, string>;
let fetched: string[];
let routes: Record<string, { status?: number; headers?: Record<string, string>; body: string }>;

beforeEach(() => {
  storage = new Map();
  fetched = [];
  routes = {};
  vi.stubGlobal("document", {
    createElement: (tag: string) => new FakeElement(tag),
    createDocumentFragment: () => new FakeElement("#fragment"),
    createTextNode: (text: string) => text,
    addEventListener(): void {},
    removeEventListener(): void {},
  });
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => void storage.set(key, value),
  });
  vi.stubGlobal("URL", { createObjectURL: () => "blob:x", revokeObjectURL(): void {} });
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

const meta = (over: Partial<PreviewMeta> = {}): PreviewMeta => ({
  kind: "text",
  totalBytes: SOURCE.length,
  truncated: false,
  filename: "README.md",
  ...over,
});

const contentUrl = (path: string): string => `/api/files/content?path=${encodeURIComponent(path)}&session=s1`;

/** `showPreview` into a fresh host, with the text settled. */
async function open(m: PreviewMeta, text: string, path = "/w/kitterm/README.md") {
  const host = new FakeElement("div");
  const handle = showPreview(host as unknown as HTMLElement, m, new Blob([text]), undefined, { path, contentUrl });
  await settle();
  return { host, handle };
}

const settle = async (): Promise<void> => {
  for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

const click = (el: FakeElement): void => {
  for (const fn of el.listeners.get("click") ?? []) fn({ preventDefault() {}, stopPropagation() {}, target: el });
};

const textOf = (host: FakeElement, selector: string): string | undefined => host.querySelector(selector)?.textContent;

describe("a Markdown file in the overlay", () => {
  it("renders by default, with the toggle and the full-width link in the header", async () => {
    const { host } = await open(meta(), SOURCE);
    expect(host.querySelector(".md-body")).not.toBeNull();
    expect(host.querySelector(".preview-code")).toBeNull();
    expect(host.querySelector(".preview-body")?.classList.contains("preview-body-rendered")).toBe(true);
    expect(textOf(host, ".preview-title")).toBe("README.md");
    expect(textOf(host, ".preview-sub")).toBe(`${SOURCE.length} B`);
    const choices = host.querySelectorAll(".view-choice");
    expect(choices.map((c) => c.textContent)).toEqual(["[x] rendered", "[ ] source"]);
    expect(host.querySelector(".view-toggle")?.hidden).toBe(false);
    const full = host.querySelector(".preview-open-full");
    expect([full?.href, full?.target, full?.rel, full?.hidden]).toEqual(["/md?path=%2Fw%2Fkitterm%2FREADME.md", "_blank", "noopener", false]);
    expect(fullWidthUrl("/a b.md")).toBe("/md?path=%2Fa%20b.md");
  });

  it("switches to the coloured source with line numbers and keeps the choice", async () => {
    const { host } = await open(meta(), SOURCE);
    click(host.querySelectorAll(".view-choice")[1]);
    await settle();
    expect(host.querySelector(".md-body")).toBeNull();
    expect(host.querySelector(".preview-code")).not.toBeNull();
    expect(textOf(host, ".code-gutter")).toBe("1\n2\n3\n4\n5");
    expect(host.querySelector(".preview-body")?.classList.contains("preview-body-rendered")).toBe(false);
    expect(storage.get(VIEW_KEY)).toBe("source");

    // The next overlay opens on the kept choice.
    const next = await open(meta(), SOURCE);
    expect(next.host.querySelector(".preview-code")).not.toBeNull();
    expect(next.host.querySelectorAll(".view-choice").map((c) => c.textContent)).toEqual(["[ ] rendered", "[x] source"]);
  });

  it("says a cut file is cut, in the header and on the last line, with the real sizes", async () => {
    const shown = "# Head\n\n" + "x".repeat(1020);
    const { host } = await open(meta({ totalBytes: 2 * 1024 * 1024, truncated: true }), shown);
    expect(textOf(host, ".preview-sub")).toBe("2.0 MB · the first 1.0 KB shown");
    const sheet = host.querySelector(".md-sheet");
    const last = sheet?.children[sheet.children.length - 1] as FakeElement;
    expect([last.className, last.textContent]).toEqual(["preview-note", "Showing the first 1.0 KB of 2.0 MB."]);
    // The source view says it too.
    click(host.querySelectorAll(".view-choice")[1]);
    await settle();
    expect(textOf(host, ".preview-note")).toBe("Showing the first 1.0 KB of 2.0 MB.");
  });

  it("names an empty file", async () => {
    const { host } = await open(meta({ totalBytes: 0, filename: "NOTES.md" }), "");
    expect(textOf(host, ".preview-note")).toBe("NOTES.md is empty.");
    expect(host.querySelector(".md-body")).toBeNull();
  });

  it("opens a relative .md link in the same overlay, resolved against the file's directory, and scrolls to the fragment", async () => {
    routes[contentUrl("/w/kitterm/docs/plan.md")] = {
      body: "# Plan\n\n## Floor\n\ntext",
      headers: { "X-Kitterm-Kind": "text", "X-Kitterm-Total-Bytes": "22", "X-Kitterm-Truncated": "0" },
    };
    const { host } = await open(meta(), SOURCE);
    const scrim = host.children[0] as FakeElement;
    const link = host.querySelector("[data-markdown]") as FakeElement;
    expect(link.getAttribute("data-markdown")).toBe("docs/plan.md#floor");
    click(link);
    await settle();
    expect(fetched).toEqual([contentUrl("/w/kitterm/docs/plan.md")]);
    // The same scrim, the new file: one overlay, not a second.
    expect(host.children).toHaveLength(1);
    expect(host.children[0]).toBe(scrim);
    expect(textOf(host, ".preview-title")).toBe("plan.md");
    expect(textOf(host, ".preview-sub")).toBe("22 B");
    expect(host.querySelector("h2")?.getAttribute("id")).toBe("md-floor");
    expect(host.querySelector(".preview-open-full")?.href).toBe("/md?path=%2Fw%2Fkitterm%2Fdocs%2Fplan.md");
    expect(scrim.getAttribute("aria-label") ?? host.querySelector(".preview-card")?.getAttribute("aria-label")).toBe("Preview of plan.md");
  });

  it("scrolls a fragment link inside the file without fetching", async () => {
    const { host } = await open(meta(), SOURCE);
    const heading = host.querySelector("h1") as FakeElement;
    const scrolled = vi.fn();
    heading.scrollIntoView = scrolled;
    click(host.querySelectorAll("[data-markdown]")[1]);
    await settle();
    expect(scrolled).toHaveBeenCalledTimes(1);
    expect(fetched).toEqual([]);
  });

  it("says why a linked file cannot be read, and keeps the overlay", async () => {
    const { host } = await open(meta(), SOURCE);
    click(host.querySelector("[data-markdown]") as FakeElement);
    await settle();
    expect(textOf(host, ".preview-note")).toBe("Cannot read /w/kitterm/docs/plan.md: the daemon answered 404.");
    expect(textOf(host, ".preview-title")).toBe("plan.md");
    expect(host.querySelector(".md-body")).toBeNull();
    expect(host.children).toHaveLength(1);
  });

  it("resolves a relative image to the same route, and shows no other image", async () => {
    const { host } = await open(meta(), SOURCE + "![far](https://x/y.png)\n");
    const images = host.querySelectorAll("img");
    expect(images.map((img) => img.getAttribute("src"))).toEqual([contentUrl("/w/kitterm/img/a.png")]);
    expect(host.querySelector('[class="md-image-text"]')?.textContent).toBe("far (https://x/y.png)");
  });

  it("reads the route's headers into the meta the overlay shows", () => {
    const headers = new Headers({ "X-Kitterm-Kind": "text", "X-Kitterm-Total-Bytes": "4096", "X-Kitterm-Truncated": "1" });
    expect(metaFromHeaders(headers, "/a/b/c.md")).toEqual({ kind: "text", totalBytes: 4096, truncated: true, filename: "c.md" });
    expect(metaFromHeaders(new Headers(), "x").kind).toBe("binary");
  });
});

describe("a file that is not Markdown", () => {
  it("shows the source alone, with no toggle and no full-width link", async () => {
    const { host } = await open(meta({ filename: "main.ts", totalBytes: 10 }), "let a = 1;", "/w/main.ts");
    expect(host.querySelector(".preview-code")).not.toBeNull();
    expect(host.querySelector(".md-body")).toBeNull();
    expect(host.querySelector(".view-toggle")?.hidden).toBe(true);
    expect(host.querySelector(".preview-open-full")?.hidden).toBe(true);
    expect(textOf(host, ".preview-sub")).toBe("10 B");
  });

  it("keeps the plain truncation note for other text", async () => {
    const { host } = await open(meta({ filename: "big.log", totalBytes: 5_000_000, truncated: true }), "line\n", "/w/big.log");
    expect(textOf(host, ".preview-sub")).toBe("4.8 MB · showing the first part");
    expect(host.querySelector(".preview-note")).toBeNull();
  });
});
