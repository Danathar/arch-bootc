FROM docker.io/archlinux/archlinux:latest@sha256:b40a74759ba638617cf7463fbd718d20d8ddcd7d22c7b79ed145241cbbb7a178 AS base-core

# Move everything from `/var` to `/usr/lib/sysimage` so behavior around pacman remains the same on `bootc usroverlay`'d systems
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

# Remove NoExtract rules, otherwise no additional languages and help pages can be installed
# See https://gitlab.archlinux.org/archlinux/archlinux-docker/-/blob/master/pacman-conf.d-noextract.conf?ref_type=heads
RUN sed -i 's/^[[:space:]]*NoExtract/#&/' /etc/pacman.conf

# Reinstall glibc to fix missing language files due to missing in the base image
RUN --mount=type=tmpfs,dst=/tmp --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman pacman -Syu glibc --noconfirm

# Install core base packages from external file
COPY packages-base.txt /tmp/packages-base.txt
RUN --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman \
    pacman -Syu --noconfirm $(cat /tmp/packages-base.txt) && \
    (pacman -Qq nano >/dev/null 2>&1 && pacman -Rns --noconfirm nano || true) && \
    pacman -S --clean --noconfirm && \
    rm /tmp/packages-base.txt

# https://github.com/bootc-dev/bootc/issues/1801
# renovate: datasource=github-releases depName=bootc-dev/bootc
ARG BOOTC_VERSION=v1.16.5
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    pacman -S --noconfirm rust go-md2man && \
    git clone --branch "${BOOTC_VERSION}" --depth 1 "https://github.com/bootc-dev/bootc.git" /tmp/bootc && \
    make -C /tmp/bootc bin install-all && \
    printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)/initramfs.img" && \
    pacman -Rns --noconfirm rust go-md2man && \
    pacman -S --clean --noconfirm

# Necessary for general behavior expected by image-based systems
RUN sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd" && \
    echo -e '\n# Source profile.d scripts for non-login shells\nfor script in /etc/profile.d/*.sh; do\n  [ -r "$script" ] && . "$script"\ndone\nunset script' >> /etc/bash.bashrc && \
    rm -rf /boot /home /root /usr/local /srv /opt /mnt /var /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -sT sysroot/ostree /ostree && ln -sT var/roothome /root && ln -sT var/srv /srv && ln -sT var/opt /opt && ln -sT var/mnt /mnt && ln -sT var/home /home && ln -sT ../var/usrlocal /usr/local && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"

# Pre-seed a default timezone so systemd-firstboot's interactive "Initial
# Setup" wizard (which prompts for timezone when /etc/localtime is unset)
# doesn't block first boot on systems with no console attached (e.g. VMs
# provisioned headlessly). Users can change it afterward with
# `timedatectl set-timezone`.
RUN ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# Keep small EFI System Partitions from filling with stale bootc kernel/initrd artifacts.
COPY system_files/ /

# Lock the root account
RUN passwd -l root

# Grant sudo to whoever config.toml (or the builder tool) places in the wheel
# group — this is opt-in per user, not a blanket grant, since only the user(s)
# explicitly added to wheel gain anything. Root is locked (see above), so this
# is the only path to admin privileges for a freshly provisioned system.
RUN mkdir -p /etc/sudoers.d && \
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel && \
    chmod 0440 /etc/sudoers.d/10-wheel && \
    visudo -cf /etc/sudoers.d/10-wheel

# Network and basic services configuration. Mask (not just disable)
# systemd-networkd-wait-online.service: this image uses NetworkManager, not
# systemd-networkd, so that unit can never succeed. It has no enablement
# symlink of its own — network-online.target pulls it in via a static
# dependency — so a plain `systemctl disable` is a no-op; masking is what
# actually stops it from being started at all. Left unmasked, it burns its
# full 2-minute timeout blocking network-online.target on every boot,
# delaying anything ordered after it (graphical login, cloud-init's network
# stage, etc.).
RUN mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service && \
    ln -sf /usr/lib/systemd/system/firewalld.service /etc/systemd/system/multi-user.target.wants/firewalld.service && \
    ln -sf /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service && \
    mkdir -p /etc/systemd/system/timers.target.wants && \
    ln -sf /usr/lib/systemd/system/arch-bootc-prune-esp.timer /etc/systemd/system/timers.target.wants/arch-bootc-prune-esp.timer && \
    systemctl mask systemd-networkd-wait-online.service

