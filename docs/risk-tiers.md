# Change risk tiers

A change to this repository is a change to an operating system other people
boot. The evidence a change needs, and whether it may merge on a green check
alone, depend on how far its blast radius reaches — so decide that **before**
writing it, not while arguing about it in review.

This page names four tiers, says what each one requires, and maps the paths in
this repository onto them. It is a classification aid, not a new gate:
[AGENTS.md](../AGENTS.md) still defines the consent gates,
[review-rubric.md](review-rubric.md) still defines what a reviewer checks, and
[quality.md](quality.md) still defines what each automated signal actually
proves.

## The tiers

| Tier | Reaches | Extra evidence required |
| --- | --- | --- |
| **T0** Documentation | Readers only | Read the rendered result |
| **T1** Build and test harness | CI, local workflow | Name the checks that ran and what they printed |
| **T2** Image contents | Every machine that installs or upgrades | Which flavors built; effect on an upgrade |
| **T3** Boot, security model, provenance, or published artifacts | Root on every machine running this image | Evidence that exercises the changed path, and an explicit statement that the security model is in scope |

Take the **highest** tier matched by any file in the diff. A pull request that
touches `docs/` and `Containerfile` is T2 or T3, not T0; the documentation half
does not dilute the rest.

When two tiers both look defensible, round up. The cost of over-classifying is
one extra check; the cost of under-classifying is a machine that does not boot.

**CI cannot tell these tiers apart, which is the whole reason the table has a
last column.** There is only one path split in the automation, and it is not the
tier boundary:

- If *every* changed file matches `**/*.md` or `docs/**`, the build workflow is
  skipped entirely and nothing runs.
- Otherwise the build workflow runs in full — shell tests, coverage floors,
  ShellCheck, and the three-flavor image build — whether the diff touched
  `renovate.json`, `tests/`, `packages-kde.txt`, or the signing step.
- zizmor runs on top of that only when `.github/workflows/**` changes.

So a T1 change to `renovate.json` gets a complete three-flavor build it did not
need, and a T3 change to the signing step gets the same build without ever
executing the step it changed. The automated signal is close to tier-blind; the
extra evidence column is what actually scales with risk.

## T0 — Documentation

`*.md` anywhere, `docs/`, `.github/pull_request_template.md`,
`.github/prompts/`.

**What runs: nothing.** The build workflow sets
`paths-ignore: ["**/*.md", "docs/**"]`, and the zizmor workflow only triggers on
`.github/workflows/**`. A T0 pull request therefore shows *no checks at all*.

**The issue forms are not T0 by this definition, even though they read like it.**
`.github/ISSUE_TEMPLATE/bug-report.yml`, `feature-request.yml`, and `config.yml`
are YAML, so they match neither `**/*.md` nor `docs/**`. Editing one triggers the
full build workflow — shell tests, ShellCheck, and a three-flavor image build —
for a change that cannot possibly affect the image. Treat them as T1: the checks
run, so quote them, and do not describe the change as "docs only".

That is correct — there is nothing for those jobs to check — but it means the
usual shorthand breaks down. **An absent check is not a passed check.** "Green"
for a T0 change means a human read it, not that CI agreed with it. Say that
plainly in the pull request rather than letting an empty checks list imply
validation happened.

The one failure mode worth watching: a change filed as T0 that also edits a
non-Markdown file. `paths-ignore` is evaluated over the whole push, so the
build does run in that case — but the tier was still wrong, and the evidence
expectations that come with the real tier still apply.

## T1 — Build and test harness

`tests/`, `.coverage-thresholds.json`, `Justfile`, `.github/workflows/`,
`.github/labeler.yml`, `.shellcheckrc`, `.editorconfig`, `renovate.json`.

Plus `.github/ISSUE_TEMPLATE/`, per the note above.

These change how the image is *judged*, not what it contains. A mistake here
does not ship a bad image directly; it lets a bad image ship later by removing
the signal that would have caught it. That makes weakening a check the
characteristic T1 failure, and it is the thing to look for in review.

What runs is *more* than the diff suggests: the full build workflow, including
the three-flavor image build, fires for any of these paths, and zizmor fires on
top of it only for `.github/workflows/**`. A green check on a T1 pull request
therefore mostly proves the image still builds, which was not in question. The
evidence that matters is the check the change actually affects.

Evidence: run the checks the diff affects and paste what they printed.

```bash
just test                 # tests + coverage floors
shellcheck <changed>      # and add new tests/test-*.sh to BOTH lint lists
actionlint / zizmor       # changed workflows
```

Two T1-specific traps, both of which have already happened here:

- A new `tests/test-*.sh` is picked up automatically by `run-tests.sh`, which
  globs, but **not** by either ShellCheck invocation — the `Justfile` `lint`
  recipe and the CI `ShellCheck` step both list files by hand. Miss one and the
  file silently escapes linting.
- Coverage floors are traced-line counts and are **Bash-version sensitive**.
  Raise a floor when you add coverage; never lower one to make a regression
  pass, and calibrate to the lowest count across supported Bash versions. See
  [ci-cd.md](ci-cd.md).

## T2 — Image contents

`packages-*.txt`, `system_files/`, and the `Containerfile` steps that install or
configure ordinary software.

The change reaches real machines, both as a fresh install and as a
`bootc upgrade` on systems already running this image. Those are different
questions and the second one is the one people forget: a file that a fresh
install creates cleanly may collide with machine-local state under `/etc` on an
upgrade.

Evidence:

- A green three-flavor build. Say **which** flavors — `base`, `kde`, and `xfce`
  are separate targets over a shared base stage, so a change to the shared stage
  reaches all three and evidence from one is not evidence for another.
- What happens to an existing deployment receiving this as an upgrade.
- The build's own in-image checks (`bootc container lint`, `systemd-analyze
  verify`, the dangling-symlink check) still pass, rather than having been
  relaxed.

A green build proves the image **builds**. Pull request builds skip the rechunk,
push, and sign steps, and nothing in CI boots the image.

## T3 — Boot, security model, provenance, or published artifacts

The load-bearing set. Any of these puts a change in T3 regardless of how small
the diff is:

- **The root-login model** — `PermitRootLogin prohibit-password` in the sshd
  drop-in, `pam_wheel.so use_uid` in `/etc/pam.d/su`, display managers that
  refuse root, `passwd --expire`. The image ships a known default root password;
  these four are only safe *together*, so touching one invalidates the reasoning
  behind the other three.
- **Signature policy and keys** — `system_files/etc/containers/policy.json`,
  `cosign.pub`, the signing step, `system_files/etc/containers/registries.d/`.
- **`bootc` provenance** — `BOOTC_VERSION`, `BOOTC_COMMIT`, the tag-to-commit
  verification in the build, or how `bootc` is obtained at all.
- **Package freshness** — `PACMAN_CACHE_BUST` and the ordering of package
  installation relative to it.
- **Boot path and service enablement** — the bootloader, initramfs/dracut,
  composefs backend, and the `/usr/lib/systemd/system/<target>.wants/` layout.
- **Published artifacts** — the push, sign, and package-retention jobs. Deleting
  package versions can orphan cosign signatures and break `bootc upgrade` on
  installed systems.

Evidence: everything T2 requires, plus evidence that exercises **the path this
change touches**. That is not one thing, because T3 covers two kinds of change
and the usual answer is only right for one of them.

*For anything a running system can demonstrate* — the root-login model, service
enablement, the boot path, `bootc upgrade` behavior — a **VM boot test**
following [CLAUDE.md](../CLAUDE.md) exactly, including confirming the image's
`org.opencontainers.image.revision` label matches the commit you meant to test
rather than trusting a tag.

*For the publication path* — the push, sign, and package-retention jobs — a VM
boot test proves nothing, and neither does a green pull request check: those
steps are gated to non-pull-request events on the default branch, so **the pull
request build never executes the code being changed**. Say so, and substitute
evidence that does reach it:

- Walk the changed step against a real run's logs, naming the run.
- For a signing change, verify a resulting image's signature against
  `cosign.pub` under the shipped policy, rather than inferring it from a green
  job.
- For a retention change, state which package versions the new setting keeps and
  deletes against the versions actually published now, and confirm the versions
  a deployed system could still be pulling survive — including the separate
  signature manifests, which a naive prune can orphan.
- Expect the first real exercise to be the run on `main` after the merge, and
  say what you will check on it and what the rollback is.

Either way, an explicit statement in the pull request that this is a security or
boot change and what the intended new model is. A T3 change described as a
cleanup is a review failure even if the code is correct.
- For a security control: proof the test **discriminates**. Observe it failing
  without the change. A check that passes both ways proves nothing — and see
  the false-positive `su` result recorded in [CLAUDE.md](../CLAUDE.md) before
  trusting any in-guest security result.

**T3 never merges on a green check alone.** No CI job boots the image, and the
publish, sign, and retention steps do not run on a pull request at all — so for
both halves of T3, the signal that would catch a regression does not exist in CI
by construction.

## What automation does per tier

| Automation | Behavior |
| --- | --- |
| Build workflow | Skipped entirely for T0; runs for T1–T3 |
| zizmor | Runs only when `.github/workflows/**` changes |
| Renovate automerge | On for digest/pin/patch/minor/major updates once the build is green |
| Renovate carve-out | **Major `bootc-dev/bootc` bumps never automerge** — they are T3, and a green build does not boot-test the image |

The Renovate carve-out is this table's one real enforcement point, and it exists
precisely because the tiering is otherwise advisory. Do not broaden the
automerge scope or remove a carve-out as part of an unrelated change; see
[renovate.md](renovate.md).

Nothing else here is enforced mechanically, and that is deliberate: no rule over
file paths can tell a `Containerfile` comment fix from a change to how `bootc`
is fetched, because both touch the same file. Classify by what the diff does.

## Worked examples

Real changes from this repository, with the tier they should have carried:

| Change | Tier | Why |
| --- | --- | --- |
| Contributing guide, quality signals, review rubric | T0 | Markdown only; no checks ran, and the pull request said so |
| `timeout-minutes` on every workflow job | T1 | Changes how CI fails, not what ships |
| Coverage floor recalibrated for Bash portability | T1 | Threshold change; the risk is masking a regression |
| Adding a package to `packages-kde.txt` | T2 | Ships to every KDE install and upgrade |
| Pinning `bootc` to a verified commit | T3 | Supply chain: a git tag is mutable and `bootc` runs as root |
| Changing `PermitRootLogin` or `policy.json` | T3 | Security model; the four root-login controls hold together |

## What this page does not do

It does not decide whether a change is a good idea, it does not replace review,
and it grants no authority. Every consent gate in [AGENTS.md](../AGENTS.md)
applies at every tier — a T0 documentation fix still needs explicit
authorization to commit, push, open a pull request, and merge.

Misclassification, not the tiers themselves, is the failure mode this page is
trying to prevent. If you are choosing between two tiers, you have already found
the answer: take the higher one.
