# Branch protection

`main` is what `build.yml` signs and publishes, on every push and again every
day on its schedule. This page says what protects it, why each rule is there,
and how to check that GitHub is really enforcing it.

## Status

The ruleset below has been active on `main` since 2026-09-24, as ruleset
`23960293`. It was applied from this file after #360 merged, with Danathar's
authorization. Check it yourself; neither call needs admin rights:

```bash
gh api repos/Danathar/arch-bootc/branches/main --jq .protected
gh api repos/Danathar/arch-bootc/rulesets
```

The first prints `true` and the second lists `protect main`. `false` and `[]`
mean someone has removed it, and `main` is unprotected again. To see the rules
GitHub applies to `main` right now:

```bash
gh api repos/Danathar/arch-bootc/rules/branches/main --jq '[.[].type] | sort'
```

## Why it matters here

Every other gate in this repository sits behind a pull request: the shell suite,
the invariants, ShellCheck, the three-flavor build, zizmor, and the
[review rubric](review-rubric.md). Nothing made anyone open one. A push to
`main` that touches anything besides documentation starts `build.yml`, which
builds all three flavors, signs them with `SIGNING_SECRET` and publishes them,
and every installed machine takes that image on its next `bootc upgrade`.

Anything that can push a branch here could push to `main` instead. Renovate
and the Hive App both push their pull request branches to this repository, and
so does any agent working with the maintainer's credentials. The consent gates
in [AGENTS.md](../AGENTS.md) tell an agent not to push without authorization.
That is an instruction to a model that reads issue and pull request text
written by others. It is not a control. The ruleset is.

## The ruleset

[`.github/rulesets/main.json`](../.github/rulesets/main.json) is the definition.
It is in GitHub's import format, so it applies as-is. What each rule does:

- **Targets `~DEFAULT_BRANCH`**, so it follows a rename of `main`.
- **No bypass actors.** Not the maintainer, not an App, not Actions. A bypass
  for any of them hands back the direct push this exists to stop.
- **`deletion` and `non_fast_forward`** stop `main` being deleted or rewritten.
- **`pull_request` with 0 approvals.** GitHub does not let anyone approve their
  own pull request. On a single-maintainer repository, requiring one approval
  means nothing can ever merge, including the change that relaxes the rule.
  What 0 still enforces is that every change arrives as a pull request that
  passed the required check. It does not make the merger a person: Renovate
  merges its own green pull requests through the API, which is how
  [renovate.md](renovate.md) says it should work.
- **One required check, `Shell tests and coverage`.** It is the only check every
  pull request gets. `build.yml` runs it on every pull request that touches
  anything besides Markdown and `docs/`, and `docs-tests.yml` runs the same job
  on the ones that touch only those, because its `paths` filter is the same two
  globs as `build.yml`'s `paths-ignore`. The job has no `if:`, no `needs:` and
  no matrix, so it cannot be skipped or renamed on the way. `integration_id`
  15368 is GitHub Actions, so a status posted by anything else does not count.
  `tests/check-invariants.sh` fails if the two copies of the job differ, if
  either gains a condition, or if the two filters stop being each other's
  complement.

Nothing in this repository pushes to `main` outside a pull request. No workflow
runs `git push`, and every first-parent commit on `main` since 2026-08-01 is a
pull request merge. Renovate merges through pull requests too: its automerge
type is the default, `pr`, and nothing in `renovate.json` or the presets it
extends sets `automergeType: "branch"`, which would push to `main` directly and
is refused by this ruleset. So applying this changed nothing about how work
lands.

## Checks that are not required

Every other job a pull request can start, and why it is not required. A
required check that some pull requests never get leaves them unmergeable, so a
job belongs here unless every pull request gets it.

- `Lint shell scripts` runs only in `build.yml`, so a documentation pull request
  never gets it.
- `Build and push image` runs only in `build.yml`, and its matrix reports it as
  `Build and push image (base)`, `(kde)` and `(xfce)`.
- `Clean up old package versions` is skipped on every pull request by its `if:`.
- `Apply path labels` classifies a change rather than checking it, and its `if:`
  skips pull requests from forks.
- `Scan workflows with zizmor` runs only when `.github/workflows/**` changes.
- `Repository invariants` runs on a pull request only when
  `nightly-compliance.yml` itself changes. The same checks run in
  `Shell tests and coverage`.
- `bootc tag still resolves to the pinned commit` runs on a pull request only
  when `nightly-compliance.yml` itself changes.
- `Published ${{ matrix.flavor }} image is signed by this repository's key`
  runs on a pull request only when `nightly-compliance.yml` itself changes.
- `Post a work order` runs on a pull request only when the `ai-fix-requested`
  label is added.

## Applying it

A pull request cannot change repository settings. A repository admin applied
it once, with:

```bash
gh api --method POST repos/Danathar/arch-bootc/rulesets \
  --input .github/rulesets/main.json
```

To change it later, edit the file through a pull request, then update the live
ruleset from the file:

```bash
gh api --method PUT repos/Danathar/arch-bootc/rulesets/23960293 \
  --input .github/rulesets/main.json
```

A job name that the ruleset requires is part of this contract. A pull request
that renames `Shell tests and coverage`, or gives either copy a path filter, an
`if:` or a matrix, fails the invariants. If a rename is really wanted, change
the job, the file and this page in one pull request. It cannot merge while the
live ruleset still requires the old name, so update the live ruleset from the
file just before merging it.

## When there is a second reviewer

Set `required_approving_review_count` to 1. Consider
`require_last_push_approval`, so a push after approval needs a fresh one.
