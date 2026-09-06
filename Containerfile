FROM docker.io/archlinux/archlinux:latest@sha256:f5b391248d617e741c95bb60ef37ccd4a365457a7c1aa1f091e936a2818f8270 AS base-core

# Move everything from `/var` to `/usr/lib/sysimage` so behavior around pacman remains the same on `bootc usroverlay`'d systems
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

# Remove NoExtract rules, otherwise no additional languages and help pages can be installed
# See https://gitlab.archlinux.org/archlinux/archlinux-docker/-/blob/master/pacman-conf.d-noextract.conf?ref_type=heads
RUN sed -i 's/^[[:space:]]*NoExtract/#&/' /etc/pacman.conf

# CI's remote buildah layer cache (see build.yml) keys a RUN step purely on
# its instruction text + parent layer digest -- it has no way to know Arch's
# live repositories changed underneath it. Left alone, a cache hit here would
# silently *skip* pacman -Syu entirely and ship whatever was cached, possibly
# missing days of security updates and contradicting this project's "every
# build gets today's Arch" design (see docs/renovate.md). CI passes today's
# date so this step (and everything after it in this stage, including the
# bootc-from-source compile below) misses cache once per calendar day --
# same-day reruns still benefit. That cascade is accepted deliberately: a
# stale package set is a real security concern, a once-daily bootc recompile
# is just CI minutes.
ARG PACMAN_CACHE_BUST=0

# Install core base packages from external file. glibc is explicitly listed
# alongside them (even though it is already part of the base image) because
# pacman always reinstalls an explicitly-named target even when it is already
# up to date -- this is what actually restores the language/locale files
# stripped by the NoExtract rules removed above. A plain `pacman -Syu` with
# no explicit targets does NOT do this. Naming glibc here has the same effect
# as a standalone reinstall step, so folding it into this one transaction is
# equivalent.
RUN --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman \
    --mount=type=bind,source=packages-base.txt,target=/tmp/packages-base.txt \
    : "cache-bust ${PACMAN_CACHE_BUST}" && \
    pacman -Syu --noconfirm glibc $(grep -vE '^[[:space:]]*#|^[[:space:]]*$' /tmp/packages-base.txt) && \
    (pacman -Qq nano >/dev/null 2>&1 && pacman -Rns --noconfirm nano || true) && \
    pacman -S --clean --noconfirm

# https://github.com/bootc-dev/bootc/issues/1801
# BOOTC_COMMIT is the commit BOOTC_VERSION's tag currently points to, verified
# against below after the clone: a git tag is mutable, so this catches a tag
# re-point (compromised upstream credentials/CI, or an accidental
# force-push) instead of silently compiling and shipping whatever commit the
# tag resolves to at build time. Matches the pin-and-verify pattern already
# used for every `uses:` reference in .github/workflows/*.yaml. Both values
# are tracked together by the "Track bootc-dev/bootc release + pinned commit"
# customManager in renovate.json.
#
# BOOTC_COMMIT is the *peeled* commit. These are annotated tags, so
# refs/tags/vX.Y.Z is the tag object and refs/tags/vX.Y.Z^{} is the commit --
# the latter is what a `--branch <tag>` clone leaves at HEAD, and so what the
# check below compares. Resolve it with:
#   git ls-remote --tags https://github.com/bootc-dev/bootc.git 'vX.Y.Z*'
# and take the ^{} row, not the bare tag row.
ARG BOOTC_VERSION=v1.16.11
ARG BOOTC_COMMIT=add7a909584c832c563bdc3a45c61e42f736ecf2
# base-devel is deliberately NOT installed here (or in packages-base.txt).
# The `rust` package already hard-depends on gcc/lld/llvm-libs/compiler-rt,
# which is all the C toolchain `cargo build` needs for linking. The only
# other thing bootc's Makefile actually invokes beyond cargo is GNU `make`
# itself, so that's added explicitly. `elfutils` is added too so dracut
# still gets its optional binary-stripping pass (`eu-strip`) exactly as
# before; everything else base-devel would have pulled in (autoconf,
# automake, bison, gdb, libtool, texinfo, ~400 MiB total) is genuinely
# unused by this build.
#
# These are removed again by name at the end of this same layer. Do NOT
# replace this with a generic `pacman -Qdtq | xargs pacman -Rns` orphan
# sweep instead of naming the packages: pacman's orphan detection (-Qdt)
# permanently excludes anything listed as another installed package's
# optional dependency, and `pacman` itself lists `base-devel` as an optdep
# ("required to use makepkg") -- an orphan-only sweep would silently leave
# a full build toolchain in the shipped image forever.
RUN --mount=type=tmpfs,dst=/tmp --mount=type=tmpfs,dst=/root \
    pacman -S --needed --asdeps --noconfirm rust make go-md2man elfutils && \
    git clone --branch "${BOOTC_VERSION}" --depth 1 "https://github.com/bootc-dev/bootc.git" /tmp/bootc && \
    bootc_head="$(git -C /tmp/bootc rev-parse HEAD)" && \
    if [ "${bootc_head}" != "${BOOTC_COMMIT}" ]; then \
        printf 'bootc tag %s resolved to %s, expected %s -- refusing to build a re-pointed tag\n' \
            "${BOOTC_VERSION}" "${bootc_head}" "${BOOTC_COMMIT}" >&2; \
        exit 1; \
    fi && \
    make -C /tmp/bootc bin install-all && \
    printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)/initramfs.img" && \
    pacman -Rns --noconfirm rust make go-md2man elfutils && \
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

