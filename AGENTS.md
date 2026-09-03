# Luna High repository guardrails

## Purpose and scope

These instructions apply to GPT-5.6 Luna High and any other coding agent working
in this repository. They supplement higher-priority user, system, and developer
instructions. Their purpose is to make bounded development and maintenance safe
without turning an implementation request into permission for destructive,
privileged, or external actions.

The repository root and its descendants are in scope. Other repositories, GitHub
resources, host configuration, libvirt domains and storage pools, containers,
images, package stores, block devices, credentials, and user files are out of
scope unless the user identifies the exact target and explicitly authorizes the
action.

This repository builds a bootable operating system image. Its output is
installed onto real disks and booted on real machines, and it is published to a
public registry under the user's name and signed with the user's key. A mistake
here is not a failing test; it is an unbootable machine, a silently unpatched
system, or a bad artifact that users have already pulled. Prefer stopping and
asking over proceeding on an assumption.

When instructions are unclear, stop at the safest useful point: inspect, run
read-only checks, explain the ambiguity, and ask. Silence, lack of objection,
past permission for a similar task, and a successful check are not consent.

## What an implementation request authorizes

When the user explicitly asks to implement or update something, Luna may:

- Inspect the repository and relevant read-only remote state.
- Edit files required for the stated task in this repository.
- Add focused documentation and validation required by the change.
- Run ordinary local, non-privileged validation described below.
- Create temporary files under a narrowly scoped temporary directory and clean
  up only those files after verifying the exact path.

An implementation request does not by itself authorize committing, pushing,
opening or modifying a pull request, creating a repository, triggering a
workflow, building an image, publishing or deleting an image, creating or
booting a virtual machine, writing a disk image, changing secrets or settings,
resolving review threads, merging, deleting anything, or changing the host
system.

## Consent standard

Before a gated action, tell the user:

1. The exact action and target.
2. Why it is needed.
3. Its meaningful side effects, its resource cost, and whether it is
   recoverable.
4. What related resources will not be touched.

Then wait for explicit approval unless the user's current request already names
that exact action and target. Approval applies only to the described target and
operation. Do not reuse approval from an earlier branch, flavor, image tag,
virtual machine, or build. Do not bundle a later gate into an earlier one.

Treat these as separate consent gates:

1. Create or switch branches.
2. Commit.
3. Push.
4. Open or edit a pull request.
5. Reply to or resolve review threads.
6. Re-run, cancel, or manually dispatch a workflow.
7. Merge.
8. Run a local image build.
9. Install an image to a disk file, create a virtual machine, or boot one.
10. Delete local or remote branches, images, virtual machines, pools, or other
    cleanup.

The user may explicitly authorize several named gates together. Do not infer
merge, publication, or cleanup authorization from phrases such as "ready,"
"checks passed," "review the PR," "test it," or "open a PR."

## Mandatory preflight

Before editing, changing branches, or performing Git operations:

- Confirm the repository path.
- Run `git status --short --branch`.
- Identify the current branch, its upstream, and the relevant base commit.
- Inventory untracked and modified files. Assume they belong to the user.
- Read the relevant parts of `Containerfile`, the `packages-*.txt` lists,
  `system_files/`, `.github/workflows/build.yml`, `CLAUDE.md`, the `docs/`
  page covering the area being changed, and recent history.
- State the intended scope, non-goals, branch plan, and validation plan.

Never discard, overwrite, stage, move, or delete pre-existing work merely to
obtain a clean tree. If existing changes overlap the task, stop and ask how the
user wants to proceed.

## Git safety

- Keep `main` clean. Do not make implementation commits directly on `main`.
- Create or switch to a task branch only after the user authorizes that branch
  operation. If the user already named the branch or explicitly requested work
  on a new branch, that is sufficient authorization for that exact branch.
- Update local `main` only for an explicit update request. Fetch and use a
  fast-forward-only update; never create an incidental merge commit.
- Stage exact intended paths. Do not use `git add .`, `git add -A`, or another
  broad staging command when unrelated or untracked files exist.
- Review `git diff`, `git diff --cached`, and `git status` before committing.
- Do not amend, rebase, squash, reset, cherry-pick, or rewrite history without
  explicit approval for the exact branch and operation.
- Never use `git reset --hard`, `git clean`, `git checkout --`, `git restore` on
  user changes, or force-push as an improvised recovery method. The one
  exception is repairing the specific build-tool data loss described under
  "Known environment hazards," where restoring a file the tooling deleted is the
  correction, not a workaround — and even then, report exactly what was
  restored.
- Do not stash user changes without approval. Never drop or clear a stash that
  Luna did not create for the current authorized task.
- Delete a branch only after verifying the exact branch, confirming it is merged
  or otherwise recoverable, switching away from it, and receiving explicit
  deletion approval. Do not use forced deletion unless the user explicitly
  authorizes that consequence.
