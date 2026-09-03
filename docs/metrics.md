# Metrics

Process metrics for this repository: what gets proposed, how much of it lands,
and how long it takes. [quality.md](quality.md) covers the automated signals
that judge a change's *content*; this file covers the flow around them.

There is no metrics service and no scheduled job writing numbers anywhere. Every
figure below is derived on demand from the GitHub API with `gh`, which is
deliberate — a metric you can recompute in one command from the source of truth
does not drift, and does not become a second thing to maintain.

## PR acceptance

The headline metric: **of the pull requests opened against this repository, what
fraction merged?** A persistently low rate means work is being proposed that
does not fit — bad scoping, missing context, or automation opening changes
nobody wants.

```bash
gh pr list --state all --limit 200 --json state \
  --jq 'group_by(.state)[] | "\(.[0].state): \(length)"'
```

Split by author, because the number is close to meaningless unpooled — this
repository's PR volume is dominated by Renovate:

```bash
gh pr list --state all --limit 200 --json state,author \
  --jq 'group_by(.author.login)[] |
        "\(.[0].author.login): total \(length),
         merged \([.[]|select(.state=="MERGED")]|length),
         closed \([.[]|select(.state=="CLOSED")]|length)"'
```

Humans and agents only, excluding bots:

```bash
gh pr list --state all --limit 200 --json state,author \
  --jq '[.[] | select(.author.login | startswith("app/") | not)] |
        {total: length,
         merged: ([.[]|select(.state=="MERGED")]|length),
         closed: ([.[]|select(.state=="CLOSED")]|length),
         open:   ([.[]|select(.state=="OPEN")]|length)}'
```

Read a closed-unmerged PR as the signal, not the failure. The interesting
question is always *why* it closed: superseded, wrong approach, or scope the
repository did not want.

## Time to merge

How long a change sits between opening and landing. Use the median, not the
mean — one PR left open over a weekend distorts an average badly at this volume.

```bash
gh pr list --state merged --limit 200 --json createdAt,mergedAt \
  --jq '[.[] | (((.mergedAt|fromdate) - (.createdAt|fromdate)) / 3600)] | sort |
        {count: length, median: .[length/2|floor], p90: .[length*0.9|floor]}'
```

Bot PRs automerge on a green build, so their time-to-merge is really a measure
of CI duration. Filter them out to measure review latency instead:

```bash
gh pr list --state merged --limit 200 --json createdAt,mergedAt,author \
  --jq '[.[] | select(.author.login | startswith("app/") | not)
             | (((.mergedAt|fromdate) - (.createdAt|fromdate)) / 3600)] | sort |
        {count: length, median: .[length/2|floor]}'
```

## Review friction

How often review actually catches something, and how much rework follows.

```bash
# Review comments per merged PR (a rough proxy for how much review found)
gh pr list --state merged --limit 50 --json number \
  --jq '.[].number' |
  while read -r n; do
    printf '%s\t%s\n' "$n" "$(gh api "repos/:owner/:repo/pulls/$n/comments" --jq 'length')"
  done
```

Zero across the board is not necessarily good news — it can mean review is
thorough, or that nobody is reviewing. Read it next to the acceptance rate.

## CI health

The build workflow's own reliability. A rising failure rate on `main` usually
means Arch moved underneath the image rather than that a commit was bad — the
daily schedule plus `PACMAN_CACHE_BUST` mean every build genuinely pulls today's
packages.

```bash
gh run list --branch main --limit 30 --json conclusion,workflowName \
  --jq 'group_by(.workflowName)[] |
        "\(.[0].workflowName): \([.[]|select(.conclusion=="success")]|length)/\(length) green"'
```

Duration, which is what the `timeout-minutes` caps in the workflows are sized
against:

```bash
gh run list --branch main --limit 20 --workflow "Build container image" \
  --json databaseId,createdAt,updatedAt \
  --jq '.[] | (((.updatedAt|fromdate) - (.createdAt|fromdate)) / 60 | floor)'
```

## Snapshot

Recomputed by hand; these are not maintained automatically and will be stale the
moment something merges. Rerun the commands above rather than trusting the
numbers here.

**As of 2026-09-03:**

| Metric | Value |
| --- | --- |
| PRs opened, all time | 113 |
| Merged | 106 |
| Closed unmerged | 4 |
| Open | 3 |
| Acceptance rate, all authors | 106 / 110 resolved (96%) |
| Acceptance rate, excluding bots | 27 / 27 resolved (100%) |
| Median time to merge, all authors | ~3.3 h |
| Median time to merge, excluding bots | ~0.4 h |

By author: Renovate 81 (76 merged, 3 closed), `Danathar` 28 (27 merged),
`danathar-atomic-hive` 2 (2 merged), `copilot-swe-agent` 2 (1 merged, 1 closed).

Two caveats worth stating rather than letting the table imply otherwise. The
non-bot median of about 24 minutes reflects a repository with a single
maintainer who reviews and merges their own work — it measures throughput, not
review latency in the usual sense. And a 100% non-bot acceptance rate means
approximately what you would expect when the author and the merger are the same
person; it is a useful baseline to watch for change, not evidence of quality.

## What is deliberately not measured

- **Lines of code, commits, or files changed.** Not correlated with anything
  worth optimizing here.
- **Test count.** The coverage floors in `.coverage-thresholds.json` already
  gate this per script, and a raw count rewards adding shallow tests.
- **Issue counts.** Volume is dominated by automated ACMM and dependency-audit
  filings, so the number tracks how many bots are pointed at the repository.
