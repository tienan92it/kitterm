/**
 * Colouring source text for the file preview.
 *
 * **The palette is not ours.** Every colour comes from the terminal theme the
 * user already picked, published as `--term-*` by `theme-tokens.ts`. Solarized
 * previews in Solarized, Dracula in Dracula. Shipping a fixed editor theme
 * would put a second palette on screen beside the shell, and one of the two
 * would always look wrong.
 *
 * **No library.** highlight.js and Prism return an HTML string, and the whole
 * point of the preview route is that a file's bytes never become markup — see
 * `FilePreview.swift`. This returns tokens instead, and the caller builds spans
 * with `textContent`, so a file that contains `<script>` stays a file that
 * contains `<script>`. Shiki would be right about grammars and wrong about
 * size: its WebAssembly engine alone is larger than this whole bundle.
 *
 * **The accuracy on offer.** These are single-pass scanners, not parsers. They
 * get comments, strings, numbers, keywords and structure right, which is what
 * makes a file readable at a glance on a phone. They do not track scope, so a
 * Rust lifetime reads as a string and a word inside a Markdown code fence is
 * still coloured as Markdown. That is the trade: nine grammars in one file,
 * against a preview that is exact.
 */

export type TokenKind =
  | "comment"
  | "string"
  | "number"
  | "keyword"
  | "name"
  | "attr"
  | "link"
  | "punct"
  | "error"
  | "plain";

export interface Token {
  kind: TokenKind;
  text: string;
}

export type Language =
  | "c-like"
  | "hash"
  | "shell"
  | "json"
  | "xml"
  | "md"
  | "log"
  | "diff"
  | "plain";

/** How a rule names what it matched. */
type KindOf = TokenKind | ((match: string, text: string, at: number) => TokenKind);

interface Rule {
  /** Sticky, always: the scanner matches at one position and moves on. */
  re: RegExp;
  kind?: KindOf;
  /** Re-scan the match with another rule set, for a whole XML tag. */
  split?: (text: string) => Token[];
}

/**
 * The ceiling on colouring, past which the rest of the file is appended as one
 * plain run.
 *
 * `MAX_CHARS` is the daemon's own preview cap, deliberately: one boundary is
 * easier to explain than two. Colour covers exactly what the preview shows, and
 * the card already says "showing the first part" where the daemon stopped.
 *
 * `MAX_TOKENS` is not that boundary — it is a guard against pathological input,
 * a quarter-megabyte of punctuation where every character is its own run. Real
 * source of that size lands near 50,000 runs, well under it.
 */
const MAX_CHARS = 262_144;
const MAX_TOKENS = 120_000;

// MARK: - The scanner

/**
 * Walk `text` once, taking the first rule that matches at each position.
 *
 * Adjacent tokens of one kind are merged as they are pushed, which is what
 * keeps the span count near the number of *coloured* runs rather than near the
 * number of matches.
 */
function run(text: string, rules: readonly Rule[], limit: number, maxTokens: number): Token[] {
  const out: Token[] = [];
  const push = (kind: TokenKind, value: string): void => {
    if (!value) return;
    const last = out[out.length - 1];
    if (last && last.kind === kind) last.text += value;
    else out.push({ kind, text: value });
  };

  let i = 0;
  scan: while (i < limit) {
    if (out.length >= maxTokens) break;
    for (const rule of rules) {
      rule.re.lastIndex = i;
      const match = rule.re.exec(text);
      // A zero-length match would never advance the cursor.
      if (!match || match[0].length === 0) continue;
      const value = match[0];
      if (rule.split) {
        for (const token of rule.split(value)) push(token.kind, token.text);
      } else {
        const kind = rule.kind ?? "plain";
        push(typeof kind === "function" ? kind(value, text, i) : kind, value);
      }
      i += value.length;
      continue scan;
    }
    push("plain", text[i]);
    i += 1;
  }
  if (i < text.length) push("plain", text.slice(i));
  return out;
}

/**
 * Terminal escapes: a build log written by a tool that colours its own output
 * is full of them, and they draw as stray letters and brackets in the middle of
 * every line. The preview is not a terminal, so it shows the text without them.
 */
