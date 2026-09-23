# Plan: loop-and-skill

## The floor

| Check | Command | Pass condition |
|---|---|---|
| Swift | `swift test` | exit 0, 859 at the start |
| CLI | `swift test --filter KittermCLITests` | exit 0, 119 at the start |
| Linux | the `facts.md` docker pipe | `Build complete`, 0 errors |
| Template | `kitterm goal new <scratch> probe` then read the written `LOOP.md` | the file is the template, and a crew can find the authority tiers and the record shape in it |

## What the measurement established

Counted on 2026-09-23, before any change:

- `LOOP.md` is 367 lines, the skill 572; thirteen `##` headings appear
  in both, and the ten record-shape sections in the skill name no
  kitterm tool at all.
- Only `Authority` is substantially project-specific: three lines name
  this repository's paths. Ten sections name none.
- `Read before you type` (8 tool mentions), `One round` (15) and
  `Monitor` (6) are the skill's own work.
- `facts.md` is 418 lines with no copy anywhere.

## Capability order

| # | Capability | Proof |
|---|---|---|
| 1 | **`LOOP.md` holds the contract.** A new `Parsed shapes` section absorbs `Round record`, `Labels` and the `STATE.md` shape, each line naming the route or parser that reads it. `One round`, `Reports`, `Prompt`, `Floor`, `Effects`, `Gap`, `Decision`, `Reflection` leave, except what tier 1 or 2 keeps. `Authority`, `Budget`, `Roles`, `Goal or chore`, `Direction`, `Stop rules` stay. | A diff read sentence by sentence: every line either moved, stayed, or is named in the record as dropped with its reason. `GoalsLayoutDocsTests` updated to pin the parsed shapes. The floor green. |
| 2 | **The skill holds the procedure.** It keeps `Rules`, `Read before you type`, `Scan`, `Schedule`, `One round`, `Monitor`, `Reports`, the model table and the three notes; it drops the ten contract sections and gains one sentence sending the reader to `<knowledge>/LOOP.md` at the start of every scan. Both Swift strings re-pasted. | No `##` heading in both files. `swift test --filter KittermCLITests` green, including the byte-for-byte test. `kitterm skills install` on a scratch dir writes the new skill. |

Capability 1 first: the skill's pointer must have somewhere to point.
