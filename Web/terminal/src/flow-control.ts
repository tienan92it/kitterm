/**
 * Client→server flow control for PTY output.
 *
 * xterm.js parses asynchronously; without backpressure a large burst (e.g.
 * `cat` of a big file) accumulates unbounded in its write queue — memory grows
 * and Ctrl+C feels ignored while buffered output drains. We count bytes queued
 * vs. parsed and ask the daemon to pause PTY reads past the high watermark,
 * resuming below the low watermark (the daemon then blocks the shell's writes
 * at the kernel PTY buffer).
 *
 * The count only comes down when xterm reports bytes parsed, so a write
 * callback that never arrives — the renderer being torn down and rebuilt after
 * a lost WebGL context is one way — leaves the count permanently high and the
 * stream paused for good. The tab then looks dead: no output, a frozen cursor,
 * and typing that goes nowhere until it is reloaded. So a pause is never
 * allowed to be permanent; if one stops making progress, it is abandoned.
 * Guessing wrong costs some buffering, while staying paused costs the session.
 */

export const FLOW_HIGH_WATER_BYTES = 512 * 1024;
export const FLOW_LOW_WATER_BYTES = 128 * 1024;
/** How long a pause may make no progress before it is treated as stuck. */
export const FLOW_STALL_MS = 5000;

export type FlowControlCallbacks = {
  onPause: () => void;
  onResume: () => void;
};

export class OutputFlowControl {
  private pending = 0;
  private paused = false;

  private stallTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly callbacks: FlowControlCallbacks,
    private readonly highWater = FLOW_HIGH_WATER_BYTES,
    private readonly lowWater = FLOW_LOW_WATER_BYTES,
    private readonly stallMs = FLOW_STALL_MS,
  ) {}

  get isPaused(): boolean {
    return this.paused;
  }

  get pendingBytes(): number {
    return this.pending;
  }

  /** Call when output bytes are handed to the terminal for parsing. */
  enqueue(bytes: number): void {
    this.pending += bytes;
    if (!this.paused && this.pending > this.highWater) {
      this.paused = true;
      this.armStallTimer();
      this.callbacks.onPause();
    }
  }

  /** Call when the terminal reports those bytes as parsed. */
  dequeue(bytes: number): void {
    this.pending = Math.max(0, this.pending - bytes);
    if (!this.paused) return;
    if (this.pending <= this.lowWater) {
      this.resume();
      return;
    }
    // Still above the low water mark, but parsing is progressing, so the
    // pause is doing its job — give it another window.
    this.armStallTimer();
  }

  /** Give up on a pause that has stopped making progress. */
  private forceResume(): void {
    if (!this.paused) return;
    // The count is untrustworthy — the bytes it is waiting on were never
    // reported parsed — so start again rather than resume into a stale total.
    this.pending = 0;
    this.resume();
  }

  private resume(): void {
    this.paused = false;
    this.clearStallTimer();
    this.callbacks.onResume();
  }

  private armStallTimer(): void {
    this.clearStallTimer();
    this.stallTimer = setTimeout(() => {
      this.stallTimer = null;
      this.forceResume();
    }, this.stallMs);
  }

  private clearStallTimer(): void {
    if (this.stallTimer !== null) {
      clearTimeout(this.stallTimer);
      this.stallTimer = null;
    }
  }

  /** New connection: server-side pause state is fresh, so mirror it. */
  reset(): void {
    this.pending = 0;
    this.paused = false;
    this.clearStallTimer();
  }

  /** Stop the watchdog when the pane goes away. */
  dispose(): void {
    this.clearStallTimer();
  }
}
