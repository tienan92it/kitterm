/**
 * Client→server flow control for PTY output.
 *
 * xterm.js parses asynchronously; without backpressure a large burst (e.g.
 * `cat` of a big file) accumulates unbounded in its write queue — memory grows
 * and Ctrl+C feels ignored while buffered output drains. We count bytes queued
 * vs. parsed and ask the daemon to pause PTY reads past the high watermark,
 * resuming below the low watermark (the daemon then blocks the shell's writes
 * at the kernel PTY buffer).
 */

export const FLOW_HIGH_WATER_BYTES = 512 * 1024;
export const FLOW_LOW_WATER_BYTES = 128 * 1024;

export type FlowControlCallbacks = {
  onPause: () => void;
  onResume: () => void;
};

export class OutputFlowControl {
  private pending = 0;
  private paused = false;

  constructor(
    private readonly callbacks: FlowControlCallbacks,
    private readonly highWater = FLOW_HIGH_WATER_BYTES,
    private readonly lowWater = FLOW_LOW_WATER_BYTES,
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
      this.callbacks.onPause();
    }
  }

  /** Call when the terminal reports those bytes as parsed. */
  dequeue(bytes: number): void {
    this.pending = Math.max(0, this.pending - bytes);
    if (this.paused && this.pending <= this.lowWater) {
      this.paused = false;
      this.callbacks.onResume();
    }
  }

  /** New connection: server-side pause state is fresh, so mirror it. */
  reset(): void {
    this.pending = 0;
    this.paused = false;
  }
}
