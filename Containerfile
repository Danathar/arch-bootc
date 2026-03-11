FROM docker.io/archlinux/archlinux:latest AS base

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
RUN --mount=type=tmpfs,dst=/tmp/pacman-cache --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman \
    pacman -Syu --noconfirm $(cat /tmp/packages-base.txt) && \
    (pacman -Qq nano >/dev/null 2>&1 && pacman -Rns --noconfirm nano || true) && \
    pacman -S --clean --noconfirm && \
    rm /tmp/packages-base.txt

# https://github.com/bootc-dev/bootc/issues/1801
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    pacman -S --noconfirm rust go-md2man && \
    git clone "https://github.com/bootc-dev/bootc.git" /tmp/bootc && \
    make -C /tmp/bootc bin install-all && \
    printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "*.img" | tail -n 1)/initramfs.img" && \
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

# Remove hardcoded root password and lock it for security
RUN passwd -l root

# Network and basic services configuration
RUN sed -i 's/^hosts: .*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service && \
    ln -sf /usr/lib/systemd/system/firewalld.service /etc/systemd/system/multi-user.target.wants/firewalld.service && \
    ln -sf /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service

# https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images
LABEL containers.bootc 1

RUN bootc container lint

# Copy ublue-os/brew and enable its systemd services
COPY --from=ghcr.io/ublue-os/brew:latest /system_files /
RUN systemctl preset brew-setup.service brew-update.timer brew-upgrade.timer


# --- Desktop Layer ---
FROM base AS kde

# Install KDE and desktop packages from external file
COPY packages-kde.txt /tmp/packages-kde.txt
RUN --mount=type=tmpfs,dst=/tmp/pacman-cache --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman \
    pacman -Syu --noconfirm $(cat /tmp/packages-kde.txt) && \
    pacman -S --clean --noconfirm && \
    rm /tmp/packages-kde.txt

# Additional desktop services
RUN mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /usr/lib/systemd/system/power-profiles-daemon.service /etc/systemd/system/multi-user.target.wants/power-profiles-daemon.service && \
    ln -sf /usr/lib/systemd/system/bluetooth.service /etc/systemd/system/multi-user.target.wants/bluetooth.service && \
    ln -sf /usr/lib/systemd/system/avahi-daemon.service /etc/systemd/system/multi-user.target.wants/avahi-daemon.service && \
    ln -sf /usr/lib/systemd/system/cups.service /etc/systemd/system/multi-user.target.wants/cups.service

# Enable graphical login for KDE
RUN mkdir -p /etc/systemd/system/graphical.target.wants && \
    ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target && \
    ln -sf /usr/lib/systemd/system/sddm.service /etc/systemd/system/graphical.target.wants/sddm.service && \
    ln -sf /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service

# Pre-configure Flathub system-wide remote
RUN mkdir -p /etc/flatpak/remotes.d && \
    curl -o /etc/flatpak/remotes.d/flathub.flatpakrepo https://flathub.org/repo/flathub.flatpakrepo

RUN bootc container lint
