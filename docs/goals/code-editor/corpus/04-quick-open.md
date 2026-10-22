# The human's word: quick open a project in the editor

2026-10-19, after v0.45.0 shipped every editor phase:

> how to quick open a project in editor?

The foreman's check the same day: `/edit` takes a file only;
`/edit?path=/Users/antran/Workspace/kitterm` (a folder) prints `Cannot
read kitterm: the daemon answered 404` with no tree; the CLI has
`kitterm open <path>` (a shell tab) and no editor command.

The human's word on 2026-10-22, on the foreman's three proposals:

> yes, run all three as one chore

1. **`/edit?path=<folder>`** opens the project tree at that folder with
   no file open, or with the folder's `README.md` when it has one, in
   place of the 404.
2. **`kitterm edit [path]`** works like `kitterm open`: it opens the
   browser at `/edit` for the folder or file; with no argument, the
   current directory.
3. **A key in a pane**, for example ⌘⇧E, opens `/edit` at the pane's
   current folder in a new tab.
