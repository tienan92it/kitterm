import { beforeAll, describe, expect, it, vi } from "vitest";

import { FakeElement } from "./fake-page";
import { languageForFence } from "./highlight";
import {
  MAX_DEPTH,
  parseMarkdown,
  renderMarkdown,
  resolveLink,
  slugify,
  type Block,
  type Inline,
} from "./markdown";

// Every expected tree below is written by hand, against the CommonMark and
// GFM specifications, never copied from the parser's own output.

const text = (value: string): Inline => ({ type: "text", text: value });
const em = (...children: Inline[]): Inline => ({ type: "emphasis", children });
const strong = (...children: Inline[]): Inline => ({ type: "strong", children });
const code = (value: string): Inline => ({ type: "code", text: value });
const link = (href: string, title: string | null, ...children: Inline[]): Inline => ({ type: "link", href, title, children });
const p = (...children: Inline[]): Block => ({ type: "paragraph", children });
const h = (level: 1 | 2 | 3 | 4 | 5 | 6, ...children: Inline[]): Block => ({ type: "heading", level, children });
const item = (...children: Block[]) => ({ children, task: null });

/** The one paragraph's inlines, for an inline case. */
const inline = (source: string): Inline[] => {
  const blocks = parseMarkdown(source);
  expect(blocks).toHaveLength(1);
  expect(blocks[0].type).toBe("paragraph");
  return (blocks[0] as { children: Inline[] }).children;
};

beforeAll(() => {
  vi.stubGlobal("document", {
    createElement: (tag: string) => new FakeElement(tag),
    createDocumentFragment: () => new FakeElement("#fragment"),
  });
});

/** The rendered tree as a string a reader can check at a glance. */
function html(node: FakeElement | string): string {
  if (typeof node === "string") return node;
  if (node.tagName === "#FRAGMENT") return node.children.map(html).join("");
  const tag = node.tagName.toLowerCase();
  const attrs = [...node.attributes].map(([k, v]) => (v === "" ? ` ${k}` : ` ${k}="${v}"`)).join("");
  if (["hr", "br", "img", "input"].includes(tag)) return `<${tag}${attrs}>`;
  return `<${tag}${attrs}>${node.children.map(html).join("")}</${tag}>`;
}

const render = (source: string, options?: Parameters<typeof renderMarkdown>[1]): string =>
  html(renderMarkdown(parseMarkdown(source), options) as unknown as FakeElement);

