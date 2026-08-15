# Dependency updates with Renovate

This repo keeps its build tooling up to date with [Renovate](https://docs.renovatebot.com/).
Renovate watches the pinned versions in `Containerfile` and `.github/workflows/build.yaml`,
opens a PR when something newer exists, and merges that PR itself once the build passes.

Everything is configured in [`renovate.json`](../renovate.json) at the repo root.

## Who runs it

The **hosted Renovate GitHub App** (`app/renovate`), installed on this fork. There is no
Renovate workflow in `.github/workflows/` — the app runs on its own schedule, which this repo
does not control. To make it run now, use the manual trigger on the Dependency Dashboard
(see below).

Because this repo is a fork, `renovate.json` sets `"forkProcessing": "enabled"`. Renovate
skips forks by default; without that line nothing would run at all.

## What is tracked

| Dependency | Pinned as | Where | How Renovate finds it |
| --- | --- | --- | --- |
| `bootc-dev/bootc` | git tag, built from source | `Containerfile` `ARG BOOTC_VERSION` | inline `# renovate:` comment |
| Arch base image | `:latest@sha256:…` | `Containerfile` `FROM` | `dockerfile` manager |
| `ublue-os/brew` | `:latest@sha256:…` | `Containerfile` `COPY --from=` | `dockerfile` manager |
| `actions/checkout` | commit SHA | `build.yaml` | `github-actions` manager |
| `docker/metadata-action` | commit SHA | `build.yaml` | `github-actions` manager |
| `redhat-actions/buildah-build` | commit SHA | `build.yaml` | `github-actions` manager |
| `sigstore/cosign-installer` | commit SHA | `build.yaml` | `github-actions` manager |
| cosign CLI | `cosign-release: vX.Y.Z` | `build.yaml` | custom regex manager |
| chunkah image | `quay.io/coreos/chunkah:vX.Y.Z` | `build.yaml` env | custom regex manager |
| shellcheck image | `docker.io/koalaman/shellcheck:vX.Y.Z` | `build.yaml` `SHELLCHECK_IMAGE` env | custom regex manager |
| zizmor | `ZIZMOR_VERSION: X.Y.Z` | `zizmor.yaml` env | custom regex manager (`pypi`) |
| runner image | `ubuntu-24.04` | `build.yaml` `runs-on` | `github-actions` manager |

Two of these need explanation.

**bootc** is not a container image reference — it is an `ARG` consumed by
`git clone --branch "${BOOTC_VERSION}"`. Renovate only sees it because of the annotation
directly above it:

```dockerfile
# renovate: datasource=github-releases depName=bootc-dev/bootc
ARG BOOTC_VERSION=vX.Y.Z
```

(Renovate rewrites the version in place, so the real file always shows whatever is current —
check `Containerfile` rather than this doc for the pinned value.)

If that comment is ever removed or reworded, bootc silently freezes at whatever version it is
on. Nothing will fail; updates just stop arriving.

**chunkah and shellcheck** are pinned by tag only. A `packageRule` explicitly disables
`digest`/`pin`/`pinDigest` updates for both, so Renovate offers new tagged releases but never
rewrites either reference into a digest. Both are tracked via custom regex managers whose
`matchStrings` capture only a semver tag — no digest capture group — so letting Renovate's
default digest-pinning apply to them fails to find anywhere to write the digest and errors the
branch (this happened for real: chunkah in #18, shellcheck in #68). Any future custom regex
manager on the `docker` datasource needs the same exclusion unless its `matchStrings` also
captures a digest.

## What is *not* tracked

`packages-base.txt`, `packages-kde.txt` and `packages-xfce.txt` carry **no version
constraints**, and the `Containerfile` runs `pacman -Syu`, a full system upgrade. Every build
therefore installs whatever Arch ships that day.

This is deliberate — Arch is a rolling distro and Renovate has no pacman datasource — but it
has a consequence worth being explicit about:

> The **recipe** is pinned. The **contents** are not. Two builds of the same commit are not
> the same image.

The scheduled daily build (`cron: "05 10 * * *"`) rebuilds, rechunks, pushes and signs a fresh
image every morning with no commits involved. The digest pins above fix the starting layer,
but `pacman -Syu` immediately upgrades past it.

The Flathub `.flatpakrepo` file is vendored at `system_files/etc/flatpak/remotes.d/` (no
longer fetched live with `curl` at build time) and has no Renovate datasource — Flathub's
URL/key have been stable since ~2018, but there's no automation watching it. Re-check it
manually if Flathub ever changes it.

## The flow, step by step

1. **Renovate runs** and compares each tracked pin against its upstream source.
2. **It creates a branch** — `renovate/<something>` — containing just the version bump.
3. **It opens a PR immediately.** It does *not* wait for a build first. The PR is open and
   visibly "unchecked" for roughly the length of a build.
4. **`build.yaml` triggers on the PR** and compiles all three flavors (`base`, `kde`, `xfce`)
   in parallel — three check runs, around 20 minutes.
   On PRs the workflow *only builds*: the rechunk, push-to-GHCR and cosign steps are gated to
   non-PR events, so nothing is published from a PR.
5. **On a later Renovate run**, it looks at the PR's status. Green → it squash-merges. Red or
   still running → it leaves the PR alone and checks again next time.
6. **The merge to `main` triggers `build.yaml` again**, and this time the full path runs:
   build → rechunk with chunkah → push to GHCR → sign with cosign.

Step 5 is the important one: **Renovate does the merging, not GitHub.** See
[Why merging is Renovate's job](#why-merging-is-renovates-job).

## What merges automatically

Almost all of it — `digest`, `pin`, `pinDigest`, `patch`, `minor` and `major` — squash-merged
once the build is green.

The one exception: a **major** version bump of `bootc-dev/bootc` never automerges, regardless
of build status. The PR build only proves the Containerfile still compiles bootc and passes
`bootc container lint` — it does not boot-test the image, so a breaking change to bootc's
on-disk format, CLI, or upgrade behavior would otherwise merge automatically like everything
else. Every other update type for that package (digest, pin, patch, minor) still automerges
normally.

The gate is the PR build, and it is worth knowing precisely what that proves and what it does
not:

- ✅ The image **compiles** for all three flavors.
- ❌ It is **not boot-tested**. A change that builds cleanly but breaks first boot or
  `bootc upgrade` will merge.
- ❌ **Three tracked dependencies are never exercised by it at all.** The rechunk, push and
  sign steps are gated to non-PR events, so `quay.io/coreos/chunkah`,
  `sigstore/cosign-installer` and the `cosign-release` CLI version are not run on a PR. An
  update to any of those gets a green build that never touched it, automerges, and is first
  exercised on `main` — where a failure means no image is published or signed that run.

That last point is the weakest link in the automerge gate. If a publish step starts failing on
`main` shortly after an automerged update, check those three first.

That trade is accepted deliberately: this is an experimental image, not production. A bad
update surfaces either as a red build on `main` (GitHub notifies) or on the next
`bootc upgrade`, and is then investigated.

The two exceptions are chunkah and shellcheck digest updates, which are disabled entirely (see
above).

## Why merging is Renovate's job

Renovate can either merge a PR itself, or hand off to GitHub's native auto-merge
(`platformAutomerge`, which defaults to `true`). This repo sets it to **`false`** on purpose.

GitHub's native auto-merge gates only on **required** status checks. `main` here is
unprotected, so there are none — a PR would qualify the moment it opened, roughly 20 minutes
before its build finishes. Renovate's own documentation warns about this:

> If you don't select any status check, and you use platform automerge, then GitHub might
> automerge PRs with failing tests!

With `platformAutomerge: false`, Renovate performs the merge and checks branch status first,
so a red or still-running build holds the PR. The cost is latency: merges land on Renovate's
run cadence rather than the instant CI turns green.

The repo setting `allow_auto_merge` is also **off**, which blocks the same path independently.
Both guards must stay in place, or be replaced together — see below.

### If you ever want instant merges

Protect `main` with the three `Build and push image (base|kde|xfce)` checks marked as
**required**, then set `platformAutomerge: true` and enable `allow_auto_merge` on the repo.
That makes native auto-merge safe *and* immediate, because GitHub now has real checks to gate
on. Note that branch protection would also apply to your own direct pushes to `main` unless
`enforce_admins` is left off.

## The Dependency Dashboard

Renovate maintains an issue titled **Dependency Dashboard** listing everything it tracks and
everything pending. It is the main control surface.

It only exists because **Issues are enabled** on this repo. If Issues get turned off, the
dashboard silently disappears and there is no other place Renovate can put it.

Useful sections:

- **Open** — PRs already raised. Ticking one forces a rebase/retry.
- **Other Branches** — update branches that exist but have no PR yet. Ticking one forces the
  PR to be created. This section should normally be empty: `"prHourlyLimit": 0` stops branches
  being created faster than their PRs. If entries start accumulating here again, suspect
  `rebaseWhen` (see Gotchas) before anything else — a branch stranded without a PR is that
  bug's first symptom.
- **Detected Dependencies** — the full inventory Renovate sees, with available updates. The
  quickest way to confirm a new pin is actually being tracked.
- **Bottom checkbox** — requests a fresh Renovate run. This is the manual trigger.

## Common tasks

**Force a run now** — tick the last checkbox on the Dependency Dashboard.

**Check whether something is tracked** — open the dashboard and look under *Detected
Dependencies*. If a pin is not listed there, Renovate cannot see it.

**Add a new tracked version** that isn't a container image or an action — add an annotation
comment above it, following the bootc example:

```dockerfile
# renovate: datasource=github-releases depName=owner/repo
ARG SOMETHING_VERSION=v1.2.3
```

For a value inside a workflow file, add a custom regex manager to `renovate.json` instead —
the chunkah and cosign entries are the two worked examples.

**Validate config changes before pushing:**

```bash
npx --yes --package renovate renovate-config-validator renovate.json
```

Pin the package version (`renovate@43.280.4` or later) if `npx` resolves a stale cached copy —
an old validator will reject `managerFilePatterns` as unknown, which is a false positive.

**Stop a specific dependency from updating** — add a `packageRule` with
`"enabled": false` and `matchPackageNames`. Later rules win, so place it after the automerge
rule, as the chunkah rule does.

## Gotchas

**This repo is a fork.** Renovate runs on the fork, not on `bootcrew/arch-bootc` upstream. The
`gh` CLI defaults to the *parent* repo, so `gh pr list` can show upstream's PRs and make it
look like Renovate is not running. Fix it once per clone:

```bash
gh repo set-default Danathar/arch-bootc
```

PR numbers in commit messages inherited from upstream refer to *upstream's* numbering, not
this fork's.

**`rebaseWhen` must not be `"never"`.** It is set to `"conflicted"`, which rebases a PR only
when it actually conflicts — keeping rebuild churn low, since each rebase costs a ~20 minute
three-flavor build.

Do not change it back to `"never"`. That value makes Renovate's branch worker return early
with `result: "no-work"` for *any* branch that already exists, before it reaches the automerge
step — so automerge silently stops working, and update branches that exist without a PR never
get one. The only thing that reaches past it is a Dependency Dashboard checkbox, which is an
explicit bypass in that code path. This repo hit exactly that on 2026-07-25: three green,
mergeable PRs sat unmerged across two Renovate runs with no error anywhere, and the logs showed
`rebaseWhen=never so skipping branch update check` followed by `"result": "no-work"` while the
same summary reported `"automerge": true`.

**Branches are not deleted on merge** (`delete_branch_on_merge` is off), so merged
`renovate/*` branches accumulate. Harmless, but they build up.
