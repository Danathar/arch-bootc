# Quality signals

Every automated signal this repository produces, what each one actually proves,
and where to look at it. The point of writing it down is the second column: a
green check here means something specific and narrower than "it works."

## The dashboard

There is no separate dashboard service. The signals live where they are
produced:

| Signal | Where to see it | Runs on |
| --- | --- | --- |
| Shell tests + coverage floors | `test` job, build workflow | PRs and pushes to `main` that touch code, plus a daily schedule |
| ShellCheck | `lint` job, build workflow | Same |
| Three-flavor image build | `build_push` job, build workflow | Same |
| `bootc container lint`, `systemd-analyze verify`, dangling-symlink check | Inside the build, per flavor | Same |
| Workflow static analysis (zizmor) | `Lint workflows` workflow | Any change under `.github/workflows/**` |
| Image signature (cosign) | `Sign container image` step | Pushes to `main` only |
| Repository invariants | `Assert repository invariants` step, build workflow; `invariants` job, nightly workflow | Same as the tests, plus nightly |
| bootc tag still resolves to its pinned commit | `bootc-pin` job, nightly workflow | Nightly |
| Published image signature verifies against `cosign.pub` | `signatures` job, nightly workflow | Nightly, per flavor |
| Dependency freshness | Renovate PRs | Continuously |

```bash
gh run list --branch main --limit 10
gh run view <run-id>
```

**"that touch code" is load-bearing.** The build workflow sets
`paths-ignore: ["**/*.md", "docs/**"]`, so a change touching only Markdown or
`docs/` runs *none* of the first four signals — no tests, no ShellCheck, no
build. That is intentional (there is nothing for them to check), but it means an
absent workflow is not a passed one. A PR showing no checks has not been
validated; it has been skipped. Only the daily schedule and the next code change
will exercise those paths again.

The README badge tracks the build workflow on `main`.

## What each signal proves

**Shell tests and the coverage gate.** `./tests/check-coverage.sh` runs the
suite under Bash xtrace and fails if any shipped script drops below its minimum
unique traced-line count in `.coverage-thresholds.json`. Floors are per script
on purpose: strong coverage of one helper cannot mask another script
disappearing from the suite entirely. The gate also fails when a new executable
Bash entry point under `scripts/` or the shipped `usr/bin` / `usr/libexec` paths
has no floor, so the manifest cannot silently fall behind the image.

It proves the covered lines execute and assert correctly. It does not prove the
uncovered ones do anything; the percentages printed alongside each floor are
context, not a target.

*Known sharp edge:* traced-line counts are bash-version sensitive. Identical
code traces 44 lines of `ostree-pkg-diff` under bash 5.2.21 and 43 under 5.3.9,
so a floor calibrated to one environment fails in the other for no real reason.
Floors are therefore set to the lowest count across supported bash versions, not
the highest one CI happens to produce. If a floor fails locally by a line or two
and you did not touch the script, check the Bash version the report names
before assuming a regression. Assertion totals are the first thing to compare --
a lower total is unambiguously a lost test -- but identical totals do not by
themselves prove the shortfall is a trace difference, since a change can stop
exercising a branch without changing how many assertions run. Running the same
revision under both Bash versions is what actually settles it; see
[ci-cd.md](ci-cd.md).

**ShellCheck.** Catches quoting, word-splitting, and unset-variable classes in
the shipped scripts and the test scripts alike — the tests are held to the same
bar as the code they cover. Both the `Justfile` `lint` recipe and the CI step
list files explicitly, and **the two lists are maintained by hand**, so a new
test file escapes linting until you add it to both. That is not hypothetical:
`tests/test-ostree-pkg-diff-db.sh` reached `main` in the `Justfile` list but not
the CI one, and went ungated in CI until it was noticed in review.

**The three-flavor build.** `base`, `kde`, and `xfce` each build from the
`Containerfile`, and each re-runs `bootc container lint`, `systemd-analyze
verify` on the shipped units, and a dangling-symlink check. A successful build
therefore carries real signal beyond "the syntax parsed."

It proves the image **builds**. It does not prove it boots, that first boot
succeeds, that logins behave, or that `bootc upgrade` works from a previously
deployed version. No CI job boots the image. PR builds additionally skip the
rechunk, push, and sign steps, so a green PR check exercises less than a push to
`main` does.

Booting is covered by the manual VM procedure in [CLAUDE.md](../CLAUDE.md),
which is the only routine way these paths get exercised.

**The invariant checks.** `./tests/check-invariants.sh` asserts, statically over
the checked-out tree, that the properties `AGENTS.md` calls load-bearing are
still where they are supposed to be: the four root-login controls, the signature
chain (including that `policy.json`'s `keyPath` still matches where the
`Containerfile` copies `cosign.pub`), the `bootc` tag-and-commit pin and its
hard failure on a mismatch, `PACMAN_CACHE_BUST` still preceding the first
`pacman -Syu`, the absence of third-party package sources, the systemd
enablement layout, SHA-pinned actions with `persist-credentials: false` and
`timeout-minutes`, and — the one that had already gone wrong — that every shell
file appears in **both** hand-maintained ShellCheck lists.

It exists because a build proves the image *builds*, and an image that has
quietly lost `pam_wheel.so use_uid` builds perfectly well. It runs in the build
workflow's `test` job on every code change and again nightly.

It reads the `Containerfile` as text, so a step with the right shape and the
wrong effect passes it; only a VM boot test settles that. It cannot see that
display managers refuse root, because that behavior comes from the packaged
units rather than from anything in this tree. And a failure means an invariant
is no longer *visible* where it was — a deliberate security change updates the
script in the same commit and says so.

