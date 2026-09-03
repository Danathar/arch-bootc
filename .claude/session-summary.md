# Session summary

A handoff note for the next agent or maintainer picking this repository up
cold. It is the *volatile* half of this repository's memory: what is in flight
right now, and what was learned that has not yet been written down properly.

## Where knowledge actually lives

This file is deliberately not the durable record. Anything that stays true
belongs in one of these instead, and should be moved there in the same pull
request that discovers it:

| Where | What belongs there |
| --- | --- |
| [AGENTS.md](../AGENTS.md) | Repository-wide policy: consent gates, safety rules, validation expectations |
| [CLAUDE.md](../CLAUDE.md) | The VM test procedure and its hard-won gotchas |
| [docs/](../docs/) | Anything a user or maintainer needs, not just an agent |
| `Containerfile` comments | Why a build step is written the way it is, and what was already tried |
| [.memory/corrections.jsonl](../.memory/corrections.jsonl) | A correction that also needs searchable history |
| [docs/reflections/](../docs/reflections/) | Why a mistake was possible and what caught it, when the reasoning does not compress to one line |

A note here that turns out to be durable has been filed in the wrong place.
Move it and delete the entry.

The split between the last two is about shape, not importance. A correction
compresses to one line because the lesson *is* the line. Some lessons do not:
the useful part is the chain — what looked fine, what the check said, why the
check was wrong — and that belongs in `docs/reflections/`. Either way the *rule*
lands in `AGENTS.md`, `CLAUDE.md`, or `docs/`; a rule that lives only in a
reflection has been filed in the wrong place too.

## Rules for this file

Same constraints as [.memory/README.md](../.memory/README.md), because the same
risks apply:

- Never record prompts, transcripts, credentials, personal data, command output,
  or host inventory — no VM names, pool names, disk paths, or IP addresses.
- Keep it factual and repository-specific. A guess is not a finding until a
  discriminating test or a review confirms it.
- Prune aggressively. A stale summary is worse than none, because it is read as
  current. Delete an entry once its work merges.

## Template

```markdown
### YYYY-MM-DD — <short topic>

**State:** what is merged, what is open, what is blocked.
**Learned:** anything that surprised you, with the evidence.
**Next gated action:** the thing that needs authorization before it proceeds.
```

## Current

### 2026-09-03 — ACMM gap issues and CI hardening

**State:** The ten open non-Renovate issues were worked as three pull requests.
`timeout-minutes` on all workflow jobs plus the `build.yaml` → `build.yml`
rename merged. The ACMM documentation set (contributing guide, quality signals,
review rubric, metrics, agent permission rules, this file) and the coverage-floor
portability fix were open at the time of writing.

**Learned:**

- The xtrace coverage floors are **not portable across Bash versions**. The same
  `ostree-pkg-diff` source traces 44 lines under bash 5.2.21 and 43 under 5.3.9,
  with identical assertion totals in both. A floor calibrated only against CI
  fails on a developer machine for no real reason. The rule — set floors to the
  lowest count across supported Bash versions — is now recorded in
  [docs/ci-cd.md](../docs/ci-cd.md), which is where it belongs; this entry only
  notes that it was found the hard way.
- **Assertion totals, not line counts, distinguish a lost test from a trace
  difference.** Compare `1..N` between environments before concluding a
  regression.
- The ACMM criteria are satisfied by **file existence**, so several issues were
  filed against a repository that already did the thing being asked for — the
  `lint`/`test` jobs gating a three-flavor build matrix already were a CI test
  matrix; only the filename differed. Check whether a gap is real before
  building something to close it.

**Next gated action:** none outstanding. Merging is always a separate, explicit
decision — see the consent gates in [AGENTS.md](../AGENTS.md).
