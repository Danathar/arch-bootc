---
name: validate-change
description: Validate a focused arch-bootc change without crossing repository consent gates.
---

# Validate an arch-bootc change

Read `AGENTS.md` first. Inspect the complete diff and choose checks from the
changed paths; do not infer authorization for privileged or resource-consuming
validation.

## Always safe when relevant

- Run `git diff --check`.
- Run `bash -n` and `shellcheck` for changed shell scripts.
- Run `actionlint` and the pinned `zizmor` command for changed workflows when
  those tools are already available.
- Run `just test` for changes to shipped shell, to the test harness, or to
  anything `AGENTS.md`, `docs/`, `.github/` or the `Containerfile` states as a
  fact. It runs `./tests/check-coverage.sh` and `./tests/check-invariants.sh`,
  which is what CI runs; `./tests/run-tests.sh` on its own enforces neither the
  per-script coverage floors nor the repository invariants, so it can be green
  against a tree CI fails.
- Recheck `git status --short --branch` and make sure only intended paths changed.

## Separate consent gates

Ask before `just lint`, because it invokes `sudo` and builds a disposable
container. Ask separately before any image build, disk-image installation, VM
creation or boot, workflow mutation, publication, or cleanup. Follow
`CLAUDE.md` exactly for an authorized VM test.

## Report

State the command and exact outcome, affected flavors, anything skipped or
inconclusive, current branch/worktree state, and every external resource created
or modified. Passing static checks are not boot or upgrade evidence.
