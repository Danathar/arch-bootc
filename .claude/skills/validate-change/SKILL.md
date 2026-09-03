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
- Run `./tests/run-tests.sh` for changes to shipped shell or the test harness.
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
