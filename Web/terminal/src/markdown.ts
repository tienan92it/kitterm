/**
 * Markdown, parsed to a block tree and rendered to the DOM.
 *
 * **Raw HTML is never parsed as HTML.** An HTML block and an inline tag are
 * text: `<script>` in a file is the eight characters `<script>` on screen. The
 * parser has no HTML rule, and the renderer builds every node with
 * `document.createElement`, sets text with `textContent` (or `append` of a
 * string, which makes a text node), and sets only the attributes
 * `RENDERED_ATTRIBUTES` names. A file's bytes never become markup, the rule
 * `file-preview.ts` and `FilePreview.swift` already keep.
 *
 * **No dependency.** The parser is CommonMark with the GFM additions the
 * objective names: tables, task items, strikethrough, bare URLs. It keeps the
 * block structure and the delimiter rules of the specification where a
 * reader notices them (lazy continuation, a list that interrupts a paragraph,
 * `_` inside a word, a code span with backticks) and simplifies where a
 * reader does not; the round record names the simplifications.
 *
 * **Bounded work.** Containers nest `MAX_DEPTH` deep and then the rest is a
 * paragraph; an inline run keeps `MAX_DELIMITERS` emphasis runs and as many
 * brackets, and the rest is text; every scan moves forward, so a crafted
 * file cannot make the parse quadratic.
 *
 * **Links are decided by the caller.** The renderer asks `resolveLink` and
 * `resolveImage` for every address and does what they say; the defaults
 * exported here let `http`, `https` and `mailto` out in a new tab, treat a
 * relative `.md` path as a document to open in the same view, show every
 * other scheme as text, and show every image as text.
 */

import { languageForFence, tokenize } from "./highlight";

// MARK: - The tree

export type Alignment = "left" | "center" | "right" | null;

export type Inline =
  | { type: "text"; text: string }
  | { type: "code"; text: string }
  | { type: "emphasis"; children: Inline[] }
  | { type: "strong"; children: Inline[] }
  | { type: "strikethrough"; children: Inline[] }
  | { type: "link"; href: string; title: string | null; children: Inline[] }
  | { type: "image"; src: string; alt: string; title: string | null }
  | { type: "break" };

export interface ListItem {
  children: Block[];
  /** `- [ ]` is `unchecked`, `- [x]` is `checked`, a plain item is `null`. */
  task: "checked" | "unchecked" | null;
}

export type Block =
  | { type: "heading"; level: 1 | 2 | 3 | 4 | 5 | 6; children: Inline[] }
  | { type: "paragraph"; children: Inline[] }
  | { type: "blockquote"; children: Block[] }
  | { type: "list"; ordered: boolean; start: number; tight: boolean; items: ListItem[] }
  | { type: "code"; language: string | null; text: string }
  | { type: "thematicBreak" }
  | { type: "table"; align: Alignment[]; header: Inline[][]; rows: Inline[][][] };

/** Containers (block quotes, lists) nest this deep; below it, lines are a paragraph. */
export const MAX_DEPTH = 32;
/** Emphasis runs and brackets one inline run keeps; the rest is text. */
export const MAX_DELIMITERS = 10_000;

// MARK: - Lines