describe("blocks", () => {
  it("parses ATX headings at every level, with closing hashes dropped", () => {
    expect(parseMarkdown("# One\n## Two ##\n###### Six\n####### Seven")).toEqual([
      h(1, text("One")),
      h(2, text("Two")),
      h(6, text("Six")),
      p(text("####### Seven")),
    ]);
  });

  it("needs a space after the hashes", () => {
    expect(parseMarkdown("#5 bolt")).toEqual([p(text("#5 bolt"))]);
  });

  it("parses setext headings", () => {
    expect(parseMarkdown("One\n===\n\nTwo\n---")).toEqual([h(1, text("One")), h(2, text("Two"))]);
  });

  it("keeps a paragraph's lines on soft breaks and trims their indent", () => {
    expect(parseMarkdown("first\n   second\nthird")).toEqual([p(text("first\nsecond\nthird"))]);
  });

  it("nests block quotes", () => {
    expect(parseMarkdown("> outer\n>\n> > inner")).toEqual([
      { type: "blockquote", children: [p(text("outer")), { type: "blockquote", children: [p(text("inner"))] }] },
    ]);
  });

  it("parses a bullet list nested by indentation", () => {
    expect(parseMarkdown("- a\n- b\n  - c\n    - d\n- e")).toEqual([
      {
        type: "list",
        ordered: false,
        start: 1,
        tight: true,
        items: [
          item(p(text("a"))),
          item(p(text("b")), {
            type: "list",
            ordered: false,
            start: 1,
            tight: true,
            items: [item(p(text("c")), { type: "list", ordered: false, start: 1, tight: true, items: [item(p(text("d")))] })],
          }),
          item(p(text("e"))),
        ],
      },
    ]);
  });

  it("parses an ordered list with its start number and the `)` delimiter", () => {
    expect(parseMarkdown("3) three\n4) four")).toEqual([
      { type: "list", ordered: true, start: 3, tight: true, items: [item(p(text("three"))), item(p(text("four")))] },
    ]);
  });

  it("marks a list loose when a blank line separates its items", () => {
    expect(parseMarkdown("- a\n\n- b")).toEqual([
      { type: "list", ordered: false, start: 1, tight: false, items: [item(p(text("a"))), item(p(text("b")))] },
    ]);
  });

  it("marks a list loose when an item holds two blocks with a blank between", () => {
    expect(parseMarkdown("- a\n\n  b\n- c")).toEqual([
      { type: "list", ordered: false, start: 1, tight: false, items: [item(p(text("a")), p(text("b"))), item(p(text("c")))] },
    ]);
  });

  it("ends a list at a line of another list type", () => {
    expect(parseMarkdown("- a\n+ b")).toEqual([
      { type: "list", ordered: false, start: 1, tight: true, items: [item(p(text("a")))] },
      { type: "list", ordered: false, start: 1, tight: true, items: [item(p(text("b")))] },
    ]);
  });

  it("parses task items", () => {
    expect(parseMarkdown("- [ ] open\n- [x] done\n- [X] also done\n- [y] not a task")).toEqual([
      {
        type: "list",
        ordered: false,
        start: 1,
        tight: true,
        items: [
          { children: [p(text("open"))], task: "unchecked" },
          { children: [p(text("done"))], task: "checked" },
          { children: [p(text("also done"))], task: "checked" },
          { children: [p(text("[y] not a task"))], task: null },
        ],
      },
    ]);
  });

  it("parses a fenced code block with the info string's first word as its language", () => {
    expect(parseMarkdown("```ts title=x\nconst a = 1;\n\n  b\n```\nafter")).toEqual([
      { type: "code", language: "ts", text: "const a = 1;\n\n  b" },
      p(text("after")),
    ]);
  });

  it("parses a tilde fence, and a fence with no info has no language", () => {
    expect(parseMarkdown("~~~\n```\nnot closed by backticks\n~~~")).toEqual([
      { type: "code", language: null, text: "```\nnot closed by backticks" },
    ]);
  });

  it("runs an unclosed fence to the end of the document", () => {
    expect(parseMarkdown("```\na\nb")).toEqual([{ type: "code", language: null, text: "a\nb" }]);
  });

  it("strips the fence's own indent from its lines", () => {
    expect(parseMarkdown("  ```\n    x\n  y\n  ```")).toEqual([{ type: "code", language: null, text: "  x\ny" }]);
  });

  it("parses indented code, with trailing blank lines dropped", () => {
    expect(parseMarkdown("    a\n\n    b\n\n\npara")).toEqual([{ type: "code", language: null, text: "a\n\nb" }, p(text("para"))]);
  });

  it("parses thematic breaks in every spelling", () => {
    expect(parseMarkdown("***\n\n- - -\n\n___")).toEqual([{ type: "thematicBreak" }, { type: "thematicBreak" }, { type: "thematicBreak" }]);
  });

  it("parses a GFM table with alignment, escaped pipes, short rows and long rows", () => {
    const source = ["| Name | Left | Centre | Right |", "|---|:--|:-:|--:|", "a | b | `c \\| d` | e | dropped", "| only |", "", "after"].join("\n");
    expect(parseMarkdown(source)).toEqual([
      {
        type: "table",
        align: [null, "left", "center", "right"],
        header: [[text("Name")], [text("Left")], [text("Centre")], [text("Right")]],
        rows: [
          [[text("a")], [text("b")], [code("c | d")], [text("e")]],
          [[text("only")], [], [], []],
        ],
      },
      p(text("after")),
    ]);
  });

  it("does not read a paragraph over a `---` as a one-column table", () => {
    expect(parseMarkdown("a | b\n---")).toEqual([h(2, text("a | b"))]);
  });

  it("keeps front matter as a YAML code block", () => {
    expect(parseMarkdown("---\ntitle: Hi\ntags: [a]\n---\n# Hi")).toEqual([
      { type: "code", language: "yaml", text: "title: Hi\ntags: [a]" },
      h(1, text("Hi")),
    ]);
  });

  it("reads an unclosed front matter as the thematic break it is", () => {
    expect(parseMarkdown("---\ntitle: Hi")).toEqual([{ type: "thematicBreak" }, p(text("title: Hi"))]);
  });

  it("keeps an HTML block as paragraph text", () => {
    expect(parseMarkdown("<div class=\"x\">\n<p>hi</p>\n</div>")).toEqual([p(text('<div class="x">\n<p>hi</p>\n</div>'))]);
  });
});

