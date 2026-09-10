# Request 01: a foreman answers a trust dialog with the toolset

Approved 2026-09-10. Frozen.

## Fixture

A daemon with `--agent-control`. A folder `claude` has never trusted, and
a session spawned in it running `claude`, so the pane sits at "Is this a
project you created or one you trust?" with the mark on `No, exit`.

## Request

Through the MCP toolset only, with no `curl` and no shell:

1. `read_screen` the pane.
2. Send one Down arrow.
3. `read_screen` again.
4. Send Enter alone.
5. `read_screen` again.

## Expected behaviour

After step 2 the mark sits on `Yes, I trust this folder`. After step 4 the
pane shows Claude's prompt. The pane never receives the literal text `[B`.

## Expected persistent effects

The folder is trusted for `claude`. Nothing else changes.
