# Pull request review rubric

What a reviewer checks here, in the order it is worth checking. Most of this is
[AGENTS.md](../AGENTS.md) restated as questions you can answer against a diff.

Reviewing is read-only analysis. Do not commit, push, comment, or resolve
threads as part of a review unless you were also asked to fix things — replying
to or resolving a thread is a write, and a code fix does not resolve a thread
automatically.

## 1. Scope

- [ ] The diff does one thing. Unrelated fixes, reformatting, and drive-by
      cleanups are not folded in.
- [ ] Nothing pre-existing or untracked got swept into the branch.
- [ ] The PR description's "what changed" matches what the diff actually does.
- [ ] Review the complete diff against the intended base, not just the last
      push.

## 2. Security invariants

Reject or escalate anything here that is not called out explicitly as a
deliberate security change.

- [ ] The root-login model is intact: `PermitRootLogin prohibit-password` in the
      sshd drop-in, `pam_wheel.so use_uid` in `/etc/pam.d/su`, display managers
      still refusing root, `passwd --expire` still forcing a change. These four
      are load-bearing *together* — the default root password is only safe
      because all of them hold.
- [ ] No default password is extended to a non-root user, and no new remote or
      graphical path to root is introduced.
- [ ] `system_files/etc/containers/policy.json` still requires a signature for
      the published namespace; `cosign.pub` is not duplicated or bypassed.
- [ ] No third-party pacman repository or signing key is added to the image.
- [ ] `PACMAN_CACHE_BUST` is intact and package installation has not moved above
      it.
- [ ] Workflow changes keep `persist-credentials: false` on checkouts, and pass
      `${{ ... }}` values through `env:` rather than interpolating them into
      `run:` blocks.

## 3. Image and system correctness

- [ ] Which flavors does this touch? A change to the shared base stage reaches
      `base`, `kde`, and `xfce` — evidence from one is not evidence for another.
- [ ] Anything enabled in the shared stage actually exists in every flavor.
- [ ] Service enablement stays in `/usr/lib/systemd/system/<target>.wants/`, not
      `/etc`, except the documented mask that must live there. No
      `systemctl preset-all`.
- [ ] No `--mount=type=bind` targets a path under `/mnt`, `/root`, `/srv`, or
      `/opt` after the directory-restructuring step. Those are dangling symlinks
      for the rest of the build, and a failed bind-mount there has been observed
      deleting real files from the **host** source directory.
- [ ] What happens to systems that receive this as a `bootc upgrade`, not just
      to a fresh install?

## 4. Comments and rationale

- [ ] Existing `Containerfile` rationale comments are not deleted, shortened, or
      tidied as a side effect.
- [ ] Any comment the change invalidates is updated in the same commit.
- [ ] New non-obvious decisions carry their own rationale. A bare one-line change
      with no explanation does not fit this codebase.

## 5. Tests and validation

- [ ] New or changed shell behavior has a test, and the test would fail without
      the change. A check that passes both ways proves nothing.
- [ ] Coverage floors in `.coverage-thresholds.json` were raised, not lowered.
      A lowered floor needs an explicit reason.
- [ ] A new `tests/test-*.sh` was added to *both* shellcheck invocations — the
      `Justfile` `lint` recipe and the CI ShellCheck step — or it silently
      escapes linting.
- [ ] No check was weakened, skipped, or deleted to obtain a pass.

## 6. Evidence

This is where reviews most often need to push back.

- [ ] The PR states the exact commands run and what they printed.
- [ ] Static checks, builds, and VM boots are distinguished from each other. A
      green PR check proves the image **builds** — PR builds skip rechunk, push,
      and sign, and nothing in CI boots the image.
- [ ] Skipped and inconclusive checks are listed. A stated gap is fine; an
      implied pass is not.
- [ ] Claims about a VM test name the artifact tested and confirm its revision
      label matches the expected commit, rather than trusting a tag.
- [ ] External state — images, tags, VMs, storage pools, loop devices, work
      directories — is listed, or explicitly "None".

## 7. Checks and threads

- [ ] Check status was read at the **current** head SHA, not an earlier push.
- [ ] Inline review threads were inspected with thread-aware state. Flat comments
      do not reveal whether a thread is unresolved or outdated.
      `./scripts/pr-review-state.sh <number>` reports both, together with the
      checks at the same head SHA; see [ci-cd.md](ci-cd.md). A resolved thread
      is not evidence the issue was fixed, only that someone resolved it.
- [ ] A suspicious finding was reproduced before code changed on account of it.
      Shell or systemd syntax that merely looks unusual is not invalid until the
      relevant tool rejects it.

## Merging

"Ready for PR" is not "ready to merge," and neither is unanimous review plus
green CI. A merge is a separate, explicit decision by the repository owner.

Renovate automerges most dependency updates once the build is green, with
deliberate carve-outs (notably major `bootc` bumps). Do not broaden that scope
or remove a carve-out as part of an unrelated review.