# Install this repo's cosign public key so the signature verification policy
# shipped above (system_files/etc/containers/policy.json) can check images
# published from ghcr.io/danathar. cosign.pub is NOT duplicated under
# system_files/: it already lives at the repo root as the single source of
# truth CI signs against and that docs/ci-cd.md tells users to commit, so
# COPYing it directly here keeps one copy in sync rather than requiring both
# to be updated whenever the key rotates.
#
# Only ghcr.io/danathar is scoped to require a signature; the "default"
# entry in policy.json stays insecureAcceptAnything so `bootc switch` /
# `podman pull` of any third-party image keeps working unmodified. Forks
# must regenerate their own keypair (see docs/ci-cd.md) AND edit the
# namespace in both system_files/etc/containers/policy.json and
# system_files/etc/containers/registries.d/arch-bootc.yaml from
# "ghcr.io/danathar" to their own "ghcr.io/<their-github-username-or-org>"
# (CI already publishes to ghcr.io/${{ github.repository_owner }}
# automatically; the policy files do not follow that automatically).
COPY cosign.pub /etc/pki/containers/arch-bootc.pub

# Default root credential, reachable ONLY from a physical console.
#
# A locked root account meant a freshly installed system had no way in at all:
# console, serial and KVM/IPMI logins were all rejected, and the desktop flavors
# boot straight to a graphical login nobody can sign into. Recovery required the
# QEMU guest agent (VMs only) or hand-editing a cloud-init seed onto the offline
# disk. Neither is something you can do at a keyboard in front of the machine.
#
# `changeme` is safe here specifically because every remote, graphical, and
# local-escalation path to root is closed, leaving only physical console
# access — the same bar as editing the disk directly:
#   - SSH:      PermitRootLogin prohibit-password, pinned below so this does
#               not silently depend on an upstream OpenSSH default.
#   - Graphical: plasmalogin (KDE) and lightdm (XFCE) both refuse root.
#   - su:       Arch ships /etc/pam.d/su with its pam_wheel.so line commented
#               out, so by default ANY local account — wheel or not — can
#               `su` to root with a bare password check, no console or group
#               membership required. That silently defeated the console-only
#               argument above: a non-wheel local account or a compromised
#               service could become root without ever touching a console.
#               Uncommenting Arch's own `pam_wheel.so use_uid` line restricts
#               `su` to wheel members. This doesn't weaken the intended path —
#               a wheel user already has full root via sudo, so gaining
#               nothing extra from `su` is fine — it only removes the path
#               for accounts that were never supposed to reach root at all.
#   - Console:   works — and this is the point.
#
# `passwd --expire` forces a change on that first login, so the well-known
# password cannot survive being used once.
#
# Do NOT extend this to a non-root user. Arch's sshd ships
# `PasswordAuthentication yes`, so a default *user* password WOULD be remotely
# exploitable on every published image; root is not.
RUN echo 'root:changeme' | chpasswd && \
    passwd --expire root && \
    mkdir -p /etc/ssh/sshd_config.d && \
    printf 'PermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/10-no-root-password.conf && \
    sed -i 's/^#auth\s\+required\s\+pam_wheel\.so use_uid/auth            required        pam_wheel.so use_uid/' /etc/pam.d/su