const BLANK = /^[ \t]*$/;
const ATX = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$/;
const FENCE = /^( {0,3})(`{3,}|~{3,})(.*)$/;
const HR = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const QUOTE = /^ {0,3}>/;
const LIST = /^( {0,3})([-+*]|(\d{1,9})([.)]))([ \t]+|$)(.*)$/;
const SETEXT = /^ {0,3}(=+|-+)[ \t]*$/;
const TABLE_DELIM = /^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/;
const DEFINITION =
  /^ {0,3}\[((?:[^\]\\]|\\.){1,999})\]:[ \t]*\n?[ \t]*(<[^<>\n]*>|[^\s<][^\s]*)(?:[ \t]*\n?[ \t]*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^()\\]|\\.)*\)))?[ \t]*(?:\n|$)/;

/** Leading tabs as spaces to the next tab stop of four, so indents compare. */
function expandIndent(line: string): string {
  if (!line.startsWith("\t") && !/^ +\t/.test(line)) return line;
  let out = "";
  let i = 0;
  for (; i < line.length; i += 1) {
    const char = line[i];
    if (char === " ") out += " ";
    else if (char === "\t") out += " ".repeat(4 - (out.length % 4));
    else break;
  }
  return out + line.slice(i);
}

function indentOf(line: string): number {
  let i = 0;
  while (i < line.length && line[i] === " ") i += 1;
  return i;
}

/** The line less `n` columns of indent (fewer when it has fewer). */
function stripIndent(line: string, n: number): string {
  return line.slice(Math.min(n, indentOf(line)));
}

function isBlank(line: string): boolean {
  return BLANK.test(line);
}

/** Whether `line` starts a block that may interrupt a paragraph. */
function interruptsParagraph(line: string): boolean {
  if (HR.test(line) || ATX.test(line) || QUOTE.test(line)) return true;
  const fence = FENCE.exec(line);
  if (fence && !(fence[2][0] === "`" && fence[3].includes("`"))) return true;
  const item = LIST.exec(line);
  if (item && item[6] !== "" && !isBlank(item[6])) {
    // An ordered list interrupts a paragraph only when it starts at 1.
    return item[3] === undefined || item[3] === "1";
  }
  return false;
}

interface Definition {
  href: string;
  title: string | null;
}

// MARK: - Blocks

class BlockParser {
  readonly definitions = new Map<string, Definition>();
  /** Inline parsing runs after every definition is known, so a reference
   * defined below its use resolves. */
  private readonly deferred: Array<() => void> = [];

  parse(text: string): Block[] {
    const lines = text.split(/\r\n|\r|\n/).map(expandIndent);
    const blocks: Block[] = [];
    let start = 0;
    // Front matter: `---` on the first line to the next `---`, kept as YAML.
    if (lines.length > 1 && /^---[ \t]*$/.test(lines[0])) {
      let end = -1;
      for (let i = 1; i < lines.length; i += 1) {
        if (/^(?:---|\.\.\.)[ \t]*$/.test(lines[i])) {
          end = i;
          break;
        }
      }
      if (end > 0) {
        blocks.push({ type: "code", language: "yaml", text: lines.slice(1, end).join("\n") });
        start = end + 1;
      }
    }
    blocks.push(...this.parseBlocks(lines.slice(start), 0));
    for (const fn of this.deferred) fn();
    return blocks;
  }

  private inlines(raw: string, target: Inline[]): void {
    this.deferred.push(() => {
      target.push(...parseInline(raw, this.definitions));
    });
  }

  private parseBlocks(lines: string[], depth: number): Block[] {
    const blocks: Block[] = [];
    if (depth >= MAX_DEPTH) {
      const text = lines.filter((line) => !isBlank(line)).map((line) => line.trim()).join("\n");
      if (text) {
        const block: Block = { type: "paragraph", children: [] };
        this.inlines(text, block.children);
        blocks.push(block);
      }
      return blocks;
    }
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      if (isBlank(line)) {
        i += 1;
        continue;
      }
      const fence = FENCE.exec(line);
      if (fence && !(fence[2][0] === "`" && fence[3].includes("`"))) {
        i = this.parseFence(lines, i, fence, blocks);
        continue;
      }
      const atx = ATX.exec(line);
      if (atx) {
        let content = atx[2] ?? "";
        content = content.replace(/^#+$/, "").replace(/[ \t]+#+$/, "").trim();
        const block: Block = { type: "heading", level: atx[1].length as 1 | 2 | 3 | 4 | 5 | 6, children: [] };
        this.inlines(content, block.children);
        blocks.push(block);
        i += 1;
        continue;
      }
      if (HR.test(line)) {
        blocks.push({ type: "thematicBreak" });
        i += 1;
        continue;
      }
      if (QUOTE.test(line)) {
        i = this.parseQuote(lines, i, depth, blocks);
        continue;
      }
      const item = LIST.exec(line);
      if (item) {
        i = this.parseList(lines, i, depth, item, blocks);
        continue;
      }
      if (indentOf(line) >= 4) {
        i = this.parseIndentedCode(lines, i, blocks);
        continue;
      }
      // A one-column table needs a pipe on its delimiter row, else `foo |` over
      // `---` is a setext heading as it reads.
      if (line.includes("|") && i + 1 < lines.length && TABLE_DELIM.test(lines[i + 1]) && (lines[i + 1].includes("|") || line.trim().length > 1)) {
        const next = this.parseTable(lines, i, blocks);
        if (next > i) {
          i = next;
          continue;
        }
      }
      i = this.parseParagraph(lines, i, blocks);
    }
    return blocks;
  }

  private parseFence(lines: string[], i: number, fence: RegExpExecArray, blocks: Block[]): number {
    const indent = fence[1].length;
    const marker = fence[2];
    const info = unescapeText(fence[3].trim());
    const close = new RegExp(`^ {0,3}${marker[0] === "`" ? "`" : "~"}{${marker.length},}[ \\t]*$`);
    const body: string[] = [];
    let j = i + 1;
    for (; j < lines.length; j += 1) {
      if (close.test(lines[j])) {
        j += 1;
        break;
      }
      body.push(stripIndent(lines[j], indent));
    }
    const language = info === "" ? null : info.split(/\s+/)[0];
    blocks.push({ type: "code", language, text: body.join("\n") });
    return j;
  }

  private parseIndentedCode(lines: string[], i: number, blocks: Block[]): number {
    const body: string[] = [];
    let j = i;
    for (; j < lines.length; j += 1) {
      const line = lines[j];
      if (isBlank(line)) body.push(stripIndent(line, 4));
      else if (indentOf(line) >= 4) body.push(line.slice(4));
      else break;
    }
    while (body.length && isBlank(body[body.length - 1])) body.pop();
    blocks.push({ type: "code", language: null, text: body.join("\n") });
    return j;
  }

  private parseQuote(lines: string[], i: number, depth: number, blocks: Block[]): number {
    const inner: string[] = [];
    let j = i;
    let lastBlank = true;
    for (; j < lines.length; j += 1) {
      const line = lines[j];
      if (QUOTE.test(line)) {
        inner.push(expandIndent(line.replace(/^ {0,3}> ?/, "")));
      } else if (!lastBlank && !isBlank(line) && !interruptsParagraph(line)) {
        // Lazy continuation: a paragraph inside the quote runs on.
        inner.push(line);
      } else {
        break;
      }
      lastBlank = isBlank(inner[inner.length - 1]);
    }
    blocks.push({ type: "blockquote", children: this.parseBlocks(inner, depth + 1) });
    return j;
  }

  private parseList(lines: string[], i: number, depth: number, first: RegExpExecArray, blocks: Block[]): number {
    const ordered = first[3] !== undefined;
    const kind = ordered ? first[4] : first[2];
    const start = ordered ? parseInt(first[3], 10) : 1;
    const items: ListItem[] = [];
    let loose = false;
    let j = i;
    while (j < lines.length) {
      const line = lines[j];
      if (HR.test(line)) break;
      const m = LIST.exec(line);
      if (!m || (m[3] !== undefined) !== ordered || (ordered ? m[4] : m[2]) !== kind) break;
      const markerWidth = m[1].length + m[2].length;
      let rest = m[6];
      let width: number;
      if (rest === "" || isBlank(rest)) {
        rest = "";
        width = markerWidth + 1;
      } else if (m[5].length >= 5) {
        // Five or more spaces: the content is indented code after one space.
        width = markerWidth + 1;
        rest = " ".repeat(m[5].length - 1) + rest;
      } else {
        width = markerWidth + m[5].length;
      }
      const itemLines: string[] = [rest];
      j += 1;
      if (rest === "" && (j >= lines.length || isBlank(lines[j]))) {
        // An item may begin with at most one blank line; this one is empty.
        items.push({ children: [], task: null });
        if (j < lines.length) {
          j += 1;
          if (j < lines.length && LIST.exec(lines[j])) loose = true;
        }
        continue;
      }
      for (; j < lines.length; j += 1) {
        const next = lines[j];
        if (isBlank(next)) {
          itemLines.push("");
          continue;
        }
        if (indentOf(next) >= width) {
          itemLines.push(stripIndent(next, width));
          continue;
        }
        const previous = itemLines[itemLines.length - 1];
        if (!isBlank(previous) && !interruptsParagraph(next) && !LIST.test(next)) {
          itemLines.push(next.trimStart());
          continue;
        }
        break;
      }
      // The first entry is the marker's own line, empty for an item with
      // nothing after its marker; it is not a blank line between items.
      let trailing = 0;
      while (itemLines.length > 1 && isBlank(itemLines[itemLines.length - 1])) {
        itemLines.pop();
        trailing += 1;
      }
      // A blank line between two blocks of one item makes the list loose.
      for (let k = 1; k < itemLines.length - 1; k += 1) {
        if (isBlank(itemLines[k]) && !isBlank(itemLines[k + 1])) loose = true;
      }
      if (trailing > 0 && j < lines.length && LIST.test(lines[j]) && !HR.test(lines[j])) loose = true;
      const children = this.parseBlocks(itemLines, depth + 1);
      items.push({ children, task: this.taskOf(itemLines[0], children) });
    }
    blocks.push({ type: "list", ordered, start, tight: !loose, items });
    return j;
  }

  /** `[ ]` or `[x]` at the head of the item's first paragraph marks a task. */
  private taskOf(firstLine: string, children: Block[]): ListItem["task"] {
    const m = /^\[([ xX])\](?:[ \t]+|$)/.exec(firstLine);
    const head = children[0];
    if (!m || !head || head.type !== "paragraph") return null;
    this.deferred.push(() => {
      const first = head.children[0];
      if (first && first.type === "text") {
        first.text = first.text.replace(/^\[[ xX]\][ \t]*/, "");
        if (first.text === "") head.children.shift();
      }
    });
    return m[1] === " " ? "unchecked" : "checked";
  }

  private parseTable(lines: string[], i: number, blocks: Block[]): number {
    const header = splitCells(lines[i]);
    const delims = splitCells(lines[i + 1]);
    if (header.length === 0 || header.length !== delims.length) return i;
    const align: Alignment[] = delims.map((cell) => {
      const left = cell.startsWith(":");
      const right = cell.endsWith(":");
      if (left && right) return "center";
      if (left) return "left";
      if (right) return "right";
      return null;
    });
    const block: Block = { type: "table", align, header: [], rows: [] };
    for (const cell of header) {
      const inlines: Inline[] = [];
      this.inlines(cell, inlines);
      block.header.push(inlines);
    }
    let j = i + 2;
    for (; j < lines.length; j += 1) {
      const line = lines[j];
      if (isBlank(line) || interruptsParagraph(line)) break;
      const cells = splitCells(line);
      const row: Inline[][] = [];
      for (let c = 0; c < header.length; c += 1) {
        const inlines: Inline[] = [];
        this.inlines(cells[c] ?? "", inlines);
        row.push(inlines);
      }
      block.rows.push(row);
    }
    blocks.push(block);
    return j;
  }

  private parseParagraph(lines: string[], i: number, blocks: Block[]): number {
    // Leading space goes; trailing space stays, because two of them before
    // a newline are a hard break.
    const collected: string[] = [lines[i].trimStart()];
    let j = i + 1;
    let level: 1 | 2 | 0 = 0;
    for (; j < lines.length; j += 1) {
      const line = lines[j];
      if (isBlank(line)) break;
      const setext = SETEXT.exec(line);
      if (setext) {
        level = setext[1][0] === "=" ? 1 : 2;
        j += 1;
        break;
      }
      if (interruptsParagraph(line)) break;
      collected.push(line.trimStart());
    }
    let text = collected.join("\n");
    // Link reference definitions sit at the head of a paragraph and are not
    // part of it.
    for (;;) {
      const def = DEFINITION.exec(text);
      if (!def) break;
      const label = normalizeLabel(def[1]);
      if (label !== "" && !this.definitions.has(label)) {
        this.definitions.set(label, {
          href: unescapeText(def[2].startsWith("<") ? def[2].slice(1, -1) : def[2]),
          title: def[3] === undefined ? null : unescapeText(def[3].slice(1, -1)),
        });
      }
      text = text.slice(def[0].length);
    }
    if (text === "") {
      if (level) blocks.push({ type: "paragraph", children: [] });
      return j;
    }
    const block: Block = level ? { type: "heading", level, children: [] } : { type: "paragraph", children: [] };
    this.inlines(text.replace(/[ \t]+$/, ""), block.children);
    blocks.push(block);
    return j;
  }
}

/** The cells of a table row; `\|` is a pipe in a cell, inside a code span too. */
function splitCells(line: string): string[] {
  let text = line.trim();
  if (text.startsWith("|")) text = text.slice(1);
  if (text.endsWith("|") && !text.endsWith("\\|")) text = text.slice(0, -1);
  const cells: string[] = [];
  let cell = "";
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (char === "\\" && i + 1 < text.length) {
      cell += text[i + 1] === "|" ? "|" : char + text[i + 1];
      i += 1;
    } else if (char === "|") {
      cells.push(cell.trim());
      cell = "";
    } else {
      cell += char;
    }
  }
  cells.push(cell.trim());
  return cells;
}

function normalizeLabel(label: string): string {
  return label.trim().replace(/\s+/g, " ").toLowerCase();
}

// MARK: - Entities and escapes

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", copy: "©", reg: "®",
  trade: "™", hellip: "…", mdash: "—", ndash: "–", laquo: "«", raquo: "»", lsquo: "‘",
  rsquo: "’", ldquo: "“", rdquo: "”", bull: "•", middot: "·", deg: "°", plusmn: "±",
  times: "×", divide: "÷", euro: "€", pound: "£", yen: "¥", cent: "¢", sect: "§",
  para: "¶", larr: "←", rarr: "→", uarr: "↑", darr: "↓", harr: "↔", ne: "≠", le: "≤",
  ge: "≥", infin: "∞", check: "✓", cross: "✗", hearts: "♥", star: "☆",
};

const ENTITY = /&(?:#(\d{1,7})|#[xX]([0-9a-fA-F]{1,6})|([a-zA-Z][a-zA-Z0-9]{1,31}));/y;

/** The character an entity at `at` names, with the match length; `null` for none. */
function entityAt(text: string, at: number): { char: string; length: number } | null {
  ENTITY.lastIndex = at;
  const m = ENTITY.exec(text);
  if (!m) return null;
  if (m[3] !== undefined) {
    const named = NAMED_ENTITIES[m[3]];
    return named === undefined ? null : { char: named, length: m[0].length };
  }
  const code = m[1] !== undefined ? parseInt(m[1], 10) : parseInt(m[2], 16);
  const char = code === 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) ? "�" : String.fromCodePoint(code);
  return { char, length: m[0].length };
}

const ASCII_PUNCT = /[!-/:-@[-`{-~]/;

/** Backslash escapes and entities resolved, for a destination, a title or an info string. */
function unescapeText(text: string): string {
  if (!text.includes("\\") && !text.includes("&")) return text;
  let out = "";
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (char === "\\" && i + 1 < text.length && ASCII_PUNCT.test(text[i + 1])) {
      out += text[i + 1];
      i += 1;
    } else if (char === "&") {
      const entity = entityAt(text, i);
      if (entity) {
        out += entity.char;
        i += entity.length - 1;
      } else out += char;
    } else out += char;
  }
  return out;
}

