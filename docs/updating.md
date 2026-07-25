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

## Comparing packages between deployments

After an update, run `ostree-pkg-diff` to see which packages were added,
removed, or version-changed between the running deployment and the previous
deployment. The command self-elevates with `sudo` when needed.

```bash
ostree-pkg-diff
```

The tool is read-only: it mounts both deployments read-only and never
modifies anything on disk.
