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
when no entry references `/EFI/Linux/<id>/`, and `--dry-run`.

Those tests always point the script at a throwaway fixture directory via
`BOOTC_PRUNE_ESP_PATH`. That is not optional: with the variable unset the script
discovers ESPs from the real mount table, and the tests would delete real boot
artifacts on whatever machine ran them. Keep new tests on the same escape hatch.

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

## Keeping pinned versions up to date

`bootc`, the base images, the GitHub Actions and the cosign/chunkah/zizmor versions are all
pinned, and Renovate keeps them current — opening a PR per update and merging it once the
build passes. See [Renovate](renovate.md) for how that works and how to control it.
