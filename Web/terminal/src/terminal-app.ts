import { setFavicon, type FaviconState } from "./favicon";
import { LOCAL_FONT_ID, resolveFontFamily, type TerminalFontId } from "./fonts";
import {
  loadLayout,
  saveLayout,
  takeLegacySessionId,
  type PaneSession,
} from "./layout-store";
import { isMacPlatform, type PaneCommand } from "./pane-keys";
import {
  countPanes,
  leaf,
  nextPane,
  paneIds,
  paneInDirection,
  removePane,
  setSplitRatio,
  splitPane,
  type LayoutNode,
  type PaneId,
} from "./pane-layout";
import { LayoutView } from "./pane-view";
import { SettingsPanel } from "./settings-panel";
import {
  DEFAULT_TAB_TITLE,
  isTabTitleStorageEvent,
  loadSettings,
  loadTabTitle,
  saveFontId,
  saveFontSize,
  saveLocalFontFamily,
  saveTabTitle,
  saveThemeId,
  type KittermSettings,
} from "./settings-store";
import { TerminalPane, type PaneHost } from "./terminal-pane";
import { findThemeById, type TerminalThemeId } from "./themes";
import { composeTabTitle } from "./title";
import { WebglBudget } from "./webgl-budget";

/** Coalesce a burst of typing into one storage write. */
const TAB_TITLE_PERSIST_DEBOUNCE_MS = 300;
/** Coalesce layout mutations (drag, focus) into one storage write. */
const LAYOUT_PERSIST_DEBOUNCE_MS = 250;
/** Stagger a restored layout so N panes do not open N sockets in one tick. */
const STAGGER_MS = 100;

export type TerminalAppOptions = {
  container: HTMLElement;
  statusEl?: HTMLElement | null;
  searchRoot?: HTMLElement | null;
  settingsRoot?: HTMLElement | null;
};

/**
 * The app shell: everything there is exactly one of per page.
 *
 * Owns `document.title`, the favicon, `window`-level listeners, the settings
 * panel, the search bar, layout persistence, and the pane tree. Individual
 * shells live in {@link TerminalPane}, which reaches back here through
 * {@link PaneHost}. Registering any of the global listeners per pane would
 * multiply their work by the pane count — see the reconnect fan-out below.
 */
export class TerminalApp implements PaneHost {
  private readonly statusEl: HTMLElement | null;
  private readonly searchRoot: HTMLElement | null;
  private readonly settingsRoot: HTMLElement | null;
  private readonly view: LayoutView;
  private readonly webgl = new WebglBudget();
  private readonly isMac = isMacPlatform();
  private readonly panes = new Map<PaneId, TerminalPane>();
  private root: LayoutNode;
  private focusedId: PaneId;
  private settingsValue: KittermSettings;
  private settingsPanel: SettingsPanel | null = null;
  private searchInput: HTMLInputElement | null = null;
  private unreadOutput = false;
  private statusClearTimer: number | null = null;
  private tabTitlePersistTimer: number | null = null;
  private layoutPersistTimer: number | null = null;
  private lastTitle = "";
  private paneCounter = 0;
  private disposed = false;
  /** A `/?session=` link is a view onto someone else's shell: it must not read
   * or overwrite this tab's saved layout until the user makes it their own. */
  private linkBoot = false;
  /** Per-pane persistent status, shown when that pane is focused. */
  private readonly paneStatuses = new Map<PaneId, string | null>();

  constructor(options: TerminalAppOptions) {
    this.statusEl = options.statusEl ?? null;
    this.searchRoot = options.searchRoot ?? null;
    this.settingsRoot = options.settingsRoot ?? null;
    this.settingsValue = loadSettings();

    this.view = new LayoutView(options.container, {
      onRatioPreview: (splitId, ratio) => {
        this.root = setSplitRatio(this.root, splitId, ratio);
        this.view.render(this.root);
      },
      onRatioCommit: () => this.scheduleLayoutPersist(),
      onClosePane: (id) => this.closePane(id),
    });

    this.applyPageBackground(findThemeById(this.settingsValue.themeId).colors.background);
    this.wireSettings();
    this.wireSearch();
    this.wireGlobalListeners();

    const boot = this.resolveBoot();
    this.root = boot.root;
    this.focusedId = boot.focus;
    boot.panes.forEach(({ id, session }, index) => {
      this.createPane(id, session, index * STAGGER_MS);
    });
    this.view.render(this.root);
    this.setFocus(this.focusedId, { persist: false });
    this.refreshTitle();
    this.updateFavicon();
  }

