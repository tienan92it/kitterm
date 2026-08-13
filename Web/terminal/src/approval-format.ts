/**
 * Presentation for tool calls waiting on a human.
 *
 * Split out of the fleet view because the fleet view runs on import and cannot
 * be unit-tested, while getting these two wrong is what makes an approval
 * unreadable on a phone — which is the one place it has to be readable.
 */

/** How long an agent has been blocked, in words rather than milliseconds. */
export function waitedLabel(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `waiting ${seconds}s`;
  return `waiting ${Math.round(seconds / 60)}m`;
}

/**
 * What you are actually approving.
 *
 * Tool arguments are JSON, and the interesting part is almost always one field:
 * the command for Bash, the path for a file write. Falling back to the whole
 * object is fine — the daemon already capped the length — but leading with the
 * command is the difference between deciding at a glance and not deciding.
 */
export function summarize(input: string): string {
  try {
    const parsed = JSON.parse(input) as Record<string, unknown>;
    if (typeof parsed.command === "string") return parsed.command;
    const path = parsed.file_path ?? parsed.path;
    if (typeof path === "string") return path;
    return JSON.stringify(parsed, null, 1);
  } catch {
    // Not JSON — a truncated payload, or a schema that moved. Show it raw
    // rather than an error: a human can still read it and decide.
    return input;
  }
}
