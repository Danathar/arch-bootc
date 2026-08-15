# Installation

## Path Q: Quickstart (guided, recommended for a first run)

If you just want a working VM (or a bare-metal install) without reading three
documents, run:

```bash
just quickstart
```

It asks what you want — VM or bare metal, which flavor, published or locally
built image, disk size, and the admin username/password — then does the whole
sequence: creates the sparse disk, runs `bootc install to-disk`, converts to
qcow2, builds a cloud-init seed, and creates the VM.

**It seeds cloud-init, so your admin user exists at first boot.** No console
login as `root`/`changeme`, no QEMU guest-agent bootstrap, no base64 —
[First Boot](first-boot.md)'s manual dance is skipped entirely. If an SSH
public key is found in `~/.ssh`, it offers to install that too.

See exactly what it would run, without running any of it:

```bash
just quickstart --dry-run
```

`--dry-run` prompts as normal but executes nothing and writes nothing — useful
both for reviewing the commands and for learning what the manual paths below
actually do.

### What it refuses to do

The guardrails are enforced in code rather than left to you to remember:

- Uses `qemu:///session` only — the shared system connection is never touched.
- Refuses a VM name that already exists on **either** libvirt connection.
  It never destroys, undefines or "recreates" an existing VM.
- Refuses to put a multi-GB disk image on `tmpfs` (that would be host RAM).
- Installs image files only through `--via-loopback`, never at a raw device.
- For bare metal, refuses the target if it is **not a whole disk**, if it
  **backs the running system**, if anything on it is **mounted**, or if it
  carries **ZFS / LVM / RAID / LUKS signatures** — that last one matters
  because pool and array members are typically *not* mounted, so "nothing is
  mounted" alone would happily wipe a live ZFS pool. Beyond that it makes you
  retype the device path and then type `ERASE`.

The manual paths below still work and are still the reference for what is
actually happening — the quickstart just runs them for you.

---

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