# Grant sudo to whoever is placed in the wheel group — whether by the console
# bootstrap above, cloud-init, or the QEMU guest agent. This is opt-in per user,
# not a blanket grant, since only the user(s) explicitly added to wheel gain
# anything. It is how a freshly provisioned system gets an admin account that
# isn't root.
RUN mkdir -p /etc/sudoers.d && \
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel && \
    chmod 0440 /etc/sudoers.d/10-wheel && \
    visudo -cf /etc/sudoers.d/10-wheel

# Service enablement policy for this image: enablement symlinks below live
# under /usr/lib/systemd/system/<target>.wants/, not /etc/systemd/system/. In
# bootc, /etc is machine-local state that gets a three-way merge on upgrade;
# an enablement symlink dropped there at build time is really only a
# *first-boot default* that a later image update cannot reliably keep
# re-asserting once the machine's /etc has diverged (e.g. after a user or
# systemd itself touches it). A /usr symlink, by contrast, is a normal
# vendored file like any other the image ships, so it tracks the image on
# every upgrade the same way a binary or config file would.
#
# This intentionally does NOT use /usr/lib/systemd/system-preset/ +
# `systemctl preset-all`: Arch's own 90-systemd.preset ships `enable
# systemd-networkd.service` and `enable systemd-networkd-wait-online.service`,
# so running preset-all would enable the exact units this image masks below.
# Hand-placed .wants symlinks avoid that.
#
# A user who wants a different choice on their own machine still can: a plain
# `systemctl disable` against one of these is a silent no-op (exit 0, /usr
# symlink untouched, unit comes back on next boot) because disable only ever
# writes to /etc, but `systemctl mask <unit>` (which always creates
# /etc/systemd/system/<unit> -> /dev/null, regardless of where the unit is
# enabled from) overrides it, and so does a local `systemctl enable`/`disable`
# pair once the user is willing to manage that unit from /etc themselves.
#
# Mask (not just disable) systemd-networkd-wait-online.service: this image
# uses NetworkManager, not systemd-networkd, so that unit can never succeed.
# It has no enablement symlink of its own — network-online.target pulls it in
# via a static dependency — so a plain `systemctl disable` is a no-op; masking
# is what actually stops it from being started at all. Left unmasked, it
# burns its full 2-minute timeout blocking network-online.target on every
# boot, delaying anything ordered after it (graphical login, cloud-init's
# network stage, etc.). This mask itself must stay in /etc, not /usr: the
# desktop stages below run their own `pacman -Syu`, and a package upgrade
# unconditionally overwrites files it owns, so a same-path mask under /usr
# would be silently restored to the real unit file the next time the systemd
# package is reinstalled or upgraded (verified). /etc is never touched by
# pacman, so it is the only location where the mask reliably survives.
# Arch's systemd package declares autovt@.service only as an Alias of
# getty@.service; it does not ship the alias file itself. `systemctl enable`
# or `preset` would materialize it, but this image deliberately avoids
# preset-all because Arch's preset would also enable the systemd-networkd
# units masked below. Vendor the alias directly so logind can start
# autovt@tty2..tty6 on demand when a user switches VTs.
RUN mkdir -p /usr/lib/systemd/system/multi-user.target.wants && \
    ln -sf /usr/lib/systemd/system/getty@.service /usr/lib/systemd/system/autovt@.service && \
    ln -sf /usr/lib/systemd/system/NetworkManager.service /usr/lib/systemd/system/multi-user.target.wants/NetworkManager.service && \
    ln -sf /usr/lib/systemd/system/firewalld.service /usr/lib/systemd/system/multi-user.target.wants/firewalld.service && \
    ln -sf /usr/lib/systemd/system/sshd.service /usr/lib/systemd/system/multi-user.target.wants/sshd.service && \
    mkdir -p /usr/lib/systemd/system/timers.target.wants && \
    ln -sf /usr/lib/systemd/system/arch-bootc-prune-esp.timer /usr/lib/systemd/system/timers.target.wants/arch-bootc-prune-esp.timer && \
    systemctl mask systemd-networkd-wait-online.service

