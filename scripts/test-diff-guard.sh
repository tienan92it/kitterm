#!/bin/sh
# Flag the changes that weaken a check, so a person reads them before a merge.
#
#   ./scripts/test-diff-guard.sh [BASE_REF [HEAD_REF]]
#
# Inputs
#   BASE_REF   default origin/main. The script diffs BASE_REF...HEAD_REF, that
#              is, the changes since the merge base.
#   HEAD_REF   default HEAD.
#   PR_BODY    the text of the pull request body, or
#   PR_BODY_FILE  the path of a file that holds it. PR_BODY wins when both are
#              set. With neither, the body is empty.
#
# Scope
#   Tests/, Web/terminal/src/**/*.test.ts and .github/workflows/.
#
# Findings (each one is a GitHub ::warning file=,line=:: annotation)
#   - a removed or changed assertion line: XCTAssert*, XCTFail, #expect,
#     expect(, assert...( . A line that only adds an assertion is no finding.
#   - an added skip or focus marker: XCTSkip, .skip(, it.skip, test.skip,
#     describe.skip, xit, .only(
#   - a change to a snapshot file (__snapshots__/, *.snap, *.snapshot)
#   - a deleted test file (a rename counts as a delete and an add)
#   - any edit under .github/workflows/
#   A new test file, or a change that only adds assertions, is no finding.
#
# Output
#   One annotation per finding on stdout, then one summary line.
#
# Exit status
#   0  no finding, or findings and a line in the PR body that starts with
#      "Chartered:" (the author names the changed assertions there)
#   1  findings and no "Chartered:" line
#   2  a bad argument or an unreadable ref
#
# The guard labels. It cannot tell a weakened test from a test that a round
# must change, so the "Chartered:" line is the author's answer to the label.
set -eu

BASE="${1:-origin/main}"
HEAD_REF="${2:-HEAD}"

for REF in "$BASE" "$HEAD_REF"; do
    if ! git rev-parse --verify --quiet "$REF^{commit}" >/dev/null; then
        echo "test-diff-guard: cannot resolve ref '$REF'" >&2
        exit 2
    fi
done

if [ -n "${PR_BODY:-}" ]; then
    BODY="$PR_BODY"
elif [ -n "${PR_BODY_FILE:-}" ]; then
    if [ ! -r "$PR_BODY_FILE" ]; then
        echo "test-diff-guard: cannot read PR_BODY_FILE '$PR_BODY_FILE'" >&2
        exit 2
    fi
    BODY="$(cat "$PR_BODY_FILE")"
else
    BODY=""
fi

FINDINGS="$(mktemp)"
trap 'rm -f "$FINDINGS"' EXIT

TEST_PATHS="Tests/ :(glob)Web/terminal/src/**/*.test.ts"
# Word splitting is intended: each word is one pathspec.
# shellcheck disable=SC2086
set -- $TEST_PATHS

# 1. File level: deleted test files, snapshot changes, workflow edits.
git -c core.quotepath=false diff --name-status --no-renames "$BASE...$HEAD_REF" -- \
    "$@" .github/workflows/ |
    awk -F'\t' '
        function snapshot(p) { return p ~ /(^|\/)__snapshots__\// || p ~ /\.snap$/ || p ~ /\.snapshot$/ }
        {
            status = substr($1, 1, 1); path = $2
            if (path ~ /^\.github\/workflows\//) {
                printf "::warning file=%s,line=1::workflow edited (%s): a person reads every change under .github/workflows/\n", path, status
                next
            }
            if (snapshot(path)) {
                printf "::warning file=%s,line=1::snapshot file changed (%s)\n", path, status
                next
            }
            if (status == "D")
                printf "::warning file=%s,line=1::test file deleted\n", path
        }' >>"$FINDINGS"

# 2. Line level: removed assertions and added skip markers. -U0 gives exact
# line numbers; a deleted file is reported above and skipped here.
git -c core.quotepath=false diff -U0 --no-color --no-renames "$BASE...$HEAD_REF" -- "$@" |
    awk '
        function trim(s) { sub(/^[ \t]+/, "", s); if (length(s) > 80) s = substr(s, 1, 80) "..."; return s }
        /^diff --git / { inhdr = 1; file = ""; gone = 0; next }
        inhdr && /^\+\+\+ / {
            if ($0 == "+++ /dev/null") gone = 1
            else { file = substr($0, 7) }
            next
        }
        inhdr && /^--- / { next }
        /^@@ / {
            inhdr = 0
            split($2, a, ","); split($3, c, ",")
            old = substr(a[1], 2) + 0
            new = substr(c[1], 2) + 0
            next
        }
        inhdr || gone || file == "" { next }
        /^-/ {
            text = substr($0, 2)
            if (text ~ /XCTAssert[A-Za-z]*|XCTFail|#expect|expect\(|(^|[^A-Za-z_])assert[A-Za-z_.]*\(/) {
                line = (new > 0) ? new : 1
                printf "::warning file=%s,line=%d::assertion removed or changed (was line %d): %s\n", file, line, old, trim(text)
            }
            old++
            next
        }
        /^\+/ {
            text = substr($0, 2)
            if (text ~ /XCTSkip|\.skip\(|it\.skip|test\.skip|describe\.skip|(^|[^A-Za-z0-9_])xit[ (]|\.only\(/)
                printf "::warning file=%s,line=%d::skip or focus marker added: %s\n", file, new, trim(text)
            new++
            next
        }' >>"$FINDINGS"

COUNT="$(wc -l <"$FINDINGS" | tr -d ' ')"
cat "$FINDINGS"

if [ "$COUNT" -eq 0 ]; then
    echo "test-diff-guard: no finding in $BASE...$HEAD_REF"
    exit 0
fi

if printf '%s\n' "$BODY" | tr -d '\r' | grep -q '^Chartered:'; then
    echo "test-diff-guard: $COUNT finding(s); the PR body has a Chartered: line, so the guard passes"
    exit 0
fi

echo "test-diff-guard: $COUNT finding(s) and no line that starts with \"Chartered:\" in the PR body." >&2
echo "Add \"Chartered: <the assertion or workflow change and why>\" to the PR body, or revert the change." >&2
exit 1
