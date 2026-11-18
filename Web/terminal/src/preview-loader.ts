/**
 * The file preview loads apart from the entry, and before its first use.
 *
 * `file-preview.ts` brings the Markdown view and the highlighter with it. A
 * terminal paints without them, so the entry does not import them
 * (`entry-split.test.ts`). A load on first use alone is wrong for a page
 * that stays open: after an upgrade the daemon serves a new web root, the
 * old chunk name answers 404, and the preview fails on every open page
 * until a reload. So the page asks for the chunk by itself, when it is idle
 * after the first terminal output, and holds the module from then on.
 *
 * A use before that load starts the load at once, and the idle load then
 * finds it. A load that fails is forgotten, so the next use asks again: one
 * network fault does not leave the page without a preview.
 */

export interface LazyModule<T> {
  /** Tell the loader that terminal output arrived. The first call
   * schedules the idle load; each later call does nothing. */
  afterFirstOutput(): void;
  /** The module: the load in flight or done, or a new load. */
  use(): Promise<T>;
}

/** `load` is the dynamic `import()`. `whenIdle` runs its argument when the
 * page has nothing more urgent to do. */
export function lazyModule<T>(load: () => Promise<T>, whenIdle: (run: () => void) => void): LazyModule<T> {
  let pending: Promise<T> | null = null;
  let scheduled = false;

  const use = (): Promise<T> => {
    if (pending) return pending;
    const started = load();
    pending = started;
    started.catch(() => {
      if (pending === started) pending = null;
    });
    return started;
  };

  return {
    afterFirstOutput(): void {
      if (scheduled) return;
      scheduled = true;
      // The caller of the idle load is nobody: a use reports the failure.
      whenIdle(() => void use().catch(() => {}));
    },
    use,
  };
}

/** The longest wait for an idle period, so a busy page still loads the
 * preview in the first seconds. */
export const IDLE_TIMEOUT_MS = 2000;

/** Run `run` when the page is idle: `requestIdleCallback` with a timeout,
 * and a timer where the browser has none (Safari). */
export function whenPageIdle(run: () => void): void {
  if (typeof requestIdleCallback === "function") {
    requestIdleCallback(() => run(), { timeout: IDLE_TIMEOUT_MS });
  } else {
    setTimeout(run, 200);
  }
}

/** One loader for the page: every pane shows a preview from the same chunk. */
export const previewModule = lazyModule(() => import("./file-preview"), whenPageIdle);
