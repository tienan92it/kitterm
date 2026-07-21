import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { UnicodeGraphemesAddon } from "@xterm/addon-unicode-graphemes";
import { WebglAddon } from "@xterm/addon-webgl";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";

import {
  ENTER_KEY_CODE,
  KEYBOARD_MODIFIER_SHIFT_BIT,
  KITTY_KEYBOARD_SET_MODE_AND_NOT,
  KITTY_KEYBOARD_SET_MODE_OR,
  KITTY_KEYBOARD_SET_MODE_REPLACE,
  KittyFlagStack,
  buildKittyKeySequence,
  extractKeyboardModifiers,
} from "./kitty";
import { setFavicon, type FaviconState } from "./favicon";
import { OutputFlowControl } from "./flow-control";
import { LOCAL_FONT_ID, resolveFontFamily, type TerminalFontId } from "./fonts";
import { KittermSession, defaultWsUrl } from "./session";
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
import { findThemeById, type TerminalThemeId } from "./themes";
import {
  composeTabTitle,
  cwdFromOsc1337,
  cwdFromOsc7,
  folderFromCwd,
} from "./title";

/** Longest OSC 1337 payload still plausibly shell integration; anything above
 * this is bulk data (inline images) we must not keep buffering for. */
const ITERM_OSC_PAYLOAD_LIMIT = 4096;

/** Coalesce a burst of typing into one storage write. */
const TAB_TITLE_PERSIST_DEBOUNCE_MS = 300;

export type TerminalAppOptions = {
  container: HTMLElement;
  statusEl?: HTMLElement | null;
  searchRoot?: HTMLElement | null;
  settingsRoot?: HTMLElement | null;
};

export class TerminalApp {
  private readonly terminal: Terminal;
  private readonly fitAddon: FitAddon;
  private readonly searchAddon: SearchAddon;
  private readonly session: KittermSession;
  private readonly kitty = new KittyFlagStack();
  private readonly statusEl: HTMLElement | null;
  private readonly searchRoot: HTMLElement | null;
  private readonly settingsRoot: HTMLElement | null;
  private settings: KittermSettings;
  private settingsPanel: SettingsPanel | null = null;
  private webglAddon: WebglAddon | null = null;
  private searchInput: HTMLInputElement | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private readonly flowControl = new OutputFlowControl({
    onPause: () => this.session.sendPause(),
    onResume: () => this.session.sendResume(),
  });
  /** `/?session=<id>` link outranks the tab's stored session. */
  private sessionId: string | null =
    new URLSearchParams(window.location.search).get("session") ??
    readStoredSessionId();
  /** True while this connection is a read-only observer of the session. */
  private readOnly = false;
  /** Current folder for the tab title; null until the shell reports one. */
  private folder: string | null = null;
  /** Last value written to `document.title`, to skip redundant writes. */
  private lastTitle = "";
  /** Pending debounced write of the tab title. */
  private tabTitlePersistTimer: number | null = null;
  /** Deep-link `/?cwd=…` — used only when spawning a fresh session. */
  private readonly requestedCwd: string | null = new URLSearchParams(
    window.location.search,
  ).get("cwd");
  /** A cwd deep link requests a NEW shell: it outranks any stored session id
   * until the daemon confirms the fresh session. */
  private deepLinkPending: boolean = new URLSearchParams(
    window.location.search,
  ).has("cwd");
  private reconnectTimer: number | null = null;
  private reconnectAttempt = 0;
  private lastConnectAt = 0;
  /** False until the first successful connect of this page's lifetime.
   * A fresh page has no terminal content, so reattach asks the daemon to
   * replay the recent tail (otherwise an idle shell shows a bare cursor). */
  private hasEverConnected = false;
  private statusClearTimer: number | null = null;
  private connectionState: FaviconState = "reconnecting";
  private unreadOutput = false;
  private disposed = false;
  private exited = false;
  constructor(options: TerminalAppOptions) {
    this.statusEl = options.statusEl ?? null;
    this.searchRoot = options.searchRoot ?? null;
    this.settingsRoot = options.settingsRoot ?? null;
    this.settings = loadSettings();
    const theme = findThemeById(this.settings.themeId);

    this.terminal = new Terminal({
      allowProposedApi: true,
      cursorBlink: true,
      fontFamily: resolveFontFamily(
        this.settings.fontId,
        this.settings.localFontFamily,
      ),
      fontSize: this.settings.fontSize,
      scrollback: 10_000,
      theme: theme.colors,
      macOptionIsMeta: true,
      rightClickSelectsWord: true,
    });

    this.fitAddon = new FitAddon();
    this.searchAddon = new SearchAddon();
    this.terminal.loadAddon(this.fitAddon);
    this.terminal.loadAddon(this.searchAddon);
    this.terminal.loadAddon(new UnicodeGraphemesAddon());

    this.session = new KittermSession({
      onOpen: () => {
        this.hasEverConnected = true;
        this.reconnectAttempt = 0;
        this.clearReconnectTimer();
        this.flowControl.reset();
        this.setStatus(null);
        this.setConnectionState("connected");
        this.fitAndResize();
        this.terminal.focus();
      },
      onFrame: (frame) => this.handleFrame(frame),
      onClose: () => {
        this.handleDisconnect();
      },
      onError: () => {
        // onClose follows and drives the reconnect; no separate handling.
      },
    });

    this.terminal.open(options.container);
    this.applyPageBackground(theme.colors.background);
    this.attachWebgl();
    this.registerKittyHandlers();
    this.registerCwdHandlers();
    this.wireInput();
    this.wireClipboard();
    this.wireSearch();
    this.wireSettings();
    this.wireShare();
    this.wireResize(options.container);
    this.wireReconnectTriggers();

    // A known session id (reload, or a `/?session=` link) has its title ready
    // before the daemon answers, so the tab does not flash a fallback name.
    this.loadTabTitleForSession();
    this.refreshTitle();
    window.addEventListener("storage", this.onStorage);
    this.setConnectionState("reconnecting");
    this.connect();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    // Write any title typed in the last few hundred milliseconds.
    this.persistTabTitle();
    this.clearReconnectTimer();
    window.removeEventListener("storage", this.onStorage);
    this.resizeObserver?.disconnect();
    this.settingsPanel?.dispose();
    this.session.close();
    this.terminal.dispose();
  }

