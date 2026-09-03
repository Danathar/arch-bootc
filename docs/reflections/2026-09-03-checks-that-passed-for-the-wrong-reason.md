# 2026-09-03 — Three checks that passed for the wrong reason

Written while adding `tests/check-invariants.sh`, the path labeler, and the
`ai-fix` work order. All three problems below were in *new* checks, found before
they merged. The common thread is worth more than any of them individually: in
each case something reported success, and the success was an artifact of how the
check was built rather than evidence about the thing it checked.

## 1. A security assertion satisfied by the comment explaining it

**What happened.** `check-invariants.sh` asserted the root-login controls with
`grep -Eq 'pam_wheel\.so use_uid' Containerfile`. Deleting the executable line
that enables it — line 166, the `sed` that uncomments Arch's own
`pam_wheel.so use_uid` — left the check green:

```
$ sed -i '166d' Containerfile && ./tests/check-invariants.sh; echo $?
0
```

Green, while any local account could reach root with the image's known default
password.

**Why it was possible.** This repository comments heavily, and a good rationale
comment necessarily uses the same words as the instruction it explains.
`pam_wheel.so use_uid` appears in the `sed` *and* in three comments about it;
`PermitRootLogin prohibit-password` appears in the sshd drop-in *and* in the
comment above it. A plain `grep` is therefore satisfied by the surviving
*explanation* of a control that has been deleted — which is exactly backwards,
because the comment is what survives a careless edit.

**What caught it.** A reviewer, not the test. Worse: **my own negative control
had hidden it.** The mutation I used to "prove the check discriminates" was
`sed -i '/pam_wheel/d'`, which deletes the comments too — so the check failed,
but for the wrong reason, and I recorded a pass.

**What changed.** Presence assertions strip comment lines before matching, and
the negative controls delete only executable lines. See the `assert_present`
comment in [`tests/check-invariants.sh`](../../tests/check-invariants.sh).

**The transferable rule.** A negative control has to be the *minimal* change
that breaks the property. A broad mutation proves the check reacts to
*something*, which is not the claim being made. When the mutation is bigger than
the property, the test is measuring the mutation.

## 2. `grep -q` downstream of a pipe, under `pipefail`

**What happened.** Fixing #1 introduced `grep -Ev '^[[:space:]]*#' file | grep -Eq pattern`
in a script running `set -uo pipefail`. It made the check **non-deterministic**:

```
$ for i in $(seq 1 12); do grep -Ev "^ *#" Containerfile | grep -Eq "^ARG PACMAN_CACHE_BUST="; printf "%s " $?; done
0 0 0 0 0 141 0 0 0 0 0 0
```

On an unmodified tree it failed roughly **one run in eight**.

**Why it was possible.** `grep -q` exits the moment it matches. The upstream
`grep` then writes into a closed pipe and takes `SIGPIPE`, exiting 141. Under
`pipefail` the pipeline reports 141, so a satisfied assertion reports failure.
It is a race, so it passes in casual testing.

**What caught it.** Running the mutation suite and noticing that mutations were
tripping checks they could not possibly affect — deleting a `pam_wheel` line
"broke" `PACMAN_CACHE_BUST is declared`. The anomaly was in the *shape* of the
results, not in any single run.

**What changed.** Both affected sites use a here-string and no pipeline.
Verified over 40 consecutive runs on an unmodified tree: zero failures.

**The transferable rule.** An intermittently-red check is worse than no check —
it trains everyone to re-run until green. And results that are *implausible*
rather than merely failing are the signal: if a mutation trips a check it cannot
reach, stop and explain that before reading anything else in the run.

## 3. A workflow that would have run the branch's code with a write token

**What happened.** `.github/workflows/ai-fix.yml` checked out with
`actions/checkout` defaults and then ran `./scripts/pr-review-state.sh` with
`GH_TOKEN` carrying `issues: write` and `pull-requests: write`. On a
`pull_request` event the default ref is the merge commit, so labelling a pull
request that *edits that script* would have executed the branch's version of it
with those permissions.

**Why it was possible.** The job already skipped fork pull requests, and that
felt like the whole threat model. It is not: this repository's own
agent-authored work arrives on **same-repository** branches, which is precisely
where the branch's code is not yet trusted.

**What caught it.** A reviewer — and the rule had been written down two pull
requests earlier, in
[`docs/security/SECURITY-AI.md`](../security/SECURITY-AI.md): the diff under
review is data, and policy and tooling are read from the base revision. The
workflow was not applying that rule to itself.

**What changed.** The checkout pins `ref: ${{ github.event.repository.default_branch }}`.

**The transferable rule.** Writing a policy down does not apply it. The first
thing to check against a new policy is the change that introduced it, and the
next thing is everything written immediately afterwards.

## What still would not be caught

`check-invariants.sh` reads the `Containerfile` as text. A step with the right
shape and the wrong effect still passes it, and no static check settles that —
only the VM procedure in [`CLAUDE.md`](../../CLAUDE.md) does. It also cannot see
that display managers refuse root, because that behavior comes from packaged
units rather than from anything in this tree.

Nothing here would have caught #1 without a human reviewer. That is the honest
summary: the check that asserts the security invariants was itself wrong, and
the thing that found it was review.