describe("inlines", () => {
  it("parses emphasis and strong with `*` and `_`", () => {
    expect(inline("*a* _b_ **c** __d__")).toEqual([
      em(text("a")), text(" "), em(text("b")), text(" "), strong(text("c")), text(" "), strong(text("d")),
    ]);
  });

  it("nests strong inside emphasis for a triple run", () => {
    expect(inline("***both***")).toEqual([em(strong(text("both")))]);
  });

  it("does not open emphasis with `_` inside a word, and does with `*`", () => {
    expect(inline("foo_bar_baz and foo*bar*baz")).toEqual([text("foo_bar_baz and foo"), em(text("bar")), text("baz")]);
  });

  it("leaves a run that opens on whitespace literal", () => {
    expect(inline("a * b * c")).toEqual([text("a * b * c")]);
  });

  it("parses strikethrough", () => {
    expect(inline("a ~~gone~~ b")).toEqual([text("a "), { type: "strikethrough", children: [text("gone")] }, text(" b")]);
  });

  it("parses a code span, one with backticks inside, and one that strips a space", () => {
    expect(inline("`a` ``b ` c`` ` d `")).toEqual([code("a"), text(" "), code("b ` c"), text(" "), code("d")]);
  });

  it("leaves an unclosed backtick run literal", () => {
    expect(inline("a ` b")).toEqual([text("a ` b")]);
  });

  it("parses an inline link with a title, and an empty destination", () => {
    expect(inline('[t](https://x.y "Title") [e]()')).toEqual([
      link("https://x.y", "Title", text("t")), text(" "), link("", null, text("e")),
    ]);
  });

  it("resolves reference links from a definition written after the use", () => {
    const blocks = parseMarkdown("[full][Ref] [collapsed][] [shortcut] [none][x]\n\n[ref]: /u 'T'\n[collapsed]: /c\n[shortcut]: </s>");
    expect(blocks).toEqual([
      p(
        link("/u", "T", text("full")), text(" "),
        link("/c", null, text("collapsed")), text(" "),
        link("/s", null, text("shortcut")), text(" [none][x]"),
      ),
    ]);
  });

  it("parses an image", () => {
    expect(inline('![alt *text*](a.png "t")')).toEqual([{ type: "image", src: "a.png", alt: "alt text", title: "t" }]);
  });

  it("parses autolinks in angle brackets, an email included", () => {
    expect(inline("<https://a.b/c> <me@x.io>")).toEqual([
      link("https://a.b/c", null, text("https://a.b/c")), text(" "), link("mailto:me@x.io", null, text("me@x.io")),
    ]);
  });

  it("parses a bare URL and leaves the sentence's punctuation out", () => {
    expect(inline("see https://a.b/c(d). (https://e.f).")).toEqual([
      text("see "), link("https://a.b/c(d)", null, text("https://a.b/c(d)")), text(". ("), link("https://e.f", null, text("https://e.f")), text(")."),
    ]);
  });

  it("parses hard breaks from two spaces and from a backslash", () => {
    expect(inline("a  \nb\\\nc \nd")).toEqual([text("a"), { type: "break" }, text("b"), { type: "break" }, text("c\nd")]);
  });

  it("parses backslash escapes of punctuation only", () => {
    expect(inline("\\*not em\\* \\\\ \\a")).toEqual([text("*not em* \\ \\a")]);
  });

  it("decodes entities, and keeps an unknown one literal", () => {
    expect(inline("&amp; &#65; &#x1F600; &copy; &nosuch; &#0;")).toEqual([text("& A 😀 © &nosuch; \ufffd")]);
  });

  it("keeps an inline tag as text", () => {
    expect(inline("a <b>bold</b> <span onclick=x>c</span>")).toEqual([text("a <b>bold</b> <span onclick=x>c</span>")]);
  });
});

