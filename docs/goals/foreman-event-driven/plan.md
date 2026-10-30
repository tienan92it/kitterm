# Plan

A human owns this file. A foreman proposes a change in a round record.

## The floor

| Check | Command | Pass |
|---|---|---|
| Linux build | the `facts.md` docker pipe when a test uses `URLSession` | `Build complete` |
| Swift tests | `swift test`, once by the crew; PR `test` proves it | exit 0 |
| Skill golden | `ForemanSkillsTests`, `GoalsLayoutDocsTests` | exit 0 |

## Capability order

1. `foreman-watch`: the `kitterm foreman watch` command — long-poll the
   event feed, exit on the first event for a named crew session, a
   heartbeat, or an epoch change; print it; the cursor carried in and
   out so no event is missed. A Swift HTTP client (the `MCPTools.Call`
   path `catch-up` uses), never `curl`.
2. `skill-rewrite`: the `foreman-loop` skill's `## Monitor` section and
   frontmatter adopt delegate → report → yield → `kitterm foreman watch`
   in the background → woken → act → report → next, scoped to the
   foreman's own crews; mirror into `ForemanSkills.swift`; pin the rules
   in `ForemanProtocolRulesTests`.
