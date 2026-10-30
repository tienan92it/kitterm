/**
 * The boot decision of the terminal page, pure: which panes open from the
 * URL and the tab's stored layout, and what a running page stores back.
 *
 * `terminal-app.ts` reads the URL and the store and hands both here, so the
 * rule that a `/?session=` link opens one pane and never restores the tab's
 * saved splits can be checked without a DOM, and so can the reload after it.
 */

import type { PaneSession, StoredLayout } from "./layout-store";
import { leaf, paneIds, type LayoutNode, type PaneId } from "./pane-layout";

export type BootPlan = {
  root: LayoutNode;
  focus: PaneId;
  panes: Array<{ id: PaneId; session: PaneSession }>;
  /** A `/?session=` or `/?cwd=` link: one fresh pane, the stored layout not
   * read. The page persists this pane like any other once it has a session,
   * so a reload reattaches to the same shell. */
  linkBoot: boolean;
  /** `?cmd=N`, for the link-boot pane alone. */
  commandScroll: number | null;
  /** `?watch=1`: a watch-only link. */
  watch: boolean;
  /** The highest pane number the plan took, so the page's counter runs on
   * from it and a later split cannot collide with a restored id. */
  paneCounter: number;
};

export type BootInput = {
  /** `window.location.search`, with its leading `?` or empty. */
  search: string;
  /** The tab's stored layout; called only when no link opens the page. */
  loadLayout: () => StoredLayout | null;
  /** The pre-splits single-session key, consumed on read. */
  takeLegacySessionId: () => string | null;
  /** The page's pane counter before boot, 0 on a fresh page. */
  paneCounter?: number;
};

export function planBoot(input: BootInput): BootPlan {
  const params = new URLSearchParams(input.search);
  const linkSession = params.get("session");
  const linkCwd = params.get("cwd");
  const linkProfile = params.get("profile");
  const cmd = Number.parseInt(params.get("cmd") ?? "", 10);
  const commandScroll = Number.isFinite(cmd) && cmd > 0 ? cmd : null;
  const watch = params.get("watch") === "1";
  let paneCounter = input.paneCounter ?? 0;
  const nextPaneId = (): PaneId => {
    paneCounter += 1;
    return `p${paneCounter}`;
  };
  const single = (session: PaneSession, linkBoot: boolean): BootPlan => {
    const id = nextPaneId();
    return {
      root: leaf(id),
      focus: id,
      panes: [{ id, session }],
      linkBoot,
      commandScroll,
      watch,
      paneCounter,
    };
  };

  // A share link or a cwd deep link is always a single fresh pane, and does
  // not restore whatever layout this tab had saved. Once the pane has its
  // session the page stores this one-pane layout in the tab's place: the user
  // navigated to this session on purpose, the old shells still run on the
  // daemon, and a reload must reattach to the session they opened.
  if (linkSession || (linkCwd && !linkProfile)) {
    return single({ sessionId: linkSession, cwd: linkCwd ?? undefined }, true);
  }

  // A profile link seeds this tab's own layout: the pane persists, so a
  // reload reattaches to its session and a respawn after a daemon restart
  // re-runs the profile's connect command.
  if (linkProfile) {
    return single({ sessionId: null, cwd: linkCwd ?? undefined, profile: linkProfile }, false);
  }

  const stored = input.loadLayout();
  if (stored) {
    const ids = paneIds(stored.root);
    const focus = ids.includes(stored.focus) ? stored.focus : (ids[0] as PaneId);
    // Keep the counter ahead of restored ids so a later split cannot collide.
    for (const id of ids) {
      const n = Number.parseInt(id.replace(/^p/, ""), 10);
      if (Number.isFinite(n) && n > paneCounter) paneCounter = n;
    }
    return {
      root: stored.root,
      focus,
      panes: ids.map((id) => ({
        id,
        session: stored.sessions.get(id) ?? { sessionId: null },
      })),
      linkBoot: false,
      commandScroll,
      watch,
      paneCounter,
    };
  }

  // A tab reloading across the deploy that introduced splits still has its
  // shell recorded under the old single-session key.
  return single({ sessionId: input.takeLegacySessionId() }, false);
}

/** What a pane carries that the store keeps between reloads. */
export type PersistedPane = {
  sessionId: string | null;
  lastCwd: string | null;
  histKey: string | null;
  profile: string | null;
};

/** The layout a running page stores: every pane with its session, the link
 * pane included, so a reload reattaches to the session a link opened. */
export function persistedLayout(
  root: LayoutNode,
  focus: PaneId,
  panes: Iterable<[PaneId, PersistedPane]>,
): StoredLayout {
  const sessions = new Map<PaneId, PaneSession>();
  for (const [id, pane] of panes) {
    sessions.set(id, {
      sessionId: pane.sessionId,
      cwd: pane.lastCwd ?? undefined,
      histKey: pane.histKey ?? undefined,
      profile: pane.profile ?? undefined,
    });
  }
  return { root, focus, sessions };
}
