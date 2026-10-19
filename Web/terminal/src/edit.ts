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
 * The pure decisions are `edit-model.ts`, `edit-tree.ts` and
 * `line-diff.ts`; the daemon conversations are `edit-fetch.ts`. This file
 * paints and wires.
 */

import "./tokens.css";
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

import { type Fetch, readFile, readListing, readProject, saveFile } from "./edit-fetch";
import {
  barLine,
  contentUrl,
  decodeText,
  type DecodedText,
  diskChangeAction,
  editUrl,
  type EditorModel,
  emptyFolder,
  encodeText,
  hasUnsavedWork,
  headerFacts,
  headerName,
  INITIAL_MODEL,
  languageOf,
  listingUrl,
  NO_FILE_NAMED,
  NO_PROJECT,
  notSaved,
  pageTitle,
  projectUrl,
  READ_ONLY_MODEL,
  readOnlyReason,
  reduce,
  stateRun,
  terminalUrl,
} from "./edit-model";
import { ancestorsOf, childrenOf, findNode, treeRoot, type TreeNode, triangle, visibleRows } from "./edit-tree";
import { resolveFontFamily } from "./fonts";
import { trackKeyboardInsets } from "./keyboard-insets";
import { diffCounts, hunkHeader, lineDiff } from "./line-diff";
import { basename, cannotRead } from "./markdown-view";
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

/** The query: the file and the session, or `null` with no file. */
export function pageTarget(search: string): { path: string; session: string | null } | null {
  const params = new URLSearchParams(search);
  const path = params.get("path");
  if (path === null || path === "") return null;
  const session = params.get("session");
  return { path, session: session === null || session === "" ? null : session };
}

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

export interface PageOptions {
  fetch?: Fetch;
  /** Where a tree row's file opens; `location.assign` on the page. */
  navigate?: (url: string) => void;
  /** The question before a reload drops typed work; `window.confirm` on the page. */
  confirm?: (question: string) => boolean;
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
  const schedule = options.schedule ?? ((tick: () => void, ms: number) => void setInterval(tick, ms));

  // --- the chrome ---------------------------------------------------------
  const header = el("header", "edit-header");
  const name = el("div", "edit-name");
  const projectName = el("span", "edit-project");
  const separator = el("span", "edit-separator", " / ");
  const pathName = el("span", "edit-path");
  const pathDir = el("span", "edit-path-dir");
  const pathBase = el("span", "edit-path-name");
  pathName.append(pathDir, pathBase);
  name.append(projectName, separator, pathName);
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
  const saveButton = button("edit-save", "[ save ⌘S ]", "save");
  saveButton.setAttribute("aria-keyshortcuts", "Meta+S Control+S");
  const terminalLink = el("a", "edit-terminal", "open in terminal");
  actions.append(saveButton, terminalLink);
  header.append(name, state, facts, actions);

  const tabs = el("nav", "edit-tabs");
  tabs.setAttribute("role", "radiogroup");
  tabs.setAttribute("aria-label", "Sidebar");
  const filesTab = button("edit-tab", "[x] files", "tab:files");
  filesTab.setAttribute("role", "radio");
  filesTab.setAttribute("aria-checked", "true");
  const editTab = button("edit-tab edit-tab-edit", "[ ] edit", "tab:edit");
  editTab.setAttribute("role", "radio");
  editTab.setAttribute("aria-checked", "false");
  tabs.append(filesTab, editTab);

  const body = el("div", "edit-body");
  const sidebar = el("aside", "edit-sidebar");
  sidebar.setAttribute("aria-label", "Files");
  const tree = el("div", "edit-tree");
  tree.setAttribute("role", "tree");
  sidebar.append(tree);
  const main = el("section", "edit-main");
  const bar = el("div", "edit-bar");
  bar.setAttribute("role", "alert");
  bar.hidden = true;
  const editorHost = el("div", "edit-editor");
  const diffHost = el("div", "edit-diff");
  diffHost.hidden = true;
  main.append(bar, editorHost, diffHost);
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

  const target = pageTarget(search);
  if (target === null) {
    namePath("/edit");
    main.replaceChildren(el("p", "edit-note", NO_FILE_NAMED));
    tree.replaceChildren(el("p", "edit-note", NO_PROJECT));
    return;
  }
  const { session } = target;

