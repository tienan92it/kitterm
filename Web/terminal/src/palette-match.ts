/**
 * The palette's fuzzy matcher (`code-editor` round 14, rule 8 of
 * `corpus/07-projects-and-tree.md`, rule 25 of `Editor components 2`): a
 * subsequence match of the query against a candidate string, scored so a
 * longer consecutive run, a match that starts a word or a path segment, and
 * a match inside the base name (after the last `/`) all rank higher. Pure:
 * no DOM, no network, no daemon call.
 */

export interface MatchResult {
  /** Higher ranks first. */
  score: number;
  /** The indices of the candidate the query matched, in order, one per
   * query character. Empty for an empty query. */
  positions: number[];
}

const CONSECUTIVE_BONUS = 5;
const WORD_START_BONUS = 8;
const BASE_NAME_BONUS = 10;

const isSeparator = (c: string): boolean => c === "/" || c === "-" || c === "_" || c === "." || c === " ";

/** Whether `candidate[i]` starts a word: the first character, right after a
 * separator, or an uppercase letter following a lowercase one (camelCase). */
function startsWord(candidate: string, i: number): boolean {
  if (i === 0) return true;
  const prev = candidate[i - 1];
  if (isSeparator(prev)) return true;
  const c = candidate[i];
  return c >= "A" && c <= "Z" && prev >= "a" && prev <= "z";
}

/** A cheap subsequence check, case-insensitive, before the full scoring
 * pass: most candidates reject here in O(length) with no allocation. */
function isSubsequence(q: string, c: string): boolean {
  let at = 0;
  for (let i = 0; i < c.length && at < q.length; i += 1) if (c[i] === q[at]) at += 1;
  return at === q.length;
}

/**
 * The best-scoring subsequence match of `query` in `candidate`,
 * case-insensitive, or `null` with none. `baseFrom` is the index the base
 * name starts at (after the last `/`), for the base-name bonus; `0` when
 * `candidate` carries no directory.
 *
 * `dp[i][j]` is the best score of a match where query character `i - 1` is
 * matched at candidate index `j - 1` exactly (not "within the first `j`",
 * which is what lets the consecutive bonus see the true previous position).
 * `from[i][j]` keeps the candidate index the predecessor matched at, for
 * reconstructing `positions`.
 */
export function fuzzyMatch(query: string, candidate: string, baseFrom = 0): MatchResult | null {
  if (query === "") return { score: 0, positions: [] };
  const q = query.toLowerCase();
  const c = candidate.toLowerCase();
  const n = q.length;
  const m = c.length;
  if (n > m || !isSubsequence(q, c)) return null;

  const NONE = Number.NEGATIVE_INFINITY;
  const dp: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(NONE));
  const from: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(-1));
  // runningBestAt[j] is the best dp[i-1][k] for k in [i-1, j], with
  // runningBestIndex[j] the k that achieved it: the "take it from anywhere
  // earlier" option for row i.
  for (let i = 1; i <= n; i += 1) {
    let runningBest = NONE;
    let runningBestIndex = -1;
    for (let j = i; j <= m; j += 1) {
      if (i - 1 >= 1) {
        const prior = dp[i - 1][j - 1];
        if (prior > runningBest) {
          runningBest = prior;
          runningBestIndex = j - 1;
        }
      } else if (j - 1 === 0 && i === 1) {
        // The first query character has no predecessor row; the running
        // best is 0 starting from the virtual position before the string.
        runningBest = 0;
        runningBestIndex = -1;
      }
      if (c[j - 1] !== q[i - 1]) continue;
      let gain = 1;
      if (j - 1 >= baseFrom) gain += BASE_NAME_BONUS;
      if (startsWord(candidate, j - 1)) gain += WORD_START_BONUS;
      let best = i === 1 ? 0 : runningBest;
      let bestFrom = i === 1 ? -1 : runningBestIndex;
      if (i > 1) {
        const consecutive = dp[i - 1][j - 1];
        if (consecutive > NONE && consecutive + CONSECUTIVE_BONUS > best) {
          best = consecutive + CONSECUTIVE_BONUS;
          bestFrom = j - 1;
        }
      }
      if (best === NONE) continue;
      dp[i][j] = gain + best;
      from[i][j] = bestFrom;
    }
  }

  let bestScore = NONE;
  let bestJ = -1;
  for (let j = n; j <= m; j += 1) {
    if (dp[n][j] > bestScore) {
      bestScore = dp[n][j];
      bestJ = j;
    }
  }
  if (bestJ < 0) return null;
  const positions: number[] = [];
  let i = n;
  let j = bestJ;
  while (i >= 1) {
    positions.push(j - 1);
    const prevJ = from[i][j];
    i -= 1;
    j = prevJ;
  }
  positions.reverse();
  return { score: bestScore, positions };
}

/** The base name and the directory of a `/`-separated path (no leading or
 * trailing slash expected): `""` for the directory at the root. */
export function splitPath(path: string): { name: string; directory: string } {
  const slash = path.lastIndexOf("/");
  return slash < 0 ? { name: path, directory: "" } : { name: path.slice(slash + 1), directory: path.slice(0, slash) };
}

/** `fuzzyMatch` over a whole relative path, with the base-name bonus set at
 * the path's own last segment. */
export function matchPath(query: string, path: string): MatchResult | null {
  const slash = path.lastIndexOf("/");
  return fuzzyMatch(query, path, slash + 1);
}

/** One contiguous run of a name's characters, matched or not, for painting
 * the matched letters in weight 600 underlined (rule 25). `positions` are
 * absolute indices into the full path `name` was taken from; `offset` is
 * where `name` starts in that path (`splitPath`'s `directory.length + 1`,
 * `0` with no directory). */
export interface NameRun {
  text: string;
  matched: boolean;
}

export function highlightRuns(name: string, positions: readonly number[], offset: number): NameRun[] {
  const runs: NameRun[] = [];
  let at = 0;
  let pi = 0;
  while (pi < positions.length && positions[pi] < offset) pi += 1;
  while (at < name.length) {
    const matched = pi < positions.length && positions[pi] - offset === at;
    let end = at + 1;
    if (matched) {
      pi += 1;
      while (end < name.length && pi < positions.length && positions[pi] - offset === end) {
        pi += 1;
        end += 1;
      }
    } else {
      while (end < name.length && !(pi < positions.length && positions[pi] - offset === end)) end += 1;
    }
    runs.push({ text: name.slice(at, end), matched });
    at = end;
  }
  return runs;
}
