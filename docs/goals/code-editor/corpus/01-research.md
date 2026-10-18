# Ship terminal tools first, then CodeMirror 6

Yes, kitterm can have a small built-in editor with a project tree, popular-language support and quick git control. The editor stays light only if kitterm builds it in four phases. Phase 1 runs micro (or the user's `$EDITOR`) and lazygit in kitterm's own panes and adds about four small client changes. Phase 1 adds 0 bytes to the web bundle and no daemon route. Phase 2 adds an `/edit` page on CodeMirror 6 (CM6), which costs about 103 KB gzip before a language, against about 703 KB gzip for Monaco. Phases 3 and 4 add git routes on the daemon's existing hardened process runner: reads first, then writes behind an explicit trust flag. The hard part is the security model, not the editor. A save route is the first HTTP route that writes outside `~/.kitterm/`, so it needs a descriptor-walk jail, an atomic save and a content-hash precondition. The main decision is in ADR form below, with status `proposed`.

## The ranked recommendation puts CM6 first and Monaco last

The ranking scores each option against the owner's three features and five constraints: bundle size, phone and IME behaviour, large files, security cost and fit with existing code. Two options are complements, not rivals. The terminal stack is the cheapest way to deliver all three features now. CM6 is the best browser engine when a browser editor is wanted.

| Rank | Option | Initial cost (gzip) | Languages | Phone and IME | Large files | Verdict |
|---|---|---|---|---|---|---|
| 1 | Terminal stack: micro or `$EDITOR` + lazygit in panes | 0 KB web; 4 MiB + 6 MiB install | micro: over 130 | Poor: touch scroll and selection fail in xterm.js | Good | Phase 1. All three features, no write route |
| 2 | CM6 page at `/edit` | ~103 KB + 2-46 KB per language, lazy | ~100 lazy; 18 popular in 250.5 KB total | Best of the full editors; active fixes | Virtualized | Phase 2. The browser editor |
| 3 | Textarea overlay + kitterm's `highlight.ts` | A few KB, no new dependency | 9 coarse scanner modes | Native IME and selection | Full rescan per change, 256 KiB cap | Fallback if the owner refuses a dependency |
| 4 | prism-code-editor (textarea overlay) | 28.1 KB for 18 languages | Prism regex | Claims good mobile; untested | Slows past ~1,000 lines | Small-file only; single maintainer |
| 5 | CodeJar + Prism | 25.5 KB for 18 languages | Prism regex | Likely fragile under IME (unverified) | Slow on huge files | Prism 1.x stalled; reject |
| 6 | Ace | 127.8 KB core + modes | Regex modes | Known Android and iOS input problems | Virtualized | Reject |
| 7 | Monaco | 703.1 KB core + 93.9 KB worker | Monarch + web-language workers | Officially unsupported on mobile | Virtualized | Reject |

The sizes come from esbuild builds of the current npm packages, measured on 2026-10-18 ([codemirror on npm](https://www.npmjs.com/package/codemirror), [monaco-editor on npm](https://www.npmjs.com/package/monaco-editor), [ace-builds on npm](https://www.npmjs.com/package/ace-builds), [prism-code-editor on npm](https://www.npmjs.com/package/prism-code-editor)). The install sizes come from the GitHub release assets on the same day ([micro releases](https://github.com/zyedidia/micro/releases/latest), [lazygit releases](https://github.com/jesseduffield/lazygit/releases/latest)).

## CM6 costs one seventh of Monaco and keeps working on phones

### Bundle size

A usable CM6 core costs **102.6 KB gzip**: line numbers, history, bracket matching, indentation, folding, highlighting and a lazy language index. That core loads 122 language chunks on demand. Python costs about 31 KB on first open and JS/TS about 46 KB, including shared parser chunks. The union of 18 popular languages is **250.5 KB gzip in 24 chunks**, but a user pays only for the languages that they open. A static load of the same 18 languages costs 369.2 KB gzip, so lazy loading cuts the up-front cost by about 72 %. Monaco's smallest core is **703.1 KB gzip** with no language, plus a mandatory 93.9 KB worker ([monaco-editor on npm](https://www.npmjs.com/package/monaco-editor)).

The kitterm baseline gives these numbers scale. The terminal page's `main-*.js` is 167 KB gzip and the `/md` page loads about 31 KB gzip of JS (measured in `~/.local/share/kitterm/web/assets/`). An `/edit` page with CM6 and the shared `tokens` and `styles` chunks lands near 120 KB gzip before a language. That estimate adds the measured chunks; it is not a Vite build. A separate Vite input keeps `main-*.js` unchanged, because only `/edit` imports CM6.

### Language coverage

CM6 ships Lezer grammars for JS/TS, Python, Go, Rust, Java, C/C++, PHP, JSON, YAML, Markdown, HTML, CSS and SQL. It adds stream-parser modes for Shell, TOML, Dockerfile, Ruby and Swift through `@codemirror/legacy-modes` ([CodeMirror bundling example](https://codemirror.net/examples/bundle/)). A Lezer grammar gives a syntax tree, so folding, indentation and bracket matching follow the grammar, not a regex. Prism, highlight.js and kitterm's own `highlight.ts` give token classes only. `highlight.ts` has nine coarse modes (`c-like`, `hash`, `shell`, `json`, `xml`, `md`, `log`, `diff`, `plain`), which suit a preview and not an editor ([highlight.ts](../../../../Web/terminal/src/highlight.ts)). Tree-sitter grammars are 10 to 100 times larger than the Lezer ones: Swift costs 293 KB gzip against 1.8 KB ([tree-sitter-wasms on npm](https://www.npmjs.com/package/tree-sitter-wasms)).

No option in scope gives real code intelligence for free. An LSP client in the browser needs a language server process on the daemon side, which is a separate project. Monaco's built-in intelligence covers only TS, JSON, CSS and HTML, and it costs multi-megabyte workers ([microsoft/monaco-editor](https://github.com/microsoft/monaco-editor)). Forgejo states the CM6 cost directly: more manual assembly, less integrated language support and no command palette ([Forgejo PR #10697](https://codeberg.org/forgejo/forgejo/pulls/10697)).

### Phone and IME behaviour

Monaco's FAQ answers "No" to mobile browser support ([microsoft/monaco-editor](https://github.com/microsoft/monaco-editor)). Its issue tracker shows broken delete on phones and a failed Chinese IME on iOS ([monaco-editor #4044](https://github.com/microsoft/monaco-editor/issues/4044), [monaco-editor #1663](https://github.com/microsoft/monaco-editor/issues/1663)). Ace keeps a small hidden buffer, but Android Chrome expects a full text buffer when the edit area takes focus ([ajaxorg/ace #3450](https://github.com/ajaxorg/ace/issues/3450)). CM6 uses native selection on phones and leaves the composed DOM alone during an IME composition ([codemirror.net](https://codemirror.net/), [Haverbeke: CodeMirror 6 status update](https://marijnhaverbeke.nl/blog/codemirror-6-progress.html)).

The CM6 changelog shows continuous mobile work through 2026-10. Version 6.43.14 (2026-10-07) changes iOS selection drawing, 6.43.2 fixes Chrome Android select-all, and 6.38.4 works around a missing `compositionend` on Chrome Android ([CodeMirror changelog](https://codemirror.net/docs/changelog/)). The same stream proves that mobile editing is never finished. Replit moved its mobile IDE to CM6 and reports a **70 % rise in weekly mobile retention** ([Replit: Betting on CodeMirror](https://blog.replit.com/codemirror)). A textarea overlay gets the best native IME, Vietnamese Telex and CJK included, because the browser owns the input. CodeJar rewrites `innerHTML` on each highlight pass, which is the pattern that aborts a composition; that IME failure is an inference, not a test.

### Large files, theme, CSP and maintenance

CM6, Monaco and Ace render only the visible viewport. prism-code-editor's README says the editor slows past about 1,000 lines on most hardware ([FIameCaster/prism-code-editor](https://github.com/FIameCaster/prism-code-editor)). Agents in kitterm write lockfiles, logs and generated code far over that limit, so a non-virtualized engine needs a hard cap. CM6 themes are plain CSS, so `EditorView.theme` accepts `var(--ui-text)` and the editor follows the terminal theme with no JS. CM6 supports a CSP nonce for its injected styles since 6.17.0, and it needs no `eval` ([CodeMirror changelog](https://codemirror.net/docs/changelog/)). Monaco has a record of `unsafe-eval` and inline-style conflicts with a strict CSP ([monaco-editor #2488](https://github.com/microsoft/monaco-editor/issues/2488)).

All candidates use MIT or BSD-3-Clause licences. `@codemirror/view` had **40 releases** in the last 12 months; Monaco and Ace had 4 each; CodeJar and stable PrismJS had 0 ([npm @codemirror/view](https://www.npmjs.com/package/@codemirror/view), [npm prismjs](https://www.npmjs.com/package/prismjs)). The CM6 risk is one primary maintainer. Sponsors such as Obsidian, Replit and Sourcegraph reduce that risk ([codemirror.net](https://codemirror.net/)). The industry trend agrees: Sourcegraph, Gitea 1.26 and Forgejo v14 replaced Monaco with CM6 for small-edit use ([Sourcegraph](https://sourcegraph.com/blog/migrating-monaco-codemirror), [Gitea 1.26.0](https://blog.gitea.com/release-of-1.26.0/), [Forgejo PR #10697](https://codeberg.org/forgejo/forgejo/pulls/10697)).

## Terminal tools deliver all three features for zero web bytes

### Editor and git tool choice

Micro is one 4 MiB binary with Ctrl-S, Ctrl-C and Ctrl-V keys, full mouse support and "over 130 languages" ([micro README](https://raw.githubusercontent.com/zyedidia/micro/master/README.md)). Its tree is the `filemanager` plugin, which does not see changes made outside the plugin ([filemanager-plugin](https://github.com/NicolaiSoeborg/filemanager-plugin)). That limit matters because Claude Code edits the same tree. Helix has the best result with no config: a file picker, a file explorer since 25.07 and 342 language entries ([helix CHANGELOG](https://github.com/helix-editor/helix/blob/master/CHANGELOG.md), [languages.toml](https://raw.githubusercontent.com/helix-editor/helix/master/languages.toml)). Helix is modal, its release unpacks to about 217 MB, and its newest release (25.07.1) is 15 months old. Neovim needs plugins for a tree and for broad tree-sitter support.

Lazygit is the best git tool for kitterm. It stages hunks and lines, commits, pushes, branches, stashes and rebases, takes mouse input and ships as one 6 MiB MIT binary ([lazygit README](https://raw.githubusercontent.com/jesseduffield/lazygit/master/README.md)). Gitui is keyboard-only, and tig has no native push or branch create ([gitui README](https://raw.githubusercontent.com/gitui-org/gitui/master/README.md), [tig manual](https://jonas.github.io/tig/doc/manual.html)). A pane runs these tools as the user, in the pane's cwd, with the user's git config, hooks, ssh-agent and signing. That shared context needs zero integration code and zero new daemon routes.

### Three gaps in xterm.js

The terminal stack fails in three places, and all three gaps are in kitterm, not in the tools. First, kitterm does not load `@xterm/addon-clipboard`, so an OSC 52 yank never reaches the browser device ([package.json](../../../../Web/terminal/package.json)). On a phone over `--lan`, micro's default `pbcopy` writes the Mac's clipboard instead, which silently loses the copy. Second, xterm.js skips its own touch handling while mouse reporting is on, so a finger drag does not scroll an alternate-screen app ([xterm.js #5377](https://github.com/xtermjs/xterm.js/issues/5377), [claudecodeui PR #1476](https://github.com/siteboon/claudecodeui/pull/1476)). Third, Chrome reserves Ctrl-W, Ctrl-T and Ctrl-N on Linux and Windows hosts ([Chromium issue 41081444](https://issues.chromium.org/issues/41081444)). macOS Chrome uses Cmd for those keys, so the Mac desktop case is safe.

The terminal stack also has two limits that kitterm cannot fix. A screen reader reads a TUI as a grid of cells, not as a text field. Phone editing gets no native selection handles, no soft-keyboard cursor control and no autocorrect control. Kitterm's extra-keys row already gives Esc, Tab, sticky Ctrl and arrows ([extra-keys.ts](../../../../Web/terminal/src/extra-keys.ts)), so short edits and lazygit taps work. Long edits on a phone stay poor.

## The tree and the git panel reuse two existing daemon parts

### Directory tree

`GET /api/files?path=&session=` already lists one directory, directories first, capped at 1,000 entries, off the event loop, at full grade ([HTTPAPIHandler.swift:2696-2769](../../../../Sources/KittermDaemon/HTTPAPIHandler.swift), [FileBrowser.swift:54-89](../../../../Sources/KittermDaemon/FileBrowser.swift)). One request per expanded folder is the same lazy model that VS Code uses ([VS Code: Staging and committing](https://code.visualstudio.com/docs/sourcecontrol/staging-commits)). A tree must never list recursively. To hide ignored files, the daemon asks git with `git check-ignore -z --stdin` and does not port the ignore rules to JS. VS Code's own port stopped at the first `.gitignore` that it found ([microsoft/vscode#189951](https://github.com/microsoft/vscode/issues/189951)). File badges (U, M, D) come from one `git status --porcelain=v2 -z` call, and a folder gets a badge when a changed path is under it.

### Git operations

Every reviewed tool surfaces the same daily set: status, diff of one file, stage and unstage, commit, push, pull or fetch, branch switch and create, discard, amend and stash ([VS Code: Source control overview](https://code.visualstudio.com/docs/sourcecontrol/overview), [jupyterlab/jupyterlab-git](https://github.com/jupyterlab/jupyterlab-git)). The owner's six features (status, diff, stage, commit, push, branch) are the first six of that list. Hunk staging is the next tier; the plan leaves it to lazygit. A unified diff works at every width. VS Code switches from side-by-side to inline below 900 px, so phase 3 starts with unified only.

The git CLI on the daemon is the correct engine. It runs the user's hooks, signing, LFS, worktrees, SSH and credential helpers with no extra code. isomorphic-git has no SSH and no LFS, and it cannot read the real `.git` from the browser ([isomorphic-git#231](https://github.com/isomorphic-git/isomorphic-git/issues/231), [isomorphic-git#1375](https://github.com/isomorphic-git/isomorphic-git/issues/1375)). Kitterm already has the hardened runner: `PullRequestStatus.run` spawns in its own process group with a 20 s timeout, then `SIGTERM` and `SIGKILL` ([PullRequestStatus.swift:552-680](../../../../Sources/KittermDaemon/PullRequestStatus.swift)). `KnowledgeBase.environment` already sets `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=true`, `GIT_SSH_COMMAND=ssh -oBatchMode=yes` and `GIT_LITERAL_PATHSPECS=1` ([KnowledgeBase.swift:250-273](../../../../Sources/KittermDaemon/KnowledgeBase.swift)). No daemon code runs `git status`, `git add` or `git commit` today, so the routes, the parsers and the tests are new.

### Refresh after external changes

The simplest working refresh is a poll of one `git status` every few seconds per open repository. The poll skips while a run is in flight, as `refreshIfDue` does for `gh`. Every status read must pass `--no-optional-locks`. Without that flag, a background status takes `index.lock` and makes an agent's `git commit` fail ([git-status docs](https://git-scm.com/docs/git-status), [openchamber#4617](https://github.com/openchamber/openchamber/pull/4617)). Status cost grows with the tree. Git's measured time on a 393K-file Chromium checkout was 17.6 s without fsmonitor and 0.83 s with it, in June 2022 data ([GitHub blog](https://github.blog/engineering/infrastructure/improve-git-monorepo-performance-with-a-file-system-monitor/)). The daemon must not turn on `core.fsmonitor` in the user's repository; that setting is the user's config.

## A save route is the first write outside `~/.kitterm/`

### Current write boundary

Every HTTP route that writes to disk today writes only under `~/.kitterm/`: drops, archives, push subscriptions, the quota file and the respawn hints ([AGENTS.md](../../../../AGENTS.md)). The drop route states the boundary: "a write into a known place rather than a way to write anywhere" ([HTTPAPIHandler.swift:2771-2780](../../../../Sources/KittermDaemon/HTTPAPIHandler.swift)). The read route `GET /api/files/content` has no jail; `FileBrowser.resolve` follows symlinks ([FileBrowser.swift:35-50](../../../../Sources/KittermDaemon/FileBrowser.swift)). That openness is acceptable for reads because a full token can already type `cat`. A write route with the same openness is a wider boundary than any route that exists. The route switch has no `PUT` case, and every body over 64 KiB overflows unless a predicate like `isDropUpload` raises the cap ([HTTPAPIHandler.swift:200-243](../../../../Sources/KittermDaemon/HTTPAPIHandler.swift)).

### Path jail rules

Every recent write-capable CVE in this class checks a string and then opens by path. filebrowser followed symlinks in its handlers (CVE-2026-54094) and then created files through a dangling symlink (CVE-2026-55668) ([GitLab advisory](https://advisories.gitlab.com/golang/github.com/filebrowser/filebrowser/v2/CVE-2026-54094/), [Miggo](https://www.miggo.io/vulnerability-database/cve/CVE-2026-55668)). Jupyter Server used a prefix test with no trailing separator (CVE-2026-5422) ([NVD](https://nvd.nist.gov/vuln/detail/CVE-2026-5422)). Deno missed NFD and case variants on APFS (CVE-2026-49401) ([GitLab advisory](https://advisories.gitlab.com/cargo/deno/CVE-2026-49401/)).

The safe pattern already exists in kitterm for reads. `KnowledgeFile` walks one descriptor from the root with `openat(..., O_NOFOLLOW)` per component and takes the type and size from `fstat` ([KnowledgeFile.swift:82-97, 203-247](../../../../Sources/KittermDaemon/KnowledgeFile.swift)). The write route adds `O_NOFOLLOW_ANY` on macOS 11+ and creates the temp file with `O_CREAT|O_EXCL|O_NOFOLLOW` ([open(2)](https://keith.github.io/xcode-man-pages/open.2.html)). It refuses any file that is not `S_ISREG` and any file with `st_nlink > 1`. It refuses writes into `.git/` by an `(st_dev, st_ino)` compare, not by a byte compare of the path. The jail root is the project root that `PtySession.project(forCwd:)` resolves, so an edit outside every project is refused.

### Atomic save and conflicts

The save writes a temp file in the same directory, calls `fsync`, copies the mode with `fchmod`, and renames over the target with `renameatx_np(..., RENAME_NOFOLLOW_ANY|RENAME_RESOLVE_BENEATH)` ([rename(2)](https://keith.github.io/xcode-man-pages/rename.2.html)). The rename replaces the inode, which file watchers such as `vite` and `tsc --watch` handle well. The cost is a broken hard link, so the route refuses hard-linked files and does not rewrite them silently.

The conflict token must hash the content. VS Code's token is mtime and size, and it loses an edit that keeps the same length ([microsoft/vscode #119002](https://github.com/microsoft/vscode/issues/119002)). An agent that edits the same file in a pane makes that case likely. The read sends an `ETag` of the SHA-256 of the bytes, and the save requires `If-Match`. The daemon answers 412 on a mismatch and 428 when `If-Match` is missing. The page refuses edit mode when `X-Kitterm-Truncated` is `1`, because a save of a cut file destroys the rest. The current read route sends no `ETag`, so phase 2 adds one ([HTTPAPIHandler.swift:4363-4379](../../../../Sources/KittermDaemon/HTTPAPIHandler.swift)).

### Origin, CSRF and audit rules

The localhost dev-server CVEs are Origin and Host failures: code-server CVE-2023-26114, webpack-dev-server CVE-2025-30360 and Vite CVE-2025-24010 ([GHSA-frjg-g767-7363](https://github.com/advisories/GHSA-frjg-g767-7363), [sapphi.red retrospective](https://green.sapphi.red/blog/addressing-source-code-leaks-across-the-ecosystem-a-retrospective)). Kitterm's `AccessPolicy.decide` already rejects a non-loopback `Host` or `Origin`, and the cookie is `SameSite=Strict` ([AccessPolicy.swift:88-139](../../../../Sources/KittermDaemon/AccessPolicy.swift)). The save route adds an exact `Origin` match, a custom header such as `X-Kitterm-Editor: 1`, and no `Access-Control-Allow-Origin`. The `/edit` page gets a strict CSP; CM6 needs only a `style-src` nonce. Each write appends one line to a 0600 audit log under `~/.kitterm/`: the time, the token kind, the path, the size and both hashes, never the content.

### Git command rules

Git commands treat every ref, path and message as data. Refs go after `--end-of-options` and paths after `--`. A name that starts with `-` is refused, and a branch name must pass `git check-ref-format --branch` unchanged ([nesbitt.io, "--end-of-options"](https://nesbitt.io/2026/07/21/end-of-options.html)). The daemon uses an allowlist of fixed subcommands, because GitPython's option blocklist fell to long-option abbreviation (CVE-2026-67325) ([GHSA-2f96-g7mh-g2hx](https://github.com/advisories/GHSA-2f96-g7mh-g2hx)). The commit message goes through `git commit -F -` on stdin. Read commands add `-c core.fsmonitor=`, because a repository's own config can run a command on a plain `git status` ([justinsteven advisory](https://github.com/justinsteven/advisories/blob/main/2022_git_buried_bare_repos_and_fsmonitor_various_abuses.md)). Commit keeps the user's global config, because `user.name`, `user.email` and the signing key live there.

### Grade for each route

A plain file save is a person editing their own file in their own browser. That is the argument that puts the drop route and `PATCH /api/sessions/<id>` at full grade without `--agent-control` ([AGENTS.md](../../../../AGENTS.md)). The save route follows it. A commit runs the repository's `pre-commit` and `commit-msg` hooks, so a commit from the browser runs repository code as the user. That power equals `POST …/input`, so stage, commit, push and branch switch sit behind full grade plus `--agent-control`. A watch token reaches no editor route, the reads included, because the file content route is full grade today.

## Seven plug-in points connect `/edit` to the existing code

The `/md` page (commit `afaab7d`) is the template, and the editor follows its shape. The plug-in points, in build order, are these:

| # | File or route | Change | Exists today |
|---|---|---|---|
| 1 | `Web/terminal/edit.html`, `src/edit.ts`, `src/edit.css`, [vite.config.ts](../../../../Web/terminal/vite.config.ts) | A fourth Vite input, `edit` | `main`, `sessions`, `md` |
| 2 | `case (.GET, "/edit")` in [HTTPAPIHandler.swift](../../../../Sources/KittermDaemon/HTTPAPIHandler.swift), [StaticPageRouteTests.swift](../../../../Tests/KittermDaemonTests/StaticPageRouteTests.swift) | One route case and one test | `/md` at line 551 |
| 3 | `GET /api/files/content` | Add an `ETag` header | Read route, 256 KiB cap, no `ETag` |
| 4 | `PUT /api/files/content` + a body-cap predicate | New jailed atomic write, 412 and 428 answers | None |
| 5 | Tree from `GET /api/files` | Client tree, one level per expand | Listing route, [file-picker.ts](../../../../Web/terminal/src/file-picker.ts) helpers |
| 6 | `.preview-controls` in [file-preview.ts](../../../../Web/terminal/src/file-preview.ts), the `/md` header | An `edit` link beside `open full width` | `open full width` link |
| 7 | Git routes on `PullRequestStatus.run` | Status, diff, then writes | Runner and git environment |

The editor is a page, not a split leaf. `PaneSession` has no pane-kind field and `layout-store` is at `VERSION = 1`, so a non-terminal leaf touches many code paths ([layout-store.ts:30-48](../../../../Web/terminal/src/layout-store.ts)). The page reuses `applyThemeTokens`, `resolveFontFamily` and the `--ui-*` tokens, so it follows the terminal theme ([md.ts](../../../../Web/terminal/src/md.ts), [tokens.css](../../../../Web/terminal/src/tokens.css)). "The page holds no action" binds only `/sessions`; `sessions-no-input.test.ts` renders `sessions.ts` alone ([sessions-no-input.test.ts](../../../../Web/terminal/src/sessions-no-input.test.ts)). Principles 4 and 5 of `design/foundation.md` still bind `/edit`: monospace, hairlines, no radius above 2 px and no transition ([foundation.md](../../../../design/foundation.md)). The editor needs an approved frame, for example `design/editor.pen`, at 390 px and 1200 px before a round builds it.

Two existing decisions push back against CM6. `highlight.ts` has no library dependency by decision, and kitterm's six runtime dependencies are all xterm packages ([highlight.ts:10-16](../../../../Web/terminal/src/highlight.ts), [package.json](../../../../Web/terminal/package.json)). CM6 adds the `@codemirror/*` and `@lezer/*` packages. The cost is limited because only the `/edit` input imports them. The textarea overlay on `highlight.ts` is the option for an owner who refuses that dependency; it accepts coarse highlighting and a full rescan per change.

## Decision record

### Title

Build the kitterm editor as terminal tools first, then a CodeMirror 6 page with a jailed save route.

### Status

Proposed. Under `docs/goals/LOOP.md`, `docs/adr/` takes a proposal, not an edit. The next free number is `docs/adr/0005`.

### Context

The owner wants three features: a project tree, popular-language support and quick git control. The editor must stay light and minimalist. The terminal page already costs 167 KB gzip, and Monaco's core alone costs 703.1 KB gzip with no mobile support. The daemon must add no blocking I/O to the event loop and must pass `swift test` and `KittermBench` with no regression ([AGENTS.md](../../../../AGENTS.md)). Every current HTTP write stays under `~/.kitterm/`; an editor save is the first write into the user's projects. Claude Code edits the same files in the panes, so a save can race an agent. The phone is a target: the design rules require 44 px targets below 768 px. xterm.js touch support is "definitely not a priority" for its maintainer ([xterm.js #5377](https://github.com/xtermjs/xterm.js/issues/5377)).

### Decision

We deliver the editor in four phases. In phase 1, we run micro (or `$EDITOR`) and lazygit in kitterm panes, and we add write-only OSC 52, a touch-drag shim, an "open in editor" action and a layout preset. In phase 2, we build `/edit` on CodeMirror 6 with lazy languages, a tree on `GET /api/files`, and `PUT /api/files/content`. That save route is full grade, jailed to the project root by a descriptor walk, atomic by temp file and rename, and checked by a SHA-256 `If-Match`. In phase 3, we add read-only git routes for status and diff of one file. In phase 4, we add stage, commit, push and branch routes behind full grade plus `--agent-control`. We run the git CLI on the daemon through `PullRequestStatus.run`; we do not use a git library.

### Consequences

The good results come first. Phase 1 delivers all three features with 0 web bytes and no new write route, so the owner gets value before any security work. The `/edit` page costs about 120 KB gzip and leaves `main-*.js` unchanged. CM6 gives the best phone and IME behaviour of the full editors. The git CLI keeps the user's hooks, signing and SSH with no new auth code.

The bad results follow. Kitterm takes on a CM6 dependency with one primary maintainer, against the zero-dependency choice in `highlight.ts`. The save route widens the write boundary from `~/.kitterm/` to every project root, which needs an audit log and a test suite for symlinks, hard links, FIFOs and APFS name forms. The atomic save breaks hard links, so the route refuses hard-linked files. The editor gets no code intelligence; an LSP is a separate decision. Git writes are unavailable to a user who does not start the daemon with `--agent-control`; that user commits in lazygit. Phase 1 still leaves long phone edits poor and screen-reader access weak.

The options this decision closes are Monaco, Ace and isomorphic-git. It also closes an editor pane as a split leaf, an unjailed write route, and a save with no precondition.

## The phased plan

Each phase is shippable alone and ends with the project's own checks: `swift test`, `KittermBench` against a scratch daemon, `pnpm test` and `pnpm build` in `Web/terminal`, and screenshots at 390 px and 1200 px.

| Phase | Scope | Daemon change | Web change | Exit condition |
|---|---|---|---|---|
| 0. Decide | ADR 0005 proposal; `design/editor.pen` frames at 390 and 1200 px | None | None | The owner accepts the ADR and the frames |
| 1. Terminal stack | Write-only OSC 52 via `@xterm/addon-clipboard`; touch drag to wheel reports in the alternate screen; "open in `$EDITOR`" on a confirmed path link in a new split; layout preset editor, lazygit and shell; strip `:line:col` before stat | None | `terminal-pane.ts`, `path-links.ts`, `package.json` | A phone scrolls lazygit and micro; a yank reaches the phone clipboard |
| 2. `/edit` page | CM6 with a hand-written language list; tree; save; external-change notice; read-only for truncated, non-UTF-8 or NUL-bearing files; keep BOM and CRLF | `/edit` route; `ETag` on read; `PUT /api/files/content` with jail, atomic save, 412 and 428; body cap; audit log | `edit.html`, `edit.ts`, `edit.css`, `edit` link in the preview card | Tests pass for a symlink, a dangling symlink, a hard link, a FIFO, `.GIT/`, NFD names and a stale `If-Match` |
| 3. Git read | Branch name and ahead/behind; file badges; unified diff of the open file | `status --porcelain=v2 -z --branch` and `diff --no-color` with `--no-optional-locks` and `-c core.fsmonitor=`; serial queue per repository; poll that skips while a run is in flight | Badges in the tree, a diff view | No `index.lock` error in an agent's commit during a poll |
| 4. Git write | Stage and unstage a file, commit, push, branch switch and create | Allowlisted argv; `-F -` message; job id for slow hooks; 409 on a held `index.lock`; signing failure reported, no unsigned retry | Commit box and buttons | Hooks run and show their output; a password prompt fails fast with a clear message |

## What this research did not verify

No engine ran on a real iPhone or Android phone, and no test used Vietnamese Telex or a CJK IME. A Playwright WebKit run cannot reproduce a soft keyboard. The bundle sizes come from esbuild, not from kitterm's Vite build, so the real numbers can differ by a few percent. Nobody measured `tokenize` on a 256 KiB file, `git status` on a large checkout, or CM6 open time on 100k lines. Nobody tested `git commit` with gpg or ssh signing under `GIT_TERMINAL_PROMPT=0` on the owner's machine. The macOS version that first shipped `O_RESOLVE_BENEATH` is not confirmed. Some 2026 CVE numbers, CVE-2026-90930 among them, come from aggregators and need an NVD check before a design document cites them. On Linux, the daemon has no FSEvents, so a recursive watch hits the inotify limit; the poll design avoids that limit.

## Conclusion

The research changes the question. "Which editor engine" is a solved question: CM6 wins on size, phones and maintenance, and the industry moved the same way. The open question is the write boundary. Kitterm has kept every HTTP write inside `~/.kitterm/` until now, and a save route is the first exception. That exception is safe only with the descriptor walk that `KnowledgeFile` already uses, plus a content-hash precondition for the race with agents.

The phase order follows from that fact. Phase 1 gives the owner a tree, 130-plus languages and full git control before kitterm writes one byte into a project. The data from phase 1 then tells the owner whether phase 2 is worth its new boundary. If the owner edits mostly at a desk, micro and lazygit can be the whole answer. If the owner edits on a phone, the `/edit` page earns its 120 KB and its jail.
