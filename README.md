# Arch Linux Bootc

Reference [Arch Linux](https://archlinux.org/) container image preconfigured for [bootc](https://github.com/bootc-dev/bootc) usage.

<img width="2335" height="1296" alt="image" src="https://github.com/user-attachments/assets/0a19ad09-fdb6-4b7f-96f0-28ae9df12889" />

<img width="2305" height="846" alt="image" src="https://github.com/user-attachments/assets/f496a2f4-0782-408c-b207-c7acdde2e5ac" />

## Goal

Use this repo as your own bootc image source, build locally, boot it in a VM, create your own user, and later update installed systems with `bootc switch`.

## Current Customizations In This Repo

This repo already includes the following opinionated changes:

- KDE Plasma desktop + SDDM enabled (graphical login by default)
- Temporary root dev login (`root` / `changeme`)
- `NetworkManager` installed and enabled for first-boot DHCP
- `sudo` installed (`visudo` included)
- `vim` installed
- `nano` removed from the image
- Local `just build-containerfile` uses `--security-opt label=disable` for more reliable rebuilds

## Prerequisites

- Linux host with `podman`, `qemu-img`, `virt-install`, `virsh`, `git`, `just`, `gh`
- A running libvirt setup (`qemu:///session` or `qemu:///system`)
- Optional for image signing: `cosign`

## Fork Or Template

### Option A: Fork (recommended for tracking upstream)

```bash
gh repo fork Danathar/arch-bootc --clone=false
```

### Option B: Template (clean starting history)

```bash
gh repo create <your-user>/arch-bootc --public --template Danathar/arch-bootc --clone=false
```

## Clone Your Repo

```bash
git clone https://github.com/<your-user>/arch-bootc.git
cd arch-bootc
git remote add upstream https://github.com/Danathar/arch-bootc.git
```

## Enable GitHub Actions + Cosign Secret

If your repo is a fork, enable Actions in GitHub first.

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

## Build Locally

```bash
just build-containerfile
```

If you want log files you can tail:

```bash
just build-containerfile 2>&1 | tee build.log
tail -f build.log
```

## Create A 100G Sparse Disk + QCOW2

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

## Create VM (User Session Track)

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

Notes:

- `secure-boot=off` avoids UEFI boot issues with unsigned custom images.
- For system libvirt (`qemu:///system`), use `--network network=default,model=virtio` instead.

## Recreate VM (Delete + Recreate)

```bash
virsh -c qemu:///session destroy arch-bootc-local || true
virsh -c qemu:///session undefine arch-bootc-local --nvram || true
```

Then run the `virt-install` command again.

## First Boot Login

Default dev root account in this image:

- user: `root`
- password: `changeme`

## Create Your Own Admin User

Replace `<username>` and `<password>`:

```bash
useradd -m -G wheel -s /bin/bash <username>
echo '<username>:<password>' | chpasswd
mkdir -p /etc/sudoers.d
printf '%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
```

Optional hardening:

```bash
passwd -l root
```

## Updating Installed Systems From Your Repo

Once installed, switch to your GHCR image and reboot:

```bash
bootc switch ghcr.io/<your-user>/arch-bootc:latest
reboot
```

Your local users and host state persist across image updates (`/etc`, `/var/home`).