  // MARK: Boot

  private resolveBoot(): {
    root: LayoutNode;
    focus: PaneId;
    panes: Array<{ id: PaneId; session: PaneSession }>;
  } {
    const params = new URLSearchParams(window.location.search);
    const linkSession = params.get("session");
    const linkCwd = params.get("cwd");

    // A share link or a cwd deep link is always a single fresh pane, and does
    // not disturb whatever layout this tab already had saved.
    if (linkSession || linkCwd) {
      this.linkBoot = true;
      const id = this.nextPaneId();
      return {
        root: leaf(id),
        focus: id,
        panes: [{ id, session: { sessionId: linkSession, cwd: linkCwd ?? undefined } }],
      };
    }

    const stored = loadLayout();
    if (stored) {
      const ids = paneIds(stored.root);
      const focus = ids.includes(stored.focus) ? stored.focus : (ids[0] as PaneId);
      // Keep the counter ahead of restored ids so a later split cannot collide.
      for (const id of ids) {
        const n = Number.parseInt(id.replace(/^p/, ""), 10);
        if (Number.isFinite(n) && n > this.paneCounter) this.paneCounter = n;
      }
      return {
        root: stored.root,
        focus,
        panes: ids.map((id) => ({
          id,
          session: stored.sessions.get(id) ?? { sessionId: null },
        })),
      };
    }

    // A tab reloading across the deploy that introduced splits still has its
    // shell recorded under the old single-session key.
    const legacy = takeLegacySessionId();
    const id = this.nextPaneId();
    return {
      root: leaf(id),
      focus: id,
      panes: [{ id, session: { sessionId: legacy } }],
    };
  }

  private nextPaneId(): PaneId {
    this.paneCounter += 1;
    return `p${this.paneCounter}`;
  }

  private createPane(id: PaneId, session: PaneSession, delayMs = 0): TerminalPane {
    const element = this.view.paneElement(id);
    const pane = new TerminalPane({
      id,
      container: element,
      host: this,
      isMac: this.isMac,
      sessionId: session.sessionId,
      cwd: session.cwd ?? null,
    });
    this.panes.set(id, pane);
    this.webgl.acquire(id, pane);
    pane.start(delayMs);
    return pane;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.persistTabTitle();
    this.persistLayout();
    window.removeEventListener("storage", this.onStorage);
    this.settingsPanel?.dispose();
    for (const pane of this.panes.values()) pane.dispose();
    this.panes.clear();
    this.view.dispose();
  }

  // MARK: PaneHost

  get settings(): KittermSettings {
    return this.settingsValue;
  }

  paneStateChanged(pane: TerminalPane): void {
    this.updateFavicon();
    // A shell that exits closes its pane — the tmux/iTerm2 behaviour, and the
    // reason `exit` needs no keybinding. The last pane stays so the page keeps
    // something to look at.
    if (pane.exited && countPanes(this.root) > 1) {
      this.closePane(pane.id);
    }
  }

  paneOutput(): void {
    if (document.hidden && !this.unreadOutput) {
      this.unreadOutput = true;
      this.updateFavicon();
    }
  }

  paneStatus(pane: TerminalPane, message: string | null): void {
    this.paneStatuses.set(pane.id, message);
    if (pane.id === this.focusedId) this.setStatus(message);
  }

  paneFlash(message: string, durationMs = 4000): void {
    this.setStatus(message);
    this.statusClearTimer = window.setTimeout(() => {
      this.statusClearTimer = null;
      this.setStatus(this.paneStatuses.get(this.focusedId) ?? null);
    }, durationMs);
  }

