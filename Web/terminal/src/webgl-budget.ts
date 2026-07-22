/**
 * Rations WebGL contexts across panes.
 *
 * Browsers cap WebGL contexts per page (commonly 8-16) and evict the *oldest*
 * when the cap is exceeded — so without a budget, opening a ninth pane could
 * silently kill the first pane's renderer. We keep a small number of contexts
 * on the panes most recently focused, which is where crisp rendering matters;
 * everything else falls back to xterm's DOM renderer, which looks identical and
 * is merely slower.
 */

const DEFAULT_MAX_CONTEXTS = 4;

export type WebglClient = {
  attachWebgl: () => boolean;
  releaseWebgl: () => void;
};

export class WebglBudget {
  /** Most-recently-focused last. */
  private readonly holders: string[] = [];
  private readonly clients = new Map<string, WebglClient>();

  constructor(private readonly max: number = DEFAULT_MAX_CONTEXTS) {}

  /** Give this pane a context, evicting the least-recently-focused if needed. */
  acquire(id: string, client: WebglClient): void {
    this.clients.set(id, client);
    if (this.holders.includes(id)) {
      this.touch(id);
      return;
    }
    while (this.holders.length >= this.max) {
      const evicted = this.holders.shift();
      if (evicted === undefined) break;
      this.clients.get(evicted)?.releaseWebgl();
    }
    if (client.attachWebgl()) {
      this.holders.push(id);
    }
  }

  /** Mark as most recently used without changing who holds a context. */
  touch(id: string): void {
    const index = this.holders.indexOf(id);
    if (index === -1) return;
    this.holders.splice(index, 1);
    this.holders.push(id);
  }

  release(id: string): void {
    const index = this.holders.indexOf(id);
    if (index !== -1) {
      this.holders.splice(index, 1);
      this.clients.get(id)?.releaseWebgl();
    }
    this.clients.delete(id);
  }

  get holderCount(): number {
    return this.holders.length;
  }
}
