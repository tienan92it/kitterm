import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { UnicodeGraphemesAddon } from "@xterm/addon-unicode-graphemes";
import { WebglAddon } from "@xterm/addon-webgl";
import { Terminal, type IMarker } from "@xterm/xterm";
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
import type { FaviconState } from "./favicon";
import { OutputFlowControl } from "./flow-control";
import { resolveFontFamily } from "./fonts";
import { matchPaneCommand, type PaneCommand } from "./pane-keys";
import {
  MAX_MARK_COMMAND_BYTES,
  MarkKind,
  parseOsc133,
  parseOsc633,
  type ParsedMark,
} from "./command-marks";
import {
  Osc99Assembler,
  parseOsc9,
  parseOsc777,
  type TerminalNotification,
} from "./notifications";
import { type KeySpec, keyBytes } from "./extra-keys";
import type { PaneId } from "./pane-layout";
import { ReplayGuard } from "./replay-guard";
import {
  SwipeAccumulator,
  swipeTarget,
  swipeToInput,
} from "./touch-scroll";
import { KittermSession, defaultWsUrl } from "./session";
import type { KittermSettings } from "./settings-store";
import { findThemeById } from "./themes";
import { cwdFromOsc1337, cwdFromOsc7, folderFromCwd } from "./title";

/** Longest OSC 1337 payload still plausibly shell integration; anything above
 * this is bulk data (inline images) we must not keep buffering for. */
const ITERM_OSC_PAYLOAD_LIMIT = 4096;

/** Prompt markers kept per pane for ⌘↑/⌘↓ navigation. */
const MAX_PROMPT_MARKERS = 200;

/**
 * One shell: an xterm instance, its WebSocket, and its reconnect state.
 *
 * A pane owns nothing global. `document.title`, the favicon, `window`
 * listeners, the settings panel, and layout persistence all belong to the app
 * shell, which a pane reaches only through {@link PaneHost}. That separation is
 * what makes several panes able to coexist in one page: registering any of
 * those per pane would multiply the work by the pane count.
 */
export interface PaneHost {
  /** Shared across every pane; the shell owns persistence. */
  readonly settings: KittermSettings;
  /** Connection state or exit changed — the shell re-aggregates the favicon. */
  paneStateChanged(pane: TerminalPane): void;
  /** Output arrived; the shell decides whether that means "unread". */
  paneOutput(pane: TerminalPane): void;
  /** A program in this pane asked for attention (OSC 9/777/99). */
  paneAttention(pane: TerminalPane, note: TerminalNotification): void;
  /** Persistent status for this pane (surfaced when it is focused). */
  paneStatus(pane: TerminalPane, message: string | null): void;
  /** Transient toast from any pane, shown immediately. */
  paneFlash(message: string, durationMs?: number): void;
  /** The daemon named this pane's session. */
  paneSessionId(pane: TerminalPane, id: string, replaced: boolean): void;
  /** The shell's cwd changed — drives the tab title while focused. */
  paneFolderChanged(pane: TerminalPane): void;
  /** Controller/observer resolved. */
  paneRoleChanged(pane: TerminalPane): void;
  /** A pane keybinding fired. */
  paneCommand(pane: TerminalPane, command: PaneCommand): void;
  /** The user clicked into this pane. */
  paneFocusRequested(pane: TerminalPane): void;
  /** ⌘F inside this pane. */
  paneSearchRequested(pane: TerminalPane): void;
}

export type TerminalPaneOptions = {
  id: PaneId;
  container: HTMLElement;
  host: PaneHost;
  isMac: boolean;
  /** Reattach target; null spawns a fresh shell. */
  sessionId?: string | null;
  /** Where a fresh shell should start — also used when a reattach misses. */
  cwd?: string | null;
  /** Durable key selecting this pane's own history file on the daemon. */
  histKey?: string | null;
  /** `?cmd=N` — scroll to the N-th command once it is replayed. */
  commandScroll?: number | null;
};

