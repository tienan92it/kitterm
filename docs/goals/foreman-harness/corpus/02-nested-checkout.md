# Request 02: a checkout under a registered parent is its own project

Approved 2026-09-10. Frozen.

## Fixture

A scratch state directory. A folder `<tmp>/work` registered with
`kitterm project add`, and a git checkout at `<tmp>/work/app` that is not
registered. One session spawned with cwd `<tmp>/work/app`, one with cwd
`<tmp>/work`.

## Request

`GET /api/sessions` and `GET /api/projects`.

## Expected behaviour

The session in `<tmp>/work/app` carries `project.id` of the discovered
`app`, with `registered` false. The session in `<tmp>/work` carries the
registered `work`. `GET /api/projects` lists both.

## Expected persistent effects

None. `projects.json` is unchanged.