**The nightly bootc pin check.** The `Containerfile` already refuses to build
when `BOOTC_VERSION`'s tag no longer resolves to `BOOTC_COMMIT`. That check only
fires when something triggers a build, and it surfaces as a build failure, which
reads like broken CI rather than what it is. The nightly job asks upstream the
same question on its own schedule and names it: a git tag is mutable, `bootc`
runs as root on every machine booting this image, and a re-pointed tag is a
supply-chain event.

**The nightly signature verification.** Runs `cosign verify --key cosign.pub`
against the published `latest` of each flavor, **with no registry credentials**.
That is the point: a pass means the signature verifies for anyone pulling the
published image, not merely that CI can verify its own artifact with its own
token. It also catches `cosign.pub` in the repository drifting away from the key
the pipeline actually signs with.

**zizmor.** Static analysis of the workflow files themselves — credential
persistence, template injection, and similar. Two findings it already fixed here
are easy to reintroduce: every `actions/checkout` sets `persist-credentials:
false`, and `${{ ... }}` expansions reach `run:` blocks through `env:` rather
than being pasted in as raw text. See [ci-cd.md](ci-cd.md) for the detail.

**cosign signing.** Only images pushed from `main` are signed, and the in-image
policy at `system_files/etc/containers/policy.json` requires a valid signature
for this repository's published namespace. A signature proves the image came
from this pipeline; it says nothing about whether the contents are correct.

**Renovate.** Keeps `bootc`, the base image digest, the pinned actions, and the
cosign/chunkah/zizmor versions current, automerging once the PR build is green.
The carve-outs matter: major `bootc-dev/bootc` bumps never automerge, because a
green build does not boot-test the image and a breaking change to bootc's
on-disk format or upgrade behavior would otherwise merge unattended. See
[renovate.md](renovate.md).

## Agent guardrails

`.claude/settings.json` is checked in and encodes part of [AGENTS.md](../AGENTS.md)
as permission rules, so the highest-consequence mistakes fail closed rather than
relying on an agent having read the policy carefully:

- **Denied** — reading `cosign.key` or other private-key and secret shapes;
  broad container cleanup (`podman system prune`, `rm -a`, `rmi -a`, `buildah rm
  --all`); the *irreversible* verbs on the shared `qemu:///system` connection
  (`destroy`, `undefine`, the `pool-`/`vol-`/`net-` deletions, `snapshot-delete`);
  and the git commands that are never a legitimate recovery (`reset --hard`,
  `clean`, force-push, `stash`).
- **Prompted** — anything under `sudo`, local image builds, `just lint`,
  `virt-install` and `virsh`, everything else on `qemu:///system`, and every git
  or `gh` write: branch, commit, push, PR create/edit/merge, workflow dispatch,
  secret set. These map to the consent gates in `AGENTS.md`.
- **Allowed** — the non-privileged test suite, `shellcheck`, `bash -n`,
  read-only git and host inspection, and the read-only VM/pool name inventories
  on **both** libvirt connections.

Two of those splits are deliberate and easy to get wrong in the opposite
direction:

- **`qemu:///system` is denied by verb, not wholesale.** `CLAUDE.md` requires
  inventorying *both* connections before choosing a test VM name, precisely so a
  new VM cannot collide with something real. A blanket deny on the system
  connection would block that preflight and push an agent toward bypassing
  permissions in order to do the safe thing — so the irreversible verbs are
  denied, the read-only `list --all --name` / `pool-list --all --name` are
  allowed, and everything else there prompts.
- **`git restore` and `git checkout --` prompt rather than deny.** `AGENTS.md`
  forbids them as improvised recovery but names one exception: restoring files
  that a failed buildah bind-mount deleted from the host is *the* documented
  correction. Denying them outright would block the only sanctioned repair.
  `git reset --hard`, `clean` and force-push have no such exception and stay
  denied. `git stash` is denied too, which is stricter than `AGENTS.md`'s
  "not without approval" — the recovery there is to ask, not to stash.

Be clear about the limits. These are prefix matches on command strings, so a
differently-spelled or composed command reaches the same effect without matching
a rule; they cover the well-known spellings, not the space of equivalents.
Nothing here constrains what a human types, and `.claude/settings.local.json`
(untracked) can add allowances on top for a specific machine. The rules are a
backstop for the obvious mistake, not a sandbox.

Two knobs deliberately left unset, because they are the repository owner's call
rather than a default worth imposing: `permissions.defaultMode`, and
`permissions.disableBypassPermissionsMode`, which would prevent
`--dangerously-skip-permissions` from being used in this checkout at all.

## Where the gaps are

Stated plainly so nobody mistakes silence for coverage:

- **No boot or upgrade test in CI.** The largest gap. First-boot behavior,
  service startup, login paths, and `bootc upgrade` from a deployed system are
  verified only by the manual VM procedure in [CLAUDE.md](../CLAUDE.md).
- **Coverage floors are line-based, not branch-based**, and bash-version
  sensitive as described above.
- **`Containerfile` has no unit tests.** Its correctness rests on the build's
  own lint steps, the rationale comments, and review.
- **Signature verification is tested, but not end to end.** The nightly
  `signatures` job confirms each published flavor verifies against `cosign.pub`
  with no credentials, which is the property a user depends on. What still is
  not tested is the *policy* path: nothing pulls the image under the shipped
  `system_files/etc/containers/policy.json` and confirms that
  `sigstoreSigned` + `matchRepository` accepts it and rejects an unsigned image.
  `check-invariants.sh` asserts that policy's `keyPath` matches where
  `cosign.pub` is copied, which closes the most likely way the two drift apart,
  but that is a static check, not an execution of the policy.

Trend data for the process around all this — how much lands, how fast, how often
review finds something — lives in [metrics.md](metrics.md).
