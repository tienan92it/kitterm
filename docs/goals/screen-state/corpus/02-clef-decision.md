# The human's decision on capability 4

2026-10-22. The foreman ran `kitterm screen-state stats --days 14` (due
2026-10-21) and brought the human the numbers:

| Window | Calls | `unknown` | Share |
|---|---|---|---|
| 2026-10-08 to 2026-10-22 | 181 | 31 | 17 % |
| 2026-10-08 to 2026-10-12 | 76 | 22 | 29 % |
| 2026-10-13 to 2026-10-22 | 111 | 11 | 10 % |

Every `unknown` row reads `no rule matched`; they came from 26 of the 99
sessions that asked. The log keeps no screen text, by design, so what
the rules missed is not recorded.

The human chose, from three options:

> No; capture unknowns locally

1. **Capability 4 (`clef-fallback`) is not built.** No screen text goes
   to Cloudflare; `~/.kitterm/clef.json` does not exist.
2. **A new capability, `unknown-capture`**: an opt-in local capture of
   each `unknown` screen, so the missing rules can be written from real
   samples. Off by default; the rendered screen text of an `unknown`
   answer only, 0600 under `~/.kitterm/`, rotated and capped, never sent
   anywhere; a command to list and print the samples, and to turn the
   capture on and off.
3. **Re-measure in 14 days** with the samples in hand, and then write
   the missing rules.