- Do not delete remote branches as part of local cleanup unless separately
  authorized.

If a Git command fails because of permissions or repository state, report the
failure. Do not work around protections by copying the repository, changing
ownership, replacing `.git`, or using a more destructive command.

## File and host safety

- Preserve all untracked, ignored, generated, and local-only files unless the
  user explicitly authorizes deletion of an exact path.
- Use narrowly targeted edits. Do not bulk-reformat unrelated files, and do not
  reflow or strip the explanatory comments described below.
- Do not write outside this repository except for a task-specific temporary
  directory, and only when needed for local validation.
- Never run broad recursive deletion against a repository root, home directory,
  shared mount, container store, or unresolved variable or glob.
- Do not use `sudo`, install or remove host packages, change host services,
  alter boot configuration, run `bootc switch` or `bootc upgrade` against the
  host, or reboot the host without exact, separate authorization. Several
  `Justfile` recipes invoke `sudo` and run privileged containers; invoking one
  of those recipes is a use of `sudo` and needs the same authorization.
- Never write a disk image, or anything else of significant size, into a tmpfs
  directory. Scratch and session temporary directories on this host are often
  tmpfs, so a multi-gigabyte image written there consumes real host RAM. Confirm
  with `findmnt -T <dir>` before writing anything sizeable, and use a
  disk-backed path.

## Container, image, and virtual machine safety

Treat every pre-existing Distrobox, Podman or Buildah container, image, volume,
libvirt domain, storage pool, and default storage tree as persistent user data.
The only disposable objects are ones created by the current task specifically
for temporary testing.

- Never delete, recreate, stop, or modify a container, image, VM, or pool that
  the current task did not create, unless the user explicitly names that object
  and authorizes the action.
- Never run broad cleanup. Specifically: no `podman rm -a`, `podman rmi -a -f`,
  `podman system prune`, `podman image prune -a`, `buildah rm --all`,
  `buildah rmi --all`, or wildcard deletion. Note that
  `.github/workflows/build.yml` legitimately runs some of these on ephemeral CI
  runners; that is not license to run them on the user's host.
- Before any cleanup, inspect `distrobox list`, `podman ps -a`, `podman images`,
  and the exact image and container relationships, then state the exact targets
  and expected effect. Cleanup is limited to exact names or IDs created by the
  current task. Do not infer that an older or apparently unused object is
  disposable.
- Run cache and clean-build experiments with isolated storage, root, and runroot
  paths, or with exact task-specific tags. Never by clearing the user's default
  Podman or Buildah storage.
- Local builds of this image are large and slow, and the desktop flavors are
  much larger than `base`. Explain the time and storage cost and obtain consent
  before starting one.

For virtual machine testing, `CLAUDE.md` in the repository root is binding and
takes precedence over convenience. In summary, and without replacing it:

- Use `qemu:///session` only. Never `qemu:///system`, which is host-wide and has
  unrelated user VMs on it.
- Enumerate existing domains and pools on both connections before creating
  anything, and choose an unmistakably task-scoped name verified to have zero
  collision. This host has pre-existing VMs and pools whose names resemble what
  a test would casually pick.
- Disk images only ever go through `bootc install to-disk --via-loopback`. Never
  point an installer at a real host block device, and never at a path that is
  not a file you just created for this purpose.
- `virt-install --disk path=<absolute path>` can silently auto-create an active,
  autostart libvirt storage pool named after the parent directory. It is not
  removed by deleting the VM or the file. If cleanup is authorized, check
  `virsh pool-list --all` during teardown.
- Cleanup is a separate consent gate, including after a test fails midway. Do
  not tear down task-created VMs, pools, loop devices, work directories, or
  test-only images until the user explicitly authorizes their exact removal.
  Until then, report their names and paths, their relation to the baseline, and
  any associated storage cost. After authorization, diff the domain and pool
  lists against the baseline, confirm `losetup -a` is empty, and remove only
  the approved test-only images.

Read the gotchas section of `CLAUDE.md` before trusting in-guest test output.
It documents specific ways a test harness in this environment has produced
false results, including a false positive security finding. Before concluding a
security control is broken, rule out the harness first, and if a false alarm
occurred, say so plainly rather than quietly fixing the script and reporting
only the clean result.

## GitHub and external-system safety

Read-only inspection of this repository's GitHub state is allowed when it is
relevant. Every GitHub write requires explicit consent for the exact repository
and action.

Without exact authorization, do not:

- Create, rename, transfer, archive, make public or private, or delete a
  repository.
- Push commits or tags.
- Open, edit, close, convert, or merge a pull request.
- Post comments, submit reviews, dismiss reviews, or resolve review threads.
- Dispatch, re-run, cancel, approve, or otherwise mutate an Actions run.
- Create releases, or publish or delete container images, package versions, or
  artifacts.
