/**
 * The `/edit` page: one file in CodeMirror 6, a project tree beside it, and
 * a save that never writes over an outside edit (`code-editor` round 4,
 * phase 2b of ADR 0005; the frames `Editor 1200`, `Editor 390` and
 * `Editor components` of `design/editor.pen`, `corpus/02-approved-design.md`).
 *
 * `?path=<file>&session=<id>` names the file; the daemon resolves a
 * relative path against the session's cwd, as the preview does. The page
 * asks `GET /api/files/project` for the project that would jail the save,
 * draws its tree from that root one level per expand on `GET /api/files`,
 * reads the file through `GET /api/files/content` with its `ETag`, and
 * saves through `PUT /api/files/content` with `If-Match`. Every 3 s while
 * visible it asks the read again with `If-None-Match`; a new tag under an
 * unedited buffer reloads it silently, under an edited one raises the bar
 * `? Changed on disk since you opened it.` with reload, compare and keep
 * mine; a 412 raises `! Not saved: …` with the same three.
 *
 * Only this input imports CodeMirror, so `main-*.js` keeps its size
 * (`corpus/03-all-phases.md` rule 1); a language loads lazily by the file's
 * name through `@codemirror/language-data`.
 *
 * The git tab (round 5, phase 3 of ADR 0005; the frames `Editor 1200 git`
 * and `Editor 390 git`): `[ ] files [x] git N` switches the sidebar to
 * `BRANCH` with `↑ahead ↓behind` and `CHANGES` with a badge, the name and
 * `+a −d` per file, read from `GET /api/git/status` every 3 s while
 * visible and after a save, with `If-None-Match`; the tree's rows wear the
 * same badges, a folder `M` when a changed path is under it; a change row
 * opens its unified diff from `GET /api/git/diff` in the diff view.
 *
 * The writes (round 6, phase 4; rules 7, 8, 13 and 14 of `Editor
 * components`): a `[ ]`/`[x]`/`[~]` toggle before each change's badge
 * stages or unstages the whole file, the `COMMIT` box takes a message and
 * `[ commit ]` and `[ push ↑N ]`, a button becomes `◐ committing` or
 * `◐ pushing` while its command runs, a well under the buttons keeps the
 * last 8 lines a commit or a push printed, a failed write's first line
 * stands under the buttons with `!`, and the `BRANCH` row is a select of
 * the local branches plus `new branch…`, which asks first while the
 * buffer holds unsaved edits. Every write is `POST /api/git/<kind>`,
 * followed by one status read. A daemon without `--agent-control` says
 * so in the status (`writes` false): the tab then shows no control and
 * the one sentence `NO_WRITES`.
 *
 * The pure decisions are `edit-model.ts`, `edit-tree.ts`, `edit-git.ts`
 * and `line-diff.ts`; the daemon conversations are `edit-fetch.ts`. This
 * file paints and wires.
 */

import "./tokens.css";
import "./styles.css";
import "./edit.css";

import {
  cursorCharLeft,
  cursorCharRight,
  cursorLineDown,
  cursorLineUp,
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
  insertTab,
  undo,
} from "@codemirror/commands";
import { bracketMatching, HighlightStyle, indentOnInput, syntaxHighlighting } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { highlightSelectionMatches, searchKeymap } from "@codemirror/search";
import { Compartment, EditorState } from "@codemirror/state";
import { drawSelection, EditorView, keymap, lineNumbers } from "@codemirror/view";
import { tags } from "@lezer/highlight";

import { type Fetch, gitWrite, readFile, readFilesIndex, readGitDiff, readGitStatus, readListing, readProject, readProjects, saveFile } from "./edit-fetch";
import {
  badgeForPath,
  badgeOf,
  branchLine,
  changesLabel,
  diffWhat,
  entryCounts,
  entryName,
  branchOptions,
  commitEnabled,
  type GitEntry,
  type GitStatus,
  gitTabLabel,
  inFlightWord,
  isIgnoredPath,
  NEW_BRANCH,
  NEW_BRANCH_QUESTION,
  NO_WRITES,
  pushLabel,
  stageState,
  stageToggle,
  SWITCH_QUESTION,
  toggleWrite,
  wellLines,
  type WriteKind,
  parseStatus,
  parseUnifiedDiff,
  wantsStaged,
} from "./edit-git";
import {
  barLine,
  contentUrl,
  cwdUrl,
  decodeText,
  type DecodedText,
  DISCARD_FILE_QUESTION,
  diskChangeAction,
  editUrl,
  type EditorModel,
  emptyFolder,
  EMPTY_HOME_COMMAND,
  EMPTY_HOME_SENTENCE,
  encodeText,
  filesIndexUrl,
  gitDiffUrl,
  gitStatusUrl,
  gitWriteUrl,
  hasUnsavedWork,
  headerFacts,
  headerName,
  HOME_NAME,
  HOME_TERMINAL_URL,
  INITIAL_MODEL,
  isMarkdownFile,
  languageOf,
  listingUrl,
  loadMarkdownPreview,
  markdownLinkUrl,
  type MarkdownPreview,
  NO_PROJECT,
  notSaved,
  OPEN_FROM_TREE,
  pageTarget,
  pageTitle,
  type ProjectCheckout,
  type ProjectEntry,
  type ProjectGroup,
  projectGroups,
  type ProjectLine,
  projectsUrl,
  projectUrl,
  READ_ONLY_MODEL,
  readmeIn,
  readOnlyReason,
  reduce,
  saveMarkdownPreview,
  stateRun,
  SWITCH_PROJECT_QUESTION,
  terminalUrl,
} from "./edit-model";
import {
  moreFilesLine,
  movePaletteSelection,
  PALETTE_EMPTY,
  PALETTE_KEYS,
  PALETTE_PLACEHOLDER,
  type PaletteFileRow,
  paletteGroups,
  type PaletteProjectRow,
  type PaletteRow,
  paletteRows,
} from "./palette-model";
import {
  ancestorsOf,
  chainTail,
  childrenOf,
  compactCandidate,
  findNode,
  foldersToOpen,
  MAX_COMPACT_CHAIN,
  navigateTree,
  type NavResult,
  treeRoot,
  type TreeKey,
  type TreeNode,
  type TreeRow,
  triangle,
  visibleRows,
} from "./edit-tree";
import { tagFor } from "./edit-tags";
import { resolveFontFamily } from "./fonts";
import { trackKeyboardInsets } from "./keyboard-insets";
import { diffCounts, hunkHeader, type LineDiff, lineDiff } from "./line-diff";
import { basename, cannotRead, imageResolver, renderedView, scrollToFragment } from "./markdown-view";
import { loadSettings } from "./settings-store";
import { applyThemeTokens } from "./theme-tokens";
import { findThemeById } from "./themes";

/** How often the page asks whether the disk moved, while visible. */
export const POLL_MS = 3000;

/** The question before a reload drops typed work. */
export const RELOAD_QUESTION = "Discard your edits and reload the file from disk?";

/** The source view's colours on CodeMirror's tags: the same `tok-*`
 * classes the preview paints, so the two views wear one palette. */
const highlightStyle = HighlightStyle.define([
  { tag: tags.comment, class: "tok-comment" },
  { tag: [tags.string, tags.special(tags.string), tags.regexp, tags.character], class: "tok-string" },
  { tag: [tags.number, tags.bool, tags.null, tags.atom, tags.literal], class: "tok-number" },
  { tag: [tags.keyword, tags.self], class: "tok-keyword" },
  {
    tag: [tags.function(tags.variableName), tags.function(tags.propertyName), tags.typeName, tags.className, tags.namespace, tags.tagName, tags.heading],
    class: "tok-name",
  },
  { tag: [tags.attributeName, tags.propertyName, tags.labelName, tags.macroName, tags.meta, tags.annotation, tags.processingInstruction], class: "tok-attr" },
  { tag: [tags.link, tags.url], class: "tok-link" },
  { tag: tags.invalid, class: "tok-error" },
  { tag: [tags.punctuation, tags.operator, tags.bracket, tags.separator, tags.derefOperator], class: "tok-punct" },
]);