# zram swap: the zram-generator package ships a boot-time systemd generator
# (no service to enable — it runs automatically on every boot) but no config
# of its own, so no zram device is created without one. Vendor packages are
# meant to drop their defaults in /usr/lib/systemd/zram-generator.conf.d/
# rather than the single /usr/lib/systemd/zram-generator.conf file, leaving
# /etc/systemd/zram-generator.conf.d/ free for a local admin override (see
# zram-generator.conf(5)). No fs-type/mount-point is set, so the device is
# formatted as swap (the package default).
RUN mkdir -p /usr/lib/systemd/zram-generator.conf.d && \
    printf '[zram0]\nzram-size = min(ram / 2, 4096)\ncompression-algorithm = zstd\n' | tee /usr/lib/systemd/zram-generator.conf.d/10-arch-bootc.conf

# systemd-oomd: shipped and enabled by the systemd package itself, but with
# ManagedOOMSwap=/ManagedOOMMemoryPressure= defaulting to "auto" on every
# unit, oomd never actually kills anything unless something opts a cgroup in
# with "kill" (systemd.resource-control(5)). Mirror the drop-ins the
# systemd-oomd-defaults approach uses elsewhere: -.slice (the root slice,
# systemd.slice(5)) opts the whole system in for swap-based protection, and
# user@.service opts user sessions in for memory-pressure-based protection,
# which is what actually makes oomd useful instead of a no-op.
RUN mkdir -p /usr/lib/systemd/system/-.slice.d /usr/lib/systemd/system/user@.service.d && \
    printf '[Slice]\nManagedOOMSwap=kill\n' | tee /usr/lib/systemd/system/-.slice.d/10-arch-bootc-oomd.conf && \
    printf '[Service]\nManagedOOMMemoryPressure=kill\nManagedOOMMemoryPressureLimit=50%%\n' | tee /usr/lib/systemd/system/user@.service.d/10-arch-bootc-oomd.conf && \
    mkdir -p /usr/lib/systemd/system/multi-user.target.wants /usr/lib/systemd/system/sockets.target.wants && \
    ln -sf /usr/lib/systemd/system/systemd-oomd.service /usr/lib/systemd/system/multi-user.target.wants/systemd-oomd.service && \
    ln -sf /usr/lib/systemd/system/systemd-oomd.socket /usr/lib/systemd/system/sockets.target.wants/systemd-oomd.socket

# Arch's `filesystem` package ships /etc/resolv.conf as an empty, 0700
# root-only placeholder. NetworkManager's own default is rc-manager=symlink
# (replace it with a symlink to its own correctly-permissioned stub), but
# that only kicks in for a missing or already-symlinked path -- finding a
# real pre-existing file there instead, it writes its DNS config directly
# into it, inheriting the 0700 bits rather than fixing them. systemd-resolved
# runs as the unprivileged systemd-resolve user and can never open a file
# with no group/other read bit, so it logs "Permission denied" continuously,
# every boot, for as long as the system runs.
#
# This cannot be fixed at build time. /etc/resolv.conf is a genuine bind
# mount for the duration of every RUN step (buildah's build-time DNS
# handling) -- `chmod` on it silently doesn't survive into the committed
# layer (verified: the file was stripped from the image entirely), and `mv`
# onto it fails outright with "Device or resource busy", confirming it's an
# active mountpoint, not just a managed regular file. Fix it at boot instead
# with a tmpfiles.d rule: `z` enforces mode/owner on an existing path without
# recursing, runs via systemd-tmpfiles-setup well before NetworkManager
# starts, and self-heals on every boot regardless of what created the file.
RUN printf 'z /etc/resolv.conf 0644 root root -\n' > /usr/lib/tmpfiles.d/bootc-resolv-conf-perms.conf

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
# each stage silently no-ops (socket connection refused). As with the network
# services above, all of these enablement symlinks go into
# /usr/lib/systemd/system/ rather than /etc, so cloud-init stays enabled as a
# real image default rather than as machine-local /etc state.
RUN printf 'datasource_list: [ NoCloud ]\ngrowpart:\n  mode: "off"\nresize_rootfs: false\n' > /etc/cloud/cloud.cfg.d/99-nocloud.cfg && \
    mkdir -p /usr/lib/systemd/system/cloud-init.target.wants && \
    ln -sf /usr/lib/systemd/system/cloud-init-main.service /usr/lib/systemd/system/cloud-init.target.wants/cloud-init-main.service && \
    ln -sf /usr/lib/systemd/system/cloud-init-local.service /usr/lib/systemd/system/cloud-init.target.wants/cloud-init-local.service && \
    ln -sf /usr/lib/systemd/system/cloud-init-network.service /usr/lib/systemd/system/cloud-init.target.wants/cloud-init-network.service && \
    ln -sf /usr/lib/systemd/system/cloud-config.service /usr/lib/systemd/system/cloud-init.target.wants/cloud-config.service && \
    ln -sf /usr/lib/systemd/system/cloud-final.service /usr/lib/systemd/system/cloud-init.target.wants/cloud-final.service && \
    ln -sf /usr/lib/systemd/system/cloud-init.target /usr/lib/systemd/system/multi-user.target.wants/cloud-init.target

