# Customizations & Upstream Compatibility

## Current Customizations In This Repo

This repo already includes the following opinionated changes. Two full
desktop flavors are built — `kde` (KDE Plasma) and `xfce` (Xfce) — sharing
everything below except where a flavor is called out.

**Desktop & graphics**
- Graphical login by default: Plasma Login Manager (`kde`) or LightDM (`xfce`)
- Full desktop application suite: `kde-applications-meta`/`plasma-meta`
  (`kde`), or the `xfce4`/`xfce4-goodies` groups plus the GTK companions a
  full desktop needs — NetworkManager applet, Blueman, a PolicyKit agent, and
  a PipeWire/PulseAudio panel plugin (`xfce`)
- Vulkan and Mesa drivers (`vulkan-radeon`, `vulkan-intel`, `vulkan-mesa-layers`, `libva-intel-driver`, `libva-mesa-driver`)
- Essential fonts (`noto-fonts`, `noto-fonts-emoji`, `noto-fonts-cjk`)
- `gvfs`, `gvfs-mtp`, and `udisks2` for Thunar automount/trash/phone support, plus `system-config-printer` (`xfce`)
- KDE PIM/Akonadi dependencies included (`mariadb`, `packagekit-qt6`) (`kde`)
- `xdg-desktop-portal-gtk` installed as the portal backend (`xfce`); KDE already gets both `xdg-desktop-portal-kde` and `-gtk` via `plasma-meta`
- `systemd-networkd-wait-online.service` disabled to avoid startup delays (both flavors use NetworkManager)

**Media & applications**
- GStreamer media codecs (`gst-plugins-*`, `gst-libav`)
- `distrobox`, `flatpak`, and `firefox` installed; `konsole` (`kde`) or `xfce4-terminal` (`xfce`) as the terminal
- Flathub remote pre-configured system-wide (vendored into the image at build time, not fetched over the network during the build)
- Homebrew integration via `ublue-os/brew` (pre-configured to extract on first boot for UID 1000)

**Hardware & power**
- CPU microcode (`intel-ucode`, `amd-ucode`)
- Bluetooth support installed and enabled (`bluez`, `bluez-utils`)
- Hardware utilities (`fwupd` for firmware, `smartmontools` for drive health)
- Printing stack installed and enabled, socket-activated via `cups.socket` (`cups`, `cups-pdf`)
- `power-profiles-daemon` installed and enabled
- Expanded filesystem support (`ntfs-3g`)
- zram swap enabled by default (zstd-compressed, sized `min(RAM/2, 4GiB)`), and `systemd-oomd` tuned with drop-ins (`-.slice`, `user@.service`) so it actually responds to memory pressure instead of the package's own no-op defaults

**Networking**
- `NetworkManager` installed and enabled for first-boot DHCP
- Network discovery / mDNS configured and enabled (`avahi`, `nss-mdns`)
- `firewalld` installed and enabled (for NetworkManager zone integration)

**System, security & CLI**
- Root has a default password (`changeme`), expired so it must be changed on
  first use, and reachable **only from a physical console** — SSH
  (`PermitRootLogin prohibit-password`) and both display managers refuse it.
  See [First Boot](first-boot.md).
- `sudo` installed, with `wheel` group members granted password-prompted sudo via `/etc/sudoers.d/10-wheel`
- `cloud-init` installed and enabled, pinned to the NoCloud datasource, for seeding an admin user automatically on bare-metal installs without console access
- CLI utilities (`wget`, `curl`, `rsync`, `xdg-user-dirs`, `openssh`)
- Archiving tools (`unzip`, `unrar`, `p7zip`)
- `vim` installed
- `man-db` and `man-pages` installed (not shipped by `base`/`base-devel` upstream)
- `qemu-guest-agent` installed for host-driven VM access (udev-activated only when run under QEMU/libvirt)
- `nano` removed from the image
- `base-devel` is **not** shipped in the final image. `bootc` is compiled from source during the build (see below), but only `rust make go-md2man elfutils` are installed for that and removed again by name in the same layer — see [installation.md](installation.md#customizing-the-build-aur-packages) if you need a compiler toolchain for a local package build
- Container images pulled from `ghcr.io/danathar` (this repo's own published images) require a valid cosign signature; every other registry/namespace is unrestricted. See [ci-cd.md](ci-cd.md) if you fork this repo.
- Local `just build-containerfile` / `build-base` / `build-xfce` (aliases for `just build-flavor kde/base/xfce`) use `--security-opt label=disable` for more reliable rebuilds

## Upstream Bootcrew Compatibility Work (Why This Image Works)

This project inherits key bootstrapping work from the upstream `bootcrew/arch-bootc` approach:

- `bootc` is built from upstream source (`https://github.com/bootc-dev/bootc.git`) during image build because Arch official repos do not currently ship `bootc`.
- Arch container base fixes are applied:
  - pacman `/var` paths are relocated into `/usr/lib/sysimage` for bootc-style immutable layout behavior
  - `NoExtract` rules are disabled so language/help content can be installed normally
  - `glibc` is explicitly named alongside the other base packages in the main install step to restore missing locale files from the base container (pacman always reinstalls an explicitly-named target, even one that's already current)
- Initramfs and boot integration are prepared with `dracut` config for `ostree` + `bootc` modules.
- Bootc/ostree filesystem layout and symlink structure is enforced (`/sysroot`, `/ostree`, `/var/home`, etc.) with composefs enabled.
- Required metadata label is set for bootc-compatible images: `containers.bootc=1`.

If you remove or change these compatibility steps, `bootc install/switch` behavior may break or become inconsistent.
