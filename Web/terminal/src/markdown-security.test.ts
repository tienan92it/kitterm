import { beforeAll, describe, expect, it, vi } from "vitest";

import { FakeElement } from "./fake-page";
import { parseMarkdown, renderMarkdown } from "./markdown";

// Condition 3 of `docs/goals/markdown-preview/goal.md`: raw HTML, a
// `javascript:`, `data:` or `vbscript:` link, and an event-handler attribute
// in a file all reach the DOM as text, and no rendered node carries an
// attribute the renderer did not set.

beforeAll(() => {
  vi.stubGlobal("document", {
    createElement: (tag: string) => new FakeElement(tag),
    createDocumentFragment: () => new FakeElement("#fragment"),
  });
});

const render = (source: string): FakeElement => renderMarkdown(parseMarkdown(source)) as unknown as FakeElement;

/** Every text node under `root`, joined. */
const textOf = (root: FakeElement): string => root.textContent;

/** Every element under `root`. */
const elements = (root: FakeElement): FakeElement[] => [...root.descendants()];

/** The attributes the renderer may set, written here by hand so a new one is a conscious change. */
const ALLOWED_ATTRIBUTES = new Set([
  "href", "target", "rel", "src", "alt", "title", "class", "id", "start", "type", "checked", "disabled",
  "data-language", "data-align", "data-markdown",
]);

const ALLOWED_TAGS = new Set([
  "H1", "H2", "H3", "H4", "H5", "H6", "P", "BLOCKQUOTE", "UL", "OL", "LI", "INPUT", "PRE", "CODE", "SPAN",
  "HR", "TABLE", "THEAD", "TBODY", "TR", "TH", "TD", "EM", "STRONG", "DEL", "BR", "A", "IMG",
]);