# https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images
LABEL containers.bootc 1

# Fail the build (rather than shipping a broken image) if any systemd
# enablement symlink created above is dangling, and verify the two unit
# files this repo ships parse correctly. Scans both /etc/systemd/system and
# /usr/lib/systemd/system since this image enables services from both trees
# (see the network/basic services comment earlier in this file for why most
# enablement lives under /usr). This same check is repeated before every
# `bootc container lint` call below (base, kde, xfce) since each stage adds
# its own enablement symlinks on top of base-core's.
RUN --mount=type=bind,source=system_files/usr/lib/systemd/system,target=/tmp/shipped-units,ro \
    dangling="$(find /etc/systemd/system /usr/lib/systemd/system -xtype l)" && \
    if [ -n "$dangling" ]; then echo "error: dangling systemd enablement symlink(s):" >&2; printf '%s\n' "$dangling" >&2; exit 1; fi && \
    units="$(find /tmp/shipped-units -maxdepth 1 -type f -printf '%f ')" && \
    systemd-analyze verify $(printf '/usr/lib/systemd/system/%s ' $units)

RUN bootc container lint

# Copy ublue-os/brew and enable its systemd services. `systemctl preset` has
# no way to target /usr — it always writes to /etc — so this is intentionally
# NOT converted to the /usr-based enablement policy used elsewhere in this
# file (see the network/basic services comment above); this one stays on
# /etc-based enablement.
COPY --from=ghcr.io/ublue-os/brew:latest@sha256:bed056871da6edd8c6ee455a274283ae83bf269461dcad758a7729aaad018401 /system_files /
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

# Same dangling-symlink + systemd-analyze verify check as base-core above,
# re-run here because this stage adds its own enablement symlinks on top of
# base-core's.
RUN --mount=type=bind,source=system_files/usr/lib/systemd/system,target=/tmp/shipped-units,ro \
    dangling="$(find /etc/systemd/system /usr/lib/systemd/system -xtype l)" && \
    if [ -n "$dangling" ]; then echo "error: dangling systemd enablement symlink(s):" >&2; printf '%s\n' "$dangling" >&2; exit 1; fi && \
    units="$(find /tmp/shipped-units -maxdepth 1 -type f -printf '%f ')" && \
    systemd-analyze verify $(printf '/usr/lib/systemd/system/%s ' $units)

RUN bootc container lint


# --- Desktop Layer ---
FROM base-core AS kde

# Install KDE and desktop packages from external file
RUN --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman \
    --mount=type=bind,source=packages-kde.txt,target=/tmp/packages-kde.txt \
    pacman -Syu --noconfirm $(grep -vE '^[[:space:]]*#|^[[:space:]]*$' /tmp/packages-kde.txt) && \
    pacman -S --clean --noconfirm

