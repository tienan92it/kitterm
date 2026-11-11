# kitterm binary protocol

This file holds the section `AGENTS.md` carried until 2026-11-10 (goal `lean-context`), moved here unchanged. A round that changes this surface updates this file.

## Binary protocol (`KittermProtocol`)

| Dir | Byte | Payload |
|-----|------|---------|
| C→S | `0` | UTF-8 / raw input |
| C→S | `1` | `cols:u16` `rows:u16` (big-endian) |
| C→S | `2` / `3` | pause / resume (empty) |
| C→S | `4` | mark — **deprecated and ignored.** The daemon reads marks out of the PTY stream itself (`OscMarkScanner`), so an unwatched session still has an index; accepting these too would double every mark for an older client still sending them. Payload kept in the codec for old clients: `kind:u8` (0 A, 1 B, 2 C, 3 D) `exit:i32` BE (Int32.min = absent) `offset:u64` BE `cmdline:utf8` (≤2KiB) |
| C→S | `5` | requestControl (empty) — an observer takes over: the current controller is demoted to observer, both get fresh `role` frames. The whole swap runs in one event-loop tick (`ControlHandoff`, loop-confined), so no output/input can interleave mid-swap; the promoted side attaches `.sinceOffset(logHead)` = zero replay |
| S→C | `0` | raw PTY output |
| S→C | `1` | title UTF-8 |
| S→C | `2` | session meta (length-prefixed fields) |
| S→C | `3` | cwd UTF-8 |
| S→C | `4` | exit code `i32` BE |
| S→C | `5` | session id UTF-8 (reattach via `/ws?session=<uuid>`) |
| S→C | `6` | resize `cols:u16 rows:u16` BE (observer follows controller size) |
| S→C | `7` | role `u8` (0 controller, 1 observer) |
| S→C | `8` | logState `flags:u8` (bit0 resync) `offset:u64` `replayLen:u64` BE — sent once per attach, before any replayed output |

Flow-control defaults: ~2ms / 64KB batching, PTY pause at 4MB buffered outbound, resume at 1MB, hard close at 64MB.