  // MARK: Reconnect

  private connect(): void {
    this.lastConnectAt = Date.now();
    const params = new URLSearchParams();
    if (this.deepLinkPending && this.requestedCwd) {
      params.set("cwd", this.requestedCwd);
    } else if (this.sessionId) {
      params.set("session", this.sessionId);
      if (!this.hasEverConnected) {
        params.set("fresh", "1");
      }
    }
    const query = params.toString();
    this.session.connect(query ? `${defaultWsUrl()}?${query}` : defaultWsUrl());
  }

  private handleDisconnect(): void {
    if (this.disposed || this.exited) return;
    this.setStatus("Reconnecting…");
    this.setConnectionState("reconnecting");
    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== null) return;
    const delay = Math.min(10_000, 500 * 2 ** this.reconnectAttempt);
    this.reconnectAttempt += 1;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      if (!this.disposed && !this.exited && !this.session.ready) {
        // A failed attempt fires onClose, which schedules the next retry.
        this.connect();
      }
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== null) {
      window.clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  /** Focus / tab visibility / network-online reconnect immediately. */
  private wireReconnectTriggers(): void {
    const tryNow = () => {
      if (this.disposed || this.exited || this.session.ready) return;
      if (Date.now() - this.lastConnectAt < 500) return;
      this.clearReconnectTimer();
      this.reconnectAttempt = 0;
      this.setStatus("Reconnecting…");
      this.connect();
    };
    const clearUnread = () => {
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
  }

  private attachWebgl(): void {
    try {
      const webgl = new WebglAddon();
      webgl.onContextLoss(() => {
        webgl.dispose();
        this.webglAddon = null;
      });
      this.terminal.loadAddon(webgl);
      this.webglAddon = webgl;
    } catch {
      // Canvas fallback.
    }
  }

  private wireSettings(): void {
    if (!this.settingsRoot) return;
    this.settingsPanel = new SettingsPanel(this.settingsRoot, this.settings, {
      onThemeChange: (themeId) => this.applyTheme(themeId),
      onFontChange: (fontId) => this.applyFont(fontId),
      onLocalFontFamilyChange: (family) => this.applyLocalFont(family),
      onFontSizeChange: (fontSize) => this.applyFontSize(fontSize),
      onTabTitleChange: (title) => this.applyTabTitle(title),
      onTabTitleShowFolderChange: (showFolder) =>
        this.applyTabTitleShowFolder(showFolder),
    });
  }

  private applyTabTitle(title: string): void {
    if (this.readOnly) return;
    this.settings = { ...this.settings, tabTitle: title };
    this.refreshTitle();
    // Typing repaints the title immediately but writes storage at most once
    // per burst: each write parses and re-serialises the session map and
    // wakes every other kitterm tab with a `storage` event.
    this.scheduleTabTitlePersist();
  }

  private applyTabTitleShowFolder(showFolder: boolean): void {
    if (this.readOnly) return;
    this.settings = { ...this.settings, tabTitleShowFolder: showFolder };
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

  /** Controller-only: the title belongs to the session, so an observer tab
   * must never write it back. */
  private persistTabTitle(): void {
    if (this.tabTitlePersistTimer !== null) {
      window.clearTimeout(this.tabTitlePersistTimer);
      this.tabTitlePersistTimer = null;
    }
    if (this.readOnly || !this.sessionId) return;
    saveTabTitle(this.sessionId, {
      tabTitle: this.settings.tabTitle,
      tabTitleShowFolder: this.settings.tabTitleShowFolder,
    });
  }

  /** Adopt the session's stored title — for an observer this is the title its
   * controller set. */
  private loadTabTitleForSession(): void {
    const prefs = this.sessionId
      ? loadTabTitle(this.sessionId)
      : { ...DEFAULT_TAB_TITLE };
    if (
      prefs.tabTitle === this.settings.tabTitle &&
      prefs.tabTitleShowFolder === this.settings.tabTitleShowFolder
    ) {
      return;
    }
    this.settings = { ...this.settings, ...prefs };
    this.settingsPanel?.syncTabTitle(this.settings);
    this.refreshTitle();
  }

  /** Mirror the controller's edits into observer tabs of the same browser.
   * `storage` fires only in other tabs, so this never echoes our own write. */
  private readonly onStorage = (event: StorageEvent): void => {
    if (!isTabTitleStorageEvent(event)) return;
    this.loadTabTitleForSession();
  };

  /** Copy `/?session=<id>` — open in another window/device to observe live. */
  private wireShare(): void {
    if (!this.settingsRoot) return;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "share-button";
    button.title = "Copy session link";
    button.setAttribute("aria-label", "Copy session link");
    button.textContent = "⧉";
    button.addEventListener("click", () => {
      if (!this.sessionId) return;
      void this.buildShareLink(this.sessionId).then(({ url, lan }) => {
        void navigator.clipboard.writeText(url).then(
          () => this.flashStatus(lan ? "LAN session link copied" : "Session link copied"),
          () => this.flashStatus(url, 8000),
        );
      });
    });
    this.settingsRoot.insertBefore(button, this.settingsRoot.firstChild);
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

  private applyTheme(themeId: TerminalThemeId): void {
    const theme = findThemeById(themeId);
    this.settings = { ...this.settings, themeId: theme.id };
    this.terminal.options.theme = theme.colors;
    this.applyPageBackground(theme.colors.background);
    saveThemeId(theme.id);
    this.settingsPanel?.sync(this.settings);
  }

  private applyFont(fontId: TerminalFontId): void {
    this.settings = { ...this.settings, fontId };
    this.terminal.options.fontFamily = resolveFontFamily(
      fontId,
      this.settings.localFontFamily,
    );
    this.remeasureAndFit();
    saveFontId(fontId);
    this.settingsPanel?.sync(this.settings);
  }

  private applyLocalFont(family: string): void {
    const trimmed = family.trim();
    if (!trimmed) return;
    this.settings = {
      ...this.settings,
      fontId: LOCAL_FONT_ID,
      localFontFamily: trimmed,
    };
    this.terminal.options.fontFamily = resolveFontFamily(LOCAL_FONT_ID, trimmed);
    this.remeasureAndFit();
    saveFontId(LOCAL_FONT_ID);
    saveLocalFontFamily(trimmed);
    this.settingsPanel?.sync(this.settings);
  }

  private applyFontSize(fontSize: number): void {
    this.settings = { ...this.settings, fontSize };
    this.terminal.options.fontSize = fontSize;
    this.remeasureAndFit();
    saveFontSize(fontSize);
    this.settingsPanel?.sync(this.settings);
  }

  private remeasureAndFit(): void {
    try {
      this.webglAddon?.clearTextureAtlas();
    } catch {
      /* addon may already be disposed */
    }
    this.fitAndResize();
  }

  private applyPageBackground(background: string | undefined): void {
    const color = background ?? "#0d1117";
    document.documentElement.style.background = color;
    document.body.style.background = color;
    const app = document.getElementById("app");
    if (app) app.style.background = color;
  }

  private registerKittyHandlers(): void {
    this.terminal.parser.registerCsiHandler({ prefix: ">", final: "u" }, (params) => {
      const first = params[0];
      const flags = typeof first === "number" ? first : 1;
      this.kitty.push(flags);
      return true;
    });
    this.terminal.parser.registerCsiHandler({ prefix: "<", final: "u" }, (params) => {
      const first = params[0];
      const count = typeof first === "number" && first > 0 ? first : 1;
      this.kitty.pop(count);
      return true;
    });
    this.terminal.parser.registerCsiHandler({ prefix: "=", final: "u" }, (params) => {
      const first = params[0];
      const second = params[1];
      if (typeof first !== "number") return true;
      const mode =
        typeof second === "number" && second > 0 ? second : KITTY_KEYBOARD_SET_MODE_REPLACE;
      if (
        mode === KITTY_KEYBOARD_SET_MODE_REPLACE ||
        mode === KITTY_KEYBOARD_SET_MODE_OR ||
        mode === KITTY_KEYBOARD_SET_MODE_AND_NOT
      ) {
        this.kitty.set(first, mode);
      }
      return true;
    });
  }

  private wireInput(): void {
    this.terminal.onData((data) => {
      if (!this.exited && !this.readOnly) {
        this.session.sendInput(data);
      }
    });

    this.terminal.attachCustomKeyEventHandler((event) => {
      if (event.type !== "keydown") {
        return true;
      }

      const key = event.key.toLowerCase();

      // Ctrl+C → always send ETX (\x03) ourselves. Returning true and relying on
      // xterm is unreliable when a selection exists or the browser/OS interferes;
      // explicit send matches a real terminal's SIGINT path (verified via WS).
      // Copy remains ⌘C / Ctrl+Shift+C only — never bare Ctrl+C.
      if (
        event.ctrlKey &&
        !event.metaKey &&
        !event.altKey &&
        !event.shiftKey &&
        (key === "c" || event.code === "KeyC")
      ) {
        event.preventDefault();
        this.terminal.clearSelection();
        if (!this.exited && !this.readOnly) {
          this.session.sendInput("\x03");
        }
        return false;
      }

      // Find: ⌘F on macOS, Ctrl+Shift+F elsewhere (avoid stealing Ctrl+F from apps).
      const isFind =
        (event.metaKey && !event.ctrlKey && !event.shiftKey && key === "f") ||
        (event.ctrlKey && event.shiftKey && !event.metaKey && key === "f");
      if (isFind) {
        event.preventDefault();
        this.openSearch();
        return false;
      }

      // Copy selection: ⌘C, or Ctrl+Shift+C — never bare Ctrl+C.
      const isCopy =
        (event.metaKey && !event.ctrlKey && key === "c") ||
        (event.ctrlKey && event.shiftKey && !event.metaKey && key === "c");
      if (isCopy) {
        const selection = this.terminal.getSelection();
        if (selection) {
          event.preventDefault();
          void navigator.clipboard.writeText(selection).catch(() => {});
          return false;
        }
      }

      // Paste: ⌘V / Ctrl+Shift+V (plain Ctrl+V left to the browser/xterm path).
      const isPaste =
        (event.metaKey && !event.ctrlKey && key === "v") ||
        (event.ctrlKey && event.shiftKey && !event.metaKey && key === "v");
      if (isPaste) {
        event.preventDefault();
        void navigator.clipboard
          .readText()
          .then((text) => {
            if (text && !this.exited && !this.readOnly) {
              this.session.sendInput(text);
            }
          })
          .catch(() => {});
        return false;
      }

      if (event.key !== "Enter") {
        return true;
      }
      const modifierBits = extractKeyboardModifiers(event);
      if (modifierBits !== 0 && this.kitty.disambiguateActive) {
        event.preventDefault();
        this.session.sendInput(buildKittyKeySequence(ENTER_KEY_CODE, modifierBits));
        return false;
      }
      if (modifierBits === KEYBOARD_MODIFIER_SHIFT_BIT) {
        event.preventDefault();
        this.session.sendInput("\n");
        return false;
      }
      return true;
    });
  }

  private wireClipboard(): void {
    // Middle-click paste when clipboard read is permitted.
    this.terminal.element?.addEventListener("mousedown", (event) => {
      if (event.button !== 1 || this.exited || this.readOnly) return;
      event.preventDefault();
      void navigator.clipboard
        .readText()
        .then((text) => {
          if (text) this.session.sendInput(text);
        })
        .catch(() => {});
    });
  }

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

  private closeSearch(): void {
    if (!this.searchRoot) return;
    this.searchRoot.hidden = true;
    this.searchAddon.clearDecorations();
    this.terminal.focus();
  }

  private find(direction: "next" | "prev"): void {
    const term = this.searchInput?.value ?? "";
    if (!term) return;
    if (direction === "next") {
      this.searchAddon.findNext(term, { caseSensitive: false });
    } else {
      this.searchAddon.findPrevious(term, { caseSensitive: false });
    }
  }

  private wireResize(container: HTMLElement): void {
    this.resizeObserver = new ResizeObserver(() => {
      this.fitAndResize();
    });
    this.resizeObserver.observe(container);
    window.addEventListener("resize", () => this.fitAndResize());
  }

  private fitAndResize(): void {
    // Observers render at the controller's size; never fight it locally.
    if (this.disposed || this.exited || this.readOnly) return;
    try {
      this.fitAddon.fit();
    } catch {
      return;
    }
    const cols = this.terminal.cols;
    const rows = this.terminal.rows;
    if (cols > 0 && rows > 0 && this.session.ready) {
      this.session.sendResize(cols, rows);
    }
  }

  private handleFrame(frame: import("./protocol").ServerFrame): void {
    switch (frame.type) {
      case "output": {
        const bytes = frame.data.byteLength;
        this.flowControl.enqueue(bytes);
        this.terminal.write(frame.data, () => this.flowControl.dequeue(bytes));
        if (document.hidden && !this.unreadOutput) {
          this.unreadOutput = true;
          this.updateFavicon();
        }
        break;
      }
      case "sessionId": {
        const replaced =
          !this.deepLinkPending &&
          this.sessionId !== null &&
          this.sessionId !== frame.id;
        this.deepLinkPending = false;
        this.sessionId = frame.id;
        storeSessionId(frame.id);
        if (replaced) {
          // The shell died and a new one took its place. The tab is still the
          // user's "Deploy" tab, so carry the name across rather than silently
          // reverting to the folder.
          this.persistTabTitle();
        } else {
          // A reload restores this session's title; an observer adopts the
          // controller's.
          this.loadTabTitleForSession();
        }
        if (window.location.search) {
          // Session established — drop deep-link params from the address bar.
          window.history.replaceState({}, "", window.location.pathname);
        }
        if (replaced) {
          this.flashStatus("Previous shell ended — started a new shell");
        }
        break;
      }
      case "role":
        this.readOnly = frame.role === "observer";
        // Renaming the tab is part of controlling the session.
        this.settingsPanel?.setTabTitleEditable(!this.readOnly);
        if (this.readOnly) {
          this.setStatus("Observing — read-only");
        } else {
          this.setStatus(null);
          this.fitAndResize();
        }
        break;
      case "resize":
        if (this.readOnly && frame.cols > 0 && frame.rows > 0) {
          this.terminal.resize(frame.cols, frame.rows);
        }
        break;
      case "title":
        // Legacy frame: current daemons no longer send it. The tab title comes
        // from the custom name plus the cwd, so there is nothing to do.
        break;
      case "cwd":
        if (frame.cwd) this.setFolderFromCwd(frame.cwd);
        break;
      case "sessionMeta":
        if (frame.meta.cwd) this.setFolderFromCwd(frame.meta.cwd);
        break;
      case "exit":
        this.exited = true;
        clearStoredSessionId();
        this.setStatus(`Shell exited (${frame.code}) — reload for a new shell`);
        this.setConnectionState("exited");
        this.session.close();
        break;
    }
  }

  /** Live folder source: the shell's own OSC sequences, already parsed by
   * xterm. The handlers return false so xterm's default handling is untouched,
   * and they fire about once per prompt — not per output chunk.
   *
   * OSC 7 is free: xterm buffers an OSC payload only while a handler is
   * registered for that id, and OSC 7 payloads are one path.
   *
   * OSC 1337 is not free. iTerm2 shares that id between shell integration
   * (`CurrentDir=`, tiny) and inline images (`File=`, megabytes), so keeping a
   * handler on it would make xterm accumulate every `imgcat`/matplotlib image
   * into a string just to discard it. We therefore drop the handler the first
   * time a payload is clearly not shell integration: the cost is bounded to
   * one sequence per page, and cwd tracking falls back to OSC 7 and the
   * daemon's attach-time cwd. */
  private registerCwdHandlers(): void {
    this.terminal.parser.registerOscHandler(7, (data) => {
      const cwd = cwdFromOsc7(data);
      if (cwd) this.setFolderFromCwd(cwd);
      return false;
    });

    const iterm = this.terminal.parser.registerOscHandler(1337, (data) => {
      const cwd = cwdFromOsc1337(data);
      if (cwd) {
        this.setFolderFromCwd(cwd);
      } else if (data.length > ITERM_OSC_PAYLOAD_LIMIT) {
        // An image (or similar bulk payload) — stop paying to buffer them.
        iterm.dispose();
      }
      return false;
    });
  }

  private setFolderFromCwd(cwd: string): void {
    const folder = folderFromCwd(cwd);
    if (folder === this.folder) return;
    this.folder = folder;
    this.refreshTitle();
  }

  private refreshTitle(): void {
    const title = composeTabTitle({
      custom: this.settings.tabTitle,
      showFolder: this.settings.tabTitleShowFolder,
      folder: this.folder,
    });
    if (title === this.lastTitle) return;
    this.lastTitle = title;
    document.title = title;
  }

  private setConnectionState(state: FaviconState): void {
    this.connectionState = state;
    this.updateFavicon();
  }

  private updateFavicon(): void {
    setFavicon(this.connectionState, this.unreadOutput);
  }

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

  private flashStatus(message: string, durationMs: number = 4000): void {
    this.setStatus(message);
    this.statusClearTimer = window.setTimeout(() => {
      this.statusClearTimer = null;
      this.setStatus(null);
    }, durationMs);
  }
}

const SESSION_ID_KEY = "kitterm:session-id";

/** sessionStorage is per-tab: it preserves "tab = shell" across reloads. */
function readStoredSessionId(): string | null {
  try {
    return sessionStorage.getItem(SESSION_ID_KEY);
  } catch {
    return null;
  }
}

function storeSessionId(id: string): void {
  try {
    sessionStorage.setItem(SESSION_ID_KEY, id);
  } catch {
    // private mode — reattach still works within this page's lifetime
  }
}

function clearStoredSessionId(): void {
  try {
    sessionStorage.removeItem(SESSION_ID_KEY);
  } catch {
    // ignore
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