describe("CommonMark corner cases", () => {
  it("continues a quoted paragraph lazily", () => {
    expect(parseMarkdown("> a\nb\n> c")).toEqual([{ type: "blockquote", children: [p(text("a\nb\nc"))] }]);
  });

  it("continues a list item's paragraph lazily", () => {
    expect(parseMarkdown("- a\nb")).toEqual([{ type: "list", ordered: false, start: 1, tight: true, items: [item(p(text("a\nb")))] }]);
  });

  it("lets a bullet list and a `1.` list interrupt a paragraph, and no other number", () => {
    expect(parseMarkdown("para\n- a")).toEqual([p(text("para")), { type: "list", ordered: false, start: 1, tight: true, items: [item(p(text("a")))] }]);
    expect(parseMarkdown("para\n1. a")).toEqual([p(text("para")), { type: "list", ordered: true, start: 1, tight: true, items: [item(p(text("a")))] }]);
    expect(parseMarkdown("para\n2. a")).toEqual([p(text("para\n2. a"))]);
  });

  it("does not let an empty item interrupt a paragraph", () => {
    // `-` alone under a paragraph is a setext underline, so `+` is the case.
    expect(parseMarkdown("para\n+")).toEqual([p(text("para\n+"))]);
  });

  it("reads a `---` under a paragraph as a setext heading, not a break", () => {
    expect(parseMarkdown("a\n---\n\n---")).toEqual([h(2, text("a")), { type: "thematicBreak" }]);
  });

  it("reads `* * *` as a break, not a list", () => {
    expect(parseMarkdown("- a\n* * *")).toEqual([
      { type: "list", ordered: false, start: 1, tight: true, items: [item(p(text("a")))] },
      { type: "thematicBreak" },
    ]);
  });

  it("keeps an empty list item", () => {
    expect(parseMarkdown("- a\n-\n- c")).toEqual([
      { type: "list", ordered: false, start: 1, tight: true, items: [item(p(text("a"))), item(), item(p(text("c")))] },
    ]);
  });

  it("matches emphasis runs by the rule of three", () => {
    expect(inline("*foo**bar*")).toEqual([em(text("foo**bar"))]);
    expect(inline("**foo*bar**")).toEqual([strong(text("foo*bar"))]);
  });

  it("allows no link inside a link, and an image inside one", () => {
    expect(inline("[a [b](/b) c](/c)")).toEqual([text("[a "), link("/b", null, text("b")), text(" c](/c)")]);
    expect(inline("[![i](/i)](/l)")).toEqual([link("/l", null, { type: "image", src: "/i", alt: "i", title: null })]);
  });

  it("does not interrupt a paragraph with indented code", () => {
    expect(parseMarkdown("a\n    b")).toEqual([p(text("a\nb"))]);
  });

  it("reads tabs as indent to the next stop of four", () => {
    expect(parseMarkdown("\tcode")).toEqual([{ type: "code", language: null, text: "code" }]);
    expect(parseMarkdown("-\tlist")).toEqual([{ type: "list", ordered: false, start: 1, tight: true, items: [item(p(text("list")))] }]);
  });

  it("parses CRLF line ends", () => {
    expect(parseMarkdown("# a\r\n\r\nb\r\nc")).toEqual([h(1, text("a")), p(text("b\nc"))]);
  });

  it("gives an empty document no block", () => {
    expect(parseMarkdown("")).toEqual([]);
    expect(parseMarkdown("\n\n  \n")).toEqual([]);
  });
});

describe("slugify", () => {
  it("follows GitHub's rule", () => {
    expect(slugify("Hello, World!")).toBe("hello-world");
    expect(slugify("A & B")).toBe("a--b");
    expect(slugify("snake_case keeps_underscores")).toBe("snake_case-keeps_underscores");
    expect(slugify("Ünïcödé 123")).toBe("ünïcödé-123");
    expect(slugify("!!!")).toBe("");
  });
});