// MARK: - Inlines

interface Cell {
  inline: Inline;
  prev: Cell | null;
  next: Cell | null;
  /** A delimiter run's or a bracket's cell keeps its own text; a neighbour never merges into it. */
  locked?: boolean;
}

interface Delimiter {
  cell: Cell;
  char: "*" | "_" | "~";
  count: number;
  original: number;
  canOpen: boolean;
  canClose: boolean;
  prev: Delimiter | null;
  next: Delimiter | null;
}

interface Bracket {
  cell: Cell;
  image: boolean;
  /** The delimiter stack's top when the bracket opened. */
  delimiterTop: Delimiter | null;
  prev: Bracket | null;
  active: boolean;
  /** Where the label's text begins in the source. */
  position: number;
}

const UNICODE_PUNCT = /[\p{P}\p{S}]/u;
const TEXT_RUN = /[^\\`*_~[\]!<&\nh]+/y;
const AUTOLINK = /<([a-zA-Z][a-zA-Z0-9+.-]{1,31}:[^\s<>]*)>/y;
const EMAIL_AUTOLINK =
  /<([a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>/y;
const BARE_URL = /https?:\/\/[^\s<]*[^\s<?!.,:*_~'"]/y;

class InlineParser {
  private head: Cell | null = null;
  private tail: Cell | null = null;
  private delimiterTop: Delimiter | null = null;
  private delimiterBottom: Delimiter | null = null;
  private delimiters = 0;
  private bracketTop: Bracket | null = null;
  private brackets = 0;
  private position = 0;
  /** Backtick run lengths that have no closing run anywhere ahead. */
  private readonly unclosedBackticks = new Set<number>();

  constructor(
    private readonly source: string,
    private readonly definitions: Map<string, Definition>,
  ) {}

  parse(): Inline[] {
    const src = this.source;
    while (this.position < src.length) {
      const char = src[this.position];
      switch (char) {
        case "\\":
          this.escape();
          break;
        case "`":
          this.codeSpan();
          break;
        case "*":
        case "_":
          this.delimiterRun(char);
          break;
        case "~":
          this.tildeRun();
          break;
        case "[":
          this.openBracket(false);
          break;
        case "!":
          if (src[this.position + 1] === "[") this.openBracket(true);
          else this.text("!", 1);
          break;
        case "]":
          this.closeBracket();
          break;
        case "<":
          this.angle();
          break;
        case "&": {
          const entity = entityAt(src, this.position);
          if (entity) this.text(entity.char, entity.length);
          else this.text("&", 1);
          break;
        }
        case "\n":
          this.newline();
          break;
        case "h":
          if (!this.bareUrl()) this.text("h", 1);
          break;
        default: {
          TEXT_RUN.lastIndex = this.position;
          const run = TEXT_RUN.exec(src);
          const value = run ? run[0] : char;
          this.text(value, value.length);
        }
      }
    }
    this.processEmphasis(null);
    return collect(this.head);
  }

  private append(inline: Inline): Cell {
    const cell: Cell = { inline, prev: this.tail, next: null };
    if (this.tail) this.tail.next = cell;
    else this.head = cell;
    this.tail = cell;
    return cell;
  }

  private text(value: string, consumed: number): Cell {
    this.position += consumed;
    const last = this.tail;
    if (last && last.inline.type === "text" && !last.locked) {
      last.inline.text += value;
      return last;
    }
    return this.append({ type: "text", text: value });
  }

  private escape(): void {
    const next = this.source[this.position + 1];
    if (next === "\n") {
      this.position += 2;
      this.append({ type: "break" });
      this.skipLineStart();
    } else if (next !== undefined && ASCII_PUNCT.test(next)) {
      this.text(next, 2);
    } else {
      this.text("\\", 1);
    }
  }

  private codeSpan(): void {
    const src = this.source;
    let count = 0;
    while (src[this.position + count] === "`") count += 1;
    if (!this.unclosedBackticks.has(count)) {
      let at = this.position + count;
      for (;;) {
        const found = src.indexOf("`", at);
        if (found < 0) break;
        let run = 0;
        while (src[found + run] === "`") run += 1;
        if (run === count) {
          let content = src.slice(this.position + count, found).replace(/\n/g, " ");
          if (content.length >= 2 && content.startsWith(" ") && content.endsWith(" ") && content.trim() !== "") {
            content = content.slice(1, -1);
          }
          this.position = found + run;
          this.append({ type: "code", text: content });
          return;
        }
        at = found + run;
      }
      this.unclosedBackticks.add(count);
    }
    this.text("`".repeat(count), count);
  }

  private flanking(count: number): { canOpen: boolean; canClose: boolean; char: string } {
    const src = this.source;
    const before = this.position === 0 ? " " : src[this.position - 1];
    const after = this.position + count >= src.length ? " " : src[this.position + count];
    const beforeSpace = /\s/.test(before);
    const afterSpace = /\s/.test(after);
    const beforePunct = UNICODE_PUNCT.test(before);
    const afterPunct = UNICODE_PUNCT.test(after);
    const left = !afterSpace && (!afterPunct || beforeSpace || beforePunct);
    const right = !beforeSpace && (!beforePunct || afterSpace || afterPunct);
    const char = src[this.position];
    if (char === "_") {
      return { char, canOpen: left && (!right || beforePunct), canClose: right && (!left || afterPunct) };
    }
    return { char, canOpen: left, canClose: right };
  }

  private delimiterRun(char: "*" | "_"): void {
    let count = 0;
    while (this.source[this.position + count] === char) count += 1;
    const { canOpen, canClose } = this.flanking(count);
    this.pushDelimiter(char, count, canOpen, canClose);
  }

  private tildeRun(): void {
    let count = 0;
    while (this.source[this.position + count] === "~") count += 1;
    if (count !== 2) {
      this.text("~".repeat(count), count);
      return;
    }
    const { canOpen, canClose } = this.flanking(count);
    this.pushDelimiter("~", count, canOpen, canClose);
  }

  private pushDelimiter(char: "*" | "_" | "~", count: number, canOpen: boolean, canClose: boolean): void {
    const value = char.repeat(count);
    if ((!canOpen && !canClose) || this.delimiters >= MAX_DELIMITERS) {
      this.text(value, count);
      return;
    }
    this.position += count;
    const cell = this.append({ type: "text", text: value });
    cell.locked = true;
    const delimiter: Delimiter = { cell, char, count, original: count, canOpen, canClose, prev: this.delimiterTop, next: null };
    if (this.delimiterTop) this.delimiterTop.next = delimiter;
    else this.delimiterBottom = delimiter;
    this.delimiterTop = delimiter;
    this.delimiters += 1;
  }

  private openBracket(image: boolean): void {
    const value = image ? "![" : "[";
    if (this.brackets >= MAX_DELIMITERS) {
      this.text(value, value.length);
      return;
    }
    this.position += value.length;
    const cell = this.append({ type: "text", text: value });
    cell.locked = true;
    this.bracketTop = { cell, image, delimiterTop: this.delimiterTop, prev: this.bracketTop, active: true, position: this.position };
    this.brackets += 1;
  }

  private closeBracket(): void {
    const opener = this.bracketTop;
    if (!opener) {
      this.text("]", 1);
      return;
    }
    this.bracketTop = opener.prev;
    if (!opener.active) {
      this.text("]", 1);
      return;
    }
    const src = this.source;
    const labelEnd = this.position;
    let target: Definition | null = null;
    let end = labelEnd + 1;
    if (src[end] === "(") {
      const tail = this.inlineLinkTail(end);
      if (tail) {
        target = { href: tail.href, title: tail.title };
        end = tail.end;
      }
    }
    if (!target) {
      // A full reference `[text][label]`, a collapsed `[text][]`, or a shortcut `[text]`.
      let label: string | null = null;
      let after = labelEnd + 1;
      const full = /\[((?:[^\]\\[]|\\.){0,999})\]/y;
      full.lastIndex = labelEnd + 1;
      const m = full.exec(src);
      if (m) {
        after = full.lastIndex;
        label = m[1] === "" ? null : m[1];
      }
      if (label === null) {
        const own = src.slice(opener.position, labelEnd);
        if (own.length <= 999 && !/(^|[^\\])[[\]]/.test(own)) label = own;
      }
      if (label !== null) {
        const found = this.definitions.get(normalizeLabel(label));
        if (found && normalizeLabel(label) !== "") {
          target = found;
          end = after;
        }
      }
    }
    if (!target) {
      this.text("]", 1);
      return;
    }
    this.processEmphasis(opener.delimiterTop);
    const children = collect(opener.cell.next);
    opener.cell.next = null;
    this.tail = opener.cell;
    if (opener.image) {
      opener.cell.inline = { type: "image", src: target.href, alt: plainText(children), title: target.title };
    } else {
      opener.cell.inline = { type: "link", href: target.href, title: target.title, children };
      // No link inside a link: every earlier `[` is now literal.
      for (let b = this.bracketTop; b; b = b.prev) if (!b.image) b.active = false;
    }
    this.position = end;
  }

  /** `(dest "title")` at `at`; `null` when the text there is not one. */
  private inlineLinkTail(at: number): { href: string; title: string | null; end: number } | null {
    const src = this.source;
    let i = at + 1;
    const skipSpace = (): void => {
      while (i < src.length && /\s/.test(src[i])) i += 1;
    };
    skipSpace();
    let dest = "";
    if (src[i] === "<") {
      const close = /<((?:[^<>\n\\]|\\.)*)>/y;
      close.lastIndex = i;
      const m = close.exec(src);
      if (!m) return null;
      dest = m[1];
      i = close.lastIndex;
    } else {
      let depth = 0;
      const start = i;
      for (; i < src.length; i += 1) {
        const char = src[i];
        if (char === "\\" && i + 1 < src.length && ASCII_PUNCT.test(src[i + 1])) {
          i += 1;
          continue;
        }
        if (/[\s\u0000-\u001f\u007f]/.test(char)) break;
        if (char === "(") {
          depth += 1;
          if (depth > 32) return null;
        } else if (char === ")") {
          if (depth === 0) break;
          depth -= 1;
        }
      }
      if (depth !== 0) return null;
      dest = src.slice(start, i);
    }
    const beforeTitle = i;
    skipSpace();
    let title: string | null = null;
    const quote = src[i];
    if (i > beforeTitle && (quote === '"' || quote === "'" || quote === "(")) {
      const closeChar = quote === "(" ? ")" : quote;
      let k = i + 1;
      for (; k < src.length; k += 1) {
        if (src[k] === "\\" && k + 1 < src.length) k += 1;
        else if (src[k] === closeChar) break;
        else if (quote === "(" && src[k] === "(") return null;
      }
      if (k >= src.length) return null;
      title = unescapeText(src.slice(i + 1, k));
      i = k + 1;
      skipSpace();
    }
    if (src[i] !== ")") return null;
    return { href: unescapeText(dest), title, end: i + 1 };
  }

  private angle(): void {
    const src = this.source;
    AUTOLINK.lastIndex = this.position;
    const link = AUTOLINK.exec(src);
    if (link) {
      this.position = AUTOLINK.lastIndex;
      this.append({ type: "link", href: link[1], title: null, children: [{ type: "text", text: link[1] }] });
      return;
    }
    EMAIL_AUTOLINK.lastIndex = this.position;
    const email = EMAIL_AUTOLINK.exec(src);
    if (email) {
      this.position = EMAIL_AUTOLINK.lastIndex;
      this.append({ type: "link", href: `mailto:${email[1]}`, title: null, children: [{ type: "text", text: email[1] }] });
      return;
    }
    // A tag is text: the one rule of the module.
    this.text("<", 1);
  }

  /** A bare `http://` or `https://` address, the GFM extension. */
  private bareUrl(): boolean {
    const src = this.source;
    const before = this.position === 0 ? " " : src[this.position - 1];
    if (!/[\s*_~(]/.test(before) || this.bracketTop) return false;
    BARE_URL.lastIndex = this.position;
    const m = BARE_URL.exec(src);
    if (!m) return false;
    let url = m[0];
    // A closing parenthesis belongs to the sentence unless the address opened it.
    while (url.endsWith(")")) {
      let open = 0;
      let close = 0;
      for (const char of url) {
        if (char === "(") open += 1;
        else if (char === ")") close += 1;
      }
      if (close <= open) break;
      url = url.slice(0, -1);
    }
    if (url.length <= "https://".length) return false;
    this.position += url.length;
    this.append({ type: "link", href: url, title: null, children: [{ type: "text", text: url }] });
    return true;
  }

  private newline(): void {
    const last = this.tail;
    let hard = false;
    if (last && last.inline.type === "text" && !last.locked) {
      const trimmed = last.inline.text.replace(/ +$/, "");
      hard = last.inline.text.length - trimmed.length >= 2;
      last.inline.text = trimmed;
      if (trimmed === "") this.removeCell(last);
    }
    this.position += 1;
    if (hard) this.append({ type: "break" });
    else this.text("\n", 0);
    this.skipLineStart();
  }

  private skipLineStart(): void {
    while (this.source[this.position] === " " || this.source[this.position] === "\t") this.position += 1;
  }

  private removeCell(cell: Cell): void {
    if (cell.prev) cell.prev.next = cell.next;
    else this.head = cell.next;
    if (cell.next) cell.next.prev = cell.prev;
    else this.tail = cell.prev;
  }

  private removeDelimiter(delimiter: Delimiter): void {
    if (delimiter.prev) delimiter.prev.next = delimiter.next;
    else this.delimiterBottom = delimiter.next;
    if (delimiter.next) delimiter.next.prev = delimiter.prev;
    else this.delimiterTop = delimiter.prev;
  }

  /** The CommonMark emphasis algorithm over the delimiters above `bottom`. */
  private processEmphasis(bottom: Delimiter | null): void {
    const openersBottom = new Map<string, Delimiter | null>();
    let current = bottom ? bottom.next : this.delimiterBottom;
    while (current) {
      if (!current.canClose) {
        current = current.next;
        continue;
      }
      const key = `${current.char}${current.canOpen ? 1 : 0}${current.original % 3}`;
      const floor = openersBottom.has(key) ? openersBottom.get(key) ?? null : bottom;
      let opener = current.prev;
      let found: Delimiter | null = null;
      while (opener && opener !== bottom && opener !== floor) {
        if (opener.char === current.char && opener.canOpen) {
          const oddMatch =
            (current.canOpen || opener.canClose) && current.original % 3 !== 0 && (opener.original + current.original) % 3 === 0;
          const tildeMatch = current.char !== "~" || opener.count === current.count;
          if (!oddMatch && tildeMatch) {
            found = opener;
            break;
          }
        }
        opener = opener.prev;
      }
      if (!found) {
        openersBottom.set(key, current.prev);
        if (!current.canOpen) this.removeDelimiter(current);
        current = current.next;
        continue;
      }
      const use = current.char === "~" ? 2 : found.count >= 2 && current.count >= 2 ? 2 : 1;
      found.count -= use;
      current.count -= use;
      (found.cell.inline as { text: string }).text = found.char.repeat(found.count);
      (current.cell.inline as { text: string }).text = current.char.repeat(current.count);
      const type = current.char === "~" ? "strikethrough" : use === 2 ? "strong" : "emphasis";
      const children = collectBetween(found.cell, current.cell);
      const wrapped: Cell = { inline: { type, children }, prev: found.cell, next: current.cell };
      found.cell.next = wrapped;
      current.cell.prev = wrapped;
      // The delimiters between the two are inside the new node and are gone.
      for (let d = current.prev; d && d !== found; ) {
        const prev = d.prev;
        this.removeDelimiter(d);
        d = prev;
      }
      if (found.count === 0) {
        this.removeCell(found.cell);
        this.removeDelimiter(found);
      }
      if (current.count === 0) {
        const next = current.next;
        this.removeCell(current.cell);
        this.removeDelimiter(current);
        current = next;
      }
    }
    // Every delimiter above the floor is literal text now.
    while (this.delimiterTop && this.delimiterTop !== bottom) this.removeDelimiter(this.delimiterTop);
  }
}

