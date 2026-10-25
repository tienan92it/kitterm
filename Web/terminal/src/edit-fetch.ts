/**
 * The `/edit` page's two conversations with the daemon: the read of
 * `GET /api/files/content`, conditional on the tag the page holds, and the
 * save of `PUT /api/files/content` with the editor header and `If-Match`
 * (`rounds/003.md`). Each takes the `fetch` to use, so a test hands in a
 * fake and reads what was sent.
 */

import { daemonAnswered, DAEMON_UNREACHABLE, errorWord } from "./markdown-view";

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

export interface ReadFile {
  kind: "file";
  bytes: Uint8Array;
  /** The whole file's tag; `null` for a truncated read, which has none. */
  etag: string | null;
  fileKind: string;
  contentType: string | null;
  totalBytes: number;
  truncated: boolean;
  /** The permission bits, octal, when the daemon sent them. */
  mode: string | null;
}

export type ReadResult =
  | ReadFile
  /** 304: the disk still holds the tag the page sent. */
  | { kind: "unchanged" }
  | { kind: "error"; status: number | null; reason: string };

/**
 * Read `url`. With `ifNoneMatch`, the daemon answers 304 for the same
 * bytes, and the result is `unchanged`. A status that is not 200 is an
 * error with the reason in the words of `markdown-view.ts`; a `fetch` that
 * throws is the daemon not answering, status `null`.
 */
export async function readFile(fetch: Fetch, url: string, ifNoneMatch: string | null = null): Promise<ReadResult> {
  const headers: Record<string, string> = {};
  if (ifNoneMatch) headers["If-None-Match"] = ifNoneMatch;
  let response: Response;
  try {
    response = await fetch(url, { credentials: "same-origin", headers, cache: "no-store" });
  } catch {
    return { kind: "error", status: null, reason: DAEMON_UNREACHABLE };
  }
  if (response.status === 304) return { kind: "unchanged" };
  if (!response.ok) {
    return { kind: "error", status: response.status, reason: daemonAnswered(response.status, await errorWord(response)) };
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  return {
    kind: "file",
    bytes,
    etag: response.headers.get("ETag"),
    fileKind: response.headers.get("X-Kitterm-Kind") ?? "text",
    contentType: response.headers.get("Content-Type"),
    totalBytes: Number(response.headers.get("X-Kitterm-Total-Bytes") ?? bytes.length),
    truncated: response.headers.get("X-Kitterm-Truncated") === "1",
    mode: response.headers.get("X-Kitterm-Mode"),
  };
}

export type SaveResult =
  /** 200: the new tag. */
  | { kind: "saved"; etag: string }
  /** 412: the disk's current tag, when the daemon could read it. */
  | { kind: "conflict"; etag: string | null }
  /** Any other refusal (403, 404, 409, 413, 428, a 5xx), with its sentence. */
  | { kind: "refused"; status: number | null; reason: string };

/**
 * Save `bytes` to `url` when the disk still holds `ifMatch`. The browser
 * adds the `Origin` the route wants; the editor header is this function's.
 */
export async function saveFile(fetch: Fetch, url: string, bytes: Uint8Array, ifMatch: string): Promise<SaveResult> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: "PUT",
      credentials: "same-origin",
      headers: {
        "X-Kitterm-Editor": "1",
        "If-Match": ifMatch,
        "Content-Type": "application/octet-stream",
      },
      body: bytes as Uint8Array<ArrayBuffer>,
    });
  } catch {
    return { kind: "refused", status: null, reason: DAEMON_UNREACHABLE };
  }
  if (response.status === 412) {
    const body = (await response.json().catch(() => ({}))) as { etag?: unknown };
    const etag = response.headers.get("ETag") ?? (typeof body.etag === "string" ? body.etag : null);
    return { kind: "conflict", etag };
  }
  if (!response.ok) {
    return { kind: "refused", status: response.status, reason: daemonAnswered(response.status, await errorWord(response)) };
  }
  const body = (await response.json().catch(() => ({}))) as { etag?: unknown };
  const etag = response.headers.get("ETag") ?? (typeof body.etag === "string" ? body.etag : null);
  if (etag === null) return { kind: "refused", status: response.status, reason: "the daemon answered 200 with no ETag" };
  return { kind: "saved", etag };
}

export interface ProjectAnswer {
  path: string;
  /** `directory` when the path is a folder (round 7), which opens the tree
   * in place of the editor; absent for a file, as before round 7. */
  kind?: "directory";
  project: { id: string; name: string; root: string; relative: string } | null;
}

