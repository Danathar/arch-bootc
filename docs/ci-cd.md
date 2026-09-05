# CI/CD & Automated Builds

If your repo is a fork, enable Actions in GitHub first.

## Enable GitHub Actions + Cosign Secret

Generate an empty-passphrase keypair:

```bash
COSIGN_PASSWORD="" cosign generate-key-pair
```

Upload private key as repository secret:

```bash
gh secret set SIGNING_SECRET < cosign.key
```

Commit public key:

```bash
git add cosign.pub
git commit -m "chore: update cosign public key"
git push origin main
```

## Update the in-image signature policy for your fork

The built image ships `/etc/containers/policy.json` and
`/etc/containers/registries.d/arch-bootc.yaml`, which require a valid cosign
signature (from the key above) for anything pulled from the `ghcr.io/danathar`
namespace — every other registry/namespace is left at `insecureAcceptAnything`,
so this doesn't affect ordinary `bootc switch` / `podman pull` of third-party
images.

CI automatically publishes a fork's images to `ghcr.io/<your-username-or-org>`
(`IMAGE_REGISTRY: "ghcr.io/${{ github.repository_owner }}"` in
`build.yml`), but the policy files above do **not** pick that up
automatically — they still say `ghcr.io/danathar`. If you don't update them,
your fork's images simply won't match the scoped policy and will fall through
to the `insecureAcceptAnything` default (harmless, but the in-image
verification you presumably wanted won't do anything). To fix:

1. In `system_files/etc/containers/policy.json`, change the
   `transports.docker` key from `"ghcr.io/danathar"` to
   `"ghcr.io/<your-username-or-org>"`.
2. In `system_files/etc/containers/registries.d/arch-bootc.yaml`, change the
   `docker:` key the same way.
3. Commit both, alongside your own `cosign.pub` from the step above.

### Rotating the signing key

The policy verifies against whatever key is baked into `/etc/pki/containers/arch-bootc.pub`
at build time — an already-deployed machine keeps using the key from the image
version it's currently running, not the one CI is signing with today. If you
rotate `cosign.key`/`cosign.pub`, machines still on an old image will hard-fail
to verify anything newly signed with the new key until they pick up a build
that ships the new `cosign.pub`. Make sure a new build has actually reached
those machines (via a normal `bootc upgrade`) before CI fully switches to
signing with the rotated key, or they can end up unable to verify — and
therefore unable to pull — anything from `ghcr.io/danathar` in the meantime.

## Shell tests and coverage gate

The tests live in `tests/` and are plain bash — no framework, no root, no
container runtime, no network — so the same command CI runs works locally:

```bash
just test        # or: ./tests/check-coverage.sh
```

`tests/check-coverage.sh` runs the suite under Bash xtrace and fails if any
shipped script drops below its minimum unique traced-line count in
`.coverage-thresholds.json`. The report also shows traced lines as a percentage
of non-comment lines for context. Thresholds are separate per script so strong
coverage of one helper cannot hide another script disappearing from the suite.
The gate also fails when a new executable Bash entry point under `scripts/` or
the shipped `usr/bin`/`usr/libexec` paths has no threshold. Raise a floor when
tests add coverage; do not lower one to make a regression pass.

**Set a floor to the lowest count across supported Bash versions, not the
highest one CI happens to print.** Bash's xtrace output is not identical between
releases: the same `ostree-pkg-diff` code, exercised by the same 36 assertions,
traces 44 lines under bash 5.2.21 (what `ubuntu-24.04` runners ship) and 43
under 5.3.9. A floor calibrated to CI alone therefore fails on a developer
machine with a newer Bash while CI stays green — which is exactly what happened
to the `ostree-pkg-diff` floor of 44. The report prints the Bash version it
traced with so this is visible in the log rather than mysterious.

That is also the difference to check first when a floor fails by a line or two:
compare the **assertion totals** (`1..N` and `all N assertions passed`) against
a CI run. A lower total is a real lost test, full stop.

Identical totals are weaker evidence than they look, though, and are not on
their own a licence to lower the floor. A change can stop exercising a branch
while every assertion still runs — an assertion made vacuous, or a code path
deleted along with nothing that asserted on it — and the totals would not move.
To actually distinguish the two, run the **same revision** under both Bash
versions and compare: if the counts differ there, it is the interpreter; if they
match each other but sit below the floor, coverage genuinely regressed. The
report names the Bash that produced it precisely so that comparison is
possible.

`tests/run-tests.sh` is the ungated runner. It executes every
`tests/test-*.sh` and `tests/e2e/test-*.sh`, and fails if any of them does.
`tests/test-prune-esp.sh` covers `arch-bootc-prune-esp`: argument
handling, candidate discovery, the keep-set parsed out of BLS entries (including
CRLF line endings and a final line with no newline), the refuse-to-prune guard
when no entry references `/EFI/Linux/<id>/`, `--dry-run`, and the fail-closed
rejections in `is_genuine_esp` — the check that stops the script from treating a
plugged-in bootable USB stick as the ESP.

Most of those tests point the script at a throwaway fixture directory via
`BOOTC_PRUNE_ESP_PATH`. That is not optional: with the variable unset the script
discovers ESPs from the real mount table, and the tests would delete real boot
artifacts on whatever machine ran them. Keep new tests on the same escape hatch.

The `is_genuine_esp` tests are the one exception, because that check is only
reached when the escape hatch is unset. They are safe because they replace the
mount table rather than read it: each runs with a `PATH` holding nothing but a
fixture `findmnt`/`lsblk` pair and symlinks to the few real tools the script
needs, so the host's mounts are never consulted, and each passes `--dry-run`, so
nothing is deletable even if a stub were wrong. A test that unsets
`BOOTC_PRUNE_ESP_PATH` must keep both properties.

Those tests reach the rejections that need no real block device: `findmnt` or
`lsblk` missing, a mountpoint lookup that fails, `findmnt` output missing
`SOURCE=` or `FSTYPE=`, a non-`vfat` filesystem, and a source that is empty or
not a block device. The three comparisons past that point — the ESP partition
type GUID, `RM`, and `HOTPLUG` — sit behind `[[ -b "$source" ]]`, so reaching
them needs a real block device node and they stay untested here.

`tests/test-ostree-pkg-diff.sh` covers `ostree-pkg-diff`'s parsing: the
`composefs=`/`ostree=` kernel-argument lookups, the `ostree admin status` parse
that picks the booted and rollback deployments, and the `join`+`awk` that turns
two `pacman -Q` listings into the `+`/`-`/`!` report.

That script is split in half to make this possible. Everything above its
`--- real program ---` marker is pure — it reads only what it is handed — and
everything below it mounts erofs images, shells out to pacman, and re-executes
under sudo. Sourcing returns at the marker, so the tests get the helpers and
none of the side effects. Two consequences worth knowing before editing it:

- New parsing logic belongs *above* the marker, taking its input as a
  parameter (as `karg_value` takes the cmdline path) rather than reading a
  fixed system path. Below the marker it is untestable off a real deployment.
- `test_sourcing_does_not_run_the_program` is what enforces the marker. It runs
  the source with a stub `sudo` on `PATH`, so if the guard is ever dropped the
  suite reports a failure instead of hanging on a real password prompt.

`tests/e2e/test-quickstart-dry-run.sh` drives the complete VM path through the
interactive quickstart. It shadows every mutating command with a failing stub,
supplies deterministic responses for the read-only host probes, and verifies
the printed install keeps the loopback, `qemu:///session`, sparse-image, and
cloud-init boundaries. This tests orchestration without building an image,
writing a disk, or touching libvirt. It is not evidence that an image boots; the
authorized VM procedure in `CLAUDE.md` remains the runtime test for that.

`just lint` shellchecks the test scripts too, so they are held to the same bar as
the scripts they cover.

`build.yml` runs the tests and coverage gate: a `test` job checks out the repo
and runs `./tests/check-coverage.sh`, and `build_push` needs `[lint, test]`, so no
image is built or published from a revision whose tests or coverage floors
fail. The job needs nothing but the checkout and finishes well before the build
would, so it costs no meaningful wall-clock time.

Adding a new `tests/test-*.sh` or `tests/e2e/test-*.sh` file picks it up
automatically in `run-tests.sh`, which globs both locations, but **not** in
either shellcheck invocation — both list files explicitly. Add it to the
`shellcheck` line in the `Justfile`'s `lint` recipe and to the `ShellCheck`
step's `/mnt/tests/...` arguments in `build.yml`, or it silently escapes
linting.

## Workflow linting (zizmor)

`.github/workflows/zizmor.yaml` runs [zizmor](https://docs.zizmor.sh/) against this repo's
own workflow files on any PR or push that touches `.github/workflows/**`. zizmor is a static
analyzer for GitHub Actions: it catches things like credential persistence and template
injection, which are easy to introduce and invisible in review.

Two classes of finding it already fixed here, both worth understanding because they are easy
to reintroduce:

- **`artipacked`** — `actions/checkout` leaves the job's `GITHUB_TOKEN` in `.git/config` by
  default, where any later step (or an uploaded artifact that happens to include `.git/`) can
  read it. Every checkout in this repo now sets `persist-credentials: false`. Add that to any
  new checkout step unless you actually need the credential to push.
- **`template-injection`** — a `${{ ... }}` inside a `run:` block is pasted in as raw text
  *before* the shell parses the script, so a value containing a quote or `$(...)` executes as
  code. The fix is to pass the expansion through the step's `env:` and reference it as an
  ordinary shell variable. Several steps in `build.yml` do this now (`METADATA_TAGS`,
  `PUSH_DIGEST`, `REPO_NAME`) — follow that pattern rather than interpolating directly.

The job runs with `GH_TOKEN` set so zizmor's online audits are active; without it zizmor
silently drops to offline mode and checks less than it looks like it does.

To reproduce locally before pushing:

```bash
uvx zizmor@1.29.0 --no-progress .          # offline
GH_TOKEN="$(gh auth token)" uvx zizmor@1.29.0 --no-progress .   # matches CI
```

The version is pinned in the workflow's `ZIZMOR_VERSION` env var rather than tracking
`latest`, so a new zizmor release adding new audits can't turn `main` red on its own —
Renovate bumps it as a PR whose own run proves it still passes.

## Review state and the `ai-fix-requested` work order

Two pieces, one purpose: make the *thread-aware* review state of a pull request
available, because neither the pull request UI's flat comment list nor
`gh pr view --comments` will tell you whether the thread a comment belongs to is
still unresolved, or has been marked outdated by a later push. Acting on a flat
list means re-fixing settled feedback and missing live feedback.
[AGENTS.md](../AGENTS.md) and [review-rubric.md](review-rubric.md) both require
the distinction; nothing provided it.

### `scripts/pr-review-state.sh`

Read-only. One GraphQL query, so the threads and the checks are read at the
*same* head SHA rather than from two calls that could straddle a push.

```bash
./scripts/pr-review-state.sh 161            # the current repo
./scripts/pr-review-state.sh --repo owner/name 161
./scripts/pr-review-state.sh --json 161     # for scripting
```

It prints the head SHA, every review thread with resolved/outdated state and an
excerpt, and the checks at that SHA. Exit status is the useful part when it is
used as a gate:

| Exit | Meaning |
| --- | --- |
| `0` | No unresolved threads and no failing checks |
| `1` | Something is outstanding |
| `2` | Usage or API error |

Review threads are **paginated**, and that is load-bearing rather than tidy: an
exit code of `0` has to mean the script looked at every thread, not at the first
hundred. The loop is bounded and refuses to continue on a cursor that does not
advance, because it is meant to run unattended. The check rollup is *not*
paginated — it is capped at 100 contexts, which is a property of this
repository's workflows rather than of what reviewers did — and the script warns
if that cap is ever reached instead of quietly reporting a short list.

Two things it deliberately does not claim. A **resolved thread is not evidence
the underlying issue was fixed** — only that someone marked it resolved. And an
empty check list is a *skip*, not a pass; the report says so in place, because
that is the state a documentation-only pull request is always in.

### `.github/workflows/ai-fix.yml`

Fires when the `ai-fix-requested` label lands on an issue or a pull request, or
on `workflow_dispatch` with a number. It posts one comment: the context an agent
needs before touching anything, plus the boundaries it works inside — the
untrusted-input rule, that policy is read from `main` rather than from the
branch under review, the consent gates, the tier question, and the evidence a
response owes. For a pull request it embeds the review-state report above.

**It writes no code and applies no review suggestions**, and the comment says
so. No model credentials exist in this repository's CI, and giving a workflow
the ability to push changes in response to a label would defeat every consent
gate in `AGENTS.md` — the point of those gates is that a person decides. What is
automated is the part that was manual and easy to get wrong: assembling the
thread-aware state, and putting the rules in front of the work instead of
leaving them to be looked up afterwards.

**The checkout is pinned to the default branch, not to the event's ref.** On a
`pull_request` event that ref is the merge commit, so labelling a pull request
that edits `scripts/pr-review-state.sh` would run *the branch's* copy of it with
a token carrying `issues: write` and `pull-requests: write` — enough to falsify
the work order or mutate issues far beyond the one comment the job exists for.
This is the rule in [security/SECURITY-AI.md](security/SECURITY-AI.md) applied
to itself: the diff under review is data, not trusted code. Same-repository
branches are exactly where it matters, because that is where this repository's
own agent-authored work lands.

Whether the target is a pull request is **asked**, not inferred from the event
payload: a `workflow_dispatch` run has neither a `pull_request` event nor an
`issue` payload, so deriving it would treat every manually dispatched pull
request as an issue and silently drop the review-state section. One API call is
correct for all three triggers.

Every other value originating outside the repository reaches the script through
`env:` and none is interpolated into it; the target number is rejected unless it
is digits. The only untrusted text that reaches the comment is review excerpts,
written to a file and fenced rather than passed through a shell. Fork pull
requests are skipped — a fork's `GITHUB_TOKEN` is read-only regardless of the
permissions the job requests.

## Pull request labels

`.github/workflows/labeler.yml` applies path-based labels to pull requests from
this repository, driven by the path-to-label map in `.github/labeler.yml`.

| Label | Applied when |
| --- | --- |
| `documentation` | **Every** changed file is Markdown or under `docs/` |
| `area/image` | `Containerfile`, `packages-*.txt`, `system_files/` |
| `area/ci` | `.github/workflows/`, `.github/labeler.yml`, `renovate.json` |
| `area/tests` | `tests/`, `.coverage-thresholds.json` |
| `area/scripts` | `scripts/`, `Justfile` |
| `area/security-model` | `cosign.pub`, `system_files/etc/containers/`, `docs/security/` |
| `area/agent-policy` | `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, editor and agent rule files |

Four details are deliberate rather than incidental.

**`documentation` uses `any-glob-to-all-files`.** It lands only when *every*
changed file is Markdown or under `docs/` — which is exactly when `build.yml`'s
`paths-ignore` skips the build entirely. The label therefore means "no build, no
tests and no ShellCheck ran on this pull request," which is the one thing worth
seeing at a glance on a green-looking, check-less PR. See
[quality.md](quality.md).

**Nothing here reuses an approval label.** The `quality`, `testing`, `ci` and
`security` labels in this repository mean "approved by an owner for auto-merge
on green CI." A label that means someone approved something must never be
reachable from a file path, so the path labels live under an `area/` prefix that
no automation acts on.

**It keeps the labels honest.** `sync-labels` is on, so a label is removed again
when the paths stop supporting it. `documentation` is what makes that
non-negotiable: a pull request that starts as documentation and gains code on a
later push *does* run the build, and a surviving `documentation` label would
assert the opposite of what happened. The cost is that a hand-applied label is
removed again if the paths do not support it — the right trade here, because
these labels are derived rather than editorial, and a label that lies about
whether CI ran is worse than automation overriding a manual one. Only the seven
labels in the configuration are ever touched; `hold`, `needs-human`, and the
approval labels are not.

**It runs on `pull_request`, not `pull_request_target`.** The target variant
would run with this repository's write token against a fork's branch; the only
thing it would buy is labelling fork pull requests, and a fork's `GITHUB_TOKEN`
is read-only regardless of the permissions a workflow requests. The job is
skipped for fork pull requests instead. See
[security/SECURITY-AI.md](security/SECURITY-AI.md).

The workflow creates any label it needs that does not exist yet, so no manual
repository setup is required; existing labels are left untouched. Colours and
descriptions live in the workflow's catalog while paths live in
`.github/labeler.yml`, and the workflow **fails in either direction** — a
configured label with no catalog entry, or a catalog entry with no path rule —
so the two cannot drift apart silently. The second direction is the quieter
one: it is how a deleted path rule leaves a repository label behind that
nothing will ever apply.

A label is a triage hint, not a verdict. No path rule can tell a `Containerfile`
comment fix from a change to how `bootc` is fetched — both touch the same file.
Classify a change by what the diff does; see [risk-tiers.md](risk-tiers.md).

## Nightly compliance

`.github/workflows/nightly-compliance.yml` runs three checks at 05:40 UTC, on
`workflow_dispatch`, and — for the workflow file itself — on pull requests.
They share a theme: each one can change from true to false with **no commit
happening at all**, which is precisely what a build-triggered check cannot
notice.

| Job | Asks | Fails when |
| --- | --- | --- |
| `invariants` | Are the load-bearing properties still in the tree? | `./tests/check-invariants.sh` finds one missing |
| `bootc-pin` | Does `BOOTC_VERSION` still resolve to `BOOTC_COMMIT` upstream? | The tag was re-pointed or deleted |
| `signatures` | Do the published images still verify against `cosign.pub`? | Any flavor's `latest` fails `cosign verify` |

Each is a separate job so a failure names itself in the run list instead of
hiding behind whichever check ran first, and the `signatures` job uses a
`fail-fast: false` matrix so one bad flavor does not cancel the other two.

**`invariants`.** Also wired into the build workflow's `test` job, so it gates
every code change as well as running nightly. See
[quality.md](quality.md) for what it asserts and — more usefully — what it
cannot see.

**`bootc-pin`.** The `Containerfile` already refuses to build when the tag no
longer resolves to the pinned commit. That check only fires when something
triggers a build, and it surfaces as a build failure, which reads like broken CI
rather than what it is. This job asks upstream the same question daily and
reports it as its own event, because a git tag is mutable, `bootc` runs as root
on every machine booting this image, and a re-pointed tag is a supply-chain
problem rather than a version bump. Run it by hand with:

```bash
version=$(sed -nE 's/^ARG BOOTC_VERSION=(.+)$/\1/p' Containerfile | head -1)
git ls-remote --tags https://github.com/bootc-dev/bootc.git "refs/tags/${version}^{}"
```

The `^{}` row is the one that matters: these are annotated tags, so the plain
row is the tag object and `BOOTC_COMMIT` is the commit it peels to.

**`signatures`.** Runs `cosign verify --key cosign.pub` against the published
`latest` of each flavor, deliberately **without registry credentials**. A pass
therefore means the signature verifies for anyone pulling the published image,
which is the property the in-image policy depends on — not merely that CI can
verify its own artifact with its own token. Because `cosign.pub` comes from the
checkout, it also catches the key in the repository drifting away from the key
the pipeline signs with. Reproduce it locally with no setup:

```bash
cosign verify --key cosign.pub ghcr.io/danathar/arch-bootc-base:latest
```

The `cosign-release` version is written as a literal rather than through an env
var, because `renovate.json`'s custom manager matches that exact string — an
expansion would quietly drop this workflow out of its reach and let signing and
verification drift onto different cosign majors.

This does not make signature verification end-to-end. Nothing yet pulls an image
under the shipped `policy.json` and confirms it accepts a signed image and
rejects an unsigned one; see the gaps section of [quality.md](quality.md).

## Keeping pinned versions up to date

`bootc`, the base images, the GitHub Actions and the cosign/chunkah/zizmor versions are all
pinned, and Renovate keeps them current — opening a PR per update and merging it once the
build passes. See [Renovate](renovate.md) for how that works and how to control it.
