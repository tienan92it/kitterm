# The human's word: the REVIEW section keeps up

2026-10-18, in the foreman's pane:

> Review section PR status update too slow. Are there any way to keep it
> sync up faster or watch them in realtime?

The foreman's measurement the same day: the daemon reads each GitHub
repository with `gh pr list` once every 60 s
(`PullRequestStatus.refreshSeconds`, one GraphQL call of 2.8 s) and the
page asks the pulls route every 10 s (`PULLS_REFRESH_MS`), so a change
on GitHub reaches the page in up to 70 to 80 s; seven projects have a
GitHub remote; the account's GraphQL budget is 5,000 points an hour,
shared with every crew's `gh`.

The human chose, from four options, options 1, 2 and 3:

1. **Adaptive reads.** A repository is read every 10 to 15 s while it
   has open work — an open pull request whose CI is `pending`, a pull
   request opened or changed in the last few minutes, or a live
   session carrying `pr:<N>` for it — and every 2 to 5 minutes
   otherwise.
2. **Local nudges.** The daemon reads a repository at once (within the
   minimum gap that keeps one read at a time) when a session whose
   project is that repository finishes `git push`, `gh pr create`,
   `gh pr merge`, `gh pr ready`, or `gh pr close`, and when a crew of
   that project posts a `PROGRESS` or `DONE` note.
3. **Push to the page.** A read that changes a repository's answer
   appends `pulls.changed` (with the project id) to the event feed,
   and the page, which already holds `/api/events` open, asks that
   project's pulls at once.

Not chosen: GitHub webhooks through a relay (`gh webhook forward`,
smee.io), which would bring changes made on github.com in about a
second but need an extension, admin rights on each repository and a
relay that can drop; options 1 to 3 stay the fallback if it is ever
added.