# qemu-guest-agent is installed via packages-base.txt. It is intentionally NOT
# symlinked into multi-user.target.wants: the package ships a udev rule
# (99-qemu-guest-agent.rules) that starts the service only when the
# org.qemu.guest_agent.0 virtio channel is present. The unit has an empty
# [Install] section and Restart=always, so force-enabling it would restart-loop
# on bare-metal hosts that have no agent channel.

# cloud-init: an easier way to bootstrap the first admin user than manually
# editing an offline disk (see README). Pin the datasource to NoCloud so it
# looks only at a local seed directory instead of spending boot time probing
# for a cloud provider's metadata service that doesn't exist here.
# cloud-init.target itself ships no [Install] section, so it must be linked
# into multi-user.target.wants directly; the five services below declare
# `WantedBy=cloud-init.target` in their own [Install] sections. This Arch
# build runs cloud-init as a single `cloud-init-main.service` daemon
# (`cloud-init --all-stages`); the four stage services are thin clients that
# trigger it over local Unix sockets, so the daemon must be enabled too or
# each stage silently no-ops (socket connection refused).
RUN printf 'datasource_list: [ NoCloud ]\ngrowpart:\n  mode: "off"\nresize_rootfs: false\n' > /etc/cloud/cloud.cfg.d/99-nocloud.cfg && \
    mkdir -p /etc/systemd/system/cloud-init.target.wants && \
    ln -sf /usr/lib/systemd/system/cloud-init-main.service /etc/systemd/system/cloud-init.target.wants/cloud-init-main.service && \
    ln -sf /usr/lib/systemd/system/cloud-init-local.service /etc/systemd/system/cloud-init.target.wants/cloud-init-local.service && \
    ln -sf /usr/lib/systemd/system/cloud-init-network.service /etc/systemd/system/cloud-init.target.wants/cloud-init-network.service && \
    ln -sf /usr/lib/systemd/system/cloud-config.service /etc/systemd/system/cloud-init.target.wants/cloud-config.service && \
    ln -sf /usr/lib/systemd/system/cloud-final.service /etc/systemd/system/cloud-init.target.wants/cloud-final.service && \
    ln -sf /usr/lib/systemd/system/cloud-init.target /etc/systemd/system/multi-user.target.wants/cloud-init.target

# https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images
LABEL containers.bootc 1

RUN bootc container lint

# Copy ublue-os/brew and enable its systemd services
COPY --from=ghcr.io/ublue-os/brew:latest@sha256:14ad3acb89bea0a7d98cacc206a4f590efcb794b7da7385bbeba4ed943289ad4 /system_files /
RUN systemctl preset brew-setup.service brew-update.timer brew-upgrade.timer


# --- base (CLI) target ---
# Tag every package-owned file with a chunkah `user.component` (its pacman
# package) so the CI rechunk step can split OCI layers per package, minimizing
# the bytes `bootc upgrade` downloads. Gated on CHUNK_TAG=1 (set by CI) so local
# `just` builds skip the cost and stay byte-identical otherwise.
FROM base-core AS base
ARG CHUNK_TAG=0
RUN if [ "${CHUNK_TAG}" = "1" ]; then \
      pacman -Qq | while IFS= read -r pkg; do \
        pacman -Qlq "$pkg" | sed '/\/$/d' | tr '\n' '\0' | \
          xargs -0 -r setfattr -n user.component -v "pkg:$pkg" 2>/dev/null || true ; \
      done ; \
    fi

RUN bootc container lint


# --- Desktop Layer ---
FROM base-core AS kde

# Install KDE and desktop packages from external file
COPY packages-kde.txt /tmp/packages-kde.txt
RUN --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman \
    pacman -Syu --noconfirm $(cat /tmp/packages-kde.txt) && \
    pacman -S --clean --noconfirm && \
    rm /tmp/packages-kde.txt

# mariadb (KDE PIM/Akonadi) and packagekit-qt6 are installed via
# packages-kde.txt. (systemd-networkd-wait-online.service is already
# disabled in base-core.)

# Additional desktop services
RUN sed -i 's/^hosts: .*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /usr/lib/systemd/system/power-profiles-daemon.service /etc/systemd/system/multi-user.target.wants/power-profiles-daemon.service && \
    ln -sf /usr/lib/systemd/system/bluetooth.service /etc/systemd/system/multi-user.target.wants/bluetooth.service && \
    ln -sf /usr/lib/systemd/system/avahi-daemon.service /etc/systemd/system/multi-user.target.wants/avahi-daemon.service && \
    ln -sf /usr/lib/systemd/system/cups.service /etc/systemd/system/multi-user.target.wants/cups.service

