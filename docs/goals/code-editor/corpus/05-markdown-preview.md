# The human's word: Markdown preview in the editor

2026-10-23, after v0.46.0:

> integrate Markdown preview into editor

The human chose, from two drafts, the switch:

```
kitterm / README.md   [ ] source [x] preview   [ save ⌘S ]
┌ files ────┬ preview ─────────────────────────────┐
│ ▼ kitterm │ kitterm                              │
│   README  │ A terminal daemon with a ledger.     │
└───────────┴──────────────────────────────────────┘
```

The rules, named so the human can amend them:

1. A Markdown file on `/edit` shows `[x] source [ ] preview` in the
   header; another file shows no such toggle.
2. `preview` replaces the editor area with the rendered **buffer** (the
   unsaved edits included), drawn by `markdown.ts` and the prose rules
   of `markdown-preview` (the 980 px column, the `md-*` sizes, the
   table rules); every security rule of that renderer holds.
3. In the preview, a relative `.md` link opens that file in `/edit`
   (asking first when the buffer is edited), a `#fragment` scrolls, an
   external link opens in a new tab, and a relative image loads through
   the content route.
4. ⌘S and `[ save ]` save from either view; the buffer states and the
   changed-on-disk bar behave the same in both.
5. The choice is kept per viewer; `source` is the default.
6. On a phone the toggle sits in the header of the edit tab.