  // --- the tabs (the phone) -------------------------------------------------
  const selectTab = (tab: "files" | "edit"): void => {
    root.dataset.tab = tab;
    filesTab.setAttribute("aria-checked", tab === "files" ? "true" : "false");
    filesTab.textContent = `[${tab === "files" ? "x" : " "}] files`;
    editTab.setAttribute("aria-checked", tab === "edit" ? "true" : "false");
    editTab.textContent = `[${tab === "edit" ? "x" : " "}] edit`;
  };
  filesTab.addEventListener("click", () => selectTab("files"));
  editTab.addEventListener("click", () => selectTab("edit"));
  // A phone opens on the editor (the frame `Editor 390`); a wide window
  // shows both columns, and its one tab reads `[x] files`.
  selectTab(window.matchMedia("(max-width: 767px)").matches ? "edit" : "files");

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
    editorHost.hidden = false;
  };

  /** The unified diff of the disk against the buffer, in the editor area. */
  const showDiff = (): void => {
    const diff = lineDiff(disk.text, bufferText());
    diffHost.replaceChildren();
    const top = el("div", "edit-diff-top");
    top.append(
      el("span", "edit-diff-name", basename(path)),
      " ",
      el("span", "edit-diff-counts", diffCounts(diff)),
      el("span", "edit-diff-what", " · buffer against disk"),
    );
    const back = button("edit-diff-back", "open file", "diff:back");
    back.addEventListener("click", hideDiff);
    top.append(back);
    const rows = el("div", "edit-diff-rows");
    if (diff.hunks.length === 0) rows.append(el("p", "edit-note", "The buffer equals the disk."));
    for (const hunk of diff.hunks) {
      const header = el("div", "edit-diff-line hunk");
      header.append(el("span", "edit-diff-gutter", ""), el("span", "edit-diff-text", hunkHeader(hunk)));
      rows.append(header);
      for (const line of hunk.lines) {
        const row = el("div", `edit-diff-line ${line.kind}`);
        const prefix = line.kind === "add" ? "+" : line.kind === "del" ? "−" : " ";
        row.append(
          el("span", "edit-diff-gutter", line.newNumber === undefined ? "" : String(line.newNumber)),
          el("span", "edit-diff-text", `${prefix} ${line.text}`),
        );
        rows.append(row);
      }
    }
    diffHost.append(top, rows);
    diffHost.hidden = false;
    editorHost.hidden = true;
    selectTab("edit");
  };

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
    paint();
    facts.textContent = headerFacts(languageName, decoded);
    view?.focus();
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

  const paintTree = (): void => {
    tree.replaceChildren();
    if (!treeModel) return;
    for (const { node, depth } of visibleRows(treeModel)) {
      const row = button("edit-row", "", `tree:${node.path}`);
      row.style.setProperty("--depth", String(depth));
      row.setAttribute("role", "treeitem");
      if (node.dir) row.setAttribute("aria-expanded", node.open ? "true" : "false");
      if (node.path === path) {
        row.classList.add("open");
        row.setAttribute("aria-current", "true");
      }
      row.title = node.path;
      row.append(el("span", "edit-triangle", triangle(node)), el("span", "edit-row-name", node.name));
      row.addEventListener("click", () => void onRow(node));
      tree.append(row);
      if (node.dir && node.open && node.children && node.children.length === 0) {
        const empty = el("p", "edit-note edit-row-empty", node.error ?? emptyFolder(node.name));
        empty.style.setProperty("--depth", String(depth + 1));
        tree.append(empty);
      }
    }
  };

  const list = async (node: TreeNode): Promise<void> => {
    const result = await readListing(fetchFn, listingUrl(node.path, session));
    if (result.kind === "ok") {
      node.children = childrenOf(node, result.entries);
      node.error = null;
    } else {
      node.children = [];
      node.error = cannotRead(node.name, result.reason);
    }
  };

  const onRow = async (node: TreeNode): Promise<void> => {
    if (!node.dir) {
      if (node.path === path) return selectTab("edit");
      if (hasUnsavedWork(model) && !confirmFn("Discard your edits and open another file?")) return;
      navigate(editUrl(node.path, session));
      return;
    }
    node.open = !node.open;
    if (node.open && node.children === null) await list(node);
    paintTree();
    const focus = tree.querySelector<HTMLElement>(`[data-focus="tree:${CSS.escape(node.path)}"]`);
    focus?.focus();
  };

  const projectAnswer = await readProject(fetchFn, projectUrl(path, session));
  if (projectAnswer.kind === "ok") {
    path = projectAnswer.answer.path || path;
    const named = headerName(projectAnswer.answer.project, path);
    projectName.textContent = named.project ?? "";
    separator.hidden = named.project === null;
    namePath(named.path);
    pathName.title = path;
    terminalLink.href = terminalUrl(path);
    if (projectAnswer.answer.project) {
      const { root: projectRoot, name: projectLabel } = projectAnswer.answer.project;
      treeModel = treeRoot(projectRoot, projectLabel);
      // The open file's folders listed and open, so its row shows.
      for (const directory of ancestorsOf(projectRoot, path)) {
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