# mariadb (KDE PIM/Akonadi) and packagekit-qt6 are installed via
# packages-kde.txt. (systemd-networkd-wait-online.service is already
# disabled in base-core.)

# Additional desktop services (enabled into /usr, not /etc — see the
# network/basic services comment above for why). cups.socket, not
# cups.service: the cups package ships cups.socket with
# `[Install] WantedBy=sockets.target`, not multi-user.target.
RUN sed -i 's/^hosts: .*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf && \
    mkdir -p /usr/lib/systemd/system/multi-user.target.wants /usr/lib/systemd/system/sockets.target.wants && \
    ln -sf /usr/lib/systemd/system/power-profiles-daemon.service /usr/lib/systemd/system/multi-user.target.wants/power-profiles-daemon.service && \
    ln -sf /usr/lib/systemd/system/bluetooth.service /usr/lib/systemd/system/multi-user.target.wants/bluetooth.service && \
    ln -sf /usr/lib/systemd/system/avahi-daemon.service /usr/lib/systemd/system/multi-user.target.wants/avahi-daemon.service && \
    ln -sf /usr/lib/systemd/system/cups.socket /usr/lib/systemd/system/sockets.target.wants/cups.socket

# Enable graphical login for KDE. default.target already resolves to
# graphical.target out of the box — that's systemd's own upstream default —
# not something this image needs to set, so the /etc/systemd/system/
# default.target symlink that used to be here has been removed as a no-op.
# plasma-login-manager's plasmalogin.service already declares
# `Alias=display-manager.service` in its own [Install] section, so the alias
# symlink below just materializes what the package itself declares.
RUN mkdir -p /usr/lib/systemd/system/graphical.target.wants && \
    ln -sf /usr/lib/systemd/system/plasmalogin.service /usr/lib/systemd/system/graphical.target.wants/plasmalogin.service && \
    ln -sf /usr/lib/systemd/system/plasmalogin.service /usr/lib/systemd/system/display-manager.service

# Flathub system-wide remote is now vendored (not curled at build time) as
# system_files/etc/flatpak/remotes.d/flathub.flatpakrepo, copied into every
# flavor (including the flatpak-less `base` CLI image, where it's inert) by
# the `COPY system_files/ /` in base-core.

# --- Optional AUR package layering (UNTESTED, see README "How to add your
# own packages (AUR)") ---
# `bootc` images are immutable at runtime, so any AUR package you add here
# must make no runtime writes to /usr, no assumptions about classic mutable
# /var paths, and have no interactive install/runtime requirements. Uncomment
# and adapt the block below to build one with makepkg using a temporary,
# unprivileged build user. base-devel is NOT installed by packages-base.txt
# (it was removed to keep ~400 MiB of compiler toolchain out of every
# shipped image; see the bootc-build RUN step above for why only
# `rust make go-md2man elfutils` are needed there instead). Install it here
# for the duration of the AUR build and remove it again afterward so it
# doesn't linger in this image either.
#
# RUN pacman -S --needed --noconfirm base-devel && \
#     useradd -m -u 10000 aurbuilder && \
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
#     userdel -r aurbuilder && \
#     pacman -Rns --noconfirm base-devel && \
#     pacman -S --clean --noconfirm

# Tag files with their pacman package for chunkah per-package layering (see the
# base target above). Gated on CHUNK_TAG=1 so local builds are unaffected.
ARG CHUNK_TAG=0
RUN if [ "${CHUNK_TAG}" = "1" ]; then \
      pacman -Qq | while IFS= read -r pkg; do \
        pacman -Qlq "$pkg" | sed '/\/$/d' | tr '\n' '\0' | \
          xargs -0 -r setfattr -n user.component -v "pkg:$pkg" 2>/dev/null || true ; \
      done ; \
    fi

# Same dangling-symlink + systemd-analyze verify check as base-core above,
# re-run here because this stage adds its own enablement symlinks on top of
# base-core's.
RUN --mount=type=bind,source=system_files/usr/lib/systemd/system,target=/tmp/shipped-units,ro \
    dangling="$(find /etc/systemd/system /usr/lib/systemd/system -xtype l)" && \
    if [ -n "$dangling" ]; then echo "error: dangling systemd enablement symlink(s):" >&2; printf '%s\n' "$dangling" >&2; exit 1; fi && \
    units="$(find /tmp/shipped-units -maxdepth 1 -type f -printf '%f ')" && \
    systemd-analyze verify $(printf '/usr/lib/systemd/system/%s ' $units)

