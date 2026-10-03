# Strategy

Where this project is trying to get to, how far away it is, and whether the
work being merged is taking it there. Open it before deciding what to work on
next, or before pointing an agent at something.

Like [`docs/metrics.md`](metrics.md), this page keeps no running numbers. Each
answer is a command against data the project already holds, so the page cannot
go out of date: run the command for today's answer. The one reading quoted
here is pinned to a date and range, and says so.

## The goal

The goal is to leave beta. The README's
[*Project status*](../README.md#project-status) section lists the criteria for
calling the image stable, as boxes, and says what each one needs. This page
does not copy them. It gives the command that measures progress on each, in the
same order, and a box is ticked in the README, not here.

Two things follow from how the criteria are written. Merged work moves a box
only when it changes what CI does, what is published, or what has been seen to
break. And the weeks criterion cannot start counting until the three before it
hold.

## Measuring each criterion

One entry per box, in the README's order. Each entry opens with the first
words of its box. `<date>` is a day written `YYYY-MM-DD`; every search is
pinned to it, so a command gives the same answer on that day and a month later.
The `git grep` commands read the checked-out tree, so run them in a clone at the
commit you mean to measure.

**CI boots the built** image in a VM: an active workflow line that starts one.
No output means no workflow boots anything. The pattern is the one
`tests/check-invariants.sh` uses to keep the README's first box open while this
is true; that script's own match also skips commented lines, so a hit here that
is only a comment is not a job.

```bash
git grep -nE 'qemu-system|virt-install|virsh[[:space:]]|systemd-vmspawn|bcvk' -- .github/workflows
```

**CI upgrades a system** deployed from the previous image: an active workflow
line that runs `bootc upgrade` or `bootc switch`. No output means none does.

```bash
git grep -nE 'bootc[[:space:]]+(upgrade|switch)' -- .github/workflows
```

**Images are published under** tags that are never pruned: the releases the
repository has published, and the tag rules the build workflow applies. No
release output means there are none. The tag rules are the build workflow's
`type=raw`, `type=sha` and `type=ref` lines: the moving `latest`, a date, and
pull request tags. The date ones are pruned, so none is a release tag.

```bash
gh release list --repo Danathar/arch-bootc --limit 1000
git grep -nE '^[[:space:]]+type=(raw|sha|ref)' -- .github/workflows/build.yml
```

**Eight consecutive weeks of** `:latest` without a reported boot, upgrade or
login regression: every issue opened since the window started, read by title.
Agent-filed issues carry a `[scanner]`, `[architect]` or `[quality]` title
prefix and do not always carry the `bug` label, so the label alone can miss
one. The first command lists the labelled ones and the second lists all of
them. Which are boot, upgrade or login problems has to be read from the issue.
Start the window the day the first three boxes hold, not before.

```bash
gh issue list --repo Danathar/arch-bootc --label bug --state all --limit 1000 --search "created:>=<date>" --json number,title,state
gh issue list --repo Danathar/arch-bootc --state all --limit 1000 --search "created:>=<date>" --json number,title,state
```

**The manual VM check** in [CLAUDE.md](../CLAUDE.md) is no longer the only
place first-boot behaviour is verified: every place in `tests/` that names a VM
tool. A hit has to be read. At the reading below the only hits are in
`tests/e2e/test-quickstart-dry-run.sh`, which runs the quickstart with
`--dry-run`, so nothing there boots a VM.

```bash
git grep -nE 'virt-install|qemu-system|systemd-vmspawn|bcvk' -- tests ':!tests/check-invariants.sh'
```

## Is the work going there?

**What has merged since a date**, by branch prefix. Use the day the criteria
were last changed, or the day the last box was ticked. The prefix is the
nearest thing to "what kind of work" the history records.

```bash
gh pr list --repo Danathar/arch-bootc --state merged --limit 1000 --search "merged:>=<date>" --json headRefName --jq 'map(.headRefName | split("/")[0]) | group_by(.) | map({prefix: .[0], count: length}) | sort_by(-.count)'
```

Read it against the section above. A large count under `quality/`, `sec/` or
`renovate/` and no change in any command above is a repository working on its
guardrails and its dependencies, which may be worth doing, but is not progress
on a box.

**What is waiting on the maintainer.** Issues labelled `needs-human` need a
person to decide before an agent goes further, and open pull requests labelled
`hold` have not yet had a maintainer review. No output means nothing is waiting
under that label.

```bash
gh issue list --repo Danathar/arch-bootc --label needs-human --state open --limit 1000
gh pr list --repo Danathar/arch-bootc --label hold --state open --limit 1000
```

### Reading on 2026-10-03

Taken on 2026-10-03 with the commands above, `<date>` set to 2026-09-30, the
day the criteria were added to the README (PR #426). Pull requests are bounded
with `merged:2026-09-30..2026-10-03` instead of `>=`, so a rerun reads the same
range.

| Command | Result |
| --- | --- |
| Workflow lines that boot a VM | none |
| Workflow lines that run `bootc upgrade` or `bootc switch` | none |
| Releases published | none |
| Pull requests merged, 2026-09-30 to 2026-10-03 | 17: `quality/` 7, `architect/` 3, `scanner/` 3, `renovate/` 2, `fix/` 1, `guide/` 1 |
| Issues opened in that range | 18, of which 1 labelled `bug` |
| Waiting on `needs-human` or `hold` | none |

None of the five boxes moved in that range.

## Why there is no report job

There is no scheduled workflow that writes a strategy report, and no dashboard
service. [metrics.md](metrics.md) declines both for the same reason: a number
you can recompute in one command from the source of truth does not drift, and
a job that writes it down is a second thing to keep working. The boxes change
rarely, so reading them on demand costs less than maintaining a job nobody
opens.