  paneSessionId(pane: TerminalPane, _id: string, replaced: boolean): void {
    if (replaced) {
      // The shell died and a new one took its place. The pane is still the
      // user's "Deploy" pane, so carry the name across rather than silently
      // reverting to the folder.
      this.persistTabTitle();
    } else if (pane.id === this.focusedId) {
      this.loadTabTitleForFocused();
    }
    // Fires once for the page, not once per pane: every pane would otherwise
    // race to strip the query string.
    if (window.location.search) {
      window.history.replaceState({}, "", window.location.pathname);
    }
    this.scheduleLayoutPersist();
  }

  paneFolderChanged(pane: TerminalPane): void {
    if (pane.id === this.focusedId) this.refreshTitle();
    this.scheduleLayoutPersist();
  }

  paneRoleChanged(pane: TerminalPane): void {
    if (pane.id === this.focusedId) {
      // Renaming the tab is part of controlling the session.
      this.settingsPanel?.setTabTitleEditable(!pane.readOnly);
    }
  }

  paneCommand(pane: TerminalPane, command: PaneCommand): void {
    switch (command.type) {
      case "split":
        this.splitFocused(pane.id, command.dir);
        break;
      case "close":
        this.closePane(pane.id);
        break;
      case "navigate": {
        const target = paneInDirection(this.root, pane.id, command.dir);
        if (target) this.setFocus(target);
        break;
      }
    }
  }

  paneFocusRequested(pane: TerminalPane): void {
    this.setFocus(pane.id);
  }

  paneSearchRequested(pane: TerminalPane): void {
    this.setFocus(pane.id);
    this.openSearch();
  }

  // MARK: Pane tree

  private splitFocused(target: PaneId, dir: "row" | "column"): void {
    const source = this.panes.get(target);
    const id = this.nextPaneId();
    this.root = splitPane(this.root, target, dir, id);
    // A new pane starts where the one it came from is, matching tmux.
    this.createPane(id, { sessionId: null, cwd: source?.lastCwd ?? undefined });
    this.view.render(this.root);
    this.setFocus(id);
    for (const pane of this.panes.values()) pane.scheduleFit();
  }

  private closePane(id: PaneId): void {
    if (countPanes(this.root) <= 1) {
      // Last pane: keep the page usable rather than leaving an empty shell.
      // If its shell already exited the pane's own status says so.
      if (!this.panes.get(id)?.exited) {
        this.setStatus("Last pane — type `exit` or reload to restart the shell");
      }
      return;
    }
    const next = nextPane(this.root, id, 1) ?? this.focusedId;
    const pruned = removePane(this.root, id);
    if (!pruned) return;

    this.panes.get(id)?.dispose();
    this.panes.delete(id);
    this.paneStatuses.delete(id);
    this.webgl.release(id);
    this.view.removePane(id);

    this.root = pruned;
    this.view.render(this.root);
    if (this.focusedId === id) this.setFocus(next);
    for (const pane of this.panes.values()) pane.scheduleFit();
    this.scheduleLayoutPersist();
  }

  private setFocus(id: PaneId, options: { persist?: boolean } = {}): void {
    const pane = this.panes.get(id);
    if (!pane) return;
    this.focusedId = id;
    this.view.setFocused(id);
    this.webgl.acquire(id, pane);
    pane.focus();
    this.setStatus(this.paneStatuses.get(id) ?? null);
    this.settingsPanel?.setTabTitleEditable(!pane.readOnly);
    this.loadTabTitleForFocused();
    this.refreshTitle();
    this.closeSearch({ refocus: false });
    if (options.persist !== false) this.scheduleLayoutPersist();
  }

  private get focusedPane(): TerminalPane | null {
    return this.panes.get(this.focusedId) ?? null;
  }

  // MARK: Persistence

  private scheduleLayoutPersist(): void {
    if (this.linkBoot || this.disposed) return;
    if (this.layoutPersistTimer !== null) return;
    this.layoutPersistTimer = window.setTimeout(() => {
      this.layoutPersistTimer = null;
      this.persistLayout();
    }, LAYOUT_PERSIST_DEBOUNCE_MS);
  }

