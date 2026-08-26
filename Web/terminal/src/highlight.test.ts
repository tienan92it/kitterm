import { describe, expect, it } from "vitest";

import { languageFor, tokenize, type Language, type Token, type TokenKind } from "./highlight";

/** The text of every token, in order. Nothing may be lost or invented. */
const joined = (tokens: Token[]): string => tokens.map((t) => t.text).join("");

/** The kind given to the first run whose text is exactly `needle`. */
const kindOf = (tokens: Token[], needle: string): TokenKind | undefined =>
  tokens.find((t) => t.text === needle)?.kind;

/** Whether any run of `kind` contains `needle`. */
const coloured = (tokens: Token[], kind: TokenKind, needle: string): boolean =>
  tokens.some((t) => t.kind === kind && t.text.includes(needle));

const ESC = "\u001b";

describe("languageFor", () => {
  it("reads the extension", () => {
    expect(languageFor("main.ts")).toBe("c-like");
    expect(languageFor("report.json")).toBe("json");
    expect(languageFor("NOTES.md")).toBe("md");
    expect(languageFor("page.html")).toBe("xml");
    expect(languageFor("logo.svg")).toBe("xml");
    expect(languageFor("build.log")).toBe("log");
    expect(languageFor("run.sh")).toBe("shell");
    expect(languageFor("config.yaml")).toBe("hash");
    expect(languageFor("fix.patch")).toBe("diff");
  });

  it("reads the whole path, not only the name", () => {
    expect(languageFor("/tmp/build/assets/app.tsx")).toBe("c-like");
  });

  it("knows the files the world names rather than extends", () => {
    expect(languageFor("Makefile")).toBe("hash");
    expect(languageFor("Dockerfile")).toBe("hash");
    expect(languageFor(".zshrc")).toBe("shell");
    expect(languageFor(".gitignore")).toBe("hash");
    expect(languageFor(".env.local")).toBe("hash");
  });

  // An unknown name gets no colour rather than the wrong colour.
  it("falls back to plain", () => {
    expect(languageFor("notes")).toBe("plain");
    expect(languageFor("data.q9z")).toBe("plain");
    expect(languageFor("archive.tar.q9z")).toBe("plain");
  });
});

