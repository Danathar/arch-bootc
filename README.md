# This repository is deprecated!

Moved to <https://github.com/bootcrew/mono>

# Arch Linux Bootc

[![build](https://github.com/Danathar/arch-bootc/actions/workflows/build.yaml/badge.svg)](https://github.com/Danathar/arch-bootc/actions/workflows/build.yaml)

> **Note:** This repo was created primarily using directed AI, though its contents have been manually tested and inspected. I believe it's important for anyone using open-source tools on GitHub to have this context before relying on them. Special thanks to the upstream repository [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc) for the foundational bootstrapping work.

Reference [Arch Linux](https://archlinux.org/) container image preconfigured for [bootc](https://github.com/bootc-dev/bootc) usage.

<img width="2335" height="1296" alt="image" src="https://github.com/user-attachments/assets/0a19ad09-fdb6-4b7f-96f0-28ae9df12889" />

<img width="2305" height="846" alt="image" src="https://github.com/user-attachments/assets/f496a2f4-0782-408c-b207-c7acdde2e5ac" />

## Goal

Use this repo as your own bootc image source, build locally, boot it in a VM, create your own user, and later update installed systems with `bootc switch`.

*Unlike a traditional Linux distribution where you install packages on a live system, you manage this system by editing the `Containerfile`, building a new container image, and instructing your host to boot from that image.*

## Current Customizations In This Repo

This repo already includes the following opinionated changes:

- KDE Plasma desktop + Plasma Login Manager enabled (graphical login by default)
- Full KDE applications suite via `kde-applications-meta`
- CPU microcode (`intel-ucode`, `amd-ucode`)
- Vulkan and Mesa drivers (`vulkan-radeon`, `vulkan-intel`, `vulkan-mesa-layers`, `libva-intel-driver`, `libva-mesa-driver`)
- Essential fonts (`noto-fonts`, `noto-fonts-emoji`, `noto-fonts-cjk`)
- GStreamer media codecs (`gst-plugins-*`, `gst-libav`)
- Bluetooth support installed and enabled (`bluez`, `bluez-utils`)
- Archiving tools (`unzip`, `unrar`, `p7zip`)
- Hardware utilities (`fwupd` for firmware, `smartmontools` for drive health)
- Network discovery / mDNS configured and enabled (`avahi`, `nss-mdns`)
- Printing stack installed and enabled (`cups`, `cups-pdf`)
- CLI utilities (`wget`, `curl`, `rsync`, `xdg-user-dirs`, `openssh`)
- Expanded filesystem support (`ntfs-3g`)
- Flathub remote pre-configured system-wide
- Hardcoded root password is locked for security (configure via cloud-init or SSH keys)
- `NetworkManager` installed and enabled for first-boot DHCP
- `firewalld` installed and enabled (for NetworkManager zone integration)
- `power-profiles-daemon` installed and enabled (for KDE power management)
- `sudo` installed (`visudo` included)
- `vim` installed
- `distrobox`, `flatpak`, `konsole`, and `firefox` installed
- Homebrew integration via `ublue-os/brew` (pre-configured to extract on first boot for UID 1000)
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
  ghcr.io/Danathar/arch-bootc:latest
```
*(Note: Replace `Danathar/arch-bootc` with `<your-user>/arch-bootc` if you are using your own fork's image).*

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
Use this flow when you want to install directly to physical hardware from a Linux live environment.

1. Build the container image and generate a bootable raw disk image (`ext4`):
```bash
just build-containerfile
truncate -s 100G bootable.img
just generate-bootable-image
```

2. Identify the target disk (example target: `/dev/nvme0n1`):
```bash
sudo lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
```

3. Write the image to disk:
```bash
sudo dd if=bootable.img of=/dev/nvme0n1 bs=16M status=progress oflag=direct conv=fsync
sync
```
*(Notes: `dd` erases the target disk completely. Double-check `of=` before running. Keep Secure Boot disabled unless you manage your own signed boot chain.)*

4. Reboot and boot from that disk.
   - **Note:** On the first boot after installation, the system will prompt you to select your timezone before proceeding to the graphical login.
   - Because it boots directly into the graphical login screen, you will need to switch to a virtual console (usually `Ctrl`+`Alt`+`F3`) and log in as `root`.
   - Add your user using the commands detailed in the "Post-Installation / First Boot" section below.
   - Reboot the system for good measure.

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

Optional hardening:
```bash
passwd -l root
```

---

## Updating Installed Systems From Your Repo

Once installed, switch to your GHCR image and reboot:

```bash
bootc switch ghcr.io/<your-user>/arch-bootc:latest
reboot
```

Your local users and host state persist across image updates (`/etc`, `/var/home`).

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
