/**
 * The file-type tag of the `/edit` tree (`code-editor` round 13, rule 4 of
 * `corpus/07-projects-and-tree.md`, rule 17 and the table of `Editor
 * components 2` of `design/editor.pen`): one tag per language, in its
 * `--code-*` token. A folder and an unknown extension carry no tag — both
 * `tagFor` returns `null` for.
 *
 * The colour is a kind, not a state (rule 26): the tag is painted with a
 * plain `color`, as the diff lines are, the first exception of
 * `design/foundation.md`. The CSS class per token is in `edit.css`;
 * `theme-contrast-derive.ts` registers it against the tree's two surfaces.
 */

export interface FileTag {
  /** 2 or 3 characters, right-aligned in its cell. */
  readonly text: string;
  /** The CSS class that paints `--code-*`: `edit-tag-<token>`. */
  readonly className: string;
}

interface Language {
  readonly extensions: readonly string[];
  readonly tag: string;
  readonly token: string;
}

/** The 14 languages of `Editor components 2`'s table, extension to tag and
 * `--code-*` token. */
const LANGUAGES: readonly Language[] = [
  { extensions: ["ts"], tag: "ts", token: "name" },
  { extensions: ["tsx"], tag: "tsx", token: "name" },
  { extensions: ["js", "mjs", "cjs"], tag: "js", token: "attr" },
  { extensions: ["json", "jsonc"], tag: "{}", token: "attr" },
  { extensions: ["md", "markdown"], tag: "md", token: "link" },
  { extensions: ["swift"], tag: "sw", token: "error" },
  { extensions: ["sh", "bash", "zsh"], tag: "sh", token: "string" },
  { extensions: ["css"], tag: "css", token: "keyword" },
  { extensions: ["html", "htm"], tag: "htm", token: "error" },
  { extensions: ["py"], tag: "py", token: "number" },
  { extensions: ["go"], tag: "go", token: "number" },
  { extensions: ["rs"], tag: "rs", token: "attr" },
  { extensions: ["yaml", "yml"], tag: "yml", token: "keyword" },
  { extensions: ["toml"], tag: "tml", token: "number" },
];

const BY_EXTENSION = new Map<string, Language>();
for (const language of LANGUAGES) for (const extension of language.extensions) BY_EXTENSION.set(extension, language);

/** The tag for a file's `name`, `null` for a name with no extension or one
 * this table does not know (rule 17). */
export function tagFor(name: string): FileTag | null {
  const dot = name.lastIndexOf(".");
  if (dot <= 0 || dot === name.length - 1) return null;
  const language = BY_EXTENSION.get(name.slice(dot + 1).toLowerCase());
  return language ? { text: language.tag, className: `edit-tag-${language.token}` } : null;
}
