/**
 * Holds a screen wake lock while a shell is connected, so a phone streaming a
 * long command's output doesn't sleep and drop the session — the most common
 * "my session died" complaint on mobile.
 *
 * The browser auto-releases the lock when the tab hides; we re-acquire it on
 * return. Side effects are injected so the policy is testable without the API.
 */

export type WakeSentinel = {
  release: () => Promise<void>;
  addEventListener: (type: "release", handler: () => void) => void;
};

export type WakeLockDeps = {
  /** Request a screen wake lock, or null where unsupported. */
  request: () => Promise<WakeSentinel | null>;
  /** The page is visible (a lock can only be held while visible). */
  isVisible: () => boolean;
};

export class WakeLockManager {
  private sentinel: WakeSentinel | null = null;
  private wanted = false;
  private acquiring = false;

  constructor(private readonly deps: WakeLockDeps) {}

  /** Whether a lock is desired (a shell is connected). */
  async setWanted(wanted: boolean): Promise<void> {
    this.wanted = wanted;
    if (wanted) await this.acquire();
    else await this.release();
  }

  /** Call on visibilitychange — re-acquire on return, since the browser drops
   * the lock while hidden. */
  async onVisibilityChange(): Promise<void> {
    if (this.deps.isVisible()) await this.acquire();
  }

  private async acquire(): Promise<void> {
    if (this.sentinel || this.acquiring) return;
    if (!this.wanted || !this.deps.isVisible()) return;
    this.acquiring = true;
    try {
      const sentinel = await this.deps.request();
      // State may have changed while awaiting.
      if (!sentinel) return;
      if (!this.wanted || !this.deps.isVisible()) {
        await sentinel.release().catch(() => {});
        return;
      }
      this.sentinel = sentinel;
      sentinel.addEventListener("release", () => {
        this.sentinel = null;
      });
    } catch {
      this.sentinel = null;
    } finally {
      this.acquiring = false;
    }
  }

  private async release(): Promise<void> {
    const held = this.sentinel;
    this.sentinel = null;
    if (held) await held.release().catch(() => {});
  }

  get held(): boolean {
    return this.sentinel !== null;
  }
}

/** Wire a manager to the real Screen Wake Lock API. */
export function createWakeLock(): WakeLockManager {
  const wakeLock = (navigator as Navigator & { wakeLock?: { request: (t: "screen") => Promise<WakeSentinel> } })
    .wakeLock;
  return new WakeLockManager({
    request: async () => {
      if (!wakeLock) return null;
      try {
        return await wakeLock.request("screen");
      } catch {
        return null;
      }
    },
    isVisible: () => document.visibilityState === "visible",
  });
}
