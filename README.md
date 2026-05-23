# just-buildit.github.io

Org-pages root for [github.com/just-buildit](https://github.com/just-buildit).

Serves the small static resources the toolchain depends on:

- `get-just-runit.sh` — installs `jx` (the universal entrypoint)
- `aliases.toml` — default-namespace alias manifest read by `jx`
- (eventually) `get-just-makeit.sh`, `get-just-bashit.sh`, `get-just-buildit.sh`
- `index.html` — minimal landing page

## How the mirror works

`get-just-*.sh` scripts live in their source repos under `src/`. A
GitHub Actions workflow (`.github/workflows/mirror.yml`) fetches them
on a daily cron, on manual dispatch, and on a `repository_dispatch`
event of type `mirror`. Source repos can fire that event from their
own CI on every push to `main`, making the mirror near-instant.

To add a new mirrored script: append an entry to the `SOURCES`
associative array in the workflow and commit.

## Local edits

`aliases.toml` and `index.html` are hand-edited in this repo. The
mirror workflow only touches `get-just-*.sh` files.

## Pages settings

GitHub auto-enables Pages for repos named `<org>.github.io`; no
configuration needed. The `.nojekyll` file disables Jekyll processing
so raw files (including `.sh` and `.toml`) are served as-is.