/** The inlines from `from` to the end, with adjacent text runs merged. */
function collect(from: Cell | null): Inline[] {
  const out: Inline[] = [];
  for (let cell = from; cell; cell = cell.next) push(out, cell.inline);
  return out;
}

function collectBetween(after: Cell, before: Cell): Inline[] {
  const out: Inline[] = [];
  for (let cell = after.next; cell && cell !== before; cell = cell.next) push(out, cell.inline);
  return out;
}

function push(out: Inline[], inline: Inline): void {
  if (inline.type === "text") {
    if (inline.text === "") return;
    const last = out[out.length - 1];
    if (last && last.type === "text") {
      last.text += inline.text;
      return;
    }
  }
  out.push(inline);
}

/** The text of inlines with every mark dropped: an image's alt. */
export function plainText(inlines: Inline[]): string {
  let out = "";
  for (const inline of inlines) {
    switch (inline.type) {
      case "text":
      case "code":
        out += inline.text;
        break;
      case "image":
        out += inline.alt;
        break;
      case "break":
        out += "\n";
        break;
      default:
        out += plainText(inline.children);
    }
  }
  return out;
}

function parseInline(source: string, definitions: Map<string, Definition>): Inline[] {
  if (source === "") return [];
  return new InlineParser(source, definitions).parse();
}

