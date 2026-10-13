# The approved design

2026-10-13, the human chose draft A of two browser drafts the foreman
drew on the live `/sessions` page with the page's own classes and the
machine's real listeners (`draft-a.png` beside this file; draft B grouped
the servers under project lines and was not chosen):

```
SERVERS   5 listening · 4 HTTP · 17 other
◐ localhost:3000  foundation-apps / next-server   outside kitterm · node     http  all hosts  25d
◐ localhost:4646  foundation-apps / next-server   outside kitterm · node     http  all hosts  25d
◐ localhost:3003  market-data-pipeline / kubectl  claude in a kitterm pane   http  loopback   46m
◐ localhost:8010  trading-data-api / python       outside kitterm · uv       http  all hosts  29d
◐ localhost:5432  postgres                        kitterm pane on ttys014    tcp   loopback    5d
▶ 17 other servers
```

The rules the draft fixes:

1. **One line per server, the REVIEW row's grid.** The cells, left to
   right: the mark, the address as `localhost:<port>` (a `pullRequestLink`-
   style link when the server answers HTTP, plain text otherwise), where
   it belongs (`<project> / <program>`, or the program alone with no
   project), who started it (the grey detail: the pane, `claude in` a
   pane, or `outside kitterm · <launcher>`), `http` or `tcp`, what it binds
   (`all hosts`, `loopback`), and its age.
2. **The header counts** what the list shows, how many answer HTTP, and
   the folded rest: `5 listening · 4 HTTP · 17 other`.
3. **The fold** `▶ N other servers` is the last line, closed by default,
   and opens to rows of the same shape.

4. **What the main list holds** (the human, 2026-10-13, after round 1
   found Homebrew's redis under a discovered project `homebrew`): a
   server is listed when a kitterm pane started it, or when its
   project's root lies under the user's home directory. Every other
   server folds, whatever project its cwd resolves to.

Still open for the Pen round: the mark (the draft borrowed `◐`, the
`[build]` mark, at rest), the phone layout, and the empty sentence.

The frames in `design/sessions.pen` that carry this design, and their
commit, are added here once the human approves them.
