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
`build.yaml`), but the policy files above do **not** pick that up
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

## Shell unit tests

The tests live in `tests/` and are plain bash — no framework, no root, no
container runtime, no network — so the same command CI runs works locally:

```bash
just test        # or: ./tests/run-tests.sh
```

`tests/run-tests.sh` executes every `tests/test-*.sh` and fails if any of them
does. `tests/test-prune-esp.sh` covers `arch-bootc-prune-esp`: argument
handling, candidate discovery, the keep-set parsed out of BLS entries (including
CRLF line endings and a final line with no newline), the refuse-to-prune guard
when no entry references `/EFI/Linux/<id>/`, and `--dry-run`.

Those tests always point the script at a throwaway fixture directory via
`BOOTC_PRUNE_ESP_PATH`. That is not optional: with the variable unset the script
discovers ESPs from the real mount table, and the tests would delete real boot
artifacts on whatever machine ran them. Keep new tests on the same escape hatch.

`just lint` shellchecks the test scripts too, so they are held to the same bar as
the scripts they cover.

`build.yaml` does not run them yet. To gate builds on the tests, add a `test` job
that checks out the repo and runs `./tests/run-tests.sh`, then change
`build_push`'s `needs: lint` to `needs: [lint, test]`. Adding
`/mnt/tests/run-tests.sh` and `/mnt/tests/test-prune-esp.sh` to the `ShellCheck`
step's argument list keeps CI's shellcheck coverage in step with `just lint`.

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
  ordinary shell variable. Several steps in `build.yaml` do this now (`METADATA_TAGS`,
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
