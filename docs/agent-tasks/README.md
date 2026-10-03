# Agent tasks

How to trace a change in this repository back to the agent task that produced
it, and dated ledgers of what that trace found.

Many pull requests here are opened by the Hive's coding agents, each working
from an issue. An agent change leaves marks in the pull request and in the
commits. Together they answer "which task made this change, which agent role
and model wrote it, and which issue it was for". Nothing in this repository
writes these marks: the agents add them, and this page records what they
actually look like. It was written by reading the history, so each mark below
comes with the command that reads it and the date range it was observed over.

For the numbers behind every claim, see the dated ledger at the bottom. For how
the repository works, start from
[`.github/copilot-instructions.md`](../../.github/copilot-instructions.md).

## The marks

The examples use pull request #452, which was merged for issue #448. Replace
the number to read another pull request. The commands name
`Danathar/arch-bootc` so they read this repository whatever the clone's
remotes are.

**The signature line in the pull request body.** An agent's pull request body
carries a line beginning `— hive:`. It lists `agent=<role>`, `backend=`,
`model=`, and usually `effort=`. This is the most complete mark, but not a
perfect one: some agent pull requests carry no `agent=` role, and some carry no
signature at all (see the ledger).

```bash
gh pr view 452 --repo Danathar/arch-bootc --json body --jq '.body | scan("— hive: .*")'
```

**The branch prefix.** Agent branches are named `<role>/<slug>`. The prefixes
seen are `quality/`, `sec/`, `scanner/`, `architect/`, `arch/` and `guide/`. The
prefix is not the same word as the signature's role in every case: `sec-check`
signs `sec/` branches, and `architect` signs both `architect/` and `arch/`.
Maintainer branches use `fix/`, `docs/`, `ci/`, `feat/` and `test/`, and
Renovate uses `renovate/`. `fix/` and `sec/` are shared between both, so the
prefix names a role only when it is one of the first six.

```bash
gh pr list --repo Danathar/arch-bootc --state all --limit 1000 --json headRefName --jq '[.[] | .headRefName | split("/")[0]] | group_by(.) | map({prefix: .[0], count: length})'
```

**The commit author and trailers.** Some agent commits are authored by
`danathar-atomic-hive[bot]`, and some by a role address such as
`quality@hive.kubestellar.io`. Those commits carry a matching `Signed-off-by:`
line. A `Co-Authored-By: Claude ...` trailer names the model. This trailer is
not an agent-only mark, because the maintainer's own commits carry it too (see
the ledger), so read it for the model rather than for who ran the task.

```bash
git log --author='danathar-atomic-hive\[bot\]' --author='@hive\.kubestellar\.io>' --format='%h %an %s'
git log -i --grep='^Co-Authored-By: Claude ' --format='%h %an %s'
```

**The `Hive-Run:` trailer.** A commit can carry `Hive-Run:`, `Hive-Plan:` and
`Hive-Spec:` trailers that name the issue the run was for. Only one commit on
`main` carries them so far, `2d6ec2c` for issue #388, and it is authored as
`Danathar`. The trailers survive a squash or a rebase where a branch name does
not, but one commit is too few to rely on yet.

```bash
git log -i --grep='^Hive-Run: ' --format='%h %cs %an %s'
git log -i --grep='^Hive-Run: Danathar/arch-bootc#388$' --format='%h %s'
```

**The issue link.** The pull request template does not ask for one, but
agent pull requests usually say `Closes #<n>`, which GitHub reads into the
pull request's closing references. This is the mark that names the task's
issue most often.

```bash
gh pr view 452 --repo Danathar/arch-bootc --json closingIssuesReferences
```

## Why the pull request author is the wrong key

The Hive's GitHub App opens most agent pull requests, as
`app/danathar-atomic-hive`, but not all. Agent pull requests also appear under
the maintainer's login, `Danathar`: 12 of the 105 signed pull requests up to
#452. Counting the app account alone misses them. Going the other way, the
maintainer's login also opens ordinary hand-written pull requests, so counting
`Danathar` over-counts. Some pull requests opened by the app carry no
signature, and some on an agent branch prefix carry none either (the ledger
lists them). So no one mark is complete. Read the signature, then
the branch prefix, then the trailers, and say which one you used.

## What the ledgers hold

Each dated file below is one reading of these marks over a pinned range of pull
requests and commits, with the exact command under every table so it
reproduces. It is left as it was read. A rerun reads the same range but its
current state, so it can differ where a pull request in the range has changed
since. `tests/check-invariants.sh` holds each ledger to its pinning: the
commands name the repository, stop at the pinned pull request number, and read
`main` at the pinned commit; the jq programs run against the fields their
`gh` command requests.

This is the same shape as [`docs/metrics/`](../metrics/2026-09-24.md), for the
same reason. It records who did what, not how good it was; for that, see
[`docs/metrics.md`](../metrics.md).

## Ledgers

- [2026-10-03](2026-10-03.md): pull requests up to #452, `main` at `930ed2d`