  private persistLayout(): void {
    if (this.layoutPersistTimer !== null) {
      window.clearTimeout(this.layoutPersistTimer);
      this.layoutPersistTimer = null;
    }
    if (this.linkBoot) return;
    const sessions = new Map<PaneId, PaneSession>();
    for (const [id, pane] of this.panes) {
      sessions.set(id, {
        sessionId: pane.sessionId,
        cwd: pane.lastCwd ?? undefined,
      });
    }
    saveLayout({ root: this.root, focus: this.focusedId, sessions });
  }

  // MARK: Global listeners — one set for the page, fanned out to panes

  private wireGlobalListeners(): void {
    const tryNow = (): void => {
      if (this.disposed) return;
      // Stagger: N panes reconnecting in the same tick is a burst the daemon
      // never sees from N separate tabs.
      let index = 0;
      for (const pane of this.panes.values()) {
        const delay = index * STAGGER_MS;
        index += 1;
        if (delay === 0) pane.reconnectNow();
        else window.setTimeout(() => pane.reconnectNow(), delay);
      }
    };
    const clearUnread = (): void => {
      if (this.unreadOutput) {
        this.unreadOutput = false;
        this.updateFavicon();
      }
    };

    window.addEventListener("focus", () => {
      clearUnread();
      tryNow();
    });
    window.addEventListener("online", tryNow);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") {
        clearUnread();
        tryNow();
      }
    });
    window.addEventListener("resize", () => {
      for (const pane of this.panes.values()) pane.scheduleFit();
    });
    window.addEventListener("storage", this.onStorage);
  }

  /** Mirror the controller's edits into observer tabs of the same browser.
   * `storage` fires only in other tabs, so this never echoes our own write. */
  private readonly onStorage = (event: StorageEvent): void => {
    if (!isTabTitleStorageEvent(event)) return;
    this.loadTabTitleForFocused();
  };

  // MARK: Settings

  private wireSettings(): void {
    if (!this.settingsRoot) return;
    this.settingsPanel = new SettingsPanel(this.settingsRoot, this.settingsValue, {
      onThemeChange: (themeId) => this.applyTheme(themeId),
      onFontChange: (fontId) => this.applyFont(fontId),
      onLocalFontFamilyChange: (family) => this.applyLocalFont(family),
      onFontSizeChange: (fontSize) => this.applyFontSize(fontSize),
      onTabTitleChange: (title) => this.applyTabTitle(title),
      onTabTitleShowFolderChange: (showFolder) =>
        this.applyTabTitleShowFolder(showFolder),
      onCopySessionLink: () => this.copySessionLink(),
    });
  }

  private applyToAllPanes(): void {
    for (const pane of this.panes.values()) pane.applySettings(this.settingsValue);
  }

  private applyTheme(themeId: TerminalThemeId): void {
    const theme = findThemeById(themeId);
    this.settingsValue = { ...this.settingsValue, themeId: theme.id };
    this.applyPageBackground(theme.colors.background);
    this.applyToAllPanes();
    saveThemeId(theme.id);
    this.settingsPanel?.sync(this.settingsValue);
  }

  private applyFont(fontId: TerminalFontId): void {
    this.settingsValue = { ...this.settingsValue, fontId };
    this.applyToAllPanes();
    saveFontId(fontId);
    this.settingsPanel?.sync(this.settingsValue);
  }

  private applyLocalFont(family: string): void {
    const trimmed = family.trim();
    if (!trimmed) return;
    this.settingsValue = {
      ...this.settingsValue,
      fontId: LOCAL_FONT_ID,
      localFontFamily: trimmed,
    };
    // Touch resolveFontFamily so an invalid family surfaces here rather than
    // silently inside every pane.
    resolveFontFamily(LOCAL_FONT_ID, trimmed);
    this.applyToAllPanes();
    saveFontId(LOCAL_FONT_ID);
    saveLocalFontFamily(trimmed);
    this.settingsPanel?.sync(this.settingsValue);
  }

  private applyFontSize(fontSize: number): void {
    this.settingsValue = { ...this.settingsValue, fontSize };
    this.applyToAllPanes();
    saveFontSize(fontSize);
    this.settingsPanel?.sync(this.settingsValue);
  }

  private applyPageBackground(background: string | undefined): void {
    const color = background ?? "#0d1117";
    document.documentElement.style.background = color;
    document.body.style.background = color;
    const app = document.getElementById("app");
    if (app) app.style.background = color;
  }

  // MARK: Tab title — global, driven by the focused pane

  private applyTabTitle(title: string): void {
    if (this.focusedPane?.readOnly) return;
    this.settingsValue = { ...this.settingsValue, tabTitle: title };
    this.refreshTitle();
    // Typing repaints the title immediately but writes storage at most once
    // per burst: each write parses and re-serialises the session map and
    // wakes every other kitterm tab with a `storage` event.
    this.scheduleTabTitlePersist();
  }

  private applyTabTitleShowFolder(showFolder: boolean): void {
    if (this.focusedPane?.readOnly) return;
    this.settingsValue = { ...this.settingsValue, tabTitleShowFolder: showFolder };
    this.refreshTitle();
    this.persistTabTitle();
  }

  private scheduleTabTitlePersist(): void {
    if (this.tabTitlePersistTimer !== null) {
      window.clearTimeout(this.tabTitlePersistTimer);
    }
    this.tabTitlePersistTimer = window.setTimeout(() => {
      this.tabTitlePersistTimer = null;
      this.persistTabTitle();
    }, TAB_TITLE_PERSIST_DEBOUNCE_MS);
  }

  /** Controller-only: the title belongs to the session, so an observer pane
   * must never write it back. */
  private persistTabTitle(): void {
    if (this.tabTitlePersistTimer !== null) {
      window.clearTimeout(this.tabTitlePersistTimer);
      this.tabTitlePersistTimer = null;
    }
    const pane = this.focusedPane;
    if (!pane || pane.readOnly || !pane.sessionId) return;
    saveTabTitle(pane.sessionId, {
      tabTitle: this.settingsValue.tabTitle,
      tabTitleShowFolder: this.settingsValue.tabTitleShowFolder,
    });
  }

  /** Adopt the focused session's stored title — for an observer this is the
   * title its controller set. */
  private loadTabTitleForFocused(): void {
    const sessionId = this.focusedPane?.sessionId ?? null;
    const prefs = sessionId ? loadTabTitle(sessionId) : { ...DEFAULT_TAB_TITLE };
    if (
      prefs.tabTitle === this.settingsValue.tabTitle &&
      prefs.tabTitleShowFolder === this.settingsValue.tabTitleShowFolder
    ) {
      return;
    }
    this.settingsValue = { ...this.settingsValue, ...prefs };
    this.settingsPanel?.syncTabTitle(this.settingsValue);
    this.refreshTitle();
  }

  private refreshTitle(): void {
    const base = composeTabTitle({
      custom: this.settingsValue.tabTitle,
      showFolder: this.settingsValue.tabTitleShowFolder,
      folder: this.focusedPane?.folder ?? null,
    });
    const count = this.panes.size;
    const title = count > 1 ? `${base} · ${count} panes` : base;
    if (title === this.lastTitle) return;
    this.lastTitle = title;
    document.title = title;
  }

  // MARK: Favicon — aggregated across panes

  private updateFavicon(): void {
    setFavicon(this.aggregateConnectionState(), this.unreadOutput);
  }

  private aggregateConnectionState(): FaviconState {
    let allExited = this.panes.size > 0;
    let anyReconnecting = false;
    for (const pane of this.panes.values()) {
      if (pane.connectionState !== "exited") allExited = false;
      if (pane.connectionState === "reconnecting") anyReconnecting = true;
    }
    if (allExited) return "exited";
    if (anyReconnecting) return "reconnecting";
    return "connected";
  }

  // MARK: Share — acts on the focused pane

  /** Copy `/?session=<id>` — open in another window/device to observe live. */
  private copySessionLink(): void {
    const sessionId = this.focusedPane?.sessionId;
    if (!sessionId) {
      this.paneFlash("No session to share yet");
      return;
    }
    void this.buildShareLink(sessionId).then(({ url, lan }) => {
      void navigator.clipboard.writeText(url).then(
        () => this.paneFlash(lan ? "LAN session link copied" : "Session link copied"),
        () => this.paneFlash(url, 8000),
      );
    });
  }

  /** A `kitterm.localhost` link is unreachable from other devices; in LAN
   * mode, share the daemon's LAN URL (token included) instead. */
  private async buildShareLink(
    sessionId: string,
  ): Promise<{ url: string; lan: boolean }> {
    const sameOrigin = `${window.location.origin}/?session=${encodeURIComponent(sessionId)}`;
    if (!isLoopbackHostname(window.location.hostname)) {
      return { url: sameOrigin, lan: false };
    }
    try {
      const response = await fetch("/api/lan");
      const info = (await response.json()) as {
        enabled?: boolean;
        url?: string;
        token?: string;
      };
      if (info.enabled && info.url) {
        const token = info.token ? `&token=${encodeURIComponent(info.token)}` : "";
        return {
          url: `${info.url}/?session=${encodeURIComponent(sessionId)}${token}`,
          lan: true,
        };
      }
    } catch {
      // Daemon unreachable mid-reconnect — fall back to the local link.
    }
    return { url: sameOrigin, lan: false };
  }

  // MARK: Search — one bar, driving the focused pane

  private wireSearch(): void {
    if (!this.searchRoot) return;
    this.searchRoot.innerHTML = `
      <input id="search-input" type="search" placeholder="Find in buffer…" autocomplete="off" spellcheck="false" />
      <button type="button" id="search-prev" title="Previous">↑</button>
      <button type="button" id="search-next" title="Next">↓</button>
      <button type="button" id="search-close" title="Close">✕</button>
    `;
    this.searchInput = this.searchRoot.querySelector("#search-input");
    const prev = this.searchRoot.querySelector("#search-prev");
    const next = this.searchRoot.querySelector("#search-next");
    const close = this.searchRoot.querySelector("#search-close");

    this.searchInput?.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        this.closeSearch();
        return;
      }
      if (event.key === "Enter") {
        event.preventDefault();
        this.find(event.shiftKey ? "prev" : "next");
      }
    });
    prev?.addEventListener("click", () => this.find("prev"));
    next?.addEventListener("click", () => this.find("next"));
    close?.addEventListener("click", () => this.closeSearch());
    this.searchRoot.hidden = true;
  }

  private openSearch(): void {
    if (!this.searchRoot || !this.searchInput) return;
    this.searchRoot.hidden = false;
    this.searchInput.focus();
    this.searchInput.select();
  }

  private closeSearch(options: { refocus?: boolean } = {}): void {
    if (!this.searchRoot || this.searchRoot.hidden) return;
    this.searchRoot.hidden = true;
    // Decorations belong to the pane that was searched.
    for (const pane of this.panes.values()) pane.clearSearchDecorations();
    if (options.refocus !== false) this.focusedPane?.focus();
  }

  private find(direction: "next" | "prev"): void {
    const term = this.searchInput?.value ?? "";
    if (!term) return;
    const pane = this.focusedPane;
    if (!pane) return;
    if (direction === "next") pane.findNext(term);
    else pane.findPrevious(term);
  }

  // MARK: Status

  private setStatus(message: string | null): void {
    if (!this.statusEl) return;
    if (this.statusClearTimer !== null) {
      window.clearTimeout(this.statusClearTimer);
      this.statusClearTimer = null;
    }
    if (message) {
      this.statusEl.textContent = message;
      this.statusEl.hidden = false;
    } else {
      this.statusEl.textContent = "";
      this.statusEl.hidden = true;
    }
  }
}

function isLoopbackHostname(hostname: string): boolean {
  const name = hostname.toLowerCase();
  return (
    name === "localhost" ||
    name === "127.0.0.1" ||
    name === "[::1]" ||
    name.endsWith(".localhost")
  );
}