type Tone = "warning" | "accent" | "success" | "faint" | "danger";

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, className: string, text?: string): HTMLElementTagNameMap[K] => {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

const button = (className: string, text: string, focus: string): HTMLButtonElement => {
  const node = el("button", className, text);
  node.type = "button";
  node.dataset.focus = focus;
  return node;
};

/** A one-character mark or a run of text in an owned colour: the colour
 * is a clipped background, never `color` (`design/foundation.md`). */
const mark = (text: string, tone: Tone, wide = false): HTMLSpanElement => {
  const node = el("span", `edit-mark ${tone}${wide ? " wide" : ""}`, text);
  node.setAttribute("aria-hidden", wide ? "false" : "true");
  return node;
};

/**
 * The project groups of the home page and the switcher (rounds 10 and 11,
 * rules 1 and 2): one line per project, the same shape in both, with a
 * `[x]`/`[ ]` radio only while `currentRoot` is given (the switcher). The
 * empty home (rule 1) shows only with no radio: the switcher's own empty
 * list is a project read in flight, never the home's empty state.
 */
const renderProjectGroups = (container: HTMLElement, groups: readonly ProjectGroup[], currentRoot: string | null, onChoose: (line: ProjectLine) => void): void => {
  container.replaceChildren();
  const radio = currentRoot !== null;
  if (groups.length === 0) {
    if (radio) return;
    const empty = el("p", "edit-home-empty");
    empty.append(EMPTY_HOME_SENTENCE, "  ", el("span", "edit-home-command", EMPTY_HOME_COMMAND));
    container.append(empty);
    return;
  }
  for (const group of groups) {
    container.append(el("h2", "edit-git-label", `${group.label} ${group.count}`));
    for (const line of group.lines) {
      const row = button(`edit-project-line${radio ? " radio" : ""}`, "", `project:${line.id}`);
      if (radio) {
        const current = line.root === currentRoot;
        row.append(el("span", `edit-project-radio${current ? " current" : ""}`, current ? "[x]" : "[ ]"));
      }
      row.append(el("span", "edit-project-name", line.name), el("span", "edit-project-home", line.home), el("span", "edit-project-branch", line.branch));
      const changed = el("span", "edit-project-changed");
      if (line.changed !== null) changed.append(mark("M", "warning", true), " ", el("span", "edit-project-changed-count", String(line.changed)));
      row.append(changed);
      row.addEventListener("click", () => onChoose(line));
      container.append(row);
    }
  }
};

export interface PageOptions {
  fetch?: Fetch;
  /** Where a tree row's file opens; `location.assign` on the page. */
  navigate?: (url: string) => void;
  /** The question before a reload drops typed work; `window.confirm` on the page. */
  confirm?: (question: string) => boolean;
  /** The name `new branch…` asks for; `window.prompt` on the page. */
  prompt?: (question: string) => string | null;
  /** The poll's clock; `setInterval` on the page. */
  schedule?: (tick: () => void, ms: number) => void;
}

/**
 * Paint the page into `root` for the query `search`. Returns once the file
 * is in (or the reason it is not); the poll and the tree keep running.
 */
export async function bootEditPage(root: HTMLElement, search: string, options: PageOptions = {}): Promise<void> {
  const fetchFn: Fetch = options.fetch ?? ((input, init) => fetch(input, init));
  const navigate = options.navigate ?? ((url: string) => location.assign(url));
  const confirmFn = options.confirm ?? ((question: string) => window.confirm(question));
  const promptFn = options.prompt ?? ((question: string) => window.prompt(question));
  const schedule = options.schedule ?? ((tick: () => void, ms: number) => void setInterval(tick, ms));

  // --- the chrome ---------------------------------------------------------
  const header = el("header", "edit-header");
  const name = el("div", "edit-name");
  // The project name is the switcher's own control (rule 2): `kitterm ▼`,
  // hidden with no project, so a file under none keeps its header as today.
  const projectName = button("edit-project", "", "switcher");
  projectName.hidden = true;
  projectName.setAttribute("aria-haspopup", "listbox");
  projectName.setAttribute("aria-expanded", "false");
  const projectNameText = el("span", "edit-project-text");
  const projectNameTriangle = el("span", "edit-project-triangle", "▼");
  projectName.append(projectNameText, " ", projectNameTriangle);
  const separator = el("span", "edit-separator", " / ");
  const pathName = el("span", "edit-path");
  const pathDir = el("span", "edit-path-dir");
  const pathBase = el("span", "edit-path-name");
  pathName.append(pathDir, pathBase);
  name.append(projectName, separator, pathName);
  // The switcher's own panel (rounds 10 and 11, rule 2): the two project
  // groups under the header, closed until `projectName` opens it.
  const switcherPanel = el("div", "edit-switcher");
  switcherPanel.setAttribute("role", "listbox");
  switcherPanel.setAttribute("aria-label", "Projects");
  switcherPanel.hidden = true;
  /** The path in two runs, so a phone keeps the name alone. */
  const namePath = (text: string): void => {
    const cut = text.lastIndexOf("/") + 1;
    pathDir.textContent = text.slice(0, cut);
    pathBase.textContent = text.slice(cut);
  };
  const state = el("span", "edit-state");
  state.setAttribute("role", "status");
  const facts = el("span", "edit-facts");
  const actions = el("div", "edit-actions");
  // The Markdown preview toggle (round 8, `corpus/05-markdown-preview.md`
  // rule 1): `[x] source [ ] preview`, shown only for a Markdown file.
  const MARKDOWN_PREVIEW_CHOICES: readonly MarkdownPreview[] = ["source", "preview"];
  const previewToggle = el("div", "edit-view-toggle");
  previewToggle.setAttribute("role", "radiogroup");
  previewToggle.setAttribute("aria-label", "View");
  previewToggle.hidden = true;
  const previewButtons = MARKDOWN_PREVIEW_CHOICES.map((choice) => {
    const choiceButton = button("edit-tab", "", `view:${choice}`);
    choiceButton.setAttribute("role", "radio");
    return choiceButton;
  });
  previewToggle.append(...previewButtons);
  const saveButton = button("edit-save", "[ save ⌘S ]", "save");
  saveButton.setAttribute("aria-keyshortcuts", "Meta+S Control+S");
  const terminalLink = el("a", "edit-terminal", "open in terminal");
  actions.append(previewToggle, saveButton, terminalLink);
  header.append(name, state, facts, actions, switcherPanel);

  const tabs = el("nav", "edit-tabs");
  tabs.setAttribute("role", "radiogroup");
  tabs.setAttribute("aria-label", "Sidebar");
  const filesTab = button("edit-tab", "[x] files", "tab:files");
  filesTab.setAttribute("role", "radio");
  filesTab.setAttribute("aria-checked", "true");
  const editTab = button("edit-tab edit-tab-edit", "[ ] edit", "tab:edit");
  editTab.setAttribute("role", "radio");
  editTab.setAttribute("aria-checked", "false");
  const gitTab = button("edit-tab edit-tab-git", gitTabLabel(false, null), "tab:git");
  gitTab.setAttribute("role", "radio");
  gitTab.setAttribute("aria-checked", "false");
  tabs.append(filesTab, editTab, gitTab);

  const body = el("div", "edit-body");
  const sidebar = el("aside", "edit-sidebar");
  sidebar.setAttribute("aria-label", "Files");
  const tree = el("div", "edit-tree");
  tree.setAttribute("role", "tree");
  const gitPanel = el("div", "edit-git");
  gitPanel.setAttribute("role", "region");
  gitPanel.setAttribute("aria-label", "Git");
  gitPanel.hidden = true;
  sidebar.append(tree, gitPanel);
  const main = el("section", "edit-main");
  const bar = el("div", "edit-bar");
  bar.setAttribute("role", "alert");
  bar.hidden = true;
  const editorHost = el("div", "edit-editor");
  const previewHost = el("div", "edit-preview");
  previewHost.hidden = true;
  const diffHost = el("div", "edit-diff");
  diffHost.hidden = true;
  main.append(bar, editorHost, previewHost, diffHost);
  body.append(tabs, sidebar, main);

  const keys = el("div", "edit-keys");
  keys.setAttribute("role", "toolbar");
  keys.setAttribute("aria-label", "Editor keys");
  const keySave = button("edit-key edit-key-save", "[ save ]", "key:save");
  const keyTab = button("edit-key", "tab", "key:tab");
  const keyUp = button("edit-key", "↑", "key:up");
  const keyDown = button("edit-key", "↓", "key:down");
  const keyLeft = button("edit-key", "←", "key:left");
  const keyRight = button("edit-key", "→", "key:right");
  const keyUndo = button("edit-key edit-key-undo", "undo", "key:undo");
  keys.append(keySave, keyTab, keyUp, keyDown, keyLeft, keyRight, keyUndo);

  root.replaceChildren(header, body, keys);

  // --- the project list (rounds 10 and 11, rules 1 and 2) ------------------
  // Read once, never on a poll: `GET /api/projects`, then each root's
  // `GET /api/git/status`, at most `PROJECT_STATUS_CONCURRENCY` at a time,
  // cached for the page's life so the home page and a later switcher open
  // never ask twice.
  const PROJECT_STATUS_CONCURRENCY = 4;
  let projectsList: ProjectEntry[] | null = null;
  let projectsError: string | null = null;
  const projectStatuses = new Map<string, ProjectCheckout>();

  const loadProjectGroups = async (onUpdate: (groups: ProjectGroup[]) => void): Promise<void> => {
    if (projectsList === null && projectsError === null) {
      const result = await readProjects(fetchFn, projectsUrl());
      if (result.kind === "ok") projectsList = result.projects;
      else {
        projectsList = [];
        projectsError = cannotRead("projects", result.reason);
      }
    }
    const projects = projectsList ?? [];
    onUpdate(projectGroups(projects, projectStatuses));
    const pending = projects.filter((p) => !projectStatuses.has(p.root));
    let index = 0;
    const worker = async (): Promise<void> => {
      while (index < pending.length) {
        const project = pending[index++];
        const result = await readGitStatus(fetchFn, gitStatusUrl(project.root));
        let status: ProjectCheckout = null;
        if (result.kind === "ok") {
          const parsed = parseStatus(result.body);
          status = { branch: parsed.branch, changed: parsed.counts.changed };
        }
        projectStatuses.set(project.root, status);
        onUpdate(projectGroups(projects, projectStatuses));
      }
    };
    await Promise.all(Array.from({ length: Math.min(PROJECT_STATUS_CONCURRENCY, pending.length) }, worker));
  };

  const target = pageTarget(search);
  if (target === null) {
    document.title = `${HOME_NAME} — kitterm`;
    namePath(HOME_NAME);
    pathName.title = "";
    separator.hidden = true;
    state.hidden = true;
    facts.hidden = true;
    previewToggle.hidden = true;
    saveButton.hidden = true;
    terminalLink.href = HOME_TERMINAL_URL;
    tabs.hidden = true;
    sidebar.hidden = true;
    main.hidden = true;
    keys.hidden = true;
    body.classList.add("edit-body-home");
    const home = el("div", "edit-home");
    home.setAttribute("role", "list");
    body.append(home);
    const paintHome = (groups: ProjectGroup[]): void => {
      if (projectsError !== null) {
        home.replaceChildren(el("p", "edit-note", projectsError));
        return;
      }
      renderProjectGroups(home, groups, null, (line) => navigate(editUrl(line.root)));
    };
    await loadProjectGroups(paintHome);
    return;
  }
  const { session } = target;

  // --- the tabs ---------------------------------------------------------------
  // Two choices: which panel the sidebar shows (`files` or `git`, rule 1),
  // and on a phone which column is on screen (the sidebar or the editor).
  // A wide window shows both columns, so its tabs read the panel alone and
  // `[x] files` holds while the tree shows whatever the editor area does
  // (the round 4 gap).
  const wide = window.matchMedia("(min-width: 768px)");
  let panel: "files" | "git" = "files";
  let column: "sidebar" | "edit" = wide.matches ? "sidebar" : "edit";
  let gitStatus: GitStatus | null = null;
  const paintTabs = (): void => {
    const sidebarShown = wide.matches || column === "sidebar";
    const filesOn = panel === "files" && sidebarShown;
    const gitOn = panel === "git" && sidebarShown;
    const editOn = column === "edit";
    filesTab.setAttribute("aria-checked", filesOn ? "true" : "false");
    filesTab.textContent = `[${filesOn ? "x" : " "}] files`;
    editTab.setAttribute("aria-checked", editOn ? "true" : "false");
    editTab.textContent = `[${editOn ? "x" : " "}] edit`;
    gitTab.setAttribute("aria-checked", gitOn ? "true" : "false");
    gitTab.textContent = gitTabLabel(gitOn, gitStatus?.counts ?? null);
    root.dataset.tab = column === "edit" ? "edit" : panel;
    root.dataset.panel = panel;
    tree.hidden = panel !== "files";
    gitPanel.hidden = panel !== "git";
    sidebar.setAttribute("aria-label", panel === "git" ? "Git" : "Files");
  };
  const selectTab = (tab: "files" | "edit" | "git"): void => {
    if (tab === "edit") column = "edit";
    else {
      panel = tab;
      column = "sidebar";
    }
    paintTabs();
  };
  filesTab.addEventListener("click", () => selectTab("files"));
  editTab.addEventListener("click", () => selectTab("edit"));
  gitTab.addEventListener("click", () => selectTab("git"));
  wide.addEventListener("change", paintTabs);
  // A phone opens on the editor (the frame `Editor 390`).
  paintTabs();

  // --- the file -----------------------------------------------------------
  let model: EditorModel = INITIAL_MODEL;
  let etag: string | null = null;
  let decoded: DecodedText = { text: "", utf8: true, bom: false, lineEnding: "LF" };
  /** What the disk holds, as last read: the base of `compare` and of `keep mine`. */
  let disk: { text: string; etag: string | null; decoded: DecodedText } = { text: "", etag: null, decoded };
  /** The text the held tag names: what the buffer was read from or saved as. */
  let base: { text: string } = { text: "" };
  let readOnly: string | null = null;
  let refusal: string | null = null;
  let path = target.path;
  let view: EditorView | null = null;
  const languageSlot = new Compartment();
  const readOnlySlot = new Compartment();

  const paintState = (): void => {
    const run = stateRun(model.state);
    state.replaceChildren();
    if (run) {
      state.append(mark(run.mark, run.tone), " ", el("span", `edit-state-word ${run.tone}`, run.word));
      state.className = `edit-state ${run.tone}`;
    } else {
      state.className = "edit-state";
    }
    const saves = model.state !== "read-only";
    saveButton.disabled = !saves || model.state === "saving";
    keySave.disabled = saveButton.disabled;
    // Faint while the buffer equals the disk (rule 3); the accent while a
    // save would write something.
    const quiet = model.state !== "edited";
    saveButton.classList.toggle("edit-quiet", quiet);
    keySave.classList.toggle("edit-quiet", quiet);
    document.title = pageTitle(path);
  };

  const paintBar = (): void => {
    bar.replaceChildren();
    const line = barLine(model.bar);
    if (readOnly !== null) {
      bar.hidden = false;
      bar.className = "edit-bar faint";
      bar.append(mark("–", "faint"), " ", el("span", "edit-bar-text", readOnly));
      return;
    }
    if (refusal !== null) {
      bar.hidden = false;
      bar.className = "edit-bar danger";
      bar.append(mark("!", "danger"), " ", el("span", "edit-bar-text", refusal));
      return;
    }
    if (line === null) {
      bar.hidden = true;
      bar.className = "edit-bar";
      return;
    }
    bar.hidden = false;
    bar.className = `edit-bar ${line.tone}`;
    const controls = el("span", "edit-bar-controls");
    const reload = button("edit-bar-button", "[ reload ]", "bar:reload");
    reload.addEventListener("click", () => void reloadFromDisk());
    const compare = button("edit-bar-button", "[ compare ]", "bar:compare");
    compare.addEventListener("click", () => showDiff());
    const keepMine = button("edit-bar-button", "[ keep mine ]", "bar:keep-mine");
    keepMine.addEventListener("click", () => void save(disk.etag, "keep-mine"));
    controls.append(reload, " ", compare, " ", keepMine);
    bar.append(mark(line.mark, line.tone), " ", el("span", "edit-bar-text", line.text), controls);
  };

  const paint = (): void => {
    paintState();
    paintBar();
  };

  const bufferText = (): string => view?.state.doc.toString() ?? decoded.text;

  /** The editor's text replaced by `text`, the history kept. */
  const replaceDoc = (text: string): void => {
    if (!view) return;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
  };

  const hideDiff = (): void => {
    diffHost.hidden = true;
    diffHost.replaceChildren();
    showEditorArea();
  };

  /**
   * A unified diff in the editor area (rule 9): the top line with the
   * name, the counts and what is compared, `open file` at its right, then
   * the hunks; `empty` is the sentence shown with no hunk.
   */
  const renderDiff = (name: string, counts: string, what: string, diff: LineDiff, empty: string, onBack: () => void): void => {
    diffHost.replaceChildren();
    const top = el("div", "edit-diff-top");
    top.append(el("span", "edit-diff-name", name), " ", el("span", "edit-diff-counts", counts), el("span", "edit-diff-what", ` · ${what}`));
    const back = button("edit-diff-back", "open file", "diff:back");
    back.addEventListener("click", onBack);
    top.append(back);
    const rows = el("div", "edit-diff-rows");
    if (diff.hunks.length === 0) rows.append(el("p", "edit-note", empty));
    for (const hunk of diff.hunks) {
      const header = el("div", "edit-diff-line hunk");
      header.append(el("span", "edit-diff-gutter", ""), el("span", "edit-diff-text", hunkHeader(hunk)));
      rows.append(header);
      for (const line of hunk.lines) {
        const row = el("div", `edit-diff-line ${line.kind}`);
        const prefix = line.kind === "add" ? "+ " : line.kind === "del" ? "− " : line.kind === "note" ? "" : "  ";
        row.append(
          el("span", "edit-diff-gutter", line.newNumber === undefined ? "" : String(line.newNumber)),
          el("span", "edit-diff-text", `${prefix}${line.text}`),
        );
        rows.append(row);
      }
    }
    diffHost.append(top, rows);
    diffHost.hidden = false;
    editorHost.hidden = true;
    previewHost.hidden = true;
    selectTab("edit");
  };

  /** The unified diff of the disk against the buffer, in the editor area. */
  const showDiff = (): void => {
    const diff = lineDiff(disk.text, bufferText());
    renderDiff(basename(path), diffCounts(diff), "buffer against disk", diff, "The buffer equals the disk.", hideDiff);
  };

  // --- the Markdown preview (round 8, `corpus/05-markdown-preview.md`) ---
  // The toggle replaces the editor area with the buffer rendered through
  // `markdown.ts` (rule 2); a relative `.md` link opens that file in
  // `/edit`, asking first when the buffer is edited, as the tree does
  // (rule 3), and a `#fragment` carries through the page's own hash.
  let markdownView: MarkdownPreview = loadMarkdownPreview();
  /** Whether the open file shows the toggle at all (rule 1): set once the
   * read names the file's kind, below. */
  let showsPreview = false;

  const paintPreviewToggle = (): void => {
    previewToggle.hidden = !showsPreview;
    previewButtons.forEach((choiceButton, i) => {
      const choice = MARKDOWN_PREVIEW_CHOICES[i];
      const on = choice === markdownView;
      choiceButton.setAttribute("aria-checked", on ? "true" : "false");
      choiceButton.textContent = `[${on ? "x" : " "}] ${choice}`;
    });
  };

  /** Which of the editor and the preview the editor area shows, under
   * whatever the diff view leaves behind. */
  const showEditorArea = (): void => {
    const previewing = showsPreview && markdownView === "preview";
    editorHost.hidden = previewing;
    previewHost.hidden = !previewing;
  };

  /** The buffer rendered in `.md-body`, replacing the editor area; drawn
   * again only when the view switches to it (rule 2: no live split). */
  const paintMarkdownPreview = (): void => {
    previewHost.replaceChildren(
      renderedView(bufferText(), {
        resolveImage: imageResolver(path, (p) => contentUrl(p, session)),
        onOpen: (link, fragment) => void openMarkdownLink(link, fragment),
      }),
    );
  };

  /** A relative `.md` link in the preview (rule 3). */
  const openMarkdownLink = (link: string, fragment: string): void => {
    if (hasUnsavedWork(model) && !confirmFn(DISCARD_FILE_QUESTION)) return;
    navigate(markdownLinkUrl(path, link, fragment, session));
  };

  const selectMarkdownView = (choice: MarkdownPreview): void => {
    if (choice === markdownView) return;
    markdownView = choice;
    saveMarkdownPreview(choice);
    paintPreviewToggle();
    if (markdownView === "preview") paintMarkdownPreview();
    // Leaving a shown diff behind restores the editor or the preview.
    hideDiff();
    if (markdownView === "source") view?.focus();
  };

  previewButtons.forEach((choiceButton, i) => {
    choiceButton.addEventListener("click", () => selectMarkdownView(MARKDOWN_PREVIEW_CHOICES[i]));
  });

  /** The disk's bytes taken as the buffer, when the reader agrees. */
  const reloadFromDisk = async (): Promise<void> => {
    if (hasUnsavedWork(model) && !confirmFn(RELOAD_QUESTION)) return;
    if (disk.etag === null || disk.text === bufferText()) {
      // Nothing newer is held: read again.
      const result = await readFile(fetchFn, contentUrl(path, session));
      if (result.kind === "file") {
        const text = decodeText(result.bytes);
        disk = { text: text.text, etag: result.etag, decoded: text };
      }
    }
    decoded = disk.decoded;
    etag = disk.etag;
    base = { text: disk.text };
    replaceDoc(disk.text);
    model = reduce(model, { type: "reload" });
    refusal = null;
    hideDiff();
    if (markdownView === "preview") paintMarkdownPreview();
    paint();
    facts.textContent = headerFacts(languageName, decoded);
    if (markdownView === "source") view?.focus();
  };

  /** The save: with the buffer's own tag, or the disk's for `keep mine`. */
  const save = async (ifMatch: string | null = etag, event: "save-start" | "keep-mine" = "save-start"): Promise<void> => {
    if (model.state === "read-only" || model.state === "saving" || ifMatch === null || !view) return;
    const text = bufferText();
    refusal = null;
    model = reduce(model, { type: event });
    paint();
    const result = await saveFile(fetchFn, contentUrl(path, session), encodeText(text, decoded), ifMatch);
    if (result.kind === "saved") {
      etag = result.etag;
      disk = { text, etag: result.etag, decoded };
      base = { text };
      model = reduce(model, { type: "save-ok" });
      hideDiff();
      // The save moved the tree: the badges and the counts follow at once.
      void pollGit();
    } else if (result.kind === "conflict") {
      // The disk's own text, for compare and for keep mine.
      const current = await readFile(fetchFn, contentUrl(path, session));
      if (current.kind === "file") {
        const text = decodeText(current.bytes);
        disk = { text: text.text, etag: current.etag, decoded: text };
      } else {
        disk = { ...disk, etag: result.etag };
      }
      model = reduce(model, { type: "save-conflict" });
    } else {
      refusal = notSaved(result.reason);
      model = reduce(model, { type: "save-failed" });
    }
    paint();
    // A bar's button took the focus; the keyboard belongs to the editor.
    if (event === "keep-mine") view.focus();
  };

  saveButton.addEventListener("click", () => void save());
  keySave.addEventListener("click", () => void save());
  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "s") {
      event.preventDefault();
      void save();
    }
  });

  // --- the poll -----------------------------------------------------------
  let polling = false;
  const poll = async (): Promise<void> => {
    if (polling || etag === null || readOnly !== null || document.visibilityState !== "visible") return;
    polling = true;
    try {
      const result = await readFile(fetchFn, contentUrl(path, session), etag);
      if (result.kind !== "file" || result.etag === etag) return;
      const text = decodeText(result.bytes);
      disk = { text: text.text, etag: result.etag, decoded: text };
      if (diskChangeAction(model.state) === "reload") {
        decoded = text;
        etag = result.etag;
        base = { text: text.text };
        replaceDoc(text.text);
        model = reduce(model, { type: "reload" });
        facts.textContent = headerFacts(languageName, decoded);
        if (markdownView === "preview") paintMarkdownPreview();
      } else {
        model = reduce(model, { type: "disk-changed" });
      }
      paint();
    } finally {
      polling = false;
    }
  };
  schedule(() => void poll(), POLL_MS);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void poll();
  });
  window.addEventListener("beforeunload", (event) => {
    if (hasUnsavedWork(model)) event.preventDefault();
  });

  // --- the git tab (round 5; the writes in round 6) --------------------------
  let gitEtag: string | null = null;
  let gitError: string | null = null;
  let gitPolling = false;
  /** The change row whose diff the editor area shows. */
  let openChange: string | null = null;
  /** The write in flight, one at a time (rule 14). */
  let inFlight: WriteKind | null = null;
  /** What the last commit or push printed, for the well, and the line of
   * the last write that failed (rule 13; it stays until the next write). */
  let well: string[] = [];
  let failure: string | null = null;

  // The COMMIT box is built once and kept across repaints, so the typed
  // message and the focus survive a poll that moves the status.
  const commitBox = el("section", "edit-commit");
  commitBox.setAttribute("aria-label", "Commit");
  const commitLabel = el("h2", "edit-git-label", "COMMIT");
  const message = el("textarea", "edit-commit-message");
  message.dataset.focus = "commit:message";
  message.rows = 2;
  message.setAttribute("aria-label", "Commit message");
  const commitButtons = el("div", "edit-commit-buttons");
  const commitButton = button("edit-bar-button edit-git-button", "[ commit ]", "commit");
  const pushButton = button("edit-bar-button edit-git-button", "[ push ]", "push");
  /** The turning mark and the word that take a button's place while its
   * command runs. */
  const running = (kind: "commit" | "push"): HTMLSpanElement => {
    const word = inFlightWord(kind);
    const run = el("span", "edit-state accent edit-git-running");
    run.setAttribute("role", "status");
    run.append(mark(word.mark, "accent"), " ", el("span", "edit-state-word accent", word.word));
    run.hidden = true;
    return run;
  };
  const commitRun = running("commit");
  const pushRun = running("push");
  commitButtons.append(commitButton, commitRun, pushButton, pushRun);
  const failureLine = el("p", "edit-git-failure");
  failureLine.setAttribute("role", "alert");
  failureLine.hidden = true;
  const wellBox = el("pre", "edit-git-well");
  wellBox.setAttribute("aria-label", "Command output");
  wellBox.hidden = true;
  commitBox.append(commitLabel, message, commitButtons, failureLine, wellBox);

  // The branch switcher, kept too: a select whose options follow the
  // status; `new branch…` asks for a name.
  const branchSelect = el("select", "edit-branch-select");
  branchSelect.dataset.focus = "branch";
  branchSelect.setAttribute("aria-label", "Branch");
  let branchKey = "";

  const paintCommit = (): void => {
    const can = commitEnabled(message.value, gitStatus?.counts ?? null);
    commitButton.classList.toggle("edit-quiet", !can);
    commitButton.disabled = !can || inFlight !== null;
    commitButton.hidden = inFlight === "commit";
    commitRun.hidden = inFlight !== "commit";
    pushButton.textContent = pushLabel(gitStatus);
    pushButton.disabled = inFlight !== null || !gitStatus || gitStatus.detached;
    pushButton.classList.toggle("edit-quiet", !gitStatus || gitStatus.detached);
    pushButton.hidden = inFlight === "push";
    pushRun.hidden = inFlight !== "push";
    message.disabled = inFlight === "commit";
    failureLine.replaceChildren();
    if (failure !== null) failureLine.append(mark("!", "danger"), " ", el("span", "edit-git-failure-text", failure));
    failureLine.hidden = failure === null;
    wellBox.textContent = wellLines(well).join("\n");
    wellBox.hidden = well.length === 0;
  };
  message.addEventListener("input", paintCommit);

  /**
   * One write, then the status read again so the toggles, the counts and
   * `↑N` follow at once. The well takes what a commit or a push printed;
   * a refusal becomes the failure line. True when the daemon answered ok.
   */
  const runWrite = async (kind: WriteKind, body: Record<string, unknown>): Promise<boolean> => {
    if (inFlight !== null) return false;
    inFlight = kind;
    failure = null;
    if (kind === "commit" || kind === "push") well = [];
    paintGit();
    const result = await gitWrite(fetchFn, gitWriteUrl(kind), { path, ...(session ? { session } : {}), ...body });
    inFlight = null;
    if (result.lines.length > 0) well = result.lines;
    if (result.kind === "error") failure = result.reason;
    else if (kind === "commit") message.value = "";
    paintGit();
    if (!(await pollGit())) setTimeout(() => void pollGit(), 100);
    return result.kind === "ok";
  };
  commitButton.addEventListener("click", () => void runWrite("commit", { message: message.value }));
  pushButton.addEventListener("click", () => void runWrite("push", {}));
  branchSelect.addEventListener("change", () => {
    const value = branchSelect.value;
    const current = gitStatus?.branch ?? null;
    const reset = (): void => {
      if (current !== null) branchSelect.value = current;
    };
    if (value === current) return;
    if (hasUnsavedWork(model) && !confirmFn(SWITCH_QUESTION)) return reset();
    if (value === NEW_BRANCH) {
      const name = promptFn(NEW_BRANCH_QUESTION)?.trim() ?? "";
      if (name === "") return reset();
      void runWrite("branch", { create: name }).then((ok) => {
        if (!ok) reset();
      });
      return;
    }
    void runWrite("branch", { switch: value }).then((ok) => {
      if (!ok) reset();
    });
  });

  const paintGit = (): void => {
    // The control that had the focus keeps it across the repaint.
    const focused = document.activeElement instanceof HTMLElement ? document.activeElement.dataset.focus : undefined;
    gitPanel.replaceChildren();
    if (gitError !== null) {
      gitPanel.append(el("p", "edit-note", gitError));
      return;
    }
    if (!gitStatus) return;
    const writes = gitStatus.writes === true;
    const branch = branchLine(gitStatus);
    const branchLabel = el("h2", "edit-git-label", "BRANCH");
    const branchRow = el("div", "edit-git-branch");
    if (writes && !branch.detached) {
      const options = branchOptions(gitStatus);
      const key = options.map((option) => option.value).join("\0");
      if (key !== branchKey) {
        branchSelect.replaceChildren(
          ...options.map((option) => {
            const item = document.createElement("option");
            item.value = option.value;
            item.textContent = option.label;
            return item;
          }),
        );
        branchKey = key;
      }
      branchSelect.value = branch.name;
      branchSelect.disabled = inFlight !== null;
      branchSelect.title = gitStatus.upstream ? `${branch.name} · upstream ${gitStatus.upstream}` : branch.name;
      branchRow.append(branchSelect);
    } else {
      const branchName = el("span", "edit-git-name", branch.name);
      branchName.title = gitStatus.upstream ? `${branch.name} · upstream ${gitStatus.upstream}` : branch.name;
      branchRow.append(branchName);
    }
    if (branch.detached) branchRow.append(" ", el("span", "edit-git-detached", "detached"));
    branchRow.append(el("span", "edit-git-ab", branch.ab));
    const changesLabelRow = el("h2", "edit-git-label", changesLabel(gitStatus.counts));
    gitPanel.append(branchLabel, branchRow, changesLabelRow);
    const list = el("div", "edit-changes");
    list.setAttribute("role", "list");
    for (const entry of gitStatus.files) {
      const badge = badgeOf(entry);
      if (!badge) continue;
      const row = el("div", "edit-change");
      row.setAttribute("role", "listitem");
      if (entry.path === openChange) row.classList.add("open");
      if (writes) {
        // The toggle stages or unstages the whole file (rule 8).
        const state = stageState(entry);
        const toggle = button("edit-stage", stageToggle(state), `stage:${entry.path}`);
        toggle.setAttribute("role", "checkbox");
        toggle.setAttribute("aria-checked", state === "staged" ? "true" : state === "partial" ? "mixed" : "false");
        toggle.setAttribute("aria-label", `${toggleWrite(entry)} ${entryName(entry)}`);
        toggle.disabled = inFlight !== null;
        toggle.addEventListener("click", () => void runWrite(toggleWrite(entry), { paths: [entry.path] }));
        row.append(toggle);
      }
      const open = button("edit-change-open", "", `change:${entry.path}`);
      open.title = entry.origPath ? `${entry.origPath} → ${entry.path}` : entry.path;
      if (entry.path === openChange) open.setAttribute("aria-current", "true");
      // The letter is read: it is the row's one state word.
      open.append(
        mark(badge.letter, badge.tone, true),
        el("span", "edit-change-name", entryName(entry)),
        el("span", "edit-change-counts", entryCounts(entry)),
      );
      open.addEventListener("click", () => void showChange(entry));
      row.append(open);
      list.append(row);
    }
    if (gitStatus.files.length === 0) list.append(el("p", "edit-note", "The working tree is clean."));
    gitPanel.append(list);
    if (writes) {
      gitPanel.append(commitBox);
      paintCommit();
    } else {
      gitPanel.append(el("p", "edit-note edit-git-no-writes", NO_WRITES));
    }
    if (focused) gitPanel.querySelector<HTMLElement>(`[data-focus="${CSS.escape(focused)}"]`)?.focus();
  };

  /** The unified diff of one change in the editor area. */
  const showChange = async (entry: GitEntry): Promise<void> => {
    const staged = wantsStaged(entry);
    const result = await readGitDiff(fetchFn, gitDiffUrl(entryPathOf(entry), session, staged));
    openChange = entry.path;
    paintGit();
    const back = (): void => {
      openChange = null;
      hideDiff();
      paintGit();
    };
    if (result.kind !== "ok") {
      renderDiff(entryName(entry), "", diffWhat(entry, staged), { hunks: [], added: 0, removed: 0 }, cannotRead(entryName(entry), result.reason), back);
      return;
    }
    const answer = result.answer;
    const diff = parseUnifiedDiff(answer.diff);
    const counts = answer.additions === null || answer.deletions === null ? "–" : `+${answer.additions} −${answer.deletions}`;
    let empty = "No difference.";
    if (answer.binary) empty = "A binary file: no text diff.";
    renderDiff(entryName(entry), counts, diffWhat(entry, staged), diff, empty, back);
    if (answer.truncated) diffHost.append(el("p", "edit-note", "The diff is cut at 512 KB."));
    const focus = diffHost.querySelector<HTMLElement>('[data-focus="diff:back"]');
    focus?.focus();
  };

  const entryPathOf = (entry: GitEntry): string => (gitStatus && gitStatus.root !== "/" ? `${gitStatus.root}/${entry.path}` : `/${entry.path}`);

  /** One status read, skipped while one is in flight or the page is hidden;
   * true when it ran. */
  const pollGit = async (): Promise<boolean> => {
    if (gitPolling || document.visibilityState !== "visible") return false;
    gitPolling = true;
    try {
      const result = await readGitStatus(fetchFn, gitStatusUrl(path, session), gitEtag);
      if (result.kind === "unchanged") return true;
      if (result.kind === "error") {
        // A failed read keeps the last status; a refusal says why.
        if (result.status === 404 || result.status === 403 || result.status === 503) {
          gitStatus = null;
          gitEtag = null;
          gitError = cannotRead("git status", result.reason);
          paintTabs();
          paintGit();
          paintTree();
        }
        return true;
      }
      gitStatus = parseStatus(result.body);
      gitEtag = result.etag;
      gitError = null;
      paintTabs();
      paintGit();
      paintTree();
      return true;
    } finally {
      gitPolling = false;
    }
  };
  schedule(() => void pollGit(), POLL_MS);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void pollGit();
  });

  // --- the key bar (the phone) --------------------------------------------
  const keyCommand = (key: HTMLButtonElement, command: (view: EditorView) => boolean): void => {
    // Pointer down, not click: a click would move focus off the editor and
    // close the soft keyboard the bar sits above.
    key.addEventListener("pointerdown", (event) => event.preventDefault());
    key.addEventListener("click", () => {
      if (!view) return;
      view.focus();
      command(view);
    });
  };
  keyCommand(keyTab, insertTab);
  keyCommand(keyUp, cursorLineUp);
  keyCommand(keyDown, cursorLineDown);
  keyCommand(keyLeft, cursorCharLeft);
  keyCommand(keyRight, cursorCharRight);
  keyCommand(keyUndo, undo);
  keySave.addEventListener("pointerdown", (event) => event.preventDefault());
  trackKeyboardInsets(root);

  // --- the project and the tree -------------------------------------------
  namePath(basename(path));
  pathName.title = path;
  document.title = pageTitle(path);
  terminalLink.href = terminalUrl(path);
  let treeModel: TreeNode | null = null;
  // The roving-tabindex selection (rule 7, rule 21): the one row in the
  // tab order, by its `tail` path; the first row until a click or a key
  // moves it.
  let focusedTreePath: string | null = null;

  /** The key a row's identity is painted and found by: a chain's tail, a
   * plain node's own path. */
  const rowKey = (row: Pick<TreeRow, "tail">): string => row.tail.path;

  const paintTree = (): void => {
    // With no tree the panel holds a sentence (`NO_PROJECT`, a refused
    // project read), which a git repaint must not wipe.
    if (!treeModel) return;
    const rows = visibleRows(treeModel);
    tree.replaceChildren();
    const current = focusedTreePath !== null && rows.some((r) => rowKey(r) === focusedTreePath) ? focusedTreePath : (rows[0] ? rowKey(rows[0]) : null);
    for (const treeRow of rows) {
      const { node, tail, displayName, depth } = treeRow;
      const key = rowKey(treeRow);
      const row = button("edit-row", "", `tree:${key}`);
      row.style.setProperty("--depth", String(depth));
      row.setAttribute("role", "treeitem");
      row.tabIndex = key === current ? 0 : -1;
      if (tail.dir) row.setAttribute("aria-expanded", tail.open ? "true" : "false");
      if (key === path) {
        row.classList.add("open");
        row.setAttribute("aria-current", "true");
      }
      if (isIgnoredPath(gitStatus, node.path)) row.classList.add("ignored");
      row.title = key;
      for (let level = 0; level < depth; level += 1) row.append(el("span", "edit-guide", ""));
      if (tail.dir) {
        row.append(el("span", "edit-triangle", triangle(tail)));
      } else {
        const tag = tagFor(node.name);
        row.append(el("span", `edit-tag${tag ? ` ${tag.className}` : ""}`, tag?.text ?? ""));
      }
      row.append(el("span", "edit-row-name", displayName));
      const badge = badgeForPath(gitStatus, key, tail.dir);
      if (badge) {
        const letter = mark(badge.letter, badge.tone, true);
        letter.classList.add("edit-row-badge");
        row.append(letter);
      }
      row.addEventListener("click", () => void onRow(node));
      row.addEventListener("focus", () => {
        focusedTreePath = key;
      });
      tree.append(row);
      if (tail.dir && tail.open && tail.children && tail.children.length === 0) {
        const empty = el("p", "edit-note edit-row-empty", tail.error ?? emptyFolder(displayName));
        empty.style.setProperty("--depth", String(depth + 1));
        tree.append(empty);
      }
    }
  };

  /** One directory's listing, with no chain resolution of its own: `list`
   * below is what a row's click or an ancestor-opening loop calls; this is
   * what `resolveChain` calls on each link, so a chain never re-lists a
   * folder its own expansion already covers. */
  const listOne = async (node: TreeNode): Promise<void> => {
    const result = await readListing(fetchFn, listingUrl(node.path, session));
    if (result.kind === "ok") {
      node.children = childrenOf(node, result.entries);
      node.error = null;
    } else {
      node.children = [];
      node.error = cannotRead(node.name, result.reason);
    }
  };

  /** Whether `node` is itself the single link of a compact chain (rule 6):
   * while its listing holds exactly one directory and nothing else, the
   * chain continues into that directory's listing too, up to
   * `MAX_COMPACT_CHAIN` links. */
  const resolveChain = async (node: TreeNode, chainDepth: number): Promise<void> => {
    if (chainDepth >= MAX_COMPACT_CHAIN) return;
    if (node.children === null) await listOne(node);
    const next = compactCandidate(node);
    if (next) {
      node.compactWith = next;
      await resolveChain(next, chainDepth + 1);
    }
  };

  /** A folder's listing, then every directory child's own chain resolved
   * eagerly (rule 6), so a chain shows compacted the moment its parent is
   * listed — never a bare single-child folder revealed one click at a
   * time, which is what the approved frames show. */
  const list = async (node: TreeNode): Promise<void> => {
    await listOne(node);
    if (node.children) await Promise.all(node.children.filter((child) => child.dir).map((child) => resolveChain(child, 0)));
  };

  /** The tree's keyboard (rule 7, rule 21): `↑` `↓` `←` `→` `Home` `End`
   * move the roving selection and fold or open a row in place;
   * `navigateTree` decides where, this applies it. */
  const applyTreeNav = async (rows: readonly TreeRow[], result: NavResult): Promise<void> => {
    const target = rows[result.focusIndex];
    if (result.toggle) {
      target.tail.open = result.toggle === "open";
      if (target.tail.open && target.tail.children === null) await list(target.tail);
    }
    focusedTreePath = rowKey(target);
    paintTree();
    tree.querySelector<HTMLElement>(`[data-focus="tree:${CSS.escape(focusedTreePath)}"]`)?.focus();
  };

  const TREE_KEYS: Record<string, TreeKey> = {
    ArrowUp: "up",
    ArrowDown: "down",
    ArrowLeft: "left",
    ArrowRight: "right",
    Home: "home",
    End: "end",
  };
  tree.addEventListener("keydown", (event) => {
    if (!treeModel) return;
    const focusedPath = document.activeElement instanceof HTMLElement ? document.activeElement.dataset.focus : undefined;
    if (!focusedPath?.startsWith("tree:")) return;
    const rows = visibleRows(treeModel);
    const index = rows.findIndex((r) => `tree:${rowKey(r)}` === focusedPath);
    if (index < 0) return;
    if (event.key === "Enter") {
      event.preventDefault();
      void onRow(rows[index].node);
      return;
    }
    const key = TREE_KEYS[event.key];
    if (!key) return;
    event.preventDefault();
    void applyTreeNav(rows, navigateTree(rows, index, key));
  });

  const onRow = async (node: TreeNode): Promise<void> => {
    const tail = chainTail(node);
    if (!tail.dir) {
      if (tail.path === path) return selectTab("edit");
      if (hasUnsavedWork(model) && !confirmFn(DISCARD_FILE_QUESTION)) return;
      navigate(editUrl(tail.path, session));
      return;
    }
    tail.open = !tail.open;
    if (tail.open && tail.children === null) await list(tail);
    focusedTreePath = tail.path;
    paintTree();
    const focus = tree.querySelector<HTMLElement>(`[data-focus="tree:${CSS.escape(tail.path)}"]`);
    focus?.focus();
  };

  const projectAnswer = await readProject(fetchFn, projectUrl(path, session));
  /** The folder the page opened on (the folder form, round 7), else null. */
  let folder: string | null = null;
  const project = projectAnswer.kind === "ok" ? projectAnswer.answer.project : null;
  if (projectAnswer.kind === "ok") {
    path = projectAnswer.answer.path || path;
    if (projectAnswer.answer.kind === "directory") folder = path;
    const named = headerName(project, path);
    projectNameText.textContent = named.project ?? "";
    projectName.hidden = named.project === null;
    separator.hidden = named.project === null || named.path === "";
    namePath(named.path);
    pathName.title = path;
    terminalLink.href = folder === null ? terminalUrl(path) : cwdUrl(folder);
    if (project) {
      const { root: projectRoot, name: projectLabel } = project;
      treeModel = treeRoot(projectRoot, projectLabel);
      // The open file's folders listed and open, so its row shows; on a
      // folder page the folder itself too, so its entries show.
      const toOpen = folder === null ? ancestorsOf(projectRoot, path) : foldersToOpen(projectRoot, folder);
      for (const directory of toOpen) {
        const node = findNode(treeModel, directory);
        if (!node) break;
        node.open = true;
        if (node.children === null) await list(node);
      }
      paintTree();
    } else {
      tree.replaceChildren(el("p", "edit-note", NO_PROJECT));
    }
  } else {
    tree.replaceChildren(el("p", "edit-note", cannotRead(path, projectAnswer.reason)));
  }
  void pollGit();

  // --- the switcher (rounds 10 and 11, rule 2) ------------------------------
  // The project name's own control, loaded once on the first open; a choice
  // asks the tree's own question before it drops a buffer's unsaved edits.
  let switcherGroups: ProjectGroup[] | null = null;
  let switcherOpen = false;

  const paintSwitcher = (): void => {
    switcherPanel.hidden = !switcherOpen;
    projectName.setAttribute("aria-expanded", switcherOpen ? "true" : "false");
    if (!switcherOpen) return;
    if (projectsError !== null) {
      switcherPanel.replaceChildren(el("p", "edit-note", projectsError));
      return;
    }
    renderProjectGroups(switcherPanel, switcherGroups ?? [], project?.root ?? null, chooseProject);
  };

  const closeSwitcher = (): void => {
    if (!switcherOpen) return;
    switcherOpen = false;
    paintSwitcher();
  };

  const openSwitcher = async (): Promise<void> => {
    switcherOpen = true;
    paintSwitcher();
    await loadProjectGroups((groups) => {
      switcherGroups = groups;
      if (switcherOpen) paintSwitcher();
    });
  };

  const chooseProject = (line: ProjectLine): void => {
    if (project && line.root === project.root) return closeSwitcher();
    if (hasUnsavedWork(model) && !confirmFn(SWITCH_PROJECT_QUESTION)) return;
    navigate(editUrl(line.root));
  };

  if (project) {
    projectName.addEventListener("click", () => {
      if (switcherOpen) closeSwitcher();
      else void openSwitcher();
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && switcherOpen) closeSwitcher();
    });
    document.addEventListener("click", (event) => {
      if (!switcherOpen) return;
      const target = event.target as Node;
      if (switcherPanel.contains(target) || projectName.contains(target)) return;
      closeSwitcher();
    });
  }

  // --- the palette (round 14, rule 8 of `corpus/07-projects-and-tree.md`,
  // rule 25 of `Editor components 2`) -------------------------------------
  // ⌘P (Ctrl+P) over a scrim: the query line, `FILES N` of the open
  // project's repository (the index read once on open and again past
  // `PALETTE_INDEX_STALE_MS`), then `PROJECTS N` of round 12's list, both
  // matched by `palette-match.ts`'s fuzzy matcher; `Enter` or a click opens
  // the chosen row, after the tree's own question for a file with unsaved
  // work or the switcher's for a project.
  const PALETTE_INDEX_STALE_MS = 30000;
  let paletteOpen = false;
  let paletteQuery = "";
  let paletteIndex: { root: string; files: string[] } | null = null;
  let paletteIndexEtag: string | null = null;
  let paletteIndexReadAt = 0;
  let paletteSelected = -1;
  let paletteCurrentRows: PaletteRow[] = [];

  const paletteScrim = el("div", "edit-palette-scrim");
  paletteScrim.hidden = true;
  const paletteBox = el("div", "edit-palette");
  paletteBox.setAttribute("role", "dialog");
  paletteBox.setAttribute("aria-label", "Quick open");
  const paletteInputRow = el("div", "edit-palette-input-row");
  const paletteInput = document.createElement("input");
  paletteInput.type = "text";
  paletteInput.className = "edit-palette-input";
  paletteInput.placeholder = PALETTE_PLACEHOLDER;
  paletteInput.setAttribute("aria-label", "Quick open");
  paletteInput.setAttribute("aria-autocomplete", "list");
  const paletteKeysHint = el("span", "edit-palette-keys", PALETTE_KEYS);
  paletteInputRow.append(paletteInput, paletteKeysHint);
  const paletteGroupsHost = el("div", "edit-palette-groups");
  paletteGroupsHost.setAttribute("role", "listbox");
  paletteBox.append(paletteInputRow, paletteGroupsHost);
  paletteScrim.append(paletteBox);
  root.append(paletteScrim);

  const closePalette = (): void => {
    if (!paletteOpen) return;
    paletteOpen = false;
    paletteScrim.hidden = true;
    view?.focus();
  };

  /** A row chosen by `Enter` or a click: the palette closes first, then the
   * row's own question and navigation run, as the tree's row and the
   * switcher's choice do. */
  const openPaletteRow = (row: PaletteRow): void => {
    closePalette();
    if (row.kind === "project") return chooseProject(row.line);
    if (row.path === path) return selectTab("edit");
    if (hasUnsavedWork(model) && !confirmFn(DISCARD_FILE_QUESTION)) return;
    navigate(editUrl(row.path, session));
  };

  const renderPaletteFileRow = (file: PaletteFileRow, index: number): HTMLElement => {
    const row = button(`edit-palette-row edit-palette-file${index === paletteSelected ? " selected" : ""}`, "", `palette:${file.path}`);
    row.setAttribute("role", "option");
    row.setAttribute("aria-selected", index === paletteSelected ? "true" : "false");
    row.title = file.path;
    row.append(el("span", `edit-palette-tag${file.tag ? ` ${file.tag.className}` : ""}`, file.tag?.text ?? ""));
    const name = el("span", "edit-palette-name");
    for (const run of file.runs) name.append(run.matched ? el("span", "edit-palette-match", run.text) : document.createTextNode(run.text));
    row.append(name, el("span", "edit-palette-dir", file.directory));
    row.addEventListener("click", () => openPaletteRow(file));
    return row;
  };

  const renderPaletteProjectRow = (entry: PaletteProjectRow, index: number): HTMLElement => {
    const line = entry.line;
    // `.edit-project-line` alone (rule 25: the home line without the
    // radio) — not `.edit-palette-row`, whose flex layout would win the
    // cascade at equal specificity over the line's own grid.
    const row = button(`edit-project-line${index === paletteSelected ? " selected" : ""}`, "", `palette:project:${line.id}`);
    row.setAttribute("role", "option");
    row.setAttribute("aria-selected", index === paletteSelected ? "true" : "false");
    row.append(el("span", "edit-project-name", line.name), el("span", "edit-project-home", line.home), el("span", "edit-project-branch", line.branch));
    const changed = el("span", "edit-project-changed");
    if (line.changed !== null) changed.append(mark("M", "warning", true), " ", el("span", "edit-project-changed-count", String(line.changed)));
    row.append(changed);
    row.addEventListener("click", () => openPaletteRow(entry));
    return row;
  };

  const paintPalette = (): void => {
    if (!paletteOpen) return;
    const groups = paletteGroups(paletteIndex, projectsList ?? [], projectStatuses, paletteQuery);
    paletteCurrentRows = paletteRows(groups);
    if (paletteSelected >= paletteCurrentRows.length) paletteSelected = paletteCurrentRows.length - 1;
    if (paletteSelected < 0 && paletteCurrentRows.length > 0) paletteSelected = 0;
    paletteGroupsHost.replaceChildren();
    if (groups.empty) {
      paletteGroupsHost.append(el("p", "edit-note", PALETTE_EMPTY));
      return;
    }
    if (groups.files.length > 0) {
      paletteGroupsHost.append(el("h2", "edit-git-label", `FILES ${groups.fileCount}`));
      groups.files.forEach((file, i) => paletteGroupsHost.append(renderPaletteFileRow(file, i)));
      const more = moreFilesLine(groups.fileCount);
      if (more) paletteGroupsHost.append(el("p", "edit-palette-more", more));
    }
    if (groups.projects.length > 0) {
      paletteGroupsHost.append(el("h2", "edit-git-label", `PROJECTS ${groups.projects.length}`));
      groups.projects.forEach((entry, i) => paletteGroupsHost.append(renderPaletteProjectRow(entry, groups.files.length + i)));
    }
  };

  const refreshPaletteIndex = async (): Promise<void> => {
    if (paletteIndexReadAt !== 0 && Date.now() - paletteIndexReadAt < PALETTE_INDEX_STALE_MS) return;
    const result = await readFilesIndex(fetchFn, filesIndexUrl(path, session), paletteIndexEtag);
    if (result.kind === "ok") {
      paletteIndex = { root: result.answer.root, files: result.answer.files };
      paletteIndexEtag = result.answer.etag;
    }
    // A 304 keeps the index as read; any other failure (no repository
    // included) keeps the last index, `null` the first time, and is tried
    // again past the stale window rather than on every keystroke.
    paletteIndexReadAt = Date.now();
  };

  const openPalette = async (): Promise<void> => {
    if (switcherOpen) closeSwitcher();
    paletteOpen = true;
    paletteQuery = "";
    paletteInput.value = "";
    paletteSelected = -1;
    paletteScrim.hidden = false;
    paintPalette();
    paletteInput.focus();
    await loadProjectGroups(() => {
      if (paletteOpen) paintPalette();
    });
    await refreshPaletteIndex();
    if (paletteOpen) paintPalette();
  };

  paletteInput.addEventListener("input", () => {
    paletteQuery = paletteInput.value;
    paletteSelected = -1;
    paintPalette();
  });
  paletteInput.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      paletteSelected = movePaletteSelection(paletteCurrentRows.length, paletteSelected, event.key === "ArrowDown" ? "down" : "up");
      paintPalette();
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      const row = paletteCurrentRows[paletteSelected];
      if (row) openPaletteRow(row);
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      closePalette();
    }
  });
  paletteScrim.addEventListener("click", (event) => {
    if (event.target === paletteScrim) closePalette();
  });
  document.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "p") {
      event.preventDefault();
      if (!paletteOpen) void openPalette();
    }
  });

  // --- the folder form (round 7, `corpus/04-quick-open.md` item 1) ----------
  // A folder opens its `README.md` when it holds one, by name regardless of
  // case; else the tree stands alone, open down to the folder, and the
  // editor area says where to go. The title is the folder's name.
  if (folder !== null) {
    const node = treeModel ? findNode(treeModel, folder) : null;
    const readme = node?.children ? readmeIn(folder, node.children) : null;
    if (readme === null) {
      editorHost.replaceChildren(el("p", "edit-note", OPEN_FROM_TREE));
      paint();
      // Nothing is open, so nothing saves; the buffer is not read only either.
      saveButton.disabled = true;
      keySave.disabled = true;
      return;
    }
    path = readme;
    const readmeName = basename(readme);
    const named = headerName(project && { name: project.name, relative: project.relative ? `${project.relative}/${readmeName}` : readmeName }, readme);
    separator.hidden = named.project === null;
    namePath(named.path);
    pathName.title = path;
    paintTree();
  }

  // --- the read -----------------------------------------------------------
  const read = await readFile(fetchFn, contentUrl(path, session));
  if (read.kind !== "file") {
    const reason = read.kind === "error" ? read.reason : "the daemon answered 304 to a plain read";
    editorHost.replaceChildren(el("p", "edit-note", cannotRead(basename(path), reason)));
    model = READ_ONLY_MODEL;
    paint();
    return;
  }
  decoded = decodeText(read.bytes);
  etag = read.etag;
  disk = { text: decoded.text, etag, decoded };
  base = { text: decoded.text };
  readOnly = readOnlyReason({
    kind: read.fileKind,
    contentType: read.contentType,
    truncated: read.truncated,
    totalBytes: read.totalBytes,
    shownBytes: read.bytes.length,
    utf8: decoded.utf8,
  });
  if (readOnly !== null) model = READ_ONLY_MODEL;

  const language = languageOf(basename(path), languages);
  const languageName = language?.name ?? null;
  facts.textContent = read.fileKind === "text" ? headerFacts(languageName, decoded) : (read.contentType?.split(";")[0] ?? read.fileKind);

  // The Markdown preview toggle (rule 1): a text file whose name is Markdown.
  showsPreview = read.fileKind === "text" && isMarkdownFile(path);
  paintPreviewToggle();

  view = new EditorView({
    parent: editorHost,
    state: EditorState.create({
      doc: read.fileKind === "text" ? decoded.text : "",
      extensions: [
        lineNumbers(),
        history(),
        drawSelection(),
        indentOnInput(),
        bracketMatching(),
        highlightSelectionMatches(),
        syntaxHighlighting(highlightStyle),
        keymap.of([
          { key: "Mod-s", run: () => (void save(), true) },
          indentWithTab,
          ...defaultKeymap,
          ...historyKeymap,
          ...searchKeymap,
        ]),
        EditorView.updateListener.of((update) => {
          if (!update.docChanged || model.state === "read-only") return;
          // `● edited` while the buffer differs from what its tag names
          // (rule 2): an undo back to it reads clean again.
          const same = update.state.doc.toString() === base.text;
          const next = reduce(model, { type: same ? "unchanged" : "edit" });
          if (next !== model) {
            model = next;
            paint();
          }
        }),
        languageSlot.of([]),
        readOnlySlot.of([EditorState.readOnly.of(readOnly !== null), EditorView.editable.of(readOnly === null)]),
      ],
    }),
  });
  paint();

  if (showsPreview && markdownView === "preview") {
    paintMarkdownPreview();
    showEditorArea();
    // A `.md` link in a previous preview carried its fragment here as the
    // page's own hash (rule 3).
    if (location.hash !== "") scrollToFragment(previewHost, location.hash.replace(/^#(md-)?/, ""));
  }

  if (language) {
    void language.load().then((support) => {
      view?.dispatch({ effects: languageSlot.reconfigure(support) });
    });
  }
}

const root = document.getElementById("edit");
if (root) {
  const settings = loadSettings();
  const theme = findThemeById(settings.themeId);
  applyThemeTokens(theme.colors, {
    accent: theme.accent,
    fontFamily: resolveFontFamily(settings.fontId, settings.localFontFamily),
  });
  void bootEditPage(root, location.search);
}
