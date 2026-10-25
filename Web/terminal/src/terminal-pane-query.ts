/**
 * The queries a pane sends to the daemon over HTTP and the WebSocket
 * upgrade: pure, so a cwd or a history key with a space in it can be
 * checked without a pane (`terminal-pane.ts` imports both).
 */

import { queryString, type QueryValue } from "./query";

/** The WebSocket query for a pane's reattach or fresh open: session, then
 * (mutually exclusive) `since` for a mid-session reconnect or `fresh` for a
 * first connect, then `cwd`, `hist`, and `profile`. */
export function connectQuery(opts: {
  sessionId: string | null;
  hasEverConnected: boolean;
  outputBytes: number;
  cwd: string | null;
  histKey: string | null;
  profile: string | null;
}): string {
  const params: Record<string, QueryValue> = {};
  if (opts.sessionId) {
    params.session = opts.sessionId;
    params.since = opts.hasEverConnected ? String(opts.outputBytes) : undefined;
    params.fresh = opts.hasEverConnected ? undefined : "1";
  }
  params.cwd = opts.cwd || undefined;
  params.hist = opts.histKey || undefined;
  params.profile = opts.profile || undefined;
  return queryString(params);
}

/** The `/api/files/stat` query: a repeated `path` is a byte that may
 * contain anything but NUL, so no separator joins them. */
export function statPathsQuery(paths: readonly string[], sessionId: string | null): string {
  const entries: Array<[string, QueryValue]> = paths.map((path) => ["path", path]);
  if (sessionId) entries.push(["session", sessionId]);
  return queryString(entries);
}