/** `GET /api/files/project`: where the file sits, or an error sentence. */
export async function readProject(
  fetch: Fetch,
  url: string,
): Promise<{ kind: "ok"; answer: ProjectAnswer } | { kind: "error"; status: number | null; reason: string }> {
  let response: Response;
  try {
    response = await fetch(url, { credentials: "same-origin" });
  } catch {
    return { kind: "error", status: null, reason: DAEMON_UNREACHABLE };
  }
  if (!response.ok) {
    return { kind: "error", status: response.status, reason: daemonAnswered(response.status, await errorWord(response)) };
  }
  const body = (await response.json()) as { path?: unknown; kind?: unknown; project?: unknown };
  const project = body.project as ProjectAnswer["project"] | undefined;
  return {
    kind: "ok",
    answer: {
      path: typeof body.path === "string" ? body.path : "",
      ...(body.kind === "directory" ? { kind: "directory" as const } : {}),
      project:
        project && typeof project === "object" && typeof project.root === "string"
          ? { id: String(project.id), name: String(project.name), root: project.root, relative: String(project.relative ?? "") }
          : null,
    },
  };
}

export interface ListingEntry {
  name: string;
  dir: boolean;
  size?: number;
}

/** `GET /api/files`: a directory's entries, or an error sentence. */
export async function readListing(
  fetch: Fetch,
  url: string,
): Promise<{ kind: "ok"; entries: ListingEntry[] } | { kind: "error"; status: number | null; reason: string }> {
  let response: Response;
  try {
    response = await fetch(url, { credentials: "same-origin" });
  } catch {
    return { kind: "error", status: null, reason: DAEMON_UNREACHABLE };
  }
  if (!response.ok) {
    return { kind: "error", status: response.status, reason: daemonAnswered(response.status, await errorWord(response)) };
  }
  const body = (await response.json()) as { entries?: unknown };
  const entries = Array.isArray(body.entries) ? (body.entries as ListingEntry[]) : [];
  return {
    kind: "ok",
    entries: entries
      .filter((entry) => typeof entry.name === "string")
      .map((entry) => ({ name: entry.name, dir: entry.dir === true, ...(typeof entry.size === "number" ? { size: entry.size } : {}) })),
  };
}

export type StatusResult =
  | { kind: "ok"; body: unknown; etag: string | null }
  /** 304: the repository still holds the tag the page sent. */
  | { kind: "unchanged" }
  | { kind: "error"; status: number | null; reason: string };

/**
 * `GET /api/git/status`, conditional on the tag the page holds. The body
 * is handed back as parsed JSON for `parseStatus` (`edit-git.ts`).
 */
export async function readGitStatus(fetch: Fetch, url: string, ifNoneMatch: string | null = null): Promise<StatusResult> {
  const headers: Record<string, string> = {};
  if (ifNoneMatch) headers["If-None-Match"] = ifNoneMatch;
  let response: Response;
  try {
    response = await fetch(url, { credentials: "same-origin", headers, cache: "no-store" });
  } catch {
    return { kind: "error", status: null, reason: DAEMON_UNREACHABLE };
  }
  if (response.status === 304) return { kind: "unchanged" };
  if (!response.ok) {
    return { kind: "error", status: response.status, reason: daemonAnswered(response.status, await errorWord(response)) };
  }
  return { kind: "ok", body: await response.json().catch(() => ({})), etag: response.headers.get("ETag") };
}

/** The diff route's answer, as far as the page draws it. */
export interface DiffAnswer {
  path: string;
  staged: boolean;
  untracked: boolean;
  binary: boolean;
  additions: number | null;
  deletions: number | null;
  diff: string;
  truncated: boolean;
}

/** `GET /api/git/diff`: the unified diff of one file, or an error sentence. */
export async function readGitDiff(
  fetch: Fetch,
  url: string,
): Promise<{ kind: "ok"; answer: DiffAnswer } | { kind: "error"; status: number | null; reason: string }> {
  let response: Response;
  try {
    response = await fetch(url, { credentials: "same-origin", cache: "no-store" });
  } catch {
    return { kind: "error", status: null, reason: DAEMON_UNREACHABLE };
  }
  if (!response.ok) {
    return { kind: "error", status: response.status, reason: daemonAnswered(response.status, await errorWord(response)) };
  }
  const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  return {
    kind: "ok",
    answer: {
      path: typeof body.path === "string" ? body.path : "",
      staged: body.staged === true,
      untracked: body.untracked === true,
      binary: body.binary === true,
      additions: typeof body.additions === "number" ? body.additions : null,
      deletions: typeof body.deletions === "number" ? body.deletions : null,
      diff: typeof body.diff === "string" ? body.diff : "",
      truncated: body.truncated === true,
    },
  };
}