describe("resolveLink, the default rule", () => {
  it("lets http, https and mailto out", () => {
    expect(resolveLink("https://a.b/c")).toEqual({ kind: "external", href: "https://a.b/c" });
    expect(resolveLink("http://a.b")).toEqual({ kind: "external", href: "http://a.b" });
    expect(resolveLink("mailto:me@x.io")).toEqual({ kind: "external", href: "mailto:me@x.io" });
    expect(resolveLink("HTTPS://A.B")).toEqual({ kind: "external", href: "HTTPS://A.B" });
  });

  it("opens a relative .md path, with a fragment or alone, as a document", () => {
    expect(resolveLink("other.md")).toEqual({ kind: "markdown", path: "other.md" });
    expect(resolveLink("../docs/README.MD#Section")).toEqual({ kind: "markdown", path: "../docs/README.MD#Section" });
    expect(resolveLink("#section")).toEqual({ kind: "markdown", path: "#section" });
  });

  it("makes every other scheme text, whatever its case or spacing", () => {
    for (const url of ["javascript:alert(1)", " JaVaScRiPt:alert(1)", "java\tscript:alert(1)", "data:text/html,x", "vbscript:x", "file:///etc/passwd", "ftp://a.b", "chrome://x", "//evil.example/x.md"]) {
      expect(resolveLink(url), url).toEqual({ kind: "text" });
    }
  });

  it("makes a relative path that is not a document text", () => {
    expect(resolveLink("src/main.ts")).toEqual({ kind: "text" });
    expect(resolveLink("")).toEqual({ kind: "text" });
  });
});

describe("languageForFence", () => {
  it("reads a language name, an extension, or nothing", () => {
    expect(languageForFence("ts")).toBe("c-like");
    expect(languageForFence("typescript")).toBe("c-like");
    expect(languageForFence("python title=x")).toBe("hash");
    expect(languageForFence("yaml")).toBe("hash");
    expect(languageForFence("console")).toBe("shell");
    expect(languageForFence("")).toBe("plain");
    expect(languageForFence("nosuchlang")).toBe("plain");
  });
});

describe("renderMarkdown", () => {
  it("renders headings with slug ids, numbered on a repeat", () => {
    expect(render("# A & B\n\n## A & B\n\n### !!!")).toBe('<h1 id="a--b">A & B</h1><h2 id="a--b-1">A & B</h2><h3>!!!</h3>');
  });

  it("renders a tight list without paragraphs and a loose one with them", () => {
    expect(render("- a\n- b")).toBe("<ul><li>a</li><li>b</li></ul>");
    expect(render("- a\n\n- b")).toBe("<ul><li><p>a</p></li><li><p>b</p></li></ul>");
  });

  it("renders an ordered list's start and a task item's checkbox", () => {
    expect(render("3. a")).toBe('<ol start="3"><li>a</li></ol>');
    expect(render("- [ ] a\n- [x] b")).toBe(
      '<ul><li class="md-task"><input type="checkbox" disabled> a</li><li class="md-task"><input type="checkbox" disabled checked> b</li></ul>',
    );
  });

  it("renders a table with its alignment on the cells", () => {
    expect(render("| a | b |\n|:-:|--:|\n| 1 | 2 |")).toBe(
      '<table><thead><tr><th data-align="center">a</th><th data-align="right">b</th></tr></thead><tbody><tr><td data-align="center">1</td><td data-align="right">2</td></tr></tbody></table>',
    );
  });

  it("colours fenced code through highlight.ts", () => {
    expect(render("```ts\nlet a = 1\n```")).toBe(
      '<pre class="md-code" data-language="ts"><code class="language-ts"><span class="tok-keyword">let</span> a <span class="tok-punct">=</span> <span class="tok-number">1</span></code></pre>',
    );
    expect(render("```\nplain\n```")).toBe('<pre class="md-code"><code>plain</code></pre>');
  });

  it("renders the inline forms", () => {
    expect(render("*a* **b** ~~c~~ `d`  \ne")).toBe("<p><em>a</em> <strong>b</strong> <del>c</del> <code>d</code><br>e</p>");
    expect(render("> q\n\n---")).toBe("<blockquote><p>q</p></blockquote><hr>");
  });

  it("renders links by the default rule", () => {
    expect(render('[e](https://a.b "T") [m](o.md#s) [t](ftp://x)')).toBe(
      '<p><a href="https://a.b" target="_blank" rel="noopener noreferrer" title="T">e</a> <a href="o.md#s" data-markdown="o.md#s" class="md-link">m</a> <span class="md-unlinked">t</span> (ftp://x)</p>',
    );
  });

  it("renders an image as text by default, and as an image when the resolver answers", () => {
    expect(render("![alt](a.png) ![](b.png)")).toBe('<p><span class="md-image-text">alt (a.png)</span> <span class="md-image-text">b.png</span></p>');
    expect(render('![alt](a.png "t")', { resolveImage: (src) => `/api/files/content?path=${src}` })).toBe(
      '<p><img src="/api/files/content?path=a.png" alt="alt" title="t"></p>',
    );
  });

  it("asks the caller's link resolver", () => {
    const seen: string[] = [];
    const out = render("[a](x.md) [b](https://y)", {
      resolveLink: (url) => {
        seen.push(url);
        return { kind: "markdown", path: `/md?path=${url}` };
      },
    });
    expect(seen).toEqual(["x.md", "https://y"]);
    expect(out).toBe('<p><a href="/md?path=x.md" data-markdown="/md?path=x.md" class="md-link">a</a> <a href="/md?path=https://y" data-markdown="/md?path=https://y" class="md-link">b</a></p>');
  });
});