/** Markdown text to a block tree. Never throws on any input. */
export function parseMarkdown(text: string): Block[] {
  return new BlockParser().parse(text);
}

// MARK: - Slugs

/**
 * GitHub's slug: lower case, punctuation dropped, each space a `-` (so
 * `A & B` is `a--b`, as on GitHub), and `-1`, `-2` for a repeat. The empty
 * slug gets no id.
 */
export function slugify(text: string): string {
  return text
    .toLowerCase()
    .trim()
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .replace(/\s/g, "-");
}

/**
 * Every heading id carries this prefix, because a bare id is a global on
 * the page it lands on (DOM clobbering: a heading named `location`,
 * `document` or `sessions` would shadow `window.location` or the page's own
 * element). GitHub prefixes `user-content-` for the same reason.
 */
export const HEADING_ID_PREFIX = "md-";

/**
 * The element id a `#fragment` link scrolls to: the fragment, with or
 * without its `#`, under the heading prefix. `#the-mcp-bridge` and
 * `the-mcp-bridge` both give `md-the-mcp-bridge`. The views of round 3 call
 * this when they open a `.md#fragment` link.
 */
export function fragmentTarget(fragment: string): string {
  const bare = fragment.startsWith("#") ? fragment.slice(1) : fragment;
  return bare === "" ? "" : `${HEADING_ID_PREFIX}${bare}`;
}

