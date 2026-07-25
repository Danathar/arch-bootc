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
- `systemd-networkd-wait-online.service` disabled to avoid startup delays (both flavors use NetworkManager)

**Media & applications**
- GStreamer media codecs (`gst-plugins-*`, `gst-libav`)
- `distrobox`, `flatpak`, and `firefox` installed; `konsole` (`kde`) or `xfce4-terminal` (`xfce`) as the terminal
- Flathub remote pre-configured system-wide
- Homebrew integration via `ublue-os/brew` (pre-configured to extract on first boot for UID 1000)

**Hardware & power**
- CPU microcode (`intel-ucode`, `amd-ucode`)
- Bluetooth support installed and enabled (`bluez`, `bluez-utils`)
- Hardware utilities (`fwupd` for firmware, `smartmontools` for drive health)
- Printing stack installed and enabled (`cups`, `cups-pdf`)
- `power-profiles-daemon` installed and enabled
- Expanded filesystem support (`ntfs-3g`)

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
- `qemu-guest-agent` installed for host-driven VM access (udev-activated only when run under QEMU/libvirt)
- `nano` removed from the image
- Local `just build-containerfile` uses `--security-opt label=disable` for more reliable rebuilds

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
