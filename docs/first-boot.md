# First Boot

> **Important:** Root's default password (`changeme`) only works from a
> **physical console** (local display, serial, KVM/IPMI) — SSH and both
> display managers refuse root regardless of password. It is also expired, so
> logging in forces an immediate password change before anything else works.
> For VMs, the [QEMU guest agent](vm-workflow.md#running-commands-in-the-vm-from-the-host-qemu-guest-agent)
> gets you in as root without a console at all; for bare metal with no
> console access, [seed a cloud-init config](#bootstrapping-the-first-admin-user-without-a-hypervisor-bare-metal)
> instead.

The image ships `/etc/sudoers.d/10-wheel`, so any user in the `wheel` group
gets password-prompted `sudo` — this is opt-in per user (only whoever you add
to `wheel` gains anything), not a blanket grant.

Once you're in as `root` — via the console, or the guest agent's
`guest-exec` — create your own admin account and switch to it. Replace
`<username>` and `<password>`:

```bash
# Ensure the user has UID 1000 to use the pre-configured Homebrew
useradd -m -u 1000 -G wheel -s /bin/bash <username>
echo '<username>:<password>' | chpasswd
```

Log in as `<username>` from here on — `sudo` already works via `wheel`.

## Bootstrapping the first admin user without a hypervisor (bare metal)

There's no QEMU guest agent on physical hardware — that channel only exists
between a QEMU/KVM host and its guest. If you have a console (physical,
serial, or KVM/IPMI), just log in as `root` / `changeme` as described above
and create your user directly — that's the simplest path and needs nothing
below.

If you have **no console access at all**, seed a cloud-init config instead so
the user is created automatically during boot:

### The easy way: seed a cloud-init config

The image ships `cloud-init` pinned to the NoCloud datasource specifically for
this. `/var` is a normal writable directory on the disk (not part of the
immutable image), so seeding it is a plain file write — no chroot, no
composefs tooling:

1. Boot the target machine from a live USB/ISO, then identify and mount its
   installed root partition (the third partition from the
   [bare-metal install steps](installation.md#5-install-on-bare-metal-clean-reimage);
   adjust the device/partition names for your disk), and locate the
   (single, since it's a fresh install) deployment:
```bash
sudo mkdir -p /mnt/target
sudo mount /dev/nvme0n1p3 /mnt/target
DEPLOY=$(sudo find /mnt/target/state/deploy -mindepth 1 -maxdepth 1 -type d)
```

2. Write the seed files. Replace `<username>` and the password hash (generate
   one with `openssl passwd -6`):
```bash
sudo mkdir -p "$DEPLOY/var/lib/cloud/seed/nocloud"
sudo tee "$DEPLOY/var/lib/cloud/seed/nocloud/meta-data" > /dev/null <<'EOF'
instance-id: iid-local01
EOF
sudo tee "$DEPLOY/var/lib/cloud/seed/nocloud/user-data" > /dev/null <<'EOF'
#cloud-config
users:
  - name: <username>
    uid: 1000
    groups: [wheel]
    shell: /bin/bash
    lock_passwd: false
    passwd: '<hashed-password>'
EOF
```

3. Unmount and reboot:
```bash
sudo umount /mnt/target
sudo reboot
```

`cloud-init` creates the user automatically during first boot. Log in as
`<username>` at the graphical login — `sudo` already works via `wheel`.
Verified end-to-end, including that the created user logs into a fully
working KDE Plasma session.

### Manual fallback: editing the offline disk directly

If you'd rather not use `cloud-init` (or need to troubleshoot it), create the
user directly against the installed (but not booted) disk instead, using the
image itself as the recovery toolkit (it already has `mount.composefs`,
`useradd`, and `chpasswd` built in — the live environment just needs
`podman`). Mount the disk as in step 1 above, then:

```bash
sudo podman run --rm --privileged --pid=host \
  -v /mnt/target:/target \
  ghcr.io/danathar/arch-bootc-kde:latest \
  sh -c '
    set -eu
    deploy=$(find /target/state/deploy -mindepth 1 -maxdepth 1 -type d)
    hash=$(basename "$deploy")
    mkdir -p /usr-image
    mount.composefs -o basedir=/target/composefs/objects,ro \
      "/target/composefs/images/$hash" /usr-image
    mount --bind "$deploy/etc" /usr-image/etc
    mount --bind "$deploy/var" /usr-image/var
    chroot /usr-image useradd -m -u 1000 -G wheel -s /bin/bash <username>
    echo "<username>:<password>" | chroot /usr-image chpasswd
    umount /usr-image/etc /usr-image/var
    umount /usr-image
  '
```

Unmount and reboot as in the cloud-init flow above. Log in as `<username>` at
the graphical login — `sudo` already works via `wheel`. Verified end-to-end: a
user created this way logs into a fully working KDE Plasma session.

## Homebrew

Homebrew is extracted by `brew-setup.service` on first boot to:

```bash
/var/home/linuxbrew/.linuxbrew
```

The image installs system-wide shell integration so future users and new
terminal sessions automatically get `brew` on `PATH`:

- `/etc/profile.d/homebrew.sh` for POSIX shells and Bash
- `/etc/fish/conf.d/homebrew.fish` for Fish
- Zsh login shells are covered automatically: `/etc/zsh/zprofile` sources
  `/etc/profile`, which runs `/etc/profile.d/homebrew.sh`

If you need to use Homebrew in an already-open shell before logging out/in or
opening a new terminal, run:

```bash
eval "$(/var/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

If `brew` is still unavailable after opening a new shell, check the first-boot
setup service:

```bash
sudo systemctl status brew-setup.service
sudo journalctl -u brew-setup.service -b --no-pager
```