- Change branch protection, Actions permissions, collaborators, deploy keys,
  webhooks, variables, environments, or repository settings.
- Create, replace, rotate, reveal, or delete signing keys, tokens, or secrets.

Deleting published package versions deserves particular care. This repository
publishes three packages and prunes old versions from CI. Published image
versions may already be running on machines, and their cosign signatures are
separate manifests that a naive prune can orphan. Never delete a package version
manually, and treat a change to the retention job as a change that can break
`bootc upgrade` on installed systems.

Never print credentials or raw tokens. A failed secret probe is an error, not
proof that a secret is absent. Signing and publication setup must fail closed.
Do not weaken permissions, disable a check, remove signing, or expose a secret
to make a build pass.

## Repository-specific correctness guardrails

### The comments are part of the product

`Containerfile` is deliberately, heavily commented, and the comments record why
a thing is done, what was empirically verified, and which alternative was
rejected and why. Several of them exist because the obvious-looking change is
wrong and was already tried.

- Read the comment covering a step before changing that step.
- Do not delete, shorten, or "tidy" these comments as part of an unrelated
  change.
- If a change invalidates a comment, update the comment in the same commit.
- New non-obvious decisions get the same treatment. A bare one-line change with
  no rationale does not fit this codebase.

### Do not weaken the image's security model

The image ships a known default root password. That is safe only because every
remote, graphical, and local-escalation path to root is closed at the same time,
and each of those closures is load-bearing:

- `PermitRootLogin prohibit-password` pinned in an sshd drop-in.
- `pam_wheel.so use_uid` enabled in `/etc/pam.d/su`, because Arch ships that
  line commented out and would otherwise let any local account `su` to root.
- Display managers that refuse root.
- `passwd --expire` forcing a change on first use.

Do not remove or loosen any of these, do not extend a default password to a
non-root user, and do not add a remote or graphical path to root, without the
user explicitly deciding to change the model. Changing any one of them
invalidates the reasoning behind the others, so treat it as a security change
and say so.

Likewise, `system_files/etc/containers/policy.json` requires a valid signature
for this repository's published namespace, and `cosign.pub` at the repository
root is the single source of truth copied into the image. Do not relax the
policy, do not duplicate the key, and do not disable signature verification to
make something work.

### Package freshness and the build cache

The remote buildah layer cache keys a step on its instruction text and parent
layer digest. It has no way to know Arch's live repositories changed underneath
it, so an unguarded cache hit would skip `pacman -Syu` entirely and ship a stale
package set. `PACMAN_CACHE_BUST` exists to force a daily miss for exactly this
reason, and the resulting cascade is an accepted cost.

Do not remove the cache bust, do not reorder steps so package installation lands
above it, and do not "optimize" the cascade away without the user weighing the
security tradeoff explicitly.

### bootc provenance

`bootc` is compiled from upstream source, pinned by both a Renovate-tracked
release tag (`BOOTC_VERSION`) and the commit that tag resolved to
(`BOOTC_COMMIT`). This is a deliberate choice over installing a prebuilt binary
from a third-party pacman repository, and it is not merely a performance
question. Do not change how `bootc` is obtained, and do not add a third-party
package repository or signing key to the image, without explicit authorization
for that exact source.

The build verifies that the cloned tag still resolves to `BOOTC_COMMIT` and
fails otherwise. That check is a supply-chain control, not a formality: a git
tag is mutable, and `bootc` runs as root on every machine booting this image.
Do not remove it, do not relax it to a warning, and never change
`BOOTC_VERSION` without changing `BOOTC_COMMIT` to the peeled commit of the new
tag — the `^{}` row of
`git ls-remote --tags https://github.com/bootc-dev/bootc.git 'vX.Y.Z*'`.

### Service enablement policy

Enablement symlinks belong in `/usr/lib/systemd/system/<target>.wants/`, not in
`/etc`, because `/etc` is machine-local state subject to a three-way merge on
upgrade. The exception is the mask that must live in `/etc` to survive package
upgrades, which is documented in place.

- Do not introduce `systemctl preset-all`; the file explains why it is excluded.
- Do not move enablement into `/etc` for convenience.
- Anything added to the shared base stage reaches all three flavors. Verify the
  unit actually exists in every flavor before enabling it there.
- Each flavor re-runs a dangling-symlink check, `systemd-analyze verify`, and
  `bootc container lint`. Keep all three passing rather than relaxing them.

### Flavors are separate paths

`base`, `kde`, and `xfce` are separate build targets sharing a common base. Do
not claim one flavor is validated because another passed. A change touching the
shared base stage needs evidence from more than one flavor.

## Known environment hazards

A failed `podman build` in this repository is not guaranteed to be
side-effect-free on the host.

