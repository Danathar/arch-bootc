FROM docker.io/archlinux/archlinux:latest

# Move everything from `/var` to `/usr/lib/sysimage` so behavior around pacman remains the same on `bootc usroverlay`'d systems
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

# Remove NoExtract rules, otherwise no additional languages and help pages can be installed
# See https://gitlab.archlinux.org/archlinux/archlinux-docker/-/blob/master/pacman-conf.d-noextract.conf?ref_type=heads
RUN sed -i 's/^[[:space:]]*NoExtract/#&/' /etc/pacman.conf

# Reinstall glibc to fix missing language files due to missing in the base image
RUN --mount=type=tmpfs,dst=/tmp --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman pacman -Sy glibc --noconfirm

# Core system and desktop packages.
# Keep this list flat (one package per line) to make adding/removing packages easy.
RUN pacman -Syu --noconfirm \
    base \
    cpio \
    dbus \
    dbus-glib \
    dosfstools \
    dracut \
    e2fsprogs \
    glib2 \
    linux \
    linux-firmware \
    kde-applications-meta \
    ostree \
    plasma-meta \
    podman \
    sddm \
    shadow \
    skopeo \
    xfsprogs \
    btrfs-progs \
    xorg-server && \
    pacman -S --clean --noconfirm

# https://github.com/bootc-dev/bootc/issues/1801
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    pacman -S --noconfirm make git rust go-md2man && \
    git clone "https://github.com/bootc-dev/bootc.git" /tmp/bootc && \
    make -C /tmp/bootc bin install-all && \
    printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)/initramfs.img" && \
    pacman -Rns --noconfirm make git rust go-md2man && \
    pacman -S --clean --noconfirm

# Necessary for general behavior expected by image-based systems
RUN sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd" && \
    rm -rf /boot /home /root /usr/local /srv /opt /mnt /var /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -sT sysroot/ostree /ostree && ln -sT var/roothome /root && ln -sT var/srv /srv && ln -sT var/opt /opt && ln -sT var/mnt /mnt && ln -sT var/home /home && ln -sT ../var/usrlocal /usr/local && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"

# Setup a temporary root password (changeme) for dev purposes.
RUN echo "root:changeme" | chpasswd

# User/admin tools and networking.
# `sudo` provides `visudo`; remove `nano` so `vim` is the editor available.
RUN pacman -S --noconfirm \
    distrobox \
    flatpak \
    konsole \
    networkmanager \
    sudo \
    vim && \
    (pacman -Qq nano >/dev/null 2>&1 && pacman -Rns --noconfirm nano || true) && \
    pacman -S --clean --noconfirm && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service

# Optional AUR package layering (disabled by default).
# WARNING: AUR packages are community-maintained and may assume a traditional mutable Arch layout.
# For bootc/ostree images, only layer packages that are compatible with an immutable root:
# - no runtime writes to /usr
# - no assumptions about classic mutable /var paths
# - no interactive install/runtime requirements
# Status (2026-02-28): this AUR flow is provided as a template and has not been tested in this repo.
#
# Example flow:
# 1) Build/install `paru-bin` from AUR with a temporary unprivileged build user.
# 2) Install your AUR package list (set `PACKAGE_LIST` in the command below).
# 3) Remove temporary build user artifacts.
#
# RUN pacman -S --noconfirm --needed base-devel git && \
#     useradd -m -s /bin/bash aurbuilder && \
#     echo 'aurbuilder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-aurbuilder && \
#     chmod 0440 /etc/sudoers.d/90-aurbuilder && \
#     su - aurbuilder -c 'git clone https://aur.archlinux.org/paru-bin.git ~/paru-bin' && \
#     su - aurbuilder -c 'cd ~/paru-bin && makepkg -si --noconfirm' && \
#     su - aurbuilder -c 'PACKAGE_LIST="visual-studio-code-bin"; paru -S --noconfirm --needed ${PACKAGE_LIST}' && \
#     rm -rf /home/aurbuilder/paru-bin /home/aurbuilder/.cache && \
#     userdel -r aurbuilder && \
#     rm -f /etc/sudoers.d/90-aurbuilder && \
#     pacman -S --clean --noconfirm

# Enable graphical login for KDE
RUN mkdir -p /etc/systemd/system/graphical.target.wants && \
    ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target && \
    ln -sf /usr/lib/systemd/system/sddm.service /etc/systemd/system/graphical.target.wants/sddm.service && \
    ln -sf /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service

# https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images
LABEL containers.bootc 1

RUN bootc container lint