describe("bounds", () => {
  /** Wall time of `fn`, in milliseconds. */
  const timed = (fn: () => void): number => {
    const start = performance.now();
    fn();
    return performance.now() - start;
  };

  // The bounds are wide: the measured times on a laptop sit well under a
  // tenth of each, and the test guards against a hang, not a slow day.
  it("parses and renders a 1 MB file in under 3 s", () => {
    const unit = "# Heading *one*\n\nA paragraph with **strong**, `code`, a [link](https://a.b) and https://c.d/e.\n\n- item one\n- item two\n  - nested\n\n> quoted\n\n```ts\nconst x = 1;\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n";
    let source = "";
    while (source.length < 1_048_576) source += unit;
    let blocks: Block[] = [];
    const parse = timed(() => {
      blocks = parseMarkdown(source);
    });
    const draw = timed(() => renderMarkdown(blocks));
    expect(blocks.length).toBeGreaterThan(1000);
    expect(parse + draw, `parse ${parse.toFixed(0)} ms, render ${draw.toFixed(0)} ms`).toBeLessThan(3000);
  });

  it("caps block quotes at MAX_DEPTH and finishes 10,000 of them in under 1 s", () => {
    const source = ">".repeat(10_000) + " deep";
    let blocks: Block[] = [];
    const ms = timed(() => {
      blocks = parseMarkdown(source);
    });
    expect(ms).toBeLessThan(1000);
    let depth = 0;
    let at: Block[] = blocks;
    while (at.length === 1 && at[0].type === "blockquote") {
      depth += 1;
      at = at[0].children;
    }
    expect(depth).toBe(MAX_DEPTH);
    expect(at).toEqual([p(text(">".repeat(10_000 - MAX_DEPTH) + " deep"))]);
  });

  it("finishes 10,000 emphasis runs, brackets and backticks each in under 1 s", () => {
    for (const source of ["*".repeat(10_000), "*a ".repeat(10_000), "**a* ".repeat(10_000), "[".repeat(10_000), "[a](".repeat(10_000), "` ".repeat(10_000), "~~a ".repeat(10_000), "<a ".repeat(10_000), "https://x ".repeat(10_000)]) {
      const ms = timed(() => renderMarkdown(parseMarkdown(source)));
      expect(ms, source.slice(0, 8)).toBeLessThan(1000);
    }
  });

  it("finishes 1,000 nested list levels (a 1 MB source) in under 1 s", () => {
    let source = "";
    for (let i = 0; i < 1_000; i += 1) source += `${"  ".repeat(i)}- x\n`;
    const ms = timed(() => renderMarkdown(parseMarkdown(source)));
    expect(ms).toBeLessThan(1000);
  });
});
