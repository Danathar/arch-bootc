# Agent boundaries

AI agents do much of the work in this repository. This page lists the limits
they work inside and, for each one, what actually holds it in place: GitHub
itself, a check that has to pass, the agent's own tool, or only a written
instruction.

The difference matters. A rule GitHub enforces holds whoever is pushing,
including an agent holding the maintainer's credentials. A written instruction
holds only as long as the agent follows it, and agents here read issue text
written by others, which is exactly where someone would try to talk one out of
it. So when this page says a limit is "instruction only", read that as "a
person still has to check".

This page is a map. The detail lives on the pages it links to, and
[`AGENTS.md`](../AGENTS.md) is still the policy an agent follows.

## How the boundaries are enforced

Strongest first:

1. **GitHub.** Server-side rules that apply to every push and merge, from
   anyone.
2. **The required check.** A pull request that fails `Shell tests and coverage`
   cannot merge, because GitHub requires that check.
3. **The agent's tool.** Claude Code reads a permission table from this
   repository and refuses or prompts before some commands. Renovate reads its
   own configuration. Each applies only inside that one tool.
4. **Instruction only.** Rules an agent is told to follow and nothing else
   enforces.

## Enforced by GitHub

[`.github/rulesets/main.json`](../.github/rulesets/main.json) is the ruleset on
`main`. It has no bypass actor, so it binds the maintainer, every App and
Actions alike. It holds three limits:

- Nothing is pushed to `main` directly. Every change arrives as a pull request.
- `main` cannot be deleted or have its history rewritten.
- A pull request merges only after `Shell tests and coverage`, reported by
  GitHub Actions, has passed on it.

It needs no approval, because a sole maintainer cannot approve their own pull
request. [Branch protection](branch-protection.md) explains each rule and how
to check that GitHub is really applying it.

## Enforced by the required check

`Shell tests and coverage` is the `test` job in
[`.github/workflows/build.yml`](../.github/workflows/build.yml), with a copy in
[`.github/workflows/docs-tests.yml`](../.github/workflows/docs-tests.yml) for
pull requests that touch only documentation. It runs
`tests/check-coverage.sh` and then `tests/check-invariants.sh`. The second one
is where most boundaries in this repository become mechanical. It fails when:

- the image's security model drifts: the root-login closures, the signature
  policy and its key path, the `bootc` pin, `PACMAN_CACHE_BUST`, or the
  service enablement layout ([CONTRIBUTING](../CONTRIBUTING.md#checks-you-can-run));
- a workflow job's token permissions stop matching
  [`.github/policies/workflow-permissions.json`](../.github/policies/workflow-permissions.json),
  so a job cannot gain a scope without a second edit in the same pull request;
- the agent permission files stop being tiered T3 in
  [risk tiers](risk-tiers.md) or listed among the invariants in the
  [AI security policy](security/SECURITY-AI.md);
- the required job is renamed or gains a condition that could skip it.

The check reads the tree of the pull request it runs on. A pull request can
change a check and the thing it checks in the same diff, and the check then
passes. What stops that is a person reading the diff, which is why
[risk tiers](risk-tiers.md) calls weakening a check the characteristic T1
failure.

## Enforced by the agent's tool

**Claude Code.** [`.claude/settings.json`](../.claude/settings.json) is the
permission table. Its `deny` list blocks reading `cosign.key` and other secret
files, broad container cleanup, the irreversible `virsh` verbs on
`qemu:///system`, and git commands such as `reset --hard` and force-push. Its
`ask` list prompts before `sudo`, image builds and every git or `gh` write. Its
`allow` list runs the test suite and read-only commands with no prompt. Its
`hooks` block registers
[`.claude/hooks/gate-git-diff.sh`](../.claude/hooks/gate-git-diff.sh), which
re-checks the allowed commands that can read or write files anywhere on disk.
[Quality signals](quality.md#agent-guardrails) lists the rules, and the
[AI security policy](security/SECURITY-AI.md) lists what the hook refuses.

Its limits:

- It binds Claude Code only. Another tool, or a person at a terminal, never
  reads it.
- The rules match command prefixes, so a differently spelled command can reach
  the same effect.
- `.claude/settings.local.json` is not tracked, and a machine can add
  allowances there.
- `permissions.disableBypassPermissionsMode` is not set, so a session started
  with permission checks skipped ignores the whole table.

**Renovate.** [`renovate.json`](../renovate.json) turns automerge off for a
major `bootc-dev/bootc` bump. That is the one place the
[risk tiers](risk-tiers.md) are enforced rather than advised. Every other
Renovate update merges on its own once the build is green
([Renovate](renovate.md)).

## Instruction only

- **The consent gates.** [`AGENTS.md`](../AGENTS.md) says that a request to
  implement something does not authorize a commit, a push, a pull request, an
  image build, a VM, a merge or a cleanup. Nothing outside the permission table
  above checks this.
- **Other agents' rule files.**
  [`.cursor/rules/arch-bootc-safety.mdc`](../.cursor/rules/arch-bootc-safety.mdc)
  is applied to every Cursor session and points it at `AGENTS.md`.
  [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) does
  the same for Copilot. Neither tool enforces anything from them.
- **Who merges.** The README says every agent pull request gets a `hold` label
  and that a maintainer merges it. Hive applies the label
  ([Multi-agent work](multi-agent.md#who-merges)). GitHub does not enforce it:
  the ruleset requires no approval, so anyone who can merge a green pull
  request can merge an agent's.
- **T3 changes.** [Risk tiers](risk-tiers.md) says a change to boot, the
  security model, provenance or published artifacts never merges on a green
  check alone. Apart from the Renovate rule above, that is a reviewer's call.

## What none of this stops

**Push access reaches the signing key.** `SIGNING_SECRET` is read only by the
`Sign container image` step, and that step's `if:` runs it only on `main`,
never on a pull request. That keeps the key out of ordinary pull request
builds. It is not a wall. `build.yml` runs on `pull_request`, and a pull
request from a branch in this repository runs the workflow files from its own
branch, with this repository's secrets. GitHub withholds secrets only from
pull requests opened from forks
([GitHub Docs](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions)).
No GitHub environment guards the key either. So anyone, or any agent, that can
push a branch here can write a workflow that reads it, and CI runs that
workflow before anyone reviews it. The real boundary around the key is who
holds push access.

**An agent outside Claude Code.** An agent working through another tool, or
directly through `git` and `gh` with the maintainer's credentials, meets only
the GitHub and required-check rows above.

## Changing a boundary

Classify the change with [risk tiers](risk-tiers.md) first. The ruleset, the
permission table, the hook, the skills, the Cursor rule, the workflow
permission policy and the signing step are all T3, so a change to any of them
never merges on a green check alone. Say in the pull request which way it
moves the boundary. Narrowing a limit is still T3.
