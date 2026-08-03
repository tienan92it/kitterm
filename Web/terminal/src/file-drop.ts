/**
 * Dropping files onto a pane.
 *
 * A coding agent takes context as file paths, not uploads — so a drop means
 * "put this where the shell can read it, then type where it went". The daemon
 * saves the bytes and answers with a path; we insert that path at the cursor
 * and stop there. Pressing Enter is the person's job: running something because
 * a file was dropped is delightful until the once it isn't.
 *
 * Kept free of DOM so the awkward parts — quoting, limits, failures — are
 * testable on their own.
 */

/** Most files a single drop will send, so a dragged folder cannot flood. */
export const MAX_FILES_PER_DROP = 10;

export interface DroppedFile {
  readonly name: string;
  readonly size: number;
  arrayBuffer(): Promise<ArrayBuffer>;
}

export interface UploadedDrop {
  path: string;
  name: string;
  bytes: number;
}

/** Characters that need no quoting in any shell we care about. */
const SHELL_SAFE = /^[A-Za-z0-9._\-/]+$/;

/**
 * A path ready to be typed into a shell. The daemon sanitises the filename,
 * but the directory above it is the user's home — which can contain spaces —
 * so quote unless the whole path is plainly safe.
 */
export function quoteForShell(path: string): string {
  if (SHELL_SAFE.test(path)) return path;
  return `'${path.replace(/'/g, `'\\''`)}'`;
}

/** What gets inserted at the cursor for a set of uploads. */
export function insertionText(drops: readonly UploadedDrop[]): string {
  if (drops.length === 0) return "";
  return drops.map((drop) => quoteForShell(drop.path)).join(" ") + " ";
}

export class DropRejected extends Error {}

/**
 * Send one file to the daemon and return where it landed.
 *
 * The name travels in a header rather than the URL so it never has to survive
 * path parsing; the daemon rewrites it regardless.
 */
export async function uploadDroppedFile(
  sessionId: string,
  file: DroppedFile,
  fetchImpl: typeof fetch = fetch,
): Promise<UploadedDrop> {
  const body = await file.arrayBuffer();
  const response = await fetchImpl(`/api/sessions/${encodeURIComponent(sessionId)}/files`, {
    method: "POST",
    headers: { "X-Kitterm-Filename": encodeURIComponent(file.name) },
    body,
  });
  if (!response.ok) {
    throw new DropRejected(await describeFailure(response, file));
  }
  const parsed = (await response.json()) as Partial<UploadedDrop> & { ok?: boolean };
  if (!parsed.ok || typeof parsed.path !== "string") {
    throw new DropRejected(`${file.name} could not be saved`);
  }
  return { path: parsed.path, name: parsed.name ?? file.name, bytes: parsed.bytes ?? file.size };
}

/** A message worth showing, rather than a status code. */
async function describeFailure(response: Response, file: DroppedFile): Promise<string> {
  if (response.status === 413) return `${file.name} is too large to drop`;
  if (response.status === 403) return "This view is watch-only, so files cannot be dropped";
  if (response.status === 404) return "That session is gone";
  return `${file.name} could not be saved (${response.status})`;
}

/**
 * Upload a dropped set in order and report what succeeded.
 *
 * One failure does not abandon the rest: dropping five files and getting four
 * plus a reason beats getting nothing.
 */
export async function uploadDroppedFiles(
  sessionId: string,
  files: readonly DroppedFile[],
  fetchImpl: typeof fetch = fetch,
): Promise<{ uploaded: UploadedDrop[]; errors: string[] }> {
  const uploaded: UploadedDrop[] = [];
  const errors: string[] = [];
  const accepted = files.slice(0, MAX_FILES_PER_DROP);
  if (files.length > accepted.length) {
    errors.push(`Only the first ${MAX_FILES_PER_DROP} files were taken`);
  }
  for (const file of accepted) {
    try {
      uploaded.push(await uploadDroppedFile(sessionId, file, fetchImpl));
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
  }
  return { uploaded, errors };
}

/** Whether a drag is carrying files, as opposed to text from another element. */
export function dragCarriesFiles(transfer: DataTransfer | null): boolean {
  if (!transfer) return false;
  return Array.from(transfer.types ?? []).includes("Files");
}