const ANSI = /\u001b\[[0-9;?]*[A-Za-z]|\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g;

/**
 * Split `text` into coloured runs. Every character comes back exactly once,
 * apart from terminal escapes, which are removed before the scan rather than
 * during it — a rule that discarded them mid-scan would leave `^` and `\b`
 * matching against characters that are no longer on screen.
 */
export function tokenize(text: string, language: Language): Token[] {
  const source = text.includes("\u001b") ? text.replace(ANSI, "") : text;
  return run(source, GRAMMARS[language], Math.min(source.length, MAX_CHARS), MAX_TOKENS);
}

/**
 * The next character that is not a space or a tab, within a short reach.
 *
 * Bounded, and it never slices: a lookahead that copies the rest of the file
 * for every identifier turns a linear scan into a quadratic one. Newlines stop
 * it, so a call is only a call when the bracket is on the same line.
 */
function nextNonSpace(text: string, from: number): string {
  for (let i = from; i < text.length && i < from + 40; i += 1) {
    const char = text[i];
    if (char !== " " && char !== "\t") return char;
  }
  return "";
}

// MARK: - Shared pieces

/** Whitespace as one run, so the per-character fallback stays rare. */
const SPACE: Rule = { re: /\s+/y, kind: "plain" };

const NUMBER: Rule = {
  re: /0[xXbBoO][0-9a-fA-F_]+n?|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?[a-zA-Z]{0,3}/y,
  kind: "number",
};

const PUNCT: Rule = { re: /[{}()[\].,;:+\-*/%=<>!&|^~?@#$\\]+/y, kind: "punct" };

/**
 * One set for every curly-brace language, rather than one per language.
 *
 * A preview shows a file the reader already knows the language of. Colouring
 * `func` in a Swift file costs nothing, and the alternative is nine keyword
 * lists to keep in step.
 */
const KEYWORDS = new Set(
  `abstract and as assert async await break case catch class const constexpr
   continue crate declare def default defer del delete do done elif else enum
   except extends extern final finally fn for from func function global go goto
   if impl implements import in inline instanceof interface internal is lambda
   let loop macro match mod module move mut namespace new not operator or
   override package pass private protected protocol pub public raise readonly
   ref return sealed self static struct super switch template this throw throws
   trait try type typedef typeof union unless unsafe until use using var virtual
   void volatile when where while with yield
   bool byte char double float int long short string uint void
   true false null nil none undefined None True False NULL nullptr`
    .trim()
    .split(/\s+/),
);

const SHELL_KEYWORDS = new Set(
  `if then elif else fi for while until do done case esac in function select
   return local export declare readonly unset source alias set shift trap eval
   exec echo printf cd test time`
    .trim()
    .split(/\s+/),
);

/**
 * A bare word in a curly-brace language.
 *
 * Three answers, in order: a keyword; a name, when a bracket follows or the
 * word is capitalised in the way types are; otherwise nothing. Colouring every
 * identifier is what makes a screen of code look like confetti.
 */
const wordKind: KindOf = (word, text, at) => {
  if (KEYWORDS.has(word)) return "keyword";
  if (nextNonSpace(text, at + word.length) === "(") return "name";
  if (/^[A-Z]/.test(word) && /[a-z]/.test(word)) return "name";
  return "plain";
};

const IDENT: Rule = { re: /[A-Za-z_$][\w$]*/y, kind: wordKind };

const DOUBLE_QUOTED: Rule = { re: /"(?:\\[\s\S]|[^"\\\n])*"?/y, kind: "string" };
const SINGLE_QUOTED: Rule = { re: /'(?:\\[\s\S]|[^'\\\n])*'?/y, kind: "string" };

// MARK: - Grammars

const cLike: readonly Rule[] = [
  SPACE,
  { re: /\/\/[^\n]*/y, kind: "comment" },
  { re: /\/\*[\s\S]*?(?:\*\/|$)/y, kind: "comment" },
  DOUBLE_QUOTED,
  SINGLE_QUOTED,
  { re: /`(?:\\[\s\S]|[^`\\])*`?/y, kind: "string" },
  NUMBER,
  IDENT,
  PUNCT,
];

const hash: readonly Rule[] = [
  SPACE,
  { re: /#[^\n]*/y, kind: "comment" },
  { re: /"""[\s\S]*?(?:"""|$)/y, kind: "string" },
  { re: /'''[\s\S]*?(?:'''|$)/y, kind: "string" },
  DOUBLE_QUOTED,
  SINGLE_QUOTED,
  // A key at the head of its line. YAML, TOML and INI are almost nothing else,
  // and the same shape in Python is a label — `else:` — which is a keyword
  // either way.
  {
    re: /^[ \t]*[A-Za-z_][\w.-]*(?=[ \t]*[:=])/my,
    kind: (match) => (KEYWORDS.has(match.trim()) ? "keyword" : "name"),
  },
  NUMBER,
  IDENT,
  PUNCT,
];

const shell: readonly Rule[] = [
  SPACE,
  { re: /#[^\n]*/y, kind: "comment" },
  { re: /"(?:\\[\s\S]|[^"\\])*"?/y, kind: "string" },
  { re: /'[^']*'?/y, kind: "string" },
  { re: /\$\{[^}\n]*\}?|\$[A-Za-z_]\w*|\$[\d@*#?$!-]/y, kind: "name" },
  { re: /--?[A-Za-z][\w-]*/y, kind: "attr" },
  NUMBER,
  // Dashes and dots belong to the word here, so `my-file.txt` stays one word
  // and only a leading dash starts an option.
  {
    re: /[A-Za-z_][\w.-]*/y,
    kind: (word) => (SHELL_KEYWORDS.has(word) ? "keyword" : "plain"),
  },
  PUNCT,
];

const json: readonly Rule[] = [
  SPACE,
  {
    re: /"(?:\\[\s\S]|[^"\\])*"?/y,
    kind: (match, text, at) => (nextNonSpace(text, at + match.length) === ":" ? "name" : "string"),
  },
  { re: /\/\/[^\n]*/y, kind: "comment" },
  { re: /true|false|null/y, kind: "keyword" },
  NUMBER,
  PUNCT,
];

/**
 * Inside one tag. The name sits right after `<` or `</`, so its position is
 * enough to tell it from an attribute — no parser state to carry.
 */
const tagRules: readonly Rule[] = [
  { re: /<\/?/y, kind: "punct" },
  {
    re: /[A-Za-z_:][\w:.-]*/y,
    kind: (match, text, at) => {
      if (at <= 2) return "keyword";
      return nextNonSpace(text, at + match.length) === "=" ? "attr" : "plain";
    },
  },
  { re: /"[^"]*"?|'[^']*'?/y, kind: "string" },
  { re: /\/?>/y, kind: "punct" },
  SPACE,
  { re: /[\s\S]/y, kind: "punct" },
];

const tagTokens = (text: string): Token[] => run(text, tagRules, text.length, MAX_TOKENS);

const xml: readonly Rule[] = [
  { re: /<!--[\s\S]*?(?:-->|$)/y, kind: "comment" },
  { re: /<!\[CDATA\[[\s\S]*?(?:\]\]>|$)/y, kind: "string" },
  { re: /<\?[\s\S]*?(?:\?>|$)/y, kind: "comment" },
  { re: /<![^>\n]*>?/y, kind: "comment" },
  // The whole tag in one match, quoted values included, so a `>` inside an
  // attribute cannot end it early.
  { re: /<\/?[A-Za-z][\w:.-]*(?:"[^"]*"|'[^']*'|[^>"'])*>?/y, split: tagTokens },
  { re: /[^<]+/y, kind: "plain" },
];

const md: readonly Rule[] = [
  { re: /^ {0,3}(?:```|~~~)[^\n]*/my, kind: "punct" },
  { re: /^ {0,3}#{1,6}[^\n]*/my, kind: "keyword" },
  { re: /^ {0,3}>[^\n]*/my, kind: "comment" },
  { re: /^ {0,3}(?:-{3,}|\*{3,}|_{3,})[ \t]*$/my, kind: "punct" },
  { re: /^ {0,3}(?:[-*+]|\d+[.)])[ \t]/my, kind: "punct" },
  { re: /`[^`\n]+`/y, kind: "string" },
  { re: /!?\[[^\]\n]*\]\([^)\n]*\)/y, split: (text) => linkTokens(text) },
  { re: /\*\*[^\n]+?\*\*|__[^\n]+?__/y, kind: "name" },
  { re: /\*[^\s*][^\n]*?\*|_[^\s_][^\n]*?_/y, kind: "name" },
  { re: /!?\[[^\]\n]*\]/y, kind: "name" },
  { re: /<https?:\/\/[^>\s]+>|https?:\/\/\S+/y, kind: "link" },
  // A plain run, stopped by every character a rule above can start with. `h`
  // is in that set only because a bare URL begins with one.
  { re: /[^\n`*_[\]!<>hH]+/y, kind: "plain" },
];