### 1. Create the disk image
No `config.toml`, no external image builder needed — install the published
image directly to a raw disk file with `bootc install to-disk`. First boot
puts you at a graphical login; bootstrap your first admin user via the
console (`root` / `changeme`, see [First Boot](first-boot.md)) or the
[QEMU guest agent](vm-workflow.md#running-commands-in-the-vm-from-the-host-qemu-guest-agent):

```bash
mkdir -p output
truncate -s 100G output/bootable.img
sudo podman run --rm -it --privileged --pid=host --pull=newer \
  --security-opt label=type:unconfined_t \
  -v /dev:/dev \
  -v "$(pwd)/output:/data" \
  ghcr.io/danathar/arch-bootc-kde:latest \
  bootc install to-disk --composefs-backend --via-loopback /data/bootable.img \
    --filesystem ext4 --wipe --bootloader systemd
```
*(Note: Replace `danathar/arch-bootc-kde` with `<your-user>/arch-bootc-kde` if
you are using your own fork's image, or with `arch-bootc-xfce` for the Xfce
flavor).*

### 2. Convert to QCOW2
```bash
qemu-img convert -f raw -O qcow2 -S 4k output/bootable.img output/arch-bootc-100g.qcow2
rm output/bootable.img
```

<a id="why-raw-first"></a>
> **Why install to raw and convert, rather than creating a qcow2 directly?**
> `bootc install to-disk` writes to a *block device*, and `--via-loopback` gets
> one by running `losetup` over the file. The kernel's loop driver maps a
> file's bytes straight through as sectors — it does no format interpretation,
> so it only understands raw. qcow2 keeps its data behind cluster-mapping
> metadata that the loop driver can't read, so it can't be an install target.
> bootc has no qcow2 writer of its own either.
>
> This costs less than it looks: `truncate` makes a sparse file and
> `qemu-img convert -S 4k` writes a sparse qcow2, so peak host usage is about
> the installed size twice during the conversion, not 200G.

Continue at [Create VM](vm-workflow.md#create-vm-user-session-track) using
this qcow2, then [First Boot](first-boot.md) to bootstrap your admin user via
the guest agent.

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
By default, this repository builds three images: a `base` image (CLI only),
a `kde` image (KDE Plasma desktop), and an `xfce` image (Xfce desktop).
The published GHCR images follow the same naming: `arch-bootc-base`,
`arch-bootc-kde`, and `arch-bootc-xfce`.

**Build KDE Desktop Image (Default):**
```bash
just build-containerfile
```

**Build Xfce Desktop Image:**
```bash
just build-xfce
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

#### Customizing the build (AUR packages)

> **Warning:** The AUR flow provided as a template has not been tested by the repository author yet. Use it at your own risk.

If you want to add packages from the Arch User Repository (AUR), check the commented-out section in the `Containerfile` under "Optional AUR package layering".

Because `bootc` is an immutable system, you must ensure that any AUR packages you install:
- Make no runtime writes to `/usr`
- Make no assumptions about classic mutable `/var` paths
- Have no interactive install or runtime requirements

The template provided in the `Containerfile` uses a temporary, unprivileged build user to safely compile and install AUR packages during the container build process. `base-devel` is not part of the base image (see [customizations.md](customizations.md)), so the template installs it itself for the duration of the build and removes it again afterward — you don't need to add it to `packages-base.txt`.

### 4. Create A 100G Sparse Disk + QCOW2
`generate-bootable-image` creates the sparse raw file itself (100G by default)
and installs the image into it; then convert to sparse qcow2:

```bash
just generate-bootable-image
mkdir -p output
qemu-img convert -f raw -O qcow2 -S 4k bootable.img output/arch-bootc-100g.qcow2
```

Both files are sparse, so "100G" is only the size the disk *reports*; neither
consumes more host space than the install actually writes. Size it differently
with `BUILD_DISK_SIZE` (the root filesystem bootc creates fills the disk, so
this is what sets the guest's root size):

```bash
BUILD_DISK_SIZE=40G just generate-bootable-image
```

The recipe won't overwrite an existing `bootable.img` — remove it first if you
want to rebuild at a different size.

The raw-then-convert step is not avoidable — see
[why](#why-raw-first) under Path A.

`generate-bootable-image` targets the KDE image (`arch-bootc:latest`) by
default, matching `just build-containerfile`. If you built `base` or `xfce`
instead, say so with `BUILD_FLAVOR` (it's just their `-base`/`-xfce` tag
suffix — this is required, not optional, since otherwise it'll either fail
to find an image or silently install a stale one from a different flavor
you built earlier):

```bash
BUILD_FLAVOR=xfce just generate-bootable-image   # or BUILD_FLAVOR=base
```

Verify:
```bash
qemu-img info output/arch-bootc-100g.qcow2
```

### 5. Install On Bare Metal (Clean Reimage)
Install directly to physical hardware from any Linux live environment with
`podman` available. `bootc install to-disk` writes straight to the target
block device — no intermediate raw image file, no `dd`.

1. Identify the target disk:
```bash
sudo lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
```
   > ⚠️ **This wipes the target device.** Confirm it's your intended install
   > disk and is **not mounted** before continuing.

2. Install directly to the disk (example target `/dev/nvme0n1`; point at the
   published GHCR image — swap `-kde` for `-xfce` for the Xfce flavor — or a
   local `localhost/arch-bootc:latest` after `just build-containerfile`):
```bash
sudo podman run --rm -it --privileged --pid=host --pull=newer \
  --security-opt label=type:unconfined_t \
  -v /dev:/dev \
  ghcr.io/danathar/arch-bootc-kde:latest \
  bootc install to-disk --composefs-backend /dev/nvme0n1 \
    --filesystem ext4 --wipe --bootloader systemd
```
   *(Keep Secure Boot disabled unless you manage your own signed boot chain;
   grow the root filesystem afterward if your disk is larger than the
   install's default sizing.)*

3. Reboot and boot from that disk.
   - The image defaults to UTC, so first boot goes straight to the graphical
     login (change the timezone afterward with `timedatectl set-timezone`).
   - Root cannot use the graphical login, but a normal console login prompt
     (physical, remote KVM/IPMI, serial) works: log in as `root` / `changeme`,
     set a new password when prompted, then create your own admin user. See
     [First Boot](first-boot.md). If you'd rather have an admin user seeded
     automatically with no console step at all, see
     [Bootstrapping the first admin user without a hypervisor (bare metal)](first-boot.md#bootstrapping-the-first-admin-user-without-a-hypervisor-bare-metal).

Continue to [Create VM](vm-workflow.md) if you're building a local VM instead
of bare metal, or straight to [First Boot](first-boot.md) once your system is
up.