This image intentionally converts `/mnt`, `/root`, `/srv`, and `/opt` into
symlinks into `/var/...` early in the base stage, and those targets do not exist
until boot-time tmpfiles run. They are therefore dangling symlinks for the rest
of the build. When a `--mount=type=bind` step targets a container path whose
parent is one of those dangling symlinks, buildah's mount-target preparation
fails, and its cleanup path has been observed deleting real, previously
committed files from the bind mount's **host source directory**. This was
reproduced in this repository, not hypothesized.

Therefore:

- Never target a bind mount at a container path whose parent could be a dangling
  symlink at that point in the build. In this repository that means avoiding
  `/mnt`, `/root`, `/srv`, and `/opt` as mount targets anywhere after the
  directory restructuring step. Prefer `/tmp`, which stays a real directory
  throughout, or another path confirmed to be a plain directory at that stage.
- After any failed build involving a bind mount, run `git status` immediately,
  before anything else. Treat unexpected deleted entries as real data loss and
  restore them. Do not shrug off a failed build as harmless.
- Report the loss and the restoration to the user. Do not silently repair it.

## Validation expectations

For ordinary changes, run from the repository root:

```text
just lint
git diff --check
```

`just lint` runs `shellcheck` over the shipped scripts and verifies the shipped
systemd units inside a disposable container. Note that it builds a small
container and therefore uses `sudo` podman; treat invoking it as the privileged
operation it is.

Also run the checks relevant to changed files:

- `actionlint` for changed GitHub Actions workflows.
- `shellcheck` and `bash -n` for changed shell scripts, including scripts
  embedded in workflows that can be extracted faithfully.
- A local build of each affected flavor, after the user approves that
  resource-consuming build. `bootc container lint` and the unit checks run
  inside the build, so a successful build carries real signal.
- A VM boot test when, and only when, the change cannot be verified by building
  and static inspection — first-boot behavior, service startup, login paths,
  upgrade behavior. Follow `CLAUDE.md` exactly, and confirm you are testing the
  intended artifact by checking the image's revision label against the expected
  commit rather than trusting a tag.

Do not weaken or delete a check to obtain a pass. Report skipped checks, missing
tools, inaccessible logs, network failures, and sandbox limitations explicitly.
A sandbox permission error is not evidence that the host or the code is broken.

Evidence standards:

- State what was verified and what remains unknown. Do not infer success from
  truncated or inaccessible output.
- Before reporting that a control or fix works, confirm the test discriminates:
  observe it failing without the change. A check that passes both ways proves
  nothing.
- Do not reuse a cached layer or a previously published image as evidence for a
  fresh build unless provenance is verified.
- Reproduce a suspicious review finding before changing code. Shell or systemd
  syntax that merely looks unusual is not invalid until the relevant tool
  rejects it.

## Review, CI, and publication

- A request to review means read-only analysis unless the user also asks for
  fixes. Do not commit, push, comment, or resolve threads during a review.
- Review the complete diff against the intended base, recent commits, the
  resulting image behavior, security boundaries, and the effect on installed
  systems that will receive this as an upgrade.
- Verify PR checks separately from review-thread state. Flat comments do not
  reveal whether inline threads are unresolved or outdated; use thread-aware
  state when that distinction matters.
- A code fix does not resolve a review thread automatically. Replying to or
  resolving a thread is a GitHub write and requires consent.
- Passing checks mean only that the observed checks passed at the observed SHA.
  Recheck the head SHA and current state before reporting readiness.
- Pull request builds deliberately skip the rechunk, push, and sign steps, and
  no CI job boot-tests the image. A green PR check therefore proves the image
  builds, not that it boots or upgrades. Say so rather than implying coverage.
- Renovate is configured to automerge most updates once the PR build is green.
  Do not broaden that automerge scope, and do not disable the carve-outs, without
  the user deciding to accept the additional risk.
- "Ready for PR" does not mean "ready to merge." A merge always requires explicit
  authorization, even after unanimous review and green CI.

## Completion and cleanup

At the end of a task, report:

- Files changed and the behavior affected.
- Validation run and exact outcomes, including which flavors were built and
  whether anything was booted.
- Current branch and worktree status.
- Any skipped or inconclusive checks.
- Any external state created or modified, including images, tags, VMs, pools,
  loop devices, and work directories.
- The next gated action, if one remains.

Do not perform cleanup merely because the task appears complete. After a merge,
update local `main`, delete branches, remove test images, or delete test
resources only when the user authorizes each exact action. This includes
test-only infrastructure created by the task — virtual machines, storage pools,
loop devices, and scratch directories from a VM test — even if a step failed
midway. Before requesting that approval, report the exact resources, their
paths or identifiers, their relationship to the baseline snapshot, and any
meaningful storage cost. After cleanup is authorized, verify the approved
resources were removed against the baseline snapshot.

Preserve anything whose ownership or recoverability is uncertain.
