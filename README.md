# Arch Linux Bootc

[![build](https://github.com/Danathar/arch-bootc/actions/workflows/build.yaml/badge.svg)](https://github.com/Danathar/arch-bootc/actions/workflows/build.yaml)

> **Note:** This repo was created primarily using directed AI, though its contents have been manually tested and inspected. I believe it's important for anyone using open-source tools on GitHub to have this context before relying on them. Special thanks to the upstream repository [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc) for the foundational bootstrapping work.

Reference [Arch Linux](https://archlinux.org/) container image preconfigured for [bootc](https://github.com/bootc-dev/bootc) usage.

<img width="2335" height="1296" alt="image" src="https://github.com/user-attachments/assets/0a19ad09-fdb6-4b7f-96f0-28ae9df12889" />

<img width="2305" height="846" alt="image" src="https://github.com/user-attachments/assets/f496a2f4-0782-408c-b207-c7acdde2e5ac" />

## Goal

Use this repo as your own bootc image source, build locally, boot it in a VM, create your own user, and later update installed systems with `bootc switch`.

*Unlike a traditional Linux distribution where you install packages on a live system, you manage this system by editing the `Containerfile`, building a new container image, and instructing your host to boot from that image.*

> ⚠️ **First boot:** The root account is locked by default. Whichever path you take, inject a user **before** install (via `config.toml` in Path A, or your builder) — otherwise you'll boot to a graphical login you can't sign into. On a bare-metal first boot the system also prompts for timezone, then drops to graphical login; switch to a virtual console (`Ctrl`+`Alt`+`F3`) to finish setup. See [Post-Installation / First Boot](#post-installation--first-boot).

## Current Customizations In This Repo

This repo already includes the following opinionated changes:

**Desktop & graphics**
- KDE Plasma desktop + Plasma Login Manager enabled (graphical login by default)
- Full KDE applications suite via `kde-applications-meta`
- Vulkan and Mesa drivers (`vulkan-radeon`, `vulkan-intel`, `vulkan-mesa-layers`, `libva-intel-driver`, `libva-mesa-driver`)
- Essential fonts (`noto-fonts`, `noto-fonts-emoji`, `noto-fonts-cjk`)
- KDE PIM/Akonadi dependencies included (`mariadb`, `packagekit-qt6`) and `systemd-networkd-wait-online.service` disabled to avoid Plasma startup delays

**Media & applications**
- GStreamer media codecs (`gst-plugins-*`, `gst-libav`)
- `distrobox`, `flatpak`, `konsole`, and `firefox` installed
- Flathub remote pre-configured system-wide
- Homebrew integration via `ublue-os/brew` (pre-configured to extract on first boot for UID 1000)

**Hardware & power**
- CPU microcode (`intel-ucode`, `amd-ucode`)
- Bluetooth support installed and enabled (`bluez`, `bluez-utils`)
- Hardware utilities (`fwupd` for firmware, `smartmontools` for drive health)
- Printing stack installed and enabled (`cups`, `cups-pdf`)
- `power-profiles-daemon` installed and enabled (for KDE power management)
- Expanded filesystem support (`ntfs-3g`)

**Networking**
- `NetworkManager` installed and enabled for first-boot DHCP
- Network discovery / mDNS configured and enabled (`avahi`, `nss-mdns`)
- `firewalld` installed and enabled (for NetworkManager zone integration)

**System, security & CLI**
- Hardcoded root password is locked for security (configure via cloud-init or SSH keys)
- `sudo` installed (`visudo` included)
- CLI utilities (`wget`, `curl`, `rsync`, `xdg-user-dirs`, `openssh`)
- Archiving tools (`unzip`, `unrar`, `p7zip`)
- `vim` installed
- `qemu-guest-agent` installed for host-driven VM access (udev-activated only when run under QEMU/libvirt)
- `nano` removed from the image
- Local `just build-containerfile` uses `--security-opt label=disable` for more reliable rebuilds

## Prerequisites

- Linux host with `podman`, `qemu-img`, `virt-install`, `virsh`, `git`, `just`, `gh`
- A running libvirt setup (`qemu:///session` or `qemu:///system`)
- Optional for image signing: `cosign`

> **Note:** This project uses `just` as a command runner. You can inspect the `Justfile` to see the underlying `podman` and `qemu` commands being executed.

---

## Path A: Quick Start (Pre-built Image)

Use this path if you want to create a VM disk image from the already-published GHCR image and skip local `Containerfile` builds.

If the GHCR package is private, authenticate first:

```bash
sudo podman login ghcr.io
```

### 1. Create a user config
Because the root account is locked by default, you must inject a user during the image generation process. Create a `config.toml` file:

```toml
# config.toml
[[customizations.user]]
name = "myuser"
password = "hashed_password_here"
groups = ["wheel"]
key = "ssh-rsa AAAAB3Nza..." # Optional: add your SSH public key
```
*(Note: To generate a hashed password, you can run `openssl passwd -6`)*

### 2. Build the disk image
Build a `qcow2` image directly from GHCR, passing your configuration:

```bash
mkdir -p output
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v "$(pwd)/output:/output" \
  -v "$(pwd)/config.toml:/config.toml:ro" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --rootfs ext4 \
  --chown "$(id -u):$(id -g)" \
  --config /config.toml \
  ghcr.io/danathar/arch-bootc-kde:latest
```
*(Note: Replace `Danathar/arch-bootc-kde` with `<your-user>/arch-bootc-kde` if you are using your own fork's image).*

- Output is written under `output/qcow2/` (usually `output/qcow2/disk.qcow2`).
- Optional: enlarge the virtual disk size before creating the VM:

```bash
qemu-img resize output/qcow2/disk.qcow2 100G
```

---

## Path B: Customizing & Building Locally

### 1. Fork Or Template

**Option A: Fork (recommended for tracking upstream)**
```bash
gh repo fork Danathar/arch-bootc --clone=false
```

**Option B: Template (clean starting history)**
```bash
gh repo create <your-user>/arch-bootc --public --template Danathar/arch-bootc --clone=false
```

### 2. Clone Your Repo
```bash
git clone https://github.com/<your-user>/arch-bootc.git
cd arch-bootc
git remote add upstream https://github.com/Danathar/arch-bootc.git
```

### 3. Build Locally
By default, this repository builds two images: a `base` image (CLI only) and a `kde` image (Desktop).
The published GHCR images follow the same naming: `arch-bootc-base` and `arch-bootc-kde`.

**Build Desktop Image (Default):**
```bash
just build-containerfile
```

**Build Base Image (CLI only):**
```bash
just build-base
```

If you want log files you can tail:
```bash
just build-containerfile 2>&1 | tee build.log
tail -f build.log
```

### 4. Create A 100G Sparse Disk + QCOW2
Create sparse raw file, install image into it, then convert to sparse qcow2:

```bash
truncate -s 100G bootable.img
just generate-bootable-image
mkdir -p output
qemu-img convert -f raw -O qcow2 -S 4k bootable.img output/arch-bootc-100g.qcow2
```

Verify:
```bash
qemu-img info output/arch-bootc-100g.qcow2
```

### 5. Install On Bare Metal (Clean Reimage)
Install directly to physical hardware from any Linux live environment. This reuses
the same `bootc-image-builder` + `config.toml` flow as Path A — just emitting a
**raw** disk image instead of `qcow2`. That `config.toml` is what injects your
user account; because the root account is locked, installing *without* it leaves
you at a graphical login you cannot sign into.

1. Create your `config.toml` (user, hashed password, optional SSH key) exactly as
   in [Path A step 1](#1-create-a-user-config).

2. Build a **raw** disk image. Point the builder at the published GHCR image (or
   at a local `localhost/arch-bootc:latest` after `just build-containerfile`):
```bash
mkdir -p output
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v "$(pwd)/output:/output" \
  -v "$(pwd)/config.toml:/config.toml:ro" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type raw \
  --rootfs ext4 \
  --chown "$(id -u):$(id -g)" \
  --config /config.toml \
  ghcr.io/danathar/arch-bootc-kde:latest
```
   The image is written to `output/image/disk.raw`.

3. Identify the target disk:
```bash
sudo lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
```
   > ⚠️ **`dd` to the wrong device irreversibly destroys it.** Confirm the target
   > is your intended install disk and is **not mounted** before continuing.

4. Write the image to disk (example target `/dev/nvme0n1`):
```bash
sudo dd if=output/image/disk.raw of=/dev/nvme0n1 bs=16M status=progress oflag=direct conv=fsync
sync
```
   *(Keep Secure Boot disabled unless you manage your own signed boot chain. The
   raw image is the builder's default size; grow the root filesystem afterward if
   your disk is larger.)*

5. Reboot and boot from that disk.
   - On first boot the system prompts for timezone, then reaches the graphical login.
   - Log in as the user you defined in `config.toml` — no locked-root or
     virtual-console bootstrapping needed.

### 6. Create VM (User Session Track)
This is the track used here: `qemu:///session`, 8GB RAM, 10 vCPU, UEFI, Secure Boot disabled.

```bash
virt-install \
  --connect qemu:///session \
  --name arch-bootc-local \
  --memory 8192 \
  --vcpus 10 \
  --cpu host-passthrough \
  --import \
  --disk path=/absolute/path/to/arch-bootc/output/arch-bootc-100g.qcow2,format=qcow2,bus=virtio \
  --network user,model=virtio \
  --graphics spice \
  --video virtio \
  --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no \
  --osinfo linux2024 \
  --noautoconsole
```
*(Notes: `secure-boot=off` avoids UEFI boot issues with unsigned custom images. For system libvirt (`qemu:///system`), use `--network network=default,model=virtio` instead.)*

To recreate VM (Delete + Recreate):
```bash
virsh -c qemu:///session destroy arch-bootc-local || true
virsh -c qemu:///session undefine arch-bootc-local --nvram || true
```
Then run the `virt-install` command again.

### Running commands in the VM from the host (QEMU guest agent)

The image installs `qemu-guest-agent`, and `virt-install` attaches the
`org.qemu.guest_agent.0` channel by default for Linux guests. The agent is
started automatically by its udev rule once the VM boots, so you can run
commands inside the VM from the host without SSH or a console login:

```bash
# Verify the agent is connected
virsh -c qemu:///session qemu-agent-command arch-bootc-local '{"execute":"guest-ping"}'

# Run a command in the guest (returns a PID), then read its output
virsh -c qemu:///session qemu-agent-command arch-bootc-local \
  '{"execute":"guest-exec","arguments":{"path":"/usr/bin/bootc","arg":["status"],"capture-output":true}}'
virsh -c qemu:///session qemu-agent-command arch-bootc-local \
  '{"execute":"guest-exec-status","arguments":{"pid":<PID>}}'
```

(`out-data` in the result is base64-encoded.) Usermode networking (`--network
user`) has no inbound route for SSH, so the guest agent is the simplest way to
drive the VM from the host.

---

## Path C: Setting up CI/CD & Automated Builds

If your repo is a fork, enable Actions in GitHub first.

### Enable GitHub Actions + Cosign Secret

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

---

## Post-Installation / First Boot

> **Important:** The root account is locked by default. You should configure user accounts via cloud-init, standard users in your builder tool, or inject an SSH key during image generation.

If you somehow gained root access (e.g. via virtual console or live media), create your own admin account. Replace `<username>` and `<password>`:

```bash
# Ensure the user has UID 1000 to use the pre-configured Homebrew
useradd -m -u 1000 -G wheel -s /bin/bash <username>
echo '<username>:<password>' | chpasswd
mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
```

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

Optional hardening:
```bash
passwd -l root
```

---

## Updating Installed Systems From Your Repo

Once installed, switch to your GHCR image and reboot:

```bash
bootc switch ghcr.io/<your-user>/arch-bootc-kde:latest
reboot
```

Your local users and host state persist across image updates (`/etc`, `/var/home`).

### Troubleshooting: composefs garbage collection error ("Invalid splitstream header magic value")

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
and the skew is gone. This image now builds v1.16.0 (see `BOOTC_VERSION` in the
Containerfile).

**Recovering an affected machine:**

1. The upgrade content usually applied even though GC errored — the new
   deployment is staged. Confirm and reboot to activate it:
   ```bash
   sudo bootc status   # look for a staged deployment
   sudo reboot
   ```
2. The upgrade that *installs* the v1.16.0 image still runs under the old bootc,
   so GC may throw the error one final time; reboot anyway. Every `bootc
   upgrade` after you are running v1.16.0 is clean.
3. If a leftover image ref keeps tripping GC on an old (offset-0) stream, list
   the refs and remove only ones **not** tied to your booted/rollback
   deployments (these are tracked via boot entries, not `streams/refs`):
   ```bash
   sudo find /sysroot/composefs/streams/refs -type l -printf '%p -> %l\n'
   # /sysroot is mounted read-only; bootc remounts it rw during its own
   # operations. Hand-editing the composefs repo is unsupported — prefer the
   # v1.16.0 upgrade, which resolves this without manual surgery.
   ```

---

## Comparing packages between deployments

After an update, run `ostree-pkg-diff` to see which packages were added,
removed, or version-changed between the running deployment and the previous
deployment. The command self-elevates with `sudo` when needed.

```bash
ostree-pkg-diff
```

The tool is read-only: it mounts both deployments read-only and never
modifies anything on disk.

---

## How to add your own packages (AUR)

> **Warning:** The AUR flow provided as a template has not been tested by the repository author yet. Use it at your own risk.

If you want to add packages from the Arch User Repository (AUR), check the commented-out section in the `Containerfile` under "Optional AUR package layering".

Because `bootc` is an immutable system, you must ensure that any AUR packages you install:
- Make no runtime writes to `/usr`
- Make no assumptions about classic mutable `/var` paths
- Have no interactive install or runtime requirements

The template provided in the `Containerfile` uses a temporary, unprivileged build user to safely compile and install AUR packages during the container build process.

---

## Upstream Bootcrew Compatibility Work (Why This Image Works)

This project inherits key bootstrapping work from the upstream `bootcrew/arch-bootc` approach:

- `bootc` is built from upstream source (`https://github.com/bootc-dev/bootc.git`) during image build because Arch official repos do not currently ship `bootc`.
- Arch container base fixes are applied:
  - pacman `/var` paths are relocated into `/usr/lib/sysimage` for bootc-style immutable layout behavior
  - `NoExtract` rules are disabled so language/help content can be installed normally
  - `glibc` is reinstalled to restore missing locale files from the base container
- Initramfs and boot integration are prepared with `dracut` config for `ostree` + `bootc` modules.
- Bootc/ostree filesystem layout and symlink structure is enforced (`/sysroot`, `/ostree`, `/var/home`, etc.) with composefs enabled.
- Required metadata label is set for bootc-compatible images: `containers.bootc=1`.

If you remove or change these compatibility steps, `bootc install/switch` behavior may break or become inconsistent.