/** `path#fragment` with the fragment moved under the heading prefix; a path with no fragment is unchanged. */
function withFragmentTarget(path: string): string {
  const hash = path.indexOf("#");
  if (hash < 0 || hash === path.length - 1) return path;
  return `${path.slice(0, hash)}#${fragmentTarget(path.slice(hash))}`;
}

// MARK: - Rendering

export type LinkTarget = { kind: "external"; href: string } | { kind: "markdown"; path: string } | { kind: "text" };

export interface RenderOptions {
  /** Where a link goes; the default is `resolveLink`. */
  resolveLink?: (url: string) => LinkTarget;
  /** The `src` an image may load from, or `null` to show it as text; the default shows every image as text. */
  resolveImage?: (src: string) => string | null;
}

/** Every attribute the renderer may set, and the only ones a rendered node carries. */
export const RENDERED_ATTRIBUTES: ReadonlySet<string> = new Set([
  "href", "target", "rel", "src", "alt", "title", "class", "id", "start", "type", "checked", "disabled",
  "data-language", "data-align", "data-markdown",
]);

const SCHEME = /^([a-z][a-z0-9+.-]*):/;

/**
 * The default link rule. `http`, `https` and `mailto` are external; a
 * relative path ending in `.md`, with an optional fragment, and a bare
 * `#fragment` are documents; every other scheme and every other path is
 * text. The scheme is read case- and whitespace-insensitively, so
 * ` JaVaScRiPt:` and `java\tscript:` are the scheme they hide.
 */
