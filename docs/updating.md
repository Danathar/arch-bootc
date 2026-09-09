# Updating & Day-2 Operations

## Updating Installed Systems From Your Repo

Once installed, switch to your GHCR image and reboot:

```bash
bootc switch ghcr.io/<your-user>/arch-bootc-kde:latest
reboot
```

Your local users and host state persist across image updates (`/etc`, `/var/home`).

## Troubleshooting: composefs garbage collection error ("Invalid splitstream header magic value")

This image installs with the native composefs backend. On `bootc v1.15.x`, a
`bootc upgrade` could fetch and store the new image successfully but then fail
during `Running composefs garbage collection` with:

```text
Running composefs garbage collection: ... Walking stream oci-manifest-sha256:<digest>:
... Creating new splitstream reader: Invalid splitstream header magic value
```

**Cause — bootc/composefs-rs version skew, not disk corruption.** The on-disk
splitstream header layout changed in composefs-rs commit `b7dc27065`
(2026-03-17), which added `#[repr(C)]` to the header structs. Before that, the
compiler reordered the fields and the `SplitStream` magic landed at byte offset
18; after it, the magic sits at offset 0. `bootc v1.15.2` pins composefs-rs
`2203e8f` (2026-03-06, *pre*-`repr(C)`), so it reads/writes the offset-18
layout. If the system was originally installed with a newer toolchain that
wrote the offset-0 layout, v1.15.2's GC cannot parse those streams and aborts
with the error above — naming the specific stream it failed to read.

**Fix — build `bootc v1.16.0` or newer.** v1.16.0 pins composefs-rs `e2770757`
(2026-05-28), which includes both the `repr(C)` offset-0 layout *and* "read and
upgrade older composefs-rs repos" (`54d248f7a`), so its GC handles a mixed repo
and the skew is gone. This image builds `bootc` well past that version — see
`BOOTC_VERSION` in the `Containerfile`, kept current by
[Renovate](renovate.md).

**Recovering an affected machine:**

1. The upgrade content usually applied even though GC errored — the new
   deployment is staged. Confirm and reboot to activate it:
   ```bash
   sudo bootc status   # look for a staged deployment
   sudo reboot
   ```
2. The upgrade that *installs* the fixed bootc version still runs under the
   old bootc, so GC may throw the error one final time; reboot anyway. Every
   `bootc upgrade` after you are running the fixed version is clean.
3. If a leftover image ref keeps tripping GC on an old (offset-0) stream, list
   the refs and remove only ones **not** tied to your booted/rollback
   deployments (these are tracked via boot entries, not `streams/refs`):
   ```bash
   sudo find /sysroot/composefs/streams/refs -type l -printf '%p -> %l\n'
   # /sysroot is mounted read-only; bootc remounts it rw during its own
   # operations. Hand-editing the composefs repo is unsupported — prefer
   # upgrading to a fixed bootc version, which resolves this without manual
   # surgery.
   ```

## Troubleshooting: rootless podman fails with `default OCI runtime "crun" not found`

On a system upgraded from an older image, every rootless `podman` command —
including `podman info` — can fail with:

```text
Error: default OCI runtime "crun" not found: invalid argument
```

The message is misleading. `crun` is installed (it is in `packages-base.txt`),
`/usr/bin/crun` is owned by the `crun` package, and it runs fine. Ask podman
what actually happened:

```bash
podman --log-level=debug info 2>&1 | grep -E 'graph root|run root|tmp dir|crun'
```

```text
Overriding tmp dir "/run/user/1000/libpod/tmp" with "/run/libpod" from database
Using graph root /var/lib/containers/storage
Using run root /run/containers/storage
Configured OCI runtime crun initialization failed:
    creating OCI runtime exit files directory: mkdir /run/libpod: permission denied
```