RUN bootc container lint


# --- Desktop Layer (XFCE) ---
FROM base-core AS xfce

# Install XFCE and desktop packages from external file
RUN --mount=type=cache,dst=/usr/lib/sysimage/cache/pacman \
    --mount=type=bind,source=packages-xfce.txt,target=/tmp/packages-xfce.txt \
    pacman -Syu --noconfirm $(grep -vE '^[[:space:]]*#|^[[:space:]]*$' /tmp/packages-xfce.txt) && \
    pacman -S --clean --noconfirm

# (systemd-networkd-wait-online.service is already disabled in base-core.)

# Additional desktop services (enabled into /usr, not /etc — see the
# network/basic services comment above for why). cups.socket, not
# cups.service: the cups package ships cups.socket with
# `[Install] WantedBy=sockets.target`, not multi-user.target.
RUN sed -i 's/^hosts: .*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf && \
    mkdir -p /usr/lib/systemd/system/multi-user.target.wants /usr/lib/systemd/system/sockets.target.wants && \
    ln -sf /usr/lib/systemd/system/power-profiles-daemon.service /usr/lib/systemd/system/multi-user.target.wants/power-profiles-daemon.service && \
    ln -sf /usr/lib/systemd/system/bluetooth.service /usr/lib/systemd/system/multi-user.target.wants/bluetooth.service && \
    ln -sf /usr/lib/systemd/system/avahi-daemon.service /usr/lib/systemd/system/multi-user.target.wants/avahi-daemon.service && \
    ln -sf /usr/lib/systemd/system/cups.socket /usr/lib/systemd/system/sockets.target.wants/cups.socket

# Enable graphical login for XFCE via LightDM. default.target already
# resolves to graphical.target out of the box — that's systemd's own
# upstream default — not something this image needs to set, so the
# /etc/systemd/system/default.target symlink that used to be here has been
# removed as a no-op. lightdm.service already declares
# `Alias=display-manager.service` in its own [Install] section, so the alias
# symlink below just materializes what the package itself declares.
RUN mkdir -p /usr/lib/systemd/system/graphical.target.wants && \
    ln -sf /usr/lib/systemd/system/lightdm.service /usr/lib/systemd/system/graphical.target.wants/lightdm.service && \
    ln -sf /usr/lib/systemd/system/lightdm.service /usr/lib/systemd/system/display-manager.service

# Flathub system-wide remote is now vendored (not curled at build time) as
# system_files/etc/flatpak/remotes.d/flathub.flatpakrepo, copied into every
# flavor (including the flatpak-less `base` CLI image, where it's inert) by
# the `COPY system_files/ /` in base-core.

# Tag files with their pacman package for chunkah per-package layering (see the
# base target above). Gated on CHUNK_TAG=1 so local builds are unaffected.
ARG CHUNK_TAG=0
RUN if [ "${CHUNK_TAG}" = "1" ]; then \
      pacman -Qq | while IFS= read -r pkg; do \
        pacman -Qlq "$pkg" | sed '/\/$/d' | tr '\n' '\0' | \
          xargs -0 -r setfattr -n user.component -v "pkg:$pkg" 2>/dev/null || true ; \
      done ; \
    fi

# Same dangling-symlink + systemd-analyze verify check as base-core above,
# re-run here because this stage adds its own enablement symlinks on top of
# base-core's.
RUN --mount=type=bind,source=system_files/usr/lib/systemd/system,target=/tmp/shipped-units,ro \
    dangling="$(find /etc/systemd/system /usr/lib/systemd/system -xtype l)" && \
    if [ -n "$dangling" ]; then echo "error: dangling systemd enablement symlink(s):" >&2; printf '%s\n' "$dangling" >&2; exit 1; fi && \
    units="$(find /tmp/shipped-units -maxdepth 1 -type f -printf '%f ')" && \
    systemd-analyze verify $(printf '/usr/lib/systemd/system/%s ' $units)

RUN bootc container lint