export class TerminalPane {
  readonly id: PaneId;
  private readonly terminal: Terminal;
  private readonly fitAddon: FitAddon;
  private readonly searchAddon: SearchAddon;
  private readonly session: KittermSession;
  private readonly kitty = new KittyFlagStack();
  private readonly host: PaneHost;
  private readonly isMac: boolean;
  private webglAddon: WebglAddon | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private readonly flowControl = new OutputFlowControl({
    onPause: () => this.session.sendPause(),
    onResume: () => this.session.sendResume(),
  });
  private readonly replayGuard = new ReplayGuard();
  private readonly osc99 = new Osc99Assembler();
  /** 633;E command line awaiting its preExec mark. */
  private pendingCommandLine: string | null = null;
  /** The current replay window was announced with resync=1 (stale-screen
   * rebuild) — marks parsed from it were already reported once. */
  private replayIsResync = false;
  /** Markers on prompt lines for ⌘↑/⌘↓ navigation. */
  private promptMarkers: IMarker[] = [];
  /** A `?cmd=N` deep link to scroll to once the command appears. */
  private pendingCommandScroll: number | null;
  private sessionIdValue: string | null;
  /** Start directory for a fresh shell; kept so a respawn lands in the same
   * place after the daemon forgets the session. */
  private cwd: string | null;
  /** Durable per-pane history key, sent to the daemon as `?hist=`. */
  private readonly histKeyValue: string | null;
  private readOnlyValue = false;
  private folderValue: string | null = null;
  private reconnectTimer: number | null = null;
  private reconnectAttempt = 0;
  private lastConnectAt = 0;
  /** False until the first successful connect of this pane's lifetime.
   * A fresh pane has no terminal content, so reattach asks the daemon to
   * replay the recent tail (otherwise an idle shell shows a bare cursor). */
  private hasEverConnected = false;
  /** Absolute session-log offset of the next output byte this pane expects.
   * Counted on receive and re-anchored by each `logState` frame; sent back
   * as `?since=` so a reconnect replays exactly the missed bytes. */
  private outputBytes = 0;
  private connectionStateValue: FaviconState = "reconnecting";
  private disposed = false;
  private exitedValue = false;
  /** Coalesces a burst of ResizeObserver callbacks into one fit per frame. */
  private fitHandle: number | null = null;

  constructor(options: TerminalPaneOptions) {
    this.id = options.id;
    this.host = options.host;
    this.isMac = options.isMac;
    this.sessionIdValue = options.sessionId ?? null;
    this.cwd = options.cwd ?? null;
    this.histKeyValue = options.histKey ?? null;
    this.pendingCommandScroll = options.commandScroll ?? null;

    const settings = this.host.settings;
    const theme = findThemeById(settings.themeId);

    this.terminal = new Terminal({
      allowProposedApi: true,
      cursorBlink: true,
      fontFamily: resolveFontFamily(settings.fontId, settings.localFontFamily),
      fontSize: settings.fontSize,
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
        this.host.paneStatus(this, null);
        this.setConnectionState("connected");
        this.scheduleFit();
        this.scheduleCommandScrollFallback();
      },
      onFrame: (frame) => this.handleFrame(frame),
      onClose: () => this.handleDisconnect(),
      onError: () => {
        // onClose follows and drives the reconnect; no separate handling.
      },
    });

