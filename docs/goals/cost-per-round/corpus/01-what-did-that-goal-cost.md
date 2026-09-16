# Request 01: what did that goal cost

Approved 2026-09-15. Frozen. Table columns re-aligned 2026-09-16 to the
command's right-aligned output; the numbers did not change.

## Fixture

A `docs/goals/` tree with one goal, `example`, holding three round
records. Rounds 1 and 2 were written after this goal shipped and each
carries a `Cost:` line and a `Sessions:` id whose archive names a
transcript. Round 3 predates the bill and carries neither. The three
transcripts are fixtures under `Tests/`: round 1's shows $2.64, 1.02 M
cache-read tokens, 74 k cache-creation, 450 input, 17.7 k output, 9.2 k
thinking, 5 m 48 s wall-clock; round 2's shows $0.41 and a zeroed
`modelUsage`; round 3 has no transcript. Round 1's `Result:` names PR
#12 and its Floor line says "28 new". Round 2's decision is `failed`.

## Request

A person runs `kitterm goal cost <root> example`.

## Expected behaviour

A monospace table with one row per round and a totals row:

```
example                         $      in  cached      out  wall tests  files   decision      PR
  001 send-on-transition     2.64   1.10M     93%    17.7k  5m48   +28     12   done         #12
  002 the-toggle             0.41       0       —        0  0m00    +0      3   failed         —
  003 subscriptions             —       —       —        —     —   +20      7   done          #9
  total                      3.05   1.10M     93%    17.7k  5m48   +48     22
  1 round predates the bill and is not counted.
```

`in` is input plus cache creation plus cache read; `cached` is cache read
over `in`. `--json` prints the same numbers as one object per round with
the field names from the transcript, unrounded.

## Expected persistent effects

None. The command reads and prints.

## What passes

The CLI test in capability 4 over this fixture, byte for byte on the
table and field for field on the JSON.