/** `[text](url)`: the words are the label, the target is the link. */
function linkTokens(text: string): Token[] {
  const open = text.indexOf("](");
  if (open < 0) return [{ kind: "name", text }];
  return [
    { kind: "name", text: text.slice(0, open + 1) },
    { kind: "link", text: text.slice(open + 1) },
  ];
}

const log: readonly Rule[] = [
  SPACE,
  { re: /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?/y, kind: "number" },
  { re: /\d{2}:\d{2}:\d{2}(?:[.,]\d+)?/y, kind: "number" },
  { re: /\b(?:ERROR|ERR|FATAL|CRITICAL|SEVERE|PANIC|FAIL|FAILED)\b/y, kind: "error" },
  { re: /\b(?:WARN|WARNING)\b/y, kind: "attr" },
  { re: /\b(?:INFO|NOTICE|PASSED|SUCCESS|OK)\b/y, kind: "name" },
  { re: /\b(?:DEBUG|TRACE|VERBOSE)\b/y, kind: "comment" },
  { re: /https?:\/\/\S+/y, kind: "link" },
  { re: /"[^"\n]*"|'[^'\n]*'/y, kind: "string" },
  // A bracketed tag: the thread, the module, the subsystem.
  { re: /\[[^\]\n]{1,60}\]/y, kind: "keyword" },
  { re: /\b\d+(?:\.\d+)*\b/y, kind: "number" },
  { re: /[A-Za-z_][\w.-]*/y, kind: "plain" },
];

