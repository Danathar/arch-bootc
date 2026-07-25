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

## Keeping pinned versions up to date

`bootc`, the base images, the GitHub Actions and the cosign/chunkah versions are all pinned,
and Renovate keeps them current — opening a PR per update and merging it once the build
passes. See [Renovate](renovate.md) for how that works and how to control it.