# Enable graphical login for KDE
RUN mkdir -p /etc/systemd/system/graphical.target.wants && \
    ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target && \
    ln -sf /usr/lib/systemd/system/plasmalogin.service /etc/systemd/system/graphical.target.wants/plasmalogin.service && \
    ln -sf /usr/lib/systemd/system/plasmalogin.service /etc/systemd/system/display-manager.service

# Pre-configure Flathub system-wide remote
RUN mkdir -p /etc/flatpak/remotes.d && \
    curl -fsSL --retry 3 -o /etc/flatpak/remotes.d/flathub.flatpakrepo https://flathub.org/repo/flathub.flatpakrepo

# --- Optional AUR package layering (UNTESTED, see README "How to add your
# own packages (AUR)") ---
# `bootc` images are immutable at runtime, so any AUR package you add here
# must make no runtime writes to /usr, no assumptions about classic mutable
# /var paths, and have no interactive install/runtime requirements. Uncomment
# and adapt the block below to build one with makepkg using a temporary,
# unprivileged build user (base-devel is already installed via
# packages-base.txt).
#
# RUN useradd -m -u 10000 aurbuilder && \
#     echo 'aurbuilder ALL=(ALL) NOPASSWD: /usr/bin/pacman' >> /etc/sudoers.d/aurbuilder && \
#     su - aurbuilder -c ' \
#       set -e && \
#       cd /tmp && \
#       curl -fsSL -o example-pkg.tar.gz "https://aur.archlinux.org/cgit/aur.git/snapshot/example-pkg.tar.gz" && \
#       tar xf example-pkg.tar.gz && \
#       cd example-pkg && \
#       makepkg -si --noconfirm \
#     ' && \
#     rm -f /etc/sudoers.d/aurbuilder && \
#     userdel -r aurbuilder

# Tag files with their pacman package for chunkah per-package layering (see the
# base target above). Gated on CHUNK_TAG=1 so local builds are unaffected.
ARG CHUNK_TAG=0
RUN if [ "${CHUNK_TAG}" = "1" ]; then \
      pacman -Qq | while IFS= read -r pkg; do \
        pacman -Qlq "$pkg" | sed '/\/$/d' | tr '\n' '\0' | \
          xargs -0 -r setfattr -n user.component -v "pkg:$pkg" 2>/dev/null || true ; \
      done ; \
    fi

RUN bootc container lint


# --- Desktop Layer (XFCE) ---
FROM base-core AS xfce

# Install XFCE and desktop packages from external file
COPY packages-xfce.txt /tmp/packages-xfce.txt
RUN --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman \
    pacman -Syu --noconfirm $(cat /tmp/packages-xfce.txt) && \
    pacman -S --clean --noconfirm && \
    rm /tmp/packages-xfce.txt

# (systemd-networkd-wait-online.service is already disabled in base-core.)

# Additional desktop services
RUN sed -i 's/^hosts: .*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /usr/lib/systemd/system/power-profiles-daemon.service /etc/systemd/system/multi-user.target.wants/power-profiles-daemon.service && \
    ln -sf /usr/lib/systemd/system/bluetooth.service /etc/systemd/system/multi-user.target.wants/bluetooth.service && \
    ln -sf /usr/lib/systemd/system/avahi-daemon.service /etc/systemd/system/multi-user.target.wants/avahi-daemon.service && \
    ln -sf /usr/lib/systemd/system/cups.service /etc/systemd/system/multi-user.target.wants/cups.service

# Enable graphical login for XFCE via LightDM
RUN mkdir -p /etc/systemd/system/graphical.target.wants && \
    ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target && \
    ln -sf /usr/lib/systemd/system/lightdm.service /etc/systemd/system/graphical.target.wants/lightdm.service && \
    ln -sf /usr/lib/systemd/system/lightdm.service /etc/systemd/system/display-manager.service

# Pre-configure Flathub system-wide remote
RUN mkdir -p /etc/flatpak/remotes.d && \
    curl -fsSL --retry 3 -o /etc/flatpak/remotes.d/flathub.flatpakrepo https://flathub.org/repo/flathub.flatpakrepo

# Tag files with their pacman package for chunkah per-package layering (see the
# base target above). Gated on CHUNK_TAG=1 so local builds are unaffected.
ARG CHUNK_TAG=0
RUN if [ "${CHUNK_TAG}" = "1" ]; then \
      pacman -Qq | while IFS= read -r pkg; do \
        pacman -Qlq "$pkg" | sed '/\/$/d' | tr '\n' '\0' | \
          xargs -0 -r setfattr -n user.component -v "pkg:$pkg" 2>/dev/null || true ; \
      done ; \
    fi

RUN bootc container lint
