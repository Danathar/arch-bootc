image_name := env("BUILD_IMAGE_NAME", "arch-bootc")
image_tag := env("BUILD_IMAGE_TAG", "latest")
base_dir := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "ext4")
selinux := env("BUILD_SELINUX", "true")
# Apparent size of the raw disk `generate-bootable-image` installs into. The
# file is sparse, so this reserves nothing up front -- it only sets how large
# the disk (and therefore the root filesystem bootc creates on it) appears to
# the guest. 100G matches docs/installation.md and the `arch-bootc-100g.qcow2`
# name used from there on.
disk_size := env("BUILD_DISK_SIZE", "100G")
# Which locally-built image `bootc`/`generate-bootable-image` should target.
# `kde` matches build-containerfile's default (unsuffixed) tag, kept as the
# default so existing workflows are unaffected. `base`/`xfce` match
# build-base/build-xfce's `-base`/`-xfce` suffixed tags.
flavor := env("BUILD_FLAVOR", "kde")

options := if selinux == "true" { "-v /var/lib/containers:/var/lib/containers:Z -v /etc/containers:/etc/containers:Z -v /sys/fs/selinux:/sys/fs/selinux --security-opt label=type:unconfined_t" } else { "-v /var/lib/containers:/var/lib/containers -v /etc/containers:/etc/containers" }
container_runtime := env("CONTAINER_RUNTIME", `command -v podman >/dev/null 2>&1 && echo podman || echo docker`)
image_ref := if flavor == "kde" { image_name + ":" + image_tag } else { image_name + "-" + flavor + ":" + image_tag }

# This is the one place that knows how a flavor maps to its image tag suffix
# (kde is unsuffixed for backwards compatibility; base and xfce get a
# `-base`/`-xfce` suffix). build-containerfile/build-base/build-xfce below
# are kept only as stable entry points for docs and muscle memory, and just
# forward into this recipe.
#
# Build a single flavor locally. FLAVOR must match a Containerfile target: kde, base, or xfce.
build-flavor flavor $image_name=image_name:
    sudo {{container_runtime}} build --security-opt label=disable --target "{{flavor}}" -f Containerfile -t "${image_name}{{ if flavor == "kde" { "" } else { "-" + flavor } }}:{{image_tag}}" .

# Referenced by name in docs/installation.md, docs/customizations.md, and
# this Justfile's own `bootc` recipe below -- kept working even though
# build-flavor is now the single source of truth for how a flavor is built.
#
# Backwards-compatible alias for build-flavor kde.
build-containerfile image_name=image_name: (build-flavor "kde" image_name)

# Backwards-compatible alias for build-flavor base.
build-base image_name=image_name: (build-flavor "base" image_name)

# Backwards-compatible alias for build-flavor xfce.
build-xfce image_name=image_name: (build-flavor "xfce" image_name)

bootc *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! sudo {{container_runtime}} image exists "{{image_ref}}"; then
        echo "error: image '{{image_ref}}' not found locally." >&2
        echo "Build it first (just build-containerfile / just build-base / just build-xfce)," >&2
        echo "or set BUILD_FLAVOR (kde/base/xfce) to match what you already built." >&2
        exit 1
    fi
    sudo {{container_runtime}} run \
        --rm --privileged --pid=host \
        -it \
        {{options}} \
        -v /dev:/dev \
        -e RUST_LOG=debug \
        -v "{{base_dir}}:/data" \
        "{{image_ref}}" bootc {{ARGS}}

generate-bootable-image $base_dir=base_dir $filesystem=filesystem $disk_size=disk_size:
    #!/usr/bin/env bash
    set -euo pipefail
    # truncate, not fallocate: this must stay sparse. fallocate reserves every
    # byte on the host up front, so the file costs its full size the moment it
    # is created; truncate leaves a hole and only consumes what the install
    # actually writes. docs/installation.md creates the file this way too, so
    # running that flow or this recipe standalone behaves identically.
    if [ ! -e "${base_dir}/bootable.img" ] ; then
        truncate -s "${disk_size}" "${base_dir}/bootable.img"
    fi
    just bootc install to-disk --composefs-backend --via-loopback /data/bootable.img --filesystem "${filesystem}" --wipe --bootloader systemd

# The unit files reference paths (ExecStart=/usr/libexec/arch-bootc-prune-esp,
# plus standard systemd targets like multi-user.target/timers.target) that
# don't exist as such on an arbitrary dev host, so verify runs inside a
# disposable container built from the same Arch base image with
# system_files/ overlaid on top -- matching how they're actually laid out at
# runtime -- rather than against the host's own systemd install.
#
# Static checks: shellcheck on system_files scripts, systemd-analyze verify on the unit files.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> shellcheck"
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "error: shellcheck not found on PATH." >&2
        echo "Install it (e.g. 'sudo pacman -S shellcheck', 'apt install shellcheck'," >&2
        echo "or 'brew install shellcheck') and re-run 'just lint'." >&2
        exit 1
    fi
    shellcheck system_files/usr/bin/ostree-pkg-diff system_files/usr/libexec/arch-bootc-prune-esp
    # homebrew.sh is sourced by /etc/profile.d, not executed directly, so it
    # has no shebang of its own -- tell shellcheck what to assume.
    shellcheck --shell=bash system_files/etc/profile.d/homebrew.sh

    echo "==> systemd-analyze verify"
    lint_tag="arch-bootc-lint-systemd-$$"
    printf 'FROM docker.io/archlinux/archlinux:latest\nCOPY system_files/ /\nRUN systemd-analyze verify /usr/lib/systemd/system/arch-bootc-prune-esp.service /usr/lib/systemd/system/arch-bootc-prune-esp.timer\n' \
        | sudo {{container_runtime}} build -q -t "${lint_tag}" -f - .
    sudo {{container_runtime}} rmi "${lint_tag}" >/dev/null
