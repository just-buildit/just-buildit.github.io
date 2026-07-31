# just-buildit.github.io

Org-pages root for [github.com/just-buildit](https://github.com/just-buildit).

Serves the small static resources the toolchain depends on:

- `get-jb.sh` — installs `jbx` (the universal entrypoint)
- `aliases.toml` — default-namespace alias manifest read by `jbx`
- `standard.mk` — the cross-org Makefile standard, vendored by every repo in
    `just-buildit` and `doppler-dsp`
- (eventually) `get-just-makeit.sh`, `get-just-bashit.sh`, `get-just-buildit.sh`
- `index.html` — minimal landing page

## Using `standard.mk`

The shared Makefile every repo in `just-buildit` and `doppler-dsp` vendors.
Design: doppler-dsp/doppler#555. Scope and success criteria: the
just-buildit/.github README.

### Getting started (once)

```sh
curl -fsSL -o standard.mk https://just-buildit.github.io/standard.mk
```

- In `Makefile`: set the `HAS_*` flags and command variables, then
    `include standard.mk`. Nothing shared goes in this file.
- Repo-only targets go in `local.mk`, named in `LOCAL_TARGETS` so `help` and
    the gates see them.
- Run `make lint`. Vendoring the file is what arms the drift gate — there is
    no second line to remember, and no way to forget it.

**Always fetch canonical; never copy another repo's `standard.mk`.** A sibling
may be behind, and adopting a stale copy is the one way to end up with the
drift gate switched off while everything still reports green.

### Every day

| command                                |                                                               |
| -------------------------------------- | ------------------------------------------------------------- |
| `make help`                            | the real target list, generated from `##`, never hand-written |
| `make format`                          | fix formatting                                                |
| `make lint`                            | the gate CI runs — exactly this, nothing else                 |
| `make test` / `test-fast` / `test-all` | the suites                                                    |
| `make gates`                           | everything that guards a merge; run before pushing            |

### Changing something

- **Repo-specific** → change a variable in your `Makefile`.
- **Shared** → edit canonical here, then re-vendor in every adopter.
- **Never edit `standard.mk` in place.** It is vendored verbatim; a local edit
    is the fork this exists to prevent, and `make lint` fails on it.
- **A new linter** → add it to `LINT_TOOLS` and define `LINT_<tool>`; the
    pre-commit hook dispatches to the `make -s lint-<tool>` that results.

### What will stop you, and what it means

| message                           | meaning                                              |
| --------------------------------- | ---------------------------------------------------- |
| `standard.mk differs from …`      | your copy drifted — re-fetch canonical               |
| `cannot fetch …`                  | the gate could not reach its reference, so it failed |
| `'X' has no '## description'`     | undocumented target, or a rule `help` omits          |
| `.PHONY targets with no recipe`   | a target that exits 0 having done nothing            |
| `HAS_X is on, but X_CMD is empty` | flag enabled, its command never set                  |

### One job per file

| file                      | owns                                                   |
| ------------------------- | ------------------------------------------------------ |
| `pyproject.toml`          | **which** tools, at **what** versions (`uv.lock` pins) |
| `Makefile`                | **how** they run — the only place a tool is named      |
| `.pre-commit-config.yaml` | **when** they run; dispatches to `make -s lint-*`      |
| `.github/workflows`       | calls `make <target>`; anything else is plumbing       |

`make lint` needs network, by design: it compares your vendored copy against
this file every time, with no cache. A gate that cannot reach its reference has
not passed — it has not run, and it says so by failing.

## How the mirror works

`get-just-*.sh` scripts live in their source repos under `src/`. A
GitHub Actions workflow (`.github/workflows/mirror.yml`) fetches them
on a daily cron, on manual dispatch, and on a `repository_dispatch`
event of type `mirror`. Source repos can fire that event from their
own CI on every push to `main`, making the mirror near-instant.

To add a new mirrored script: append an entry to the `SOURCES`
associative array in the workflow and commit.

## Local edits

`aliases.toml`, `index.html` and `standard.mk` are hand-edited in this
repo. The mirror workflow only touches `get-just-*.sh` files.

`standard.mk` is **canonical here**, and this repo is deliberately not one
of its adopters — it has no `Makefile`, so it consumes nothing it also
defines. Every adopter vendors a byte-identical copy and gates on the
difference (`make lint` runs a `standard-check` that fetches this file and
fails on any drift, and fails rather than skips when it cannot reach it).

So editing this file changes every repo's `make lint` the moment it deploys.
The order that follows from that: land the change here, confirm
<https://just-buildit.github.io/standard.mk> serves it, then re-vendor in
each adopter. Design RFC: doppler-dsp/doppler#555; plan and success criteria:
the just-buildit/.github README.

## Pages settings

GitHub auto-enables Pages for repos named `<org>.github.io`; no
configuration needed. The `.nojekyll` file disables Jekyll processing
so raw files (including `.sh` and `.toml`) are served as-is.