describe("tokenize", () => {
  const LANGUAGES: Language[] = [
    "c-like",
    "hash",
    "shell",
    "json",
    "xml",
    "md",
    "log",
    "diff",
    "plain",
  ];

  const SAMPLES = [
    "",
    "\n\n\n",
    "plain words with no structure at all",
    'const a = "x"; // note\n',
    "# heading\n- item\n\n```js\nlet x = 1\n```\n",
    '{"key": [1, 2.5, true, null], "s": "a\\"b"}',
    '<a href="x?a=1&b=2">text</a>\n<!-- gone -->',
    "2026-08-25T10:00:00Z ERROR [main] failed at https://example.com/x\n",
    "--- a/x.ts\n+++ b/x.ts\n@@ -1 +1 @@\n-old\n+new\n",
    'unterminated "string and /* comment',
    `${ESC}[31mred${ESC}[0m`,
    "emoji \u{1F600} and accents café",
  ];

  // The one invariant that matters: the caller writes these runs into the DOM
  // and the result must be the file, character for character. Anything else
  // silently shows the user a different file than the one they opened. Terminal
  // escapes are the one exception, and they are removed in every language.
  it("returns every character exactly once, in order", () => {
    for (const language of LANGUAGES) {
      for (const sample of SAMPLES) {
        const expected = sample.replace(/\u001b\[[0-9;?]*[A-Za-z]/g, "");
        expect(
          joined(tokenize(sample, language)),
          `${language}: ${JSON.stringify(sample)}`,
        ).toBe(expected);
      }
    }
  });

  it("never emits an empty run", () => {
    for (const language of LANGUAGES) {
      for (const sample of SAMPLES) {
        expect(tokenize(sample, language).every((t) => t.text.length > 0)).toBe(true);
      }
    }
  });

  it("merges neighbours of one kind into a single run", () => {
    // Words and the spaces between them are all plain, so there is one run.
    const tokens = tokenize("alpha beta gamma delta", "c-like");
    expect(tokens.filter((t) => t.kind === "plain")).toHaveLength(1);
  });

  it("colours nothing in a plain file", () => {
    const tokens = tokenize('# not a heading\nconst x = "y"', "plain");
    expect(tokens.every((t) => t.kind === "plain")).toBe(true);
  });
});

describe("c-like", () => {
  const of = (source: string) => tokenize(source, "c-like");

  it("finds comments, strings and numbers", () => {
    const tokens = of('const n = 42; // why\nlet s = "hi";\n/* block */');
    expect(kindOf(tokens, "const")).toBe("keyword");
    expect(kindOf(tokens, "42")).toBe("number");
    expect(kindOf(tokens, "// why")).toBe("comment");
    expect(kindOf(tokens, '"hi"')).toBe("string");
    expect(kindOf(tokens, "/* block */")).toBe("comment");
  });

  // A `//` inside a string is text, and a quote inside a comment is not a
  // string. Order in the rule list is what decides both.
  it("does not find a comment inside a string", () => {
    expect(kindOf(of('"http://x"'), '"http://x"')).toBe("string");
    expect(kindOf(of('// a "quote'), '// a "quote')).toBe("comment");
  });

  it("names a word that is called, and a type", () => {
    expect(kindOf(of("render(x)"), "render")).toBe("name");
    expect(kindOf(of("let v: Widget"), "Widget")).toBe("name");
  });

  // Colouring every identifier is what makes a screen of code look like
  // confetti, so a bare word stays plain.
  it("leaves an ordinary identifier alone", () => {
    expect(coloured(of("let total = other"), "plain", "other")).toBe(true);
  });

  it("closes an unterminated string at the end of its line", () => {
    const tokens = of('let s = "open\nlet t = 1');
    expect(kindOf(tokens, '"open')).toBe("string");
    expect(kindOf(tokens, "1")).toBe("number");
  });
});

describe("json", () => {
  it("tells a key from a value", () => {
    const tokens = tokenize('{"name": "kitterm", "port": 3418}', "json");
    expect(kindOf(tokens, '"name"')).toBe("name");
    expect(kindOf(tokens, '"kitterm"')).toBe("string");
    expect(kindOf(tokens, "3418")).toBe("number");
  });

  it("colours the three literals", () => {
    const tokens = tokenize("[true, false, null]", "json");
    expect(kindOf(tokens, "true")).toBe("keyword");
    expect(kindOf(tokens, "null")).toBe("keyword");
  });

  it("keeps an escaped quote inside its string", () => {
    const tokens = tokenize('{"a": "x\\"y"}', "json");
    expect(kindOf(tokens, '"x\\"y"')).toBe("string");
  });
});

describe("xml", () => {
  it("separates the tag name, the attribute and its value", () => {
    const tokens = tokenize('<a href="/x">text</a>', "xml");
    expect(kindOf(tokens, "a")).toBe("keyword");
    expect(kindOf(tokens, "href")).toBe("attr");
    expect(kindOf(tokens, '"/x"')).toBe("string");
    expect(coloured(tokens, "plain", "text")).toBe(true);
  });

  // A `>` inside a quoted value must not end the tag early.
  it("keeps a bracket inside an attribute value", () => {
    const tokens = tokenize('<img alt="a > b" src="x">', "xml");
    expect(kindOf(tokens, '"a > b"')).toBe("string");
    expect(kindOf(tokens, "src")).toBe("attr");
  });

  it("greys a comment", () => {
    expect(kindOf(tokenize("<!-- hidden -->", "xml"), "<!-- hidden -->")).toBe("comment");
  });
});

describe("markdown", () => {
  it("colours a heading, a list marker and a code span", () => {
    const tokens = tokenize("# Title\n\n- one `code` two\n", "md");
    expect(kindOf(tokens, "# Title")).toBe("keyword");
    expect(kindOf(tokens, "`code`")).toBe("string");
    expect(coloured(tokens, "punct", "-")).toBe(true);
  });

  it("splits a link into its words and its target", () => {
    const tokens = tokenize("see [the docs](https://example.com) now", "md");
    expect(kindOf(tokens, "[the docs]")).toBe("name");
    expect(kindOf(tokens, "(https://example.com)")).toBe("link");
  });

  it("finds a bare URL", () => {
    expect(
      coloured(tokenize("go to https://example.com/x now", "md"), "link", "example.com"),
    ).toBe(true);
  });

  // A `#` that is not at the head of a line is a word, not a heading.
  it("only reads a heading at the start of a line", () => {
    expect(coloured(tokenize("issue #37 is open", "md"), "keyword", "#37")).toBe(false);
  });
});

describe("shell", () => {
  it("colours variables, options and keywords", () => {
    const tokens = tokenize("if [ -n $NAME ]; then\n  ls --color=auto $HOME\nfi\n", "shell");
    expect(kindOf(tokens, "if")).toBe("keyword");
    expect(kindOf(tokens, "$NAME")).toBe("name");
    expect(kindOf(tokens, "$HOME")).toBe("name");
    expect(kindOf(tokens, "--color")).toBe("attr");
  });

  // `my-file.txt` is one word; only a leading dash starts an option. Reading
  // the `-file` half as a flag is what a naive dash rule does.
  it("keeps a dashed filename whole", () => {
    const tokens = tokenize("cat my-file.txt", "shell");
    expect(coloured(tokens, "plain", "my-file.txt")).toBe(true);
    expect(tokens.some((t) => t.kind === "attr")).toBe(false);
  });

  it("greys a comment to the end of its line", () => {
    expect(kindOf(tokenize("# note\nls\n", "shell"), "# note")).toBe("comment");
  });
});

describe("log", () => {
  it("ranks the levels by colour", () => {
    const tokens = tokenize("ERROR x\nWARN y\nINFO z\nDEBUG w\n", "log");
    expect(kindOf(tokens, "ERROR")).toBe("error");
    expect(kindOf(tokens, "WARN")).toBe("attr");
    expect(kindOf(tokens, "INFO")).toBe("name");
    expect(kindOf(tokens, "DEBUG")).toBe("comment");
  });

  it("finds a timestamp and a bracketed tag", () => {
    const tokens = tokenize("2026-08-25T10:00:00Z [worker] done\n", "log");
    expect(kindOf(tokens, "2026-08-25T10:00:00Z")).toBe("number");
    expect(kindOf(tokens, "[worker]")).toBe("keyword");
  });

  // A level word is a whole word. `ERRORS_TOTAL` is a name, not a failure.
  it("does not colour a level inside a longer word", () => {
    expect(coloured(tokenize("ERRORS_TOTAL=0", "log"), "error", "ERROR")).toBe(false);
  });

  it("drops terminal escapes rather than drawing them", () => {
    const tokens = tokenize(`${ESC}[31mFAILED${ESC}[0m here`, "log");
    expect(joined(tokens)).toBe("FAILED here");
    expect(kindOf(tokens, "FAILED")).toBe("error");
  });
});

describe("diff", () => {
  it("separates additions from removals", () => {
    const tokens = tokenize("--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-gone\n+new\n same\n", "diff");
    expect(kindOf(tokens, "+new")).toBe("string");
    expect(kindOf(tokens, "-gone")).toBe("error");
    expect(kindOf(tokens, "@@ -1,2 +1,2 @@")).toBe("link");
    expect(kindOf(tokens, "--- a/x")).toBe("keyword");
    expect(coloured(tokens, "plain", " same")).toBe(true);
  });
});

describe("the ceiling", () => {
  // Twice what the daemon will ever send, so the ceiling is certainly crossed.
  const big = 'const value = "x"; // a line of source\n'.repeat(14_000);

  // Past the ceiling the rest arrives as one plain run. The file is still
  // whole — it is the colour that stops, not the text.
  it("keeps the whole file when it is larger than the budget", () => {
    const tokens = tokenize(big, "c-like");
    expect(big.length).toBeGreaterThan(500_000);
    expect(joined(tokens)).toBe(big);
    expect(tokens.length).toBeLessThan(120_001);
  });

  // A quarter-megabyte of punctuation would be one run per character without
  // the token guard, which is the case the guard exists for.
  it("holds the run count down on pathological input", () => {
    expect(tokenize("{".repeat(300_000), "c-like").length).toBeLessThan(10);
  });

  it("stays fast on a large file", () => {
    const started = performance.now();
    tokenize(big, "c-like");
    expect(performance.now() - started).toBeLessThan(1000);
  });
});
