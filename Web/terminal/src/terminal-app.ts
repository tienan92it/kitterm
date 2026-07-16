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
import { KittermSession } from "./session";
import { githubDarkTheme } from "./theme-github-dark";

export type TerminalAppOptions = {
  container: HTMLElement;
  statusEl?: HTMLElement | null;
  searchRoot?: HTMLElement | null;
};

export class TerminalApp {
  private readonly terminal: Terminal;
  private readonly fitAddon: FitAddon;
  private readonly searchAddon: SearchAddon;
  private readonly session: KittermSession;
  private readonly kitty = new KittyFlagStack();
  private readonly statusEl: HTMLElement | null;
  private readonly searchRoot: HTMLElement | null;
  private searchInput: HTMLInputElement | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private disposed = false;
  private exited = false;
  constructor(options: TerminalAppOptions) {
    this.statusEl = options.statusEl ?? null;
    this.searchRoot = options.searchRoot ?? null;
    this.terminal = new Terminal({
      allowProposedApi: true,
      cursorBlink: true,
      fontFamily: "Menlo, Monaco, 'Courier New', monospace",
      fontSize: 13,
      scrollback: 10_000,
      theme: githubDarkTheme,
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
    this.attachWebgl();
    this.registerKittyHandlers();
    this.wireInput();
    this.wireClipboard();
    this.wireSearch();
    this.wireResize(options.container);

    this.session.connect();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.resizeObserver?.disconnect();
    this.session.close();
    this.terminal.dispose();
  }

  private attachWebgl(): void {
    try {
      const webgl = new WebglAddon();
      webgl.onContextLoss(() => webgl.dispose());
      this.terminal.loadAddon(webgl);
    } catch {
      // Canvas fallback.
    }
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

      const meta = event.metaKey || event.ctrlKey;

      if (meta && !event.shiftKey && event.key.toLowerCase() === "f") {
        event.preventDefault();
        this.openSearch();
        return false;
      }

      // Copy selection: ⌘/Ctrl+C or ⌘/Ctrl+Shift+C when text is selected.
      if (meta && event.key.toLowerCase() === "c") {
        const selection = this.terminal.getSelection();
        if (selection) {
          event.preventDefault();
          void navigator.clipboard.writeText(selection).catch(() => {});
          return false;
        }
      }
      // Explicit paste: ⌘/Ctrl+Shift+V (plain ⌘V still uses the browser paste → onData path).
      if (meta && event.shiftKey && event.key.toLowerCase() === "v") {
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
      case "output":
        this.terminal.write(frame.data);
        break;
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