Rootless podman is using the **rootful** storage paths. It reads root's
world-readable `db.sql` under `/var/lib/containers/storage`, inherits
`/run/libpod` as its tmp dir from that database, and then cannot create it as an
unprivileged user. Every configured runtime fails to initialize for the same
reason, and podman reports only the summary — which names the default runtime
rather than the permission error behind it.

**Cause — an orphaned `/etc/containers/storage.conf`, not a missing runtime.**
Older `containers-common` packages installed a `storage.conf` into `/etc` with
`driver`, `runroot`, and `graphroot` **uncommented** and pointing at the rootful
locations. Current `containers-common` ships that template at
`/usr/share/containers/storage.conf` with those keys commented out, and installs
nothing of the kind under `/etc/containers/`. Neither this repository nor the
pinned Arch base image creates the file — the base image has no
`/etc/containers` directory at all — so a **fresh install is unaffected**.

On a machine that has been carrying the file since an older image, it survives
as machine-local `/etc` state through the three-way merge on every upgrade.
Podman honours it literally, which is what redirects rootless storage to root's
tree. Confirm with:

```bash
pacman -Qo /etc/containers/storage.conf     # "No package owns" == orphan
grep -E '^(driver|runroot|graphroot)' /etc/containers/storage.conf
```

The same generation of `containers-common` also left `containers.conf`,
`registries.conf`, `mounts.conf`, and `seccomp.json` behind in `/etc/containers`
on affected machines. Only `storage.conf` breaks podman outright, but the others
are equally stale and equally unowned; `pacman -Qo` identifies them the same way.

**Check the values before removing anything.** `pacman -Qo` cannot tell a stale
orphan from a file an administrator wrote on purpose — neither is owned by a
package, and the `grep` above only shows that the keys are set, not what they
are set to. The content is what distinguishes them: the stale template pins
podman's *own built-in rootful defaults*, so removing it changes nothing, while
a hand-written file usually points somewhere else and removing it would pull a
custom driver or storage location out from under existing rootful containers —
which then appear to have vanished.

Safe to remove only if all three values match these exactly, i.e. the file is
redundant with podman's defaults:

```text
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
```

Any other `graphroot` or `runroot` means someone chose it deliberately. Leave
that file alone and use the per-user override below, which fixes rootless
podman without touching `/etc` at all.

**Fix — move the orphan aside.** Prefer `mv` over `rm`, so the change is
reversible if something on the machine did depend on it after all:

```bash
sudo mv /etc/containers/storage.conf /etc/containers/storage.conf.orphan-bak
podman info --format '{{.Store.GraphRoot}} {{.Store.RunRoot}}'
# /var/home/<user>/.local/share/containers/storage /run/user/<uid>/containers
```

If you would rather not touch `/etc` — or the file turned out to be
intentional — a per-user override fixes rootless podman without removing
anything:

```bash
mkdir -p ~/.config/containers
cat > ~/.config/containers/storage.conf <<EOF
[storage]
driver = "overlay"
runroot = "/run/user/$(id -u)/containers"
graphroot = "$HOME/.local/share/containers/storage"
EOF
```

The heredoc delimiter is deliberately unquoted so `$(id -u)` and `$HOME` expand
as you run it. Do not hardcode `1000`: on an account with any other UID that
path is another user's runtime directory, which is inaccessible and reproduces
the same permission-denied failure this section is about.

Either way, verify with a real container rather than `podman info` alone:

```bash
podman run --rm docker.io/library/alpine true && echo OK
```

Note that `/etc` file timestamps are not evidence of age here: the merge on
upgrade refreshes them, so a years-old orphan can look like it was written on
the day of your last update.

## Comparing packages between deployments

After an update, run `ostree-pkg-diff` to see which packages were added,
removed, or version-changed between the running deployment and the previous
deployment. The command self-elevates with `sudo` when needed.

```bash
ostree-pkg-diff
```

The tool is read-only: it mounts both deployments read-only and never
modifies anything on disk.