/** One project of `GET /api/projects` (rounds 10 and 11): the identity the
 * home page and the switcher group by. */
export interface ProjectRef {
  id: string;
  name: string;
  root: string;
  registered: boolean;
}

/** `GET /api/projects`: every project the daemon has seen, or an error
 * sentence. A project missing an id, a name or a root is dropped. */
export async function readProjects(fetch: Fetch, url: string): Promise<{ kind: "ok"; projects: ProjectRef[] } | { kind: "error"; status: number | null; reason: string }> {
  let response: Response;
  try {
    response = await fetch(url, { credentials: "same-origin" });
  } catch {
    return { kind: "error", status: null, reason: DAEMON_UNREACHABLE };
  }
  if (!response.ok) {
    return { kind: "error", status: response.status, reason: daemonAnswered(response.status, await errorWord(response)) };
  }
  const body = (await response.json().catch(() => ({}))) as { projects?: unknown };
  const list = Array.isArray(body.projects) ? body.projects : [];
  const projects: ProjectRef[] = [];
  for (const raw of list) {
    const item = (raw ?? {}) as Record<string, unknown>;
    if (typeof item.id !== "string" || typeof item.name !== "string" || typeof item.root !== "string") continue;
    projects.push({ id: item.id, name: item.name, root: item.root, registered: item.registered === true });
  }
  return { kind: "ok", projects };
}

/** `GET /api/files/index` (the palette, round 14): the file paths of the
 * repository the path resolves to, relative to `root`. */
export interface FilesIndexAnswer {
  root: string;
  files: string[];
  truncated: boolean;
  etag: string | null;
}

export type FilesIndexResult =
  | { kind: "ok"; answer: FilesIndexAnswer }
  /** 304: the index still holds the tag the page sent. */
  | { kind: "unchanged" }
  | { kind: "error"; status: number | null; reason: string };

/**
 * `GET /api/files/index`, conditional on the tag the page holds (the
 * palette reads it once on the first open and again when more than 30 s
 * have passed since the last read).
 */
export async function readFilesIndex(fetch: Fetch, url: string, ifNoneMatch: string | null = null): Promise<FilesIndexResult> {
  const headers: Record<string, string> = {};
  if (ifNoneMatch) headers["If-None-Match"] = ifNoneMatch;
  let response: Response;
  try {
    response = await fetch(url, { credentials: "same-origin", headers, cache: "no-store" });
  } catch {
    return { kind: "error", status: null, reason: DAEMON_UNREACHABLE };
  }
  if (response.status === 304) return { kind: "unchanged" };
  if (!response.ok) {
    return { kind: "error", status: response.status, reason: daemonAnswered(response.status, await errorWord(response)) };
  }
  const body = (await response.json().catch(() => ({}))) as { root?: unknown; files?: unknown; truncated?: unknown };
  const files = Array.isArray(body.files) ? body.files.filter((f): f is string => typeof f === "string") : [];
  return {
    kind: "ok",
    answer: { root: typeof body.root === "string" ? body.root : "", files, truncated: body.truncated === true, etag: response.headers.get("ETag") },
  };
}

export type WriteResult =
  | { kind: "ok"; body: Record<string, unknown>; lines: string[] }
  | { kind: "error"; status: number | null; reason: string; lines: string[] };

/**
 * `POST /api/git/<kind>` (round 6): the body as JSON with the editor
 * header the daemon requires, the answer's `lines` (what the command and
 * the hooks printed) kept on both outcomes, and a refusal's `error` word in
 * `reason` as the daemon wrote it (`git push exited 1: …`).
 */
export async function gitWrite(fetch: Fetch, url: string, body: Record<string, unknown>): Promise<WriteResult> {
  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      cache: "no-store",
      headers: { "Content-Type": "application/json", "X-Kitterm-Editor": "1" },
      body: JSON.stringify(body),
    });
  } catch {
    return { kind: "error", status: null, reason: DAEMON_UNREACHABLE, lines: [] };
  }
  const answer = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  const lines = Array.isArray(answer.lines) ? answer.lines.filter((line): line is string => typeof line === "string") : [];
  if (!response.ok) {
    const error = typeof answer.error === "string" && answer.error !== "" ? answer.error : null;
    return { kind: "error", status: response.status, reason: error ?? daemonAnswered(response.status, null), lines };
  }
  return { kind: "ok", body: answer, lines };
}
