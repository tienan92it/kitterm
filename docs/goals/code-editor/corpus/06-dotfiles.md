# The human's word: dotfiles in the editor tree

2026-10-23, after v0.47.0:

> why I don't see environment files (.env, .dev...) or files with dot (.)
> prefix in editor?

The cause: the tree asks `GET /api/files` without `hidden=1`, so the
daemon lists with `.skipsHiddenFiles` and every name that starts with
`.` drops out. The human chose, from two options, to always show them:

> 1, run it as a chore. Editor should behave as the normal editors

The rules, named so the human can amend them:

1. The `/edit` tree lists the entries whose names start with `.`
   (`.env`, `.github/`, `.gitignore`) in every folder, with no toggle.
2. The tree hides what a normal editor hides by default, VS Code's
   `files.exclude`: `.git`, `.svn`, `.hg`, `CVS`, `.DS_Store` and
   `Thumbs.db`. The tree drops these names itself and does not rely on
   the listing.
3. A dotfile row looks and acts like every other row: it opens, saves,
   and wears its git badge. The listing's order holds: folders first,
   then by name.
4. Only the `/edit` tree changes. The pane's file browser and the
   listing route's default stay as they are.
