# The human's word: the REVIEW section responds at once

2026-10-27, after v0.48.1:

> REVIEW section PRs still update too delay. I need it response as soon
> as possible for reviewing

The foreman's reading the same day: round 8's adaptive reads, nudges
and `pulls.changed` hold, but two changes still wait for the next read,
up to `idleSeconds` (180 s) plus the page's 10 s:

- a change made on github.com (a merge, a ready, a close, a new pull
  request from the web);
- a crew's `gh pr create` or `git push`: Claude Code's Bash tool runs
  outside the pane's shell, so the pane records no mark and no command
  nudge fires (a `PROGRESS` or `DONE` note still nudges).

The foreman's measurement the same day: `gh api -i -H 'If-None-Match:
<etag>' 'repos/<o>/<r>/pulls?state=all&sort=updated&direction=desc&per_page=5'`
answers `304 Not Modified` while nothing changed, and three such calls
left `X-RateLimit-Remaining` unchanged at 4994; a call takes about 0.8 s
of `gh` start-up. Webhooks stay declined (`03-faster-pull-sync.md`).

The rules, named so the human can amend them:

1. **A change probe.** While a full-grade page watches a repository (the
   pulls route was asked for it in the last 30 s), the daemon sends the
   conditional REST request above every 5 s for that repository, with
   the `ETag` of the last answer, through the human's own `gh`.
2. **A changed answer reads at once.** A `200` with a new `ETag` starts
   the full `gh pr list` read at once, within round 8's one-read-at-a-
   time rule and the `readsPerMinute` ceiling; the read's
   `pulls.changed` repaints the page as before.
3. **Free when idle.** A `304` starts nothing. The probe runs off the
   event loop, one at a time per repository, stops when no page has
   watched for 30 s, backs off to 60 s after a failure, and never
   changes the GraphQL budget arithmetic of round 8.
4. **CI keeps its own pace.** A finished check does not change a pull
   request's `updated_at`, so a pending CI keeps round 8's 15 s full
   read.
5. The REVIEW rows, the goal lines and every word on the page stay as
   they are.
