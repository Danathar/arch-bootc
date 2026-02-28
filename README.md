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

- KDE Plasma desktop + SDDM enabled (graphical login by default)
- Full KDE applications suite via `kde-applications-meta`
- Essential fonts (`noto-fonts`, `noto-fonts-emoji`, `noto-fonts-cjk`)
- GStreamer media codecs (`gst-plugins-*`, `gst-libav`)
- Bluetooth support installed and enabled (`bluez`, `bluez-utils`)
- Archiving tools (`unzip`, `unrar`, `p7zip`)
- Flathub remote pre-configured system-wide
- Temporary root dev login (`root` / `changeme`)
- `NetworkManager` installed and enabled for first-boot DHCP
- `sudo` installed (`visudo` included)
- `vim` installed
- `distrobox`, `flatpak`, `konsole`, and `firefox` installed
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

Build a `qcow2` image directly from GHCR:

```bash
mkdir -p output
sudo podman run --rm -it --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v "$(pwd)/output:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --rootfs ext4 \
  --chown "$(id -u):$(id -g)" \
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
```bash
just build-containerfile
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
5. Proceed to the "Post-Installation / First Boot" section below.

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

Default dev root account in this image:
- user: `root`
- password: `changeme`

Once logged in, create your own admin account. Replace `<username>` and `<password>`:

```bash
useradd -m -G wheel -s /bin/bash <username>
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