export function resolveLink(url: string): LinkTarget {
  const compact = url.replace(/[\s\u0000-\u001f\u007f]/g, "").toLowerCase();
  const scheme = SCHEME.exec(compact);
  if (scheme) {
    return scheme[1] === "http" || scheme[1] === "https" || scheme[1] === "mailto"
      ? { kind: "external", href: url.trim() }
      : { kind: "text" };
  }
  if (compact.startsWith("//") || compact.startsWith("\\\\")) return { kind: "text" };
  if (/^#./.test(compact)) return { kind: "markdown", path: url.trim() };
  if (/\.md(#[^#]*)?$/.test(compact)) return { kind: "markdown", path: url.trim() };
  return { kind: "text" };
}

/** The default image rule: no image loads; it is its alt text and its address. */
export function resolveImage(): string | null {
  return null;
}

class Renderer {
  private readonly slugs = new Map<string, number>();
  private readonly resolveLink: (url: string) => LinkTarget;
  private readonly resolveImage: (src: string) => string | null;

  constructor(options: RenderOptions) {
    this.resolveLink = options.resolveLink ?? resolveLink;
    this.resolveImage = options.resolveImage ?? resolveImage;
  }

  blocks(blocks: Block[], into: ParentNode & Node, tight = false): void {
    for (const block of blocks) into.appendChild(this.block(block, tight));
  }

  private block(block: Block, tight: boolean): Node {
    switch (block.type) {
      case "heading": {
        const el = document.createElement(`h${block.level}`);
        const slug = this.uniqueSlug(slugify(plainText(block.children)));
        if (slug) el.setAttribute("id", `${HEADING_ID_PREFIX}${slug}`);
        this.inlines(block.children, el);
        return el;
      }
      case "paragraph": {
        if (tight) {
          const span = document.createDocumentFragment();
          this.inlines(block.children, span);
          return span;
        }
        const p = document.createElement("p");
        this.inlines(block.children, p);
        return p;
      }
      case "blockquote": {
        const el = document.createElement("blockquote");
        this.blocks(block.children, el);
        return el;
      }
      case "list": {
        const el = document.createElement(block.ordered ? "ol" : "ul");
        if (block.ordered && block.start !== 1) el.setAttribute("start", String(block.start));
        for (const item of block.items) {
          const li = document.createElement("li");
          if (item.task) {
            li.setAttribute("class", "md-task");
            const box = document.createElement("input");
            box.setAttribute("type", "checkbox");
            box.setAttribute("disabled", "");
            if (item.task === "checked") box.setAttribute("checked", "");
            li.appendChild(box);
            li.append(" ");
          }
          this.blocks(item.children, li, block.tight);
          el.appendChild(li);
        }
        return el;
      }
      case "code": {
        const pre = document.createElement("pre");
        pre.setAttribute("class", "md-code");
        const code = document.createElement("code");
        if (block.language) {
          pre.setAttribute("data-language", block.language);
          // A class only for a language that is a word; `<script>` is none.
          if (/^[\w+#.-]{1,32}$/.test(block.language)) code.setAttribute("class", `language-${block.language}`);
        }
        for (const token of tokenize(block.text, languageForFence(block.language ?? ""))) {
          if (token.kind === "plain") {
            code.append(token.text);
            continue;
          }
          const span = document.createElement("span");
          span.setAttribute("class", `tok-${token.kind}`);
          span.textContent = token.text;
          code.appendChild(span);
        }
        pre.appendChild(code);
        return pre;
      }
      case "thematicBreak":
        return document.createElement("hr");
      case "table": {
        const table = document.createElement("table");
        const thead = document.createElement("thead");
        const headRow = document.createElement("tr");
        block.header.forEach((cell, c) => headRow.appendChild(this.cell("th", cell, block.align[c])));
        thead.appendChild(headRow);
        table.appendChild(thead);
        if (block.rows.length) {
          const tbody = document.createElement("tbody");
          for (const row of block.rows) {
            const tr = document.createElement("tr");
            row.forEach((cell, c) => tr.appendChild(this.cell("td", cell, block.align[c])));
            tbody.appendChild(tr);
          }
          table.appendChild(tbody);
        }
        return table;
      }
    }
  }

  private cell(tag: "th" | "td", inlines: Inline[], align: Alignment | undefined): HTMLElement {
    const el = document.createElement(tag);
    if (align) el.setAttribute("data-align", align);
    this.inlines(inlines, el);
    return el;
  }

  private uniqueSlug(slug: string): string {
    if (slug === "") return "";
    const seen = this.slugs.get(slug) ?? 0;
    this.slugs.set(slug, seen + 1);
    return seen === 0 ? slug : `${slug}-${seen}`;
  }

  private inlines(inlines: Inline[], into: ParentNode & Node): void {
    for (const inline of inlines) {
      switch (inline.type) {
        case "text":
          into.append(inline.text);
          break;
        case "code": {
          const el = document.createElement("code");
          el.textContent = inline.text;
          into.appendChild(el);
          break;
        }
        case "emphasis":
        case "strong":
        case "strikethrough": {
          const el = document.createElement(inline.type === "emphasis" ? "em" : inline.type === "strong" ? "strong" : "del");
          this.inlines(inline.children, el);
          into.appendChild(el);
          break;
        }
        case "break":
          into.appendChild(document.createElement("br"));
          break;
        case "link":
          this.link(inline, into);
          break;
        case "image":
          this.image(inline, into);
          break;
      }
    }
  }

  private link(inline: Extract<Inline, { type: "link" }>, into: ParentNode & Node): void {
    const target = this.resolveLink(inline.href);
    if (target.kind === "text") {
      // The words stay, and the address shows as text beside them.
      const span = document.createElement("span");
      span.setAttribute("class", "md-unlinked");
      this.inlines(inline.children, span);
      into.appendChild(span);
      into.append(` (${inline.href})`);
      return;
    }
    const a = document.createElement("a");
    if (target.kind === "external") {
      a.setAttribute("href", target.href);
      a.setAttribute("target", "_blank");
      a.setAttribute("rel", "noopener noreferrer");
    } else {
      // The href's fragment names the prefixed heading id, so a `#fragment`
      // link scrolls on its own; `data-markdown` keeps the path as written.
      a.setAttribute("href", withFragmentTarget(target.path));
      a.setAttribute("data-markdown", target.path);
      a.setAttribute("class", "md-link");
    }
    if (inline.title) a.setAttribute("title", inline.title);
    this.inlines(inline.children, a);
    into.appendChild(a);
  }

  private image(inline: Extract<Inline, { type: "image" }>, into: ParentNode & Node): void {
    const src = this.resolveImage(inline.src);
    if (src === null) {
      const span = document.createElement("span");
      span.setAttribute("class", "md-image-text");
      span.textContent = inline.alt === "" ? inline.src : `${inline.alt} (${inline.src})`;
      into.appendChild(span);
      return;
    }
    const img = document.createElement("img");
    img.setAttribute("src", src);
    img.setAttribute("alt", inline.alt);
    if (inline.title) img.setAttribute("title", inline.title);
    into.appendChild(img);
  }
}

/**
 * The DOM for `blocks`, built with `createElement` and `textContent` only.
 * A heading carries its slug as `id` under `HEADING_ID_PREFIX`; a link and
 * an image go where `options` say, or where the default rules say.
 */
export function renderMarkdown(blocks: Block[], options: RenderOptions = {}): DocumentFragment {
  const fragment = document.createDocumentFragment();
  new Renderer(options).blocks(blocks, fragment);
  return fragment;
}