const diff: readonly Rule[] = [
  { re: /^(?:diff |index |--- |\+\+\+ |old mode|new mode|similarity |rename )[^\n]*/my, kind: "keyword" },
  { re: /^@@[^\n]*/my, kind: "link" },
  { re: /^\+[^\n]*/my, kind: "string" },
  { re: /^-[^\n]*/my, kind: "error" },
  { re: /^[^\n]+/my, kind: "plain" },
  { re: /\n/y, kind: "plain" },
];

const plain: readonly Rule[] = [{ re: /[^\n]*\n?/y, kind: "plain" }];

const GRAMMARS: Record<Language, readonly Rule[]> = {
  "c-like": cLike,
  hash,
  shell,
  json,
  xml,
  md,
  log,
  diff,
  plain,
};

// MARK: - Picking the grammar

const BY_EXTENSION: Record<string, Language> = {
  js: "c-like", mjs: "c-like", cjs: "c-like", jsx: "c-like", ts: "c-like", tsx: "c-like",
  mts: "c-like", cts: "c-like", java: "c-like", kt: "c-like", kts: "c-like", swift: "c-like",
  go: "c-like", rs: "c-like", c: "c-like", h: "c-like", cc: "c-like", cpp: "c-like",
  hpp: "c-like", cxx: "c-like", m: "c-like", mm: "c-like", cs: "c-like", scala: "c-like",
  php: "c-like", dart: "c-like", zig: "c-like", groovy: "c-like", gradle: "c-like",
  css: "c-like", scss: "c-like", less: "c-like", proto: "c-like", sql: "c-like",

  py: "hash", rb: "hash", pl: "hash", r: "hash", yaml: "hash", yml: "hash", toml: "hash",
  ini: "hash", cfg: "hash", conf: "hash", properties: "hash", env: "hash", tf: "hash",

  sh: "shell", bash: "shell", zsh: "shell", fish: "shell",

  json: "json", jsonl: "json", json5: "json", jsonc: "json", lock: "json",

  html: "xml", htm: "xml", xhtml: "xml", xml: "xml", svg: "xml", plist: "xml", vue: "xml",

  md: "md", markdown: "md", mdx: "md",

  log: "log", out: "log", err: "log",

  diff: "diff", patch: "diff",
};

/** Files the world knows by name rather than by extension. */
const BY_NAME: Record<string, Language> = {
  makefile: "hash",
  dockerfile: "hash",
  gemfile: "hash",
  rakefile: "hash",
  brewfile: "hash",
  procfile: "hash",
  justfile: "hash",
  ".gitignore": "hash",
  ".dockerignore": "hash",
  ".gitattributes": "hash",
  ".editorconfig": "hash",
  ".bashrc": "shell",
  ".zshrc": "shell",
  ".profile": "shell",
  ".bash_profile": "shell",
  ".zprofile": "shell",
};

/**
 * Which grammar a filename asks for.
 *
 * Nothing is guessed from the bytes. The daemon has already decided the file is
 * text; the name decides how it is coloured, and an unknown name gets no
 * colour at all rather than the wrong colour.
 */
export function languageFor(filename: string): Language {
  const name = filename.slice(filename.lastIndexOf("/") + 1).toLowerCase();
  const byName = BY_NAME[name];
  if (byName) return byName;
  if (name.startsWith(".env")) return "hash";
  const dot = name.lastIndexOf(".");
  if (dot <= 0) return "plain";
  return BY_EXTENSION[name.slice(dot + 1)] ?? "plain";
}
