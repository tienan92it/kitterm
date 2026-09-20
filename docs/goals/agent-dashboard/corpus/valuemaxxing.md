# Research: what "valuemaxxing" can be measured from

Measured 2026-09-17 against the real transcripts, the real round
records, and the repository's own merge history. Every number below came
from a file on this machine; none is estimated.

Amended 2026-09-18, after round 6 built the parser and measured the
same sources. Four numbers below are superseded: 84 merged pull
requests, not 83; 59,251 merged lines, not 58,853 (a one-day range
difference); 2 corrections in the round records, not 3; and **7
sessions over $5 under 95% cached, worth $64.92**, not 3 worth $33.54.
The conclusions hold on the measured numbers. The page reads the live
figures; this file is the reasoning.

## What the word is taken to mean

The human asked to "measure and show valuemaxxing". Taken here as: **how
much delivered work each dollar buys, and which lever moves that
number**. A page that only shows spend says how much went out. A page
that shows yield says what came back, and where to push.

If that reading is wrong, this file is the thing to correct; every
capability below hangs off it.

## The answer first

**Yield is measurable today, and the lever is delegation.** kitterm's
last 30 days cost $976.74 and produced 83 merged pull requests, 58,853
merged lines, and 24 releases. A crew session in a worktree costs $42 an
API hour and 7 cents a merged line; a session in the repository root
costs $61 an hour and 9 cents a line. **Work done in a crew is 31%
cheaper per hour of model time than the same work done in the root.**

Three findings change what the dashboard should draw, and one of them
removes something it draws today.

## 1. Yield, for kitterm, over the last 30 days

| Unit | Count | Cost each |
|---|---:|---:|
| Merged pull requests | 83 | **$11.77** |
| Merged lines added | 58,853 | **$0.017** |
| Releases | 24 | **$40.70** |
| Hours of model time | 20.9 | **$47** |

Total spend $976.74 over 92 billed sessions. The median merged PR is 503
lines; 11 of the 83 are under 50 lines.

**Lines and PRs are proxies, not value.** The page must say so in the
same breath, the way the apportionment note already does. A 3,737-line
PR is not 7 times the value of a 503-line one.

## 2. Delegation is the lever, and it is already measured

| Role | Sessions | Spend | Share | API h | $/API h | Lines added | $/line |
|---|---:|---:|---:|---:|---:|---:|---:|
| Root session | 102 | $2,073.94 | 86% | 34.0 | **$61** | 23,081 | $0.09 |
| Crew, in a worktree | 36 | $339.53 | 14% | 8.1 | **$42** | 5,191 | $0.07 |

Account-wide, over 30 days. The role is read from the transcript's own
directory: a path holding `--claude-worktrees-` is a crew.

A crew is cheaper for a reason the data shows rather than asserts: it
starts with a fresh context sized to one item, while a root session
carries every earlier turn into every later one.

## 3. Most spend has no unit of work attached

- **14 of 51 round records carry a `- Cost:` line.** The other 37 predate
  the rule. So the ledger prices 27% of the rounds the loop has run.
- **14% of account spend runs in a crew worktree.** The rest runs in a
  root session, which no round record claims.
- The 14 priced rounds cost **$143.85**, a mean of **$10.28** and a
  median wall time of 30 minutes.

The join between a dollar and a delivered unit exists — it is the
`Cost:` line, and `KnowledgeSummary` already sums it. It is simply not
applied to most of the spend. **That gap is the single largest thing
between this repository and a real value measure.**

## 4. Cache share has stopped being a lever

Of the 56 kitterm sessions over $5, **53 sit between 95% and 99% cached**.
The three below 95% are worth $33.54 in total.

The page prints "98% cached" beside every workspace, project and goal
heading. It is a constant, and a constant carries no information. It
should appear **only when it is low** — an exception, not a column.

This is a measured reversal of a decision from `workspace-ledger`, where
the cache share was put on every heading. It was the right call when
nothing had measured the spread. It is the wrong call now.

## 5. Spend is concentrated, and a long session is why

The top 10 billed sessions are **71%** of 30-day account spend; the top
25 are 79%. The largest single session is **$1,116.33** — 329 wall hours,
15.1 API hours, a long-lived orchestrator.

A long session's cost grows with its own context: every turn re-reads
what came before. That is visible in the cache-read column, and it is
the arithmetic behind finding 2.

## 6. Cheap sessions are not the problem

**119 of 150 billed sessions changed no line at all**, and together they
are **21%** of spend. 28 sessions cost under a dollar each, $6.03 in
total. Exploration, questions and dead ends are not where the money
goes, and a dashboard that shames them would be pointing at the wrong
thing.

## 7. What cannot be measured yet, and is not claimed

- **Quality.** 51 rounds, every one recorded `done`, with 3 corrections
  and 0 failures. Either the loop is working or the record cannot
  express a failure. The data does not separate those, so the page must
  not imply the first.
- **Rework.** Two commits in 30 days name a fix to an earlier PR. That is
  too few to rank a rework rate on, and a rate built on two points would
  be noise drawn as a line.
- **A money value for the work.** Nothing on this machine knows what an
  hour of the human's time is worth, and the page takes no input
  (principle 1). So the page shows cost per unit and stops. It does not
  invent a rate and multiply by it.

## What this makes the page draw

| Block | Shows | Source |
|---|---|---|
| **Yield** | what the range's spend bought: PRs, lines, releases, model hours, each with its unit cost | `GET /api/usage/daily` for the spend; the merge history for the counts |
| **Where the dollar goes** | one `split` row per role, with `$/API h` and `$/line` | the transcript directory, already read |
| **Leaks** | spend with no round record; corrections per round; sessions below 95% cached | the round records and the bills |

And one thing it stops drawing: the cache share on every heading, which
becomes an exception line instead.
