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
import { OutputFlowControl } from "./flow-control";
import { LOCAL_FONT_ID, resolveFontFamily, type TerminalFontId } from "./fonts";
import { KittermSession } from "./session";
import { SettingsPanel } from "./settings-panel";
import {
  loadSettings,
  saveFontId,
  saveFontSize,
  saveLocalFontFamily,
  saveThemeId,
  type KittermSettings,
} from "./settings-store";
import { findThemeById, type TerminalThemeId } from "./themes";

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
        this.setStatus(null);
        this.fitAndResize();
        this.terminal.focus();
      },
      onFrame: (frame) => this.handleFrame(frame),
      onClose: () => {
        if (!this.exited) {
          this.setStatus("Disconnected — reload for a new shell");
        }
      },
      onError: () => {
        this.setStatus("Connection error");
      },
    });

    this.terminal.open(options.container);
    this.applyPageBackground(theme.colors.background);
    this.attachWebgl();
    this.registerKittyHandlers();
    this.wireInput();
    this.wireClipboard();
    this.wireSearch();
    this.wireSettings();
    this.wireResize(options.container);

    this.session.connect();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.resizeObserver?.disconnect();
    this.settingsPanel?.dispose();
    this.session.close();
    this.terminal.dispose();
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
    });
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
      if (!this.exited) {
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
        if (!this.exited) {
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
            if (text && !this.exited) {
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
      if (event.button !== 1 || this.exited) return;
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
    if (this.disposed || this.exited) return;
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
        break;
      }
      case "title":
        if (frame.title.trim()) {
          document.title = `${frame.title} — kitterm`;
        }
        break;
      case "cwd":
        if (frame.cwd) {
          document.title = `${basename(frame.cwd)} — kitterm`;
        }
        break;
      case "sessionMeta":
        if (frame.meta.cwd) {
          document.title = `${basename(frame.meta.cwd)} — kitterm`;
        }
        break;
      case "exit":
        this.exited = true;
        this.setStatus(`Shell exited (${frame.code}) — reload for a new shell`);
        this.session.close();
        break;
    }
  }

  private setStatus(message: string | null): void {
    if (!this.statusEl) return;
    if (message) {
      this.statusEl.textContent = message;
      this.statusEl.hidden = false;
    } else {
      this.statusEl.textContent = "";
      this.statusEl.hidden = true;
    }
  }
}

function basename(path: string): string {
  const parts = path.replace(/\/+$/, "").split("/");
  return parts[parts.length - 1] || path;
}
