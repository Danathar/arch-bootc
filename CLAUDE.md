# Testing changes in a real VM

When a change needs to be verified by actually booting the built image (not just
`podman build` + static inspection), follow this procedure. It was developed verifying
the default-root-console-login change (2026-07-25) and caught a real test-script bug of
mine along the way — read the gotchas section, they're not hypothetical.

## Non-negotiable safety rules

- **`qemu:///session` only. Never `qemu:///system`.** The system connection is shared,
  host-wide, and typically has other VMs already running on it — touching it at all is
  out of scope unless explicitly asked.
- **Enumerate existing VMs and storage pools *before* creating anything**, and pick a
  name you've verified has zero collision against both connections:
  ```bash
  virsh -c qemu:///session list --all --name
  virsh -c qemu:///session pool-list --all --name
  ```
  The host this repo is developed on has pre-existing VMs and pools with names that
  look exactly like what a test might casually choose (e.g. matching this repo's own
  naming conventions, or generic "-verify"/"-test" suffixes) — these are real, from
  genuine prior work. Never touch them. Use an unmistakably-scoped name for your own VM
  (e.g. `claude-<purpose>-verify-<timestamp>`).

  **In particular, never touch `arch-bootc-local`.** That is the user's own VM, created
  by following [docs/vm-workflow.md](docs/vm-workflow.md) — it is this repo's documented
  manual-testing VM, not a leftover, and its name is the single most likely collision for
  a test working in this repository. Do not destroy, undefine, redefine, or reinstall it,
  and do not "recreate" it even though `docs/vm-workflow.md` contains a delete-and-recreate
  snippet: that snippet is an instruction to the user, not authorization for an agent.

  A snapshot taken 2026-08-08 illustrates how populated this host already is — session
  VMs `arch-bootc-local`, `cinnamon-ublue-test`, `dakota`, `debian-bootc-local`,
  `debian-zfs`, `fedora`, `mx-bootc-test`, `xfce-ublue-test`; session pools including
  `cloudinit-verify`, `offline-recovery-verify`, `wheel-verify-test`, `xfce-verify`,
  `just-disk`, `output`, `qcow2`, `tmp`, `Downloads`, `VMs`. Note that several of those
  pool names are directory names, i.e. exactly the auto-created pools described in the
  gotchas below — they are still the user's, and are still not yours to remove. This
  list is a dated illustration, **not** an authoritative allowlist and not a set of
  things safe to delete: it will drift, so the live enumeration above remains the check
  you actually run.
- **Never write VM disk images to the scratchpad directory.** It's tmpfs (check with
  `df -T`) — a multi-GB qcow2 there consumes real host RAM, which is exactly the kind
  of host impact to avoid. Use a real disk-backed directory instead, e.g.
  `/var/home/<user>/.claude-<purpose>-<timestamp>/` — confirm with
  `findmnt -T <dir>` that it's not tmpfs before writing anything sizeable.
- **Disk images only ever go through `--via-loopback`.** Never point
  `bootc install to-disk` at a real host block device.
- **Confirm you're testing the actual artifact**, not a stale cache: after pulling,
  check `org.opencontainers.image.revision` in the image labels against the commit SHA
  you expect.

## Procedure

1. Snapshot the baseline (VMs, pools) as above.
2. Create the disk-backed work directory.
3. Pull the published image; install to a loopback-backed raw file inside that
   directory (`bootc install to-disk --composefs-backend --via-loopback ... --wipe`).
   Confirm `losetup -a` is empty again afterward — the loop device should be released
   automatically when the installer container exits.
4. `qemu-img convert` to qcow2, delete the raw file.
5. `virt-install --connect qemu:///session ... --disk path=<qcow2> --network user
   --graphics none --noautoconsole`. Re-verify the chosen name has zero collision
   immediately before this step, not just at the start.
6. Wait for the QEMU guest agent (`guest-ping`), then confirm it's a genuine fresh
   boot — not a stale/cached response — by running something like `uptime` and
   checking it reports "up 0 min".
7. Verify. See the gotchas below before trusting output.
8. Tear down and verify cleanup (see below). Do this even if a step failed midway —
   don't leave a half-finished VM/pool/directory behind.

## Gotchas learned the hard way

- **`virt-install --disk path=<absolute path>` can silently auto-create a libvirt
  storage pool** named after the parent directory, active and autostart=yes. It is
  *not* covered by deleting the VM or the underlying file. Check
  `virsh -c qemu:///session pool-list --all` after teardown, not just the VM list —
  finding an extra pool there means cleanup isn't done yet.
  `virsh -c qemu:///session pool-destroy <name> && pool-undefine <name>`.

- **qemu-guest-agent's `guest-file-write` truncates large payloads per call** (seen
  truncating at ~1516→800 bytes in one test). If you're pushing a test script into the
  guest via `guest-file-open`/`guest-file-write`/`guest-file-close`, chunk it
  (~800 bytes/call) and verify the final size in-guest with `wc -c` before executing —
  don't assume one write call landed the whole file.

- **`ssh ... < /dev/null` does not test password rejection** — it just proves the
  client never got to submit a password. To actually prove
  `PermitRootLogin prohibit-password` rejects even a *correct* password, you need a
  real pty submitting real credentials. `sshpass` may not be installed and pacman can
  hit lock contention pulling it — Python's stdlib `pty` module (`pty.openpty()` +
  `os.execvp`) works without installing anything and is more reliable:
  fork a child onto the pty, watch for `assword` in its output, write the password.

- **`su -c CMD -` (implicit target user, trailing bare dash) is not equivalent to
  `su root -c CMD` (explicit target)** — the implicit form gave a false "vulnerability
  found" result once (a non-wheel user appearing to reach root), which on investigation
  was a test-script bug, not a real security gap. **Always use an explicit target
  user** when scripting `su` for a security test, and get a wrong-password negative
  control alongside the correct-password test so you have something to compare against.

- **Before concluding a security control is broken, rule out your own test harness
  first.** In this case that meant checking real/effective/saved UID via
  `/proc/self/status` to rule out a `runuser`/`pam_rootok` privilege-leak theory, then
  reproducing with a minimally different, more explicit invocation. Only report a
  finding as confirmed once you've eliminated the test itself as the cause — and if you
  did get a false alarm, say so plainly rather than quietly fixing the script and only
  reporting the final clean result.

## Cleanup checklist

- `virsh -c qemu:///session destroy <name>` then `undefine <name> --nvram`
- `virsh -c qemu:///session pool-list --all` — destroy/undefine anything you didn't
  have at baseline (see the auto-pool gotcha above)
- `rm -rf` the disk-backed work directory
- `losetup -a` — should be empty
- Any `podman pull`/local build tags created for the test — remove them too, don't
  leave multi-GB images behind
- Diff the VM list and pool list against your baseline snapshot — they should match
  exactly, not just "look empty"