/** The one assertion every case shares: nothing but the renderer's own tags and attributes. */
function assertClean(root: FakeElement): void {
  for (const el of elements(root)) {
    expect(ALLOWED_TAGS.has(el.tagName), `tag ${el.tagName}`).toBe(true);
    for (const [name, value] of el.attributes) {
      expect(ALLOWED_ATTRIBUTES.has(name), `attribute ${name} on ${el.tagName}`).toBe(true);
      expect(name.toLowerCase().startsWith("on"), `handler ${name}`).toBe(false);
      expect(value.toLowerCase().replace(/\s/g, "")).not.toMatch(/^(javascript|data|vbscript):/);
      // A bare id is a global on the page: every id wears the heading prefix.
      if (name === "id") expect(value, `id ${value}`).toMatch(/^md-./);
    }
    if (el.tagName === "A") {
      const href = el.getAttribute("href") ?? "";
      expect(href, `href ${href}`).toMatch(/^(https?:|mailto:|#|(?!\/\/)[^:]*\.md(#|$))/i);
    }
  }
}

describe("raw HTML is text", () => {
  const cases = [
    "<script>alert(1)</script>",
    "<img src=x onerror=alert(1)>",
    '<iframe src="https://evil.example"></iframe>',
    "<a href=\"javascript:alert(1)\">x</a>",
    "<svg><script>alert(1)</script></svg>",
    "text with <b onmouseover=\"alert(1)\">bold</b> inside",
    // Chartered in round 3: a comment renders nothing (see "HTML comments"
    // below); every other declaration and instruction stays text.
    "<!DOCTYPE html> <?php echo 1 ?> <![CDATA[x]]>",
    "<div>\n<script>alert(1)</script>\n</div>",
    "<style>body{display:none}</style>",
  ];

  for (const source of cases) {
    it(`keeps ${JSON.stringify(source)} as the characters it is`, () => {
      const root = render(source);
      expect(textOf(root)).toBe(source);
      for (const el of elements(root)) expect(el.tagName).toBe("P");
      assertClean(root);
    });
  }

  it("keeps a tag inside a heading, a quote, a list and a table cell as text", () => {
    const root = render("# <script>x</script>\n\n> <iframe>\n\n- <img onerror=1>\n\n| <b onclick=1>a</b> |\n|---|\n| <script> |");
    expect(textOf(root)).toContain("<script>x</script>");
    expect(textOf(root)).toContain("<iframe>");
    expect(textOf(root)).toContain("<img onerror=1>");
    expect(textOf(root)).toContain("<b onclick=1>a</b>");
    assertClean(root);
  });
});

describe("a hostile link is text", () => {
  const cases: Array<[string, string]> = [
    ["[x](javascript:alert(1))", "javascript:alert(1)"],
    ["[x]( JaVaScRiPt:alert(1))", "JaVaScRiPt:alert(1)"],
    ["[x](JAVASCRIPT:alert(1))", "JAVASCRIPT:alert(1)"],
    ["[x](data:text/html,<script>alert(1)</script>)", "data:text/html,<script>alert(1)</script>"],
    ["[x](vbscript:MsgBox(1))", "vbscript:MsgBox(1)"],
    ["[x](&#106;avascript:alert(1))", "javascript:alert(1)"],
    ["[x](&#x6A;avascript:alert(1))", "javascript:alert(1)"],
    ["[x](<javascript:alert(1)>)", "javascript:alert(1)"],
    ["<javascript:alert(1)>", "javascript:alert(1)"],
    ["[x](//evil.example/a.md)", "//evil.example/a.md"],
    ["[x](file:///etc/passwd)", "file:///etc/passwd"],
  ];

  for (const [source, address] of cases) {
    it(`shows ${JSON.stringify(source)} as text with its address`, () => {
      const root = render(source);
      expect(root.querySelectorAll("a")).toEqual([]);
      expect(textOf(root)).toContain(address);
      assertClean(root);
    });
  }

  it("shows a reference link to a hostile address as text", () => {
    const root = render("[x][r]\n\n[r]: javascript:alert(1)");
    expect(root.querySelectorAll("a")).toEqual([]);
    expect(textOf(root)).toBe("x (javascript:alert(1))");
    assertClean(root);
  });

  it("keeps a tab inside the scheme from hiding it", () => {
    // A destination with a tab is not a link at all, and the text stays.
    const root = render("[x](java\tscript:alert(1))");
    expect(root.querySelectorAll("a")).toEqual([]);
    expect(textOf(root)).toBe("[x](java\tscript:alert(1))");
    assertClean(root);
  });
});

describe("a hostile image is text", () => {
  for (const source of ["![x](javascript:alert(1))", "![x](data:image/svg+xml;base64,PHN2Zz4=)", "![x](https://evil.example/t.png)", "![x](a.png)"]) {
    it(`shows ${JSON.stringify(source)} as its alt text and its address`, () => {
      const root = render(source);
      expect(root.querySelectorAll("img")).toEqual([]);
      expect(textOf(root)).toBe(`x (${source.slice(5, -1)})`);
      assertClean(root);
    });
  }

  it("keeps an image whose address holds a space as the text it is", () => {
    const source = "![x](data:image/svg+xml,<svg onload=alert(1)>)";
    const root = render(source);
    expect(root.querySelectorAll("img")).toEqual([]);
    expect(textOf(root)).toBe(source);
    assertClean(root);
  });
});

describe("an event handler anywhere is text", () => {
  it("keeps `onclick=` inside link text as text", () => {
    const root = render('[<span onclick="alert(1)">click</span>](https://ok.example)');
    const [a] = root.querySelectorAll("a");
    expect(a.getAttribute("href")).toBe("https://ok.example");
    expect(textOf(a)).toBe('<span onclick="alert(1)">click</span>');
    expect(elements(a)).toEqual([]);
    assertClean(root);
  });

  it("keeps an attribute written after a title out of the link", () => {
    // Not a link: the text stays, and the bare address inside it is the one
    // GFM autolink, to the https address and nothing else.
    const root = render('[x](https://ok.example "t" onclick=alert(1))');
    const anchors = root.querySelectorAll("a");
    expect(anchors.map((a) => [...a.attributes])).toEqual([[["href", "https://ok.example"], ["target", "_blank"], ["rel", "noopener noreferrer"]]]);
    expect(textOf(root)).toBe('[x](https://ok.example "t" onclick=alert(1))');
    assertClean(root);
  });

  it("keeps a title's quotes and angle brackets as the title's text", () => {
    const root = render('[x](https://ok.example "\\"><script>alert(1)</script>")');
    const [a] = root.querySelectorAll("a");
    expect(a.getAttribute("title")).toBe('"><script>alert(1)</script>');
    assertClean(root);
  });

  it("keeps a fence's language and a heading's slug free of markup", () => {
    const root = render("```<script>alert(1)</script>\nx\n```\n\n# <img onerror=1>");
    const [pre] = root.querySelectorAll("pre");
    expect(pre.getAttribute("data-language")).toBe("<script>alert(1)</script>");
    expect(pre.querySelector("code")?.hasAttribute("class")).toBe(false);
    expect(root.querySelector("h1")?.getAttribute("id")).toBe("md-img-onerror1");
    assertClean(root);
  });
});

describe("a heading id never clobbers a global", () => {
  it("prefixes every id, so a heading named for a global or an element is not one", () => {
    // `# __proto__` is strong emphasis around `proto`, as on GitHub, so the
    // literal name needs its underscores escaped.
    const root = render("# location\n\n# document\n\n# sessions\n\n# __proto__\n\n# \\_\\_proto\\_\\_\n\n# constructor\n\n# location");
    const ids = root.querySelectorAll("h1").map((h) => h.getAttribute("id"));
    expect(ids).toEqual(["md-location", "md-document", "md-sessions", "md-proto", "md-__proto__", "md-constructor", "md-location-1"]);
    for (const id of ids) expect(id).toMatch(/^md-/);
    assertClean(root);
  });

  it("sends a fragment link to the prefixed id", () => {
    const root = render("[go](#location)");
    expect(root.querySelector("a")?.getAttribute("href")).toBe("#md-location");
    assertClean(root);
  });
});

describe("every rendered node", () => {
  it("carries only the renderer's attributes across one document of every form", () => {
    const source = [
      "---", "title: t", "---", "# H &amp; <b>", "", "Para *em* **st** ~~del~~ `code` [l](https://a.b \"t\") [m](o.md) ![i](i.png) <https://c.d> https://e.f &copy;  ", "next\\", "line", "",
      "> quote", "", "- a", "  - [ ] b", "- [x] c", "", "1. one", "2. two", "", "```ts", "let a = 1", "```", "", "    indented", "", "***", "",
      "| a | b |", "|:-:|--:|", "| 1 | 2 |", "", "[ref]: https://g.h",
    ].join("\n");
    const root = render(source);
    expect(elements(root).length).toBeGreaterThan(30);
    assertClean(root);
  });
});

describe("HTML comments", () => {
  // The foreman's correction of round 3: GitHub and CommonMark never show a
  // comment, and a `<!-- markdownlint … -->` line printed as text.
  const html = (root: FakeElement): string => root.children.map((c) => (typeof c === "string" ? c : `<${c.tagName.toLowerCase()}>${c.textContent}</${c.tagName.toLowerCase()}>`)).join("");

  it("renders no node for a comment on a line of its own", () => {
    const root = render("<!-- markdownlint-disable-next-line MD013 -->");
    expect(root.children).toEqual([]);
    assertClean(root);
  });

  it("hides what a comment hides, a script included", () => {
    const root = render("<!-- <script>alert(1)</script> onload=x -->");
    expect(root.children).toEqual([]);
    expect(textOf(root)).not.toContain("script");
    const inline = render("a <!-- <script>alert(1)</script> --> b");
    expect(html(inline)).toBe("<p>a  b</p>");
    assertClean(inline);
  });

  it("drops a comment that spans lines, and keeps the paragraphs around it", () => {
    const root = render("before\n\n<!-- one\ntwo -->\n\nafter");
    expect(html(root)).toBe("<p>before</p><p>after</p>");
    const inside = render("x <!-- a\nb --> y");
    expect(html(inside)).toBe("<p>x  y</p>");
  });

  it("keeps an unclosed <!-- as text to the end of its paragraph", () => {
    const root = render("a <!-- not closed\nstill text\n\n<p>next</p>");
    expect(html(root)).toBe("<p>a <!-- not closed\nstill text</p><p><p>next</p></p>");
    assertClean(root);
  });

  it("reads <!--> and <!---> as comments, per CommonMark", () => {
    expect(render("<!-->").children).toEqual([]);
    expect(render("<!--->").children).toEqual([]);
    expect(html(render("a <!--> b <!---> c"))).toBe("<p>a  b  c</p>");
  });

  it("leaves every other raw HTML as text", () => {
    const root = render("<!DOCTYPE html> <div onload=x> <![CDATA[ x ]]> <?php ?>");
    expect(html(root)).toBe("<p><!DOCTYPE html> <div onload=x> <![CDATA[ x ]]> <?php ?></p>");
    assertClean(root);
  });
});
