# ADR 0001: Render the screen in the MCP bridge, not the daemon

## Status

Accepted (2026-09-04).

## Context

A foreman reads a crew session through `kitterm mcp`. Its only read of a
pane's content is `read_output`, which returns the raw PTY bytes of one
command. For a shell command that is the right read. For a pane that runs
Claude Code it is not: the pane is one long-running command, and its output
is a stream of redraws. A spinner rewrites the same line many times a
second, every frame moves the cursor with `ESC[H`, `ESC[<n>C`, `ESC[<n>B`,
and every line ends in `ESC[K`. The bytes a foreman gets back hold the
screen, but the screen exists only after a terminal applies every cursor
move and erase in order.

A foreman session hit this on 2026-09-04. It could not tell what a Claude
Code pane showed. Claude Code prints a dim ghost suggestion on an empty
prompt (`Try "refactor <filepath>"`), which reads as typed text in a raw
tail. The foreman pressed Enter on an empty prompt. To recover, it wrote
the retained PTY log to disk, read the pane's size with `stty size` on the
PTY, and rendered the log with the `pyte` terminal emulator. That worked,
and it is the read the foreman needs. It is also a manual workaround that
depends on a Python package and on `--retain-logs`.

Two constraints bound the fix.

- `AGENTS.md` states that the daemon does not emulate a terminal: no grid,
  no cursor, no CSI or SGR. The one bounded exception is `OscMarkScanner`,
  which matches two OSC ids so an unwatched session still has a command
  index. That rule keeps the event loop cheap and the daemon small. A
  rendered screen must not become a second exception.
- The foreman is a headless process. It holds no browser. A read that
  depends on an open fleet page is a read the loop cannot rely on.

The daemon already holds the two inputs a renderer needs. `SessionLog` is
a 4 MiB ring of every output byte, and `PtySession` tracks the PTY's
`cols` and `rows` from the controller's resize frames. Neither is served
over HTTP today: output is served only per command, and the size is served
nowhere.

Three options were considered.

1. **Render in the daemon.** Add a grid per session and serve it as a
   route. It gives the cheapest read, and it breaks the invariant above.
   Every session pays for a grid, watched or not, and the daemon gains a
   VT parser on the output path.
2. **Render in the browser through the fleet page.** xterm.js already has
   the grid. The fleet page could render a session and post the text back,
   or serve it through a new route. The foreman would then depend on a
   browser tab that a human keeps open. A foreman that runs at night has
   no such tab.
3. **Render in the MCP bridge.** `kitterm mcp` is a short-lived CLI
   process outside the event loop. It fetches the raw tail and the pane
   size from the daemon, applies a bounded VT parser, and returns the text
   grid to the foreman. The daemon serves bytes and a number, and nothing
   else.

## Decision

We render the screen in the MCP bridge process.

- A new library target, `KittermScreen`, holds `ScreenRenderer`: a bounded
  VT100/xterm subset that applies output bytes to a cols × rows grid. Only
  `KittermCLI` links it. `KittermDaemon` does not depend on it, so the
  build enforces the invariant: the daemon has no code path that can reach
  a grid.
- The daemon gains one read-only route,
  `GET /api/sessions/<id>/output?tail=<bytes>`. It answers the last
  `tail` bytes of the session's ring as `application/octet-stream`, with
  `X-Kitterm-Cols`, `X-Kitterm-Rows`, `X-Kitterm-Start`, and
  `X-Kitterm-Head` headers. The session row also carries `cols` and
  `rows`. The route reads the ring under the same lock the command-output
  route uses, on the loop, with the same 256 KiB cap.
- The bridge gains a `read_screen` tool. It calls the route, renders the
  bytes at the pane's real size (or a size the caller overrides), and
  returns the grid as JSON: `cols`, `rows`, `cursor`, `lines`. With
  `styles: true` (the default) a dim run is wrapped in `{dim}…{/dim}` and
  an inverse run in `{inv}…{/inv}`, so a ghost suggestion and a selected
  menu row are legible as what they are.

The renderer's scope is fixed, and the tests pin it:

- C0 controls: BS, HT, LF, VT, FF, CR. BEL and the rest are dropped.
- ESC: `7`, `8`, `D`, `E`, `M`, `c`; charset designations are consumed;
  OSC, DCS, SOS, PM, and APC strings are consumed to their terminator.
- CSI: cursor moves (`A B C D E F G H f d`), erase (`J K`), insert and
  delete (`@ P X L M`), scroll (`S T r`), save and restore (`s u`), and
  the private modes for autowrap (`?7`), cursor visibility (`?25`), and
  the alternate screen (`?47`, `?1047`, `?1049`). Every other CSI is
  parsed and dropped. SGR tracks dim and inverse, the two attributes a
  reader needs (a placeholder, a selected row); bold and every colour
  parameter are consumed and forgotten.
- Width: East Asian wide and fullwidth ranges and emoji-presentation
  scalars take two cells; combining marks, ZWJ, and variation selectors
  take none. This is an approximation, not a Unicode width table.
- A no-break space renders as a space. The read is text for a reader, and
  Claude Code prints one after its prompt marker.

The tail starts at an arbitrary byte, often mid-frame. The renderer
drops leading UTF-8 continuation bytes and starts at the first sequence
that fixes the cursor absolutely: a cursor position (`ESC[H`,
`ESC[r;cH`), a full erase (`ESC[2J`), a reset (`ESC c`), or a switch
to the alternate screen. A TUI starts each frame with one, so every byte
after it lands where the pane put it, and text from the partial frame
before it never lands on a wrong row. A tail with none of these (plain
scrolling output) starts at the first `ESC`, else after the first LF.

## Consequences

Good:

- The foreman reads what a human sees, at the pane's real size, with one
  tool call. No Python, no `--retain-logs`, no `stty` on the PTY.
- The daemon's invariant holds by construction. The event loop gains one
  ring read per call and no parser.
- The renderer is pure Swift with no dependency. It is testable on a byte
  fixture from a real Claude Code pane, and it runs on Linux.
- A future client (the fleet page, a CLI `kitterm screen <id>`) can call
  the same route and the same library.

Bad, and accepted:

- The bridge now holds a VT parser, and a VT parser is never complete. A
  sequence outside the listed subset is dropped, so a TUI that depends on
  it renders wrong. The subset is the one Claude Code, `less`, and a shell
  prompt use; a full emulator was not the goal. The fixture tests are the
  contract.
- Every `read_screen` re-renders the tail from a blank grid. There is no
  incremental state between calls. Measured in a debug build on an Apple
  Silicon laptop, the default 64 KiB tail renders in about 15 ms and the
  256 KiB cap in about 65 ms, in the bridge process, off the daemon's loop.
  A foreman can afford that on every check.
- A screen that was last fully redrawn more than `tail` bytes ago renders
  incomplete. The caller can raise `tail` to the route's 256 KiB cap.
- The daemon exposes one more byte route. It sits behind the same access
  policy as the command-output route and reveals nothing that route did
  not already reveal.

Closed:

- Rendering in the daemon. `KittermDaemon` does not link `KittermScreen`,
  and a change that makes it do so reverses this record.
- A browser-dependent read. The fleet page may render for a human, but the
  foreman's read never routes through it.
