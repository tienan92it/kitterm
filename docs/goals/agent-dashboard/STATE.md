# STATE: agent-dashboard

- Status: waiting
- Round: 0 of 3 in this budget (first budget)
- Rounds total: 0
- Last floor: green (2026-09-17, main at 2eee3cf: swift test 780, vitest 1286 in 41 files)
- Updated: 2026-09-17, researched and planned

## Queue

1. `no-input-on-the-page` (capability 1)
2. `the-foundation-in-the-stylesheet` (capability 2)
3. `a-task-is-the-fourth-level` (capability 3)
4. `the-band-replaces-the-strip` (capability 4)
5. `every-line-is-one-line` (capability 5)

## Failures

None.

## Proposals waiting on the human

- `corpus/design-foundation.md` is written and not yet approved. It is
  the contract every round implements against, so the first round waits
  on the human's approval or their edits. Nothing else blocks.

## Done

None.

## Direction

2026-09-17: the human said the session UI is still ugly and hard to use,
and asked for a dashboard that presents and monitors workspaces and
agents. They named the scope: workspaces, projects, goals, tasks. They
named the design language: minimalism, clean, an agentic feel. They
asked for a design foundation before any implementation. And they asked
for the "Answer Workspace" input to go.

The foreman asked one question, because two readings led to different
work: whether the input goes everywhere or only where it is unusable.
The human answered **everywhere**. The page presents and monitors; it
accepts no typed work. That answer is principle 1 of the foundation and
exclusion 1 of `goal.md`.

The foreman researched before planning. Four measurements shaped the
plan, and `corpus/inventory.md` holds them all: the page is 2202 px tall
at 390 px with 587 elements and 100 class names; the task level has a
source in every `STATE.md` that nothing reads; the colour tokens are
sound and everything above them is ad hoc; and no block has a fixed
height, so a reader never learns where to look.

The Pencil design tool was not reachable — its MCP server reported
`transport not connected to app` on both calls — so the foundation is a
written contract plus a visual specimen page rather than a `.pen` file.

## Next action

The human approves or edits `corpus/design-foundation.md`. Then set
`Status: active` and run round 1, `no-input-on-the-page`, from
`plan.md` row 1. It goes first because it removes code the later
capabilities would otherwise carry.