    this.terminal.open(options.container);
    this.registerKittyHandlers();
    this.registerCwdHandlers();
    this.registerMarkHandlers();
    this.registerNotifyHandlers();
    this.wireInput();
    this.wireClipboard();
    this.wireTouch();
    this.wireResize(options.container);
    this.setConnectionState("reconnecting");
  }

  // MARK: Accessors used by the shell

  get sessionId(): string | null {
    return this.sessionIdValue;
  }

  get lastCwd(): string | null {
    return this.cwd;
  }

  get histKey(): string | null {
    return this.histKeyValue;
  }

  get folder(): string | null {
    return this.folderValue;
  }

  get readOnly(): boolean {
    return this.readOnlyValue;
  }

  get exited(): boolean {
    return this.exitedValue;
  }

  get connectionState(): FaviconState {
    return this.connectionStateValue;
  }

  focus(): void {
    this.terminal.focus();
  }

  /** Deliver a key from the on-screen extra-keys row, respecting the app's
   * cursor-keys mode. Keeps the terminal focused so the keyboard stays up. */
  sendExtraKey(spec: KeySpec): void {
    if (this.exitedValue || this.readOnlyValue) return;
    const bytes = keyBytes(spec, this.terminal.modes.applicationCursorKeysMode);
    if (bytes) this.session.sendInput(bytes);
    this.terminal.focus();
  }

  blur(): void {
    this.terminal.blur();
  }

  /** Start connecting. Separate from the constructor so the shell can stagger
   * a restored layout instead of opening N sockets in the same tick. */
  start(delayMs = 0): void {
    if (delayMs <= 0) {
      this.connect();
      return;
    }
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      if (!this.disposed) this.connect();
    }, delayMs);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.clearReconnectTimer();
    if (this.fitHandle !== null) cancelAnimationFrame(this.fitHandle);
    this.resizeObserver?.disconnect();
    this.releaseWebgl();
    this.session.close();
    this.terminal.dispose();
  }

  // MARK: Settings, applied by the shell to every pane

  applySettings(settings: KittermSettings): void {
    const theme = findThemeById(settings.themeId);
    this.terminal.options.theme = theme.colors;
    this.terminal.options.fontFamily = resolveFontFamily(
      settings.fontId,
      settings.localFontFamily,
    );
    this.terminal.options.fontSize = settings.fontSize;
    this.remeasureAndFit();
  }

  private remeasureAndFit(): void {
    try {
      this.webglAddon?.clearTextureAtlas();
    } catch {
      /* addon may already be disposed */
    }
    this.scheduleFit();
  }

  // MARK: WebGL, rationed by the shell

  attachWebgl(): boolean {
    if (this.webglAddon || this.disposed) return this.webglAddon !== null;
    try {
      const webgl = new WebglAddon();
      webgl.onContextLoss(() => {
        webgl.dispose();
        this.webglAddon = null;
      });
      this.terminal.loadAddon(webgl);
      this.webglAddon = webgl;
      return true;
    } catch {
      return false; // DOM renderer fallback
    }
  }

  releaseWebgl(): void {
    if (!this.webglAddon) return;
    try {
      this.webglAddon.dispose();
    } catch {
      /* already gone */
    }
    this.webglAddon = null;
  }

  // MARK: Search, driven by the shell's single search bar

  findNext(term: string): void {
    this.searchAddon.findNext(term, { caseSensitive: false });
  }

  findPrevious(term: string): void {
    this.searchAddon.findPrevious(term, { caseSensitive: false });
  }

  clearSearchDecorations(): void {
    this.searchAddon.clearDecorations();
  }

  // MARK: Connection

  private connect(): void {
    this.lastConnectAt = Date.now();
    const params = new URLSearchParams();
    if (this.sessionIdValue) {
      params.set("session", this.sessionIdValue);
      if (this.hasEverConnected) {
        // Mid-session reconnect: ask for exactly the bytes we missed.
        params.set("since", String(this.outputBytes));
      } else {
        params.set("fresh", "1");
      }
    }
    // Sent alongside a session id on purpose: the daemon reattaches when the
    // session is alive and otherwise spawns here, so a pane restored after a
    // daemon restart comes back in the folder it was in.
    if (this.cwd) params.set("cwd", this.cwd);
    // Selects this pane's own history file so up-arrow survives a restart.
    if (this.histKeyValue) params.set("hist", this.histKeyValue);
    const query = params.toString();
    this.session.connect(query ? `${defaultWsUrl()}?${query}` : defaultWsUrl());
  }

  /** Immediate retry on focus / visibility / network-online, driven by the
   * shell so one event does not fan out into N uncoordinated attempts. */
  reconnectNow(): void {
    if (this.disposed || this.exitedValue || this.session.ready) return;
    if (Date.now() - this.lastConnectAt < 500) return;
    this.clearReconnectTimer();
    this.reconnectAttempt = 0;
    this.host.paneStatus(this, "Reconnecting…");
    this.connect();
  }

  private handleDisconnect(): void {
    if (this.disposed || this.exitedValue) return;
    this.host.paneStatus(this, "Reconnecting…");
    this.setConnectionState("reconnecting");
    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== null) return;
    const delay = Math.min(10_000, 500 * 2 ** this.reconnectAttempt);
    this.reconnectAttempt += 1;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      if (!this.disposed && !this.exitedValue && !this.session.ready) {
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

  private setConnectionState(state: FaviconState): void {
    if (this.connectionStateValue === state) return;
    this.connectionStateValue = state;
    this.host.paneStateChanged(this);
  }

  // MARK: Sizing

  private wireResize(container: HTMLElement): void {
    this.resizeObserver = new ResizeObserver(() => this.scheduleFit());
    this.resizeObserver.observe(container);
  }

  /** Coalesce to one fit per frame: a splitter drag can fire the observer for
   * every pane many times per frame, and each fit measures the DOM and puts a
   * resize on the wire. */
  scheduleFit(): void {
    if (this.disposed || this.fitHandle !== null) return;
    this.fitHandle = requestAnimationFrame(() => {
      this.fitHandle = null;
      this.fitAndResize();
    });
  }

  private fitAndResize(): void {
    // Observers render at the controller's size; never fight it locally.
    if (this.disposed || this.exitedValue || this.readOnlyValue) return;
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

  // MARK: Frames

  private handleFrame(frame: import("./protocol").ServerFrame): void {
    switch (frame.type) {
      case "output": {
        const bytes = frame.data.byteLength;
        this.outputBytes += bytes;
        this.flowControl.enqueue(bytes);
        const generation = this.replayGuard.generation;
        this.terminal.write(frame.data, () => {
          this.flowControl.dequeue(bytes);
          this.replayGuard.onParsed(bytes, generation);
        });
        this.host.paneOutput(this);
        break;
      }
      case "logState":
        if (frame.resync) {
          // Stale screen (pruned offset or tail replay): clear before the
          // replay parses. Resetting an already-empty terminal is harmless.
          this.terminal.reset();
          this.kitty.reset();
        }
        this.outputBytes = frame.offset;
        this.replayIsResync = frame.resync;
        // A 633;E buffered on the old connection must not attach to the next
        // live command.
        this.pendingCommandLine = null;
        // Replayed bytes may contain device queries; swallow xterm's answers
        // to them until the whole replay window has parsed.
        this.replayGuard.arm(frame.replayLen);
        break;
      case "sessionId": {
        const replaced =
          this.sessionIdValue !== null && this.sessionIdValue !== frame.id;
        this.sessionIdValue = frame.id;
        this.host.paneSessionId(this, frame.id, replaced);
        if (replaced) {
          this.host.paneFlash("Previous shell ended — started a new shell");
        }
        break;
      }
      case "role":
        this.readOnlyValue = frame.role === "observer";
        this.host.paneRoleChanged(this);
        if (this.readOnlyValue) {
          this.host.paneStatus(this, "Observing — read-only");
        } else {
          this.host.paneStatus(this, null);
          this.scheduleFit();
        }
        break;
      case "resize":
        if (this.readOnlyValue && frame.cols > 0 && frame.rows > 0) {
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
        this.exitedValue = true;
        this.sessionIdValue = null;
        // The shell only surfaces this for the last pane; any other exiting
        // pane is closed and the message never shows.
        this.host.paneStatus(
          this,
          `Shell exited (${frame.code}) — reload for a new shell`,
        );
        this.setConnectionState("exited");
        this.session.close();
        this.host.paneStateChanged(this);
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

  /** OSC 133/633 shell-integration marks: the emulator is the parser, the
   * daemon only indexes what we report. Registered for every pane so the
   * handlers also see replayed bytes, but only the controller reports. */
  private registerMarkHandlers(): void {
    this.terminal.parser.registerOscHandler(133, (data) => {
      this.handleParsedMark(parseOsc133(data));
      return false;
    });
    this.terminal.parser.registerOscHandler(633, (data) => {
      this.handleParsedMark(parseOsc633(data));
      return false;
    });
  }

  /** OSC 9 / 777 / 99 desktop notifications: parsed here, surfaced by the
   * shell. Suppressed during replay so a reconnect does not re-fire a
   * notification the user already saw. */
  private registerNotifyHandlers(): void {
    const surface = (note: TerminalNotification | null) => {
      if (note && !this.replayGuard.active) this.host.paneAttention(this, note);
    };
    this.terminal.parser.registerOscHandler(9, (data) => {
      surface(parseOsc9(data));
      return false;
    });
    this.terminal.parser.registerOscHandler(777, (data) => {
      surface(parseOsc777(data));
      return false;
    });
    this.terminal.parser.registerOscHandler(99, (data) => {
      surface(this.osc99.feed(data));
      return false;
    });
  }

  private handleParsedMark(parsed: ParsedMark | null): void {
    if (!parsed) return;
    if (parsed.type === "commandLine") {
      // Attached to the next preExec mark rather than reported on its own.
      this.pendingCommandLine = parsed.command;
      return;
    }
    // Local navigation state first — observers and replayed bytes get
    // markers and decorations too; only the reporting below is gated.
    if (parsed.kind === MarkKind.promptStart) {
      this.addPromptMarker();
    } else if (
      parsed.kind === MarkKind.commandEnd &&
      parsed.exit !== null &&
      parsed.exit !== 0
    ) {
      this.decorateFailedCommand(parsed.exit);
    }
    // Consume a buffered 633;E even when the mark itself is not reported,
    // so a replayed command line cannot leak onto the next live command.
    let command: string | null = null;
    if (parsed.kind === MarkKind.preExec && this.pendingCommandLine) {
      command = this.pendingCommandLine;
      this.pendingCommandLine = null;
      // The daemon rejects oversized command lines; keep the mark, drop the
      // text, rather than losing the mark to a byte-cap violation.
      if (new TextEncoder().encode(command).byteLength > MAX_MARK_COMMAND_BYTES) {
        command = null;
      }
    }
    if (this.readOnlyValue || this.exitedValue) return;
    // A resync replay re-covers bytes a previous connection already parsed
    // and reported — re-reporting them would duplicate marks in the daemon's
    // index. Gap replays (resync=0) are bytes nobody reported; keep those.
    if (this.replayGuard.active && this.replayIsResync) return;
    this.session.sendMark(parsed.kind, parsed.exit, this.outputBytes, command);
  }

  /** Prompt lines, oldest first; markers dispose themselves as their lines
   * scroll out of the buffer. */
  private addPromptMarker(): void {
    const marker = this.terminal.registerMarker(0);
    if (!marker) return;
    this.promptMarkers = this.promptMarkers.filter((m) => !m.isDisposed);
    this.promptMarkers.push(marker);
    while (this.promptMarkers.length > MAX_PROMPT_MARKERS) {
      this.promptMarkers.shift()?.dispose();
    }
    // A `?cmd=N` deep link waits for the command to appear as its prompt is
    // replayed, then scrolls to it exactly.
    if (
      this.pendingCommandScroll !== null &&
      this.commandCount >= this.pendingCommandScroll
    ) {
      const target = this.pendingCommandScroll;
      this.pendingCommandScroll = null;
      this.scrollToCommand(target);
    }
  }

  /** Prompt markers still in the buffer, oldest first — one per command. */
  private get liveMarkers(): IMarker[] {
    return this.promptMarkers.filter((m) => !m.isDisposed);
  }

  /** Number of commands currently addressable in this pane's buffer. */
  get commandCount(): number {
    return this.liveMarkers.length;
  }

  /** A shareable link to command `index` (1-based) in this session. */
  commandLink(index: number): string | null {
    if (!this.sessionIdValue) return null;
    return `${location.origin}/?session=${encodeURIComponent(this.sessionIdValue)}&cmd=${index}`;
  }

  /** If a `?cmd=N` link asked for more commands than the replay produced,
   * scroll to the last one as a best effort once output has settled. */
  private scheduleCommandScrollFallback(): void {
    if (this.pendingCommandScroll === null) return;
    window.setTimeout(() => {
      if (this.pendingCommandScroll === null || this.disposed) return;
      const target = this.pendingCommandScroll;
      this.pendingCommandScroll = null;
      if (this.commandCount > 0) this.scrollToCommand(target);
    }, 1500);
  }

  /** Scroll to command `index` (1-based) and flash its prompt line. Indexing
   * is buffer-relative, so a link can outrun this pane's retained commands;
   * when that happens we land on the nearest one but say so, rather than
   * highlight the wrong line with confidence. */
  scrollToCommand(index: number): void {
    const markers = this.liveMarkers;
    const clamped = Math.min(index, markers.length);
    const marker = markers[clamped - 1];
    if (!marker) return;
    if (clamped !== index) {
      this.host.paneFlash("Linked command not in scrollback — showing nearest");
    }
    this.terminal.scrollToLine(marker.line);
    const decoration = this.terminal.registerDecoration({ marker });
    decoration?.onRender((element) => {
      element.classList.add("kitterm-cmd-target");
    });
    // The highlight is a cue, not a permanent mark.
    window.setTimeout(() => decoration?.dispose(), 2000);
  }

  /** ⌘↑ / ⌘↓ — scroll to the previous / next prompt line. */
  jumpToPrompt(direction: -1 | 1): void {
    const viewportTop = this.terminal.buffer.active.viewportY;
    const lines = this.promptMarkers
      .filter((m) => !m.isDisposed)
      .map((m) => m.line)
      .sort((a, b) => a - b);
    const target =
      direction === -1
        ? [...lines].reverse().find((line) => line < viewportTop)
        : lines.find((line) => line > viewportTop);
    if (target !== undefined) {
      this.terminal.scrollToLine(target);
    } else if (direction === 1) {
      this.terminal.scrollToBottom();
    }
  }

  /** A red dot on the failed command's prompt line; clicking it copies a
   * shareable link to that command. */
  private decorateFailedCommand(exit: number): void {
    const markers = this.liveMarkers;
    const marker = markers[markers.length - 1];
    if (!marker) return;
    const index = markers.length; // this command's 1-based position
    const decoration = this.terminal.registerDecoration({ marker });
    decoration?.onRender((element) => {
      element.classList.add("kitterm-cmd-failed");
      element.title = `exit ${exit} — click to copy a link to this command`;
      element.style.cursor = "pointer";
      element.onclick = (event) => {
        event.stopPropagation();
        this.copyCommandLink(index);
      };
    });
  }

  private copyCommandLink(index: number): void {
    const link = this.commandLink(index);
    if (!link) return;
    // Synchronous in the click handler so Safari's user-activation check holds.
    void navigator.clipboard.writeText(link).then(
      () => this.host.paneFlash("Command link copied"),
      () => this.host.paneFlash("Copy failed"),
    );
  }

  private setFolderFromCwd(cwd: string): void {
    this.cwd = cwd;
    const folder = folderFromCwd(cwd);
    if (folder === this.folderValue) return;
    this.folderValue = folder;
    this.host.paneFolderChanged(this);
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
      if (this.replayGuard.shouldDrop(data)) return;
      if (!this.exitedValue && !this.readOnlyValue) {
        this.session.sendInput(data);
      }
    });

    this.terminal.attachCustomKeyEventHandler((event) => {
      if (event.type !== "keydown") {
        return true;
      }

      // Pane chords first — matchPaneCommand only matches combinations no
      // terminal application can receive, so this cannot swallow a shell key.
      const command = matchPaneCommand(event, this.isMac);
      if (command) {
        event.preventDefault();
        this.host.paneCommand(this, command);
        return false;
      }

      // ⌘↑ / ⌘↓ — jump between prompt lines (needs shell-integration marks;
      // without any markers ⌘↓ still snaps to the bottom). macOS only: the
      // non-mac Ctrl+Shift+arrows are taken by pane navigation.
      if (
        this.isMac &&
        event.metaKey &&
        !event.altKey &&
        !event.ctrlKey &&
        !event.shiftKey &&
        (event.key === "ArrowUp" || event.key === "ArrowDown")
      ) {
        event.preventDefault();
        this.jumpToPrompt(event.key === "ArrowUp" ? -1 : 1);
        return false;
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
        if (!this.exitedValue && !this.readOnlyValue) {
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
        this.host.paneSearchRequested(this);
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

      // Paste (⌘V / Ctrl+V / Ctrl+Shift+V) is deliberately NOT intercepted:
      // the native paste event reaches xterm's textarea, which applies
      // bracketed paste (mode 2004) and newline normalization. Reading the
      // clipboard here and calling sendInput would bypass both, making
      // multi-line pastes execute line by line.

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

  /** Alt-screen-aware touch scrolling: on the normal screen xterm scrolls the
   * scrollback (default); on the alternate screen a swipe becomes the input
   * the app wants — mouse-wheel events or arrow keys — so vim/less/htop are
   * usable with a finger. */
  private wireTouch(): void {
    const element = this.terminal.element;
    if (!element) return;

    let lastY: number | null = null;
    let accumulator: SwipeAccumulator | null = null;

    element.addEventListener(
      "touchstart",
      (event) => {
        this.host.paneFocusRequested(this);
        if (event.touches.length !== 1) {
          lastY = null;
          return;
        }
        lastY = event.touches[0].clientY;
        // Cell height drives the step size; fall back to a sane default.
        const rowHeight =
          element.clientHeight > 0 && this.terminal.rows > 0
            ? element.clientHeight / this.terminal.rows
            : 18;
        accumulator = new SwipeAccumulator(rowHeight);
      },
      { passive: true },
    );

    element.addEventListener(
      "touchmove",
      (event) => {
        if (lastY === null || accumulator === null || event.touches.length !== 1) return;
        const target = swipeTarget(
          this.terminal.buffer.active.type === "alternate",
          this.terminal.modes.mouseTrackingMode !== "none",
        );
        // Let xterm handle scrollback on the normal screen.
        if (target === "scrollback") return;

        const y = event.touches[0].clientY;
        // feed() is down-positive: moving the finger down increases clientY.
        const steps = accumulator.feed(y - lastY);
        lastY = y;
        // We own this gesture now — stop xterm from also scrolling.
        event.preventDefault();
        if (steps === 0 || this.exitedValue || this.readOnlyValue) return;

        const cursor = {
          col: this.terminal.buffer.active.cursorX + 1,
          row: this.terminal.buffer.active.cursorY + 1,
        };
        const input = swipeToInput(
          target,
          steps,
          cursor,
          this.terminal.modes.applicationCursorKeysMode,
        );
        if (input) this.session.sendInput(input);
      },
      // Not passive: we call preventDefault on the alt screen.
      { passive: false },
    );

    const end = () => {
      lastY = null;
      accumulator = null;
    };
    element.addEventListener("touchend", end, { passive: true });
    element.addEventListener("touchcancel", end, { passive: true });
  }

  private wireClipboard(): void {
    const element = this.terminal.element;
    if (!element) return;

    // Clicking anywhere in the pane focuses it.
    element.addEventListener(
      "mousedown",
      () => this.host.paneFocusRequested(this),
      true,
    );

    // Middle-click paste when clipboard read is permitted. Delivered via
    // terminal.paste() so bracketed paste and newline normalization apply,
    // same as a keyboard paste.
    element.addEventListener("mousedown", (event) => {
      if (event.button !== 1 || this.exitedValue || this.readOnlyValue) return;
      event.preventDefault();
      void navigator.clipboard
        .readText()
        .then((text) => {
          if (text) this.terminal.paste(text);
        })
        .catch(() => {});
    });
  }
}
