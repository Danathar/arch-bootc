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
| Thread-aware review state | `./scripts/pr-review-state.sh` | On demand; embedded in the `ai-fix-requested` work order |
| Path labels (incl. `documentation`, which marks a PR no build ran on) | Labels on the PR | Pull requests from this repository |

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

**Tuning the floors.** `./tests/tune-coverage.sh` compares each floor against
what the suite actually reaches and reports which could be raised; `--apply`
writes them. Pass each interpreter you want observed and it writes the
*minimum* across all of them:

```bash
./tests/tune-coverage.sh                                    # report only
./tests/tune-coverage.sh --bash /usr/bin/bash --bash /opt/bash-5.2 --apply
```

That is the whole reason it exists. The calibration rule below — a floor is the
lowest count across supported Bash versions, never the highest one CI happens
to produce — lived only in prose, which means it held only as long as everyone
remembered it. Here it is mechanical, and mechanical means enforced:
**`--apply` is refused unless every version in the policy's `supportedBash`
list has been observed.** Raising a floor to 44 from a 5.2 host alone would
leave every 5.3 environment failing a gate that nothing is wrong with, which is
the exact mistake the rule exists to prevent — so the tool will not let you make
it. Reporting is not gated, because it changes nothing.

**It raises and never lowers,** and the asymmetry is deliberate rather than
cautious. The evidence for raising a floor is complete: the suite demonstrably
reached that many lines. The evidence for lowering one is an absence, and a lost
test and a Bash-version trace difference are indistinguishable from the count
alone — only assertion totals separate them. So a floor above what the suite
reaches is reported as a regression and left alone, with a pointer at what to
compare. The policy, and the reasoning for each knob, is in
[.github/auto-qa-tuning.json](../.github/auto-qa-tuning.json).

Nothing runs it on a schedule. It is operator-run and edits one local file: a
bot that adjusted the quality gate on its own would be automating exactly the
decision the gate exists to force.

*Known sharp edge:* traced-line counts are bash-version sensitive. Identical
code traces 117 lines of `ostree-pkg-diff` under bash 5.2.21 and 116 under
5.3.9, so a floor calibrated to one environment fails in the other for no real
reason.
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

**The bare-metal guard tests.** `tests/test-quickstart-baremetal.sh` covers the
four functions in `scripts/quickstart.sh` whose only job is to refuse an install
that would destroy the machine running it — a partition instead of a whole disk,
a disk backing `/` or `/boot`, a disk with anything mounted, a disk carrying
ZFS/LVM/RAID/LUKS signatures, and a target whose path or identity changed while
the operator was reading the confirmation.

They are worth more than the line count suggests, because **a guard that stops
nothing still exits 0 and prints a plausible transcript** — the happy-path dry
run cannot tell a working refusal from a deleted one. Neutering the
self-destruction check turns exactly three assertions red.

Reaching them needed a sourcing guard at the bottom of `quickstart.sh`
(`[ "${BASH_SOURCE[0]}" = "${0}" ]`), because `validate_baremetal_target`'s
first statement is `[ -b ]`, which no `PATH` stub can satisfy and which needs
`CAP_MKNOD` to fake. The tests answer it with a block device that already
exists on the host, used purely as a token: every command run against it is
stubbed, and none of these functions writes anything. If no block device is
found the file **fails** rather than skipping — an absent check is not a passed
one.

**The invariant checks.** `./tests/check-invariants.sh` asserts, statically over
the checked-out tree, that the properties `AGENTS.md` calls load-bearing are
still where they are supposed to be: the root-login controls, the signature
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

Two design points are worth knowing, because both were mistakes first:

- **Presence assertions ignore comment lines.** Every control here is described
  in a nearby rationale comment using the same words as the instruction that
  implements it — `PermitRootLogin prohibit-password` appears in the sshd
  drop-in *and* in the comment above it. A plain `grep` is therefore satisfied
  by the surviving *explanation* of a control that has been deleted, which is
  exactly backwards.
- **Checks that can be reached from more than one place look in all of them.**
  `COPY system_files/ /` lands in the base stage before the desktop flavors run
  their own `pacman -Syu`, so a pacman fragment copied through that tree can
  redirect those installs without a suspicious line in the `Containerfile`.
  Likewise, enablement under `/etc` is matched by the state (any `.wants`
  directory under `/etc/systemd/system`, `systemctl enable`, or a symlink
  committed under `system_files/etc/systemd`) rather than by one spelling of
  `ln -s`.

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
- **`flow_baremetal`'s orchestration is exercised in dry-run only.** The four
  guards it depends on — `validate_baremetal_target`, `running_system_disks`,
  `block_identity`, `assert_target_identity` — are covered directly by
  `tests/test-quickstart-baremetal.sh`, which sources the script and stubs the
  commands they consult. The same file now also drives `flow_baremetal` itself
  through that sourcing entry point with `DRY_RUN=1`, answering its prompts on
  stdin, which covers the order the guards are applied in: the target is
  resolved before it is validated, the image is pulled before the identity is
  re-read, the re-read happens before the installer is invoked, and the device
  named to the installer is the resolved one rather than the one that was
  typed. `sudo`, `mount`, `umount` and `mountpoint` are stubbed to fail loudly,
  so a dry run that stopped being dry fails a case. What is still not covered
  is the `DRY_RUN=0` half of the seed step — discovering partition 3, mounting
  it, and writing the NoCloud seed into the fresh deployment — which needs a
  real installed disk and root.
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
