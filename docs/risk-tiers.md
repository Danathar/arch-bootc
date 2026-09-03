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

| Tier | Reaches | Automated signal that runs | Extra evidence required |
| --- | --- | --- | --- |
| **T0** Documentation | Readers only | **None** | Read the rendered result |
| **T1** Build and test harness | CI, local workflow | Tests, ShellCheck, zizmor | Name the checks and their output |
| **T2** Image contents | Every machine that installs or upgrades | Three-flavor build | Which flavors built; upgrade effect |
| **T3** Boot, security model, provenance, or published artifacts | Root on every machine running this image | Three-flavor build | A VM boot test, and an explicit statement that the security model is in scope |

Take the **highest** tier matched by any file in the diff. A pull request that
touches `docs/` and `Containerfile` is T2 or T3, not T0; the documentation half
does not dilute the rest.

When two tiers both look defensible, round up. The cost of over-classifying is
one extra check; the cost of under-classifying is a machine that does not boot.

## T0 — Documentation

`*.md` anywhere, `docs/`, issue and pull request templates, `.github/prompts/`.

**What runs: nothing.** The build workflow sets
`paths-ignore: ["**/*.md", "docs/**"]`, and the zizmor workflow only triggers on
`.github/workflows/**`. A T0 pull request therefore shows *no checks at all*.

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

These change how the image is *judged*, not what it contains. A mistake here
does not ship a bad image directly; it lets a bad image ship later by removing
the signal that would have caught it. That makes weakening a check the
characteristic T1 failure, and it is the thing to look for in review.

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

Evidence:

- Everything T2 requires, plus a **VM boot test** following
  [CLAUDE.md](../CLAUDE.md) exactly — including confirming the image's
  `org.opencontainers.image.revision` label matches the commit you meant to
  test, rather than trusting a tag.
- An explicit statement in the pull request that this is a security or boot
  change and what the intended new model is. A T3 change described as a cleanup
  is a review failure even if the code is correct.
- For a security control: proof the test **discriminates**. Observe it failing
  without the change. A check that passes both ways proves nothing — and see
  the false-positive `su` result recorded in [CLAUDE.md](../CLAUDE.md) before
  trusting any in-guest security result.

**T3 never merges on a green check alone.** No CI job boots the image, so the
signal that would catch a T3 regression does not exist in CI by construction.

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
