#!/usr/bin/env bash
#
# arch-bootc quickstart -- interactive installer for a VM or bare metal.
#
# Collapses the manual sequences in docs/installation.md, docs/vm-workflow.md
# and docs/first-boot.md into one guided run. It seeds cloud-init so the first
# admin user exists at first boot, which is what removes the console /
# guest-agent bootstrap step entirely.
#
# Safety rules enforced here rather than left to the reader (see
# docs/vm-workflow.md and CLAUDE.md for why each one exists):
#   - qemu:///session only; the shared system connection is never touched.
#   - A VM name that already exists on either connection is refused, never
#     reused or recreated.
#   - Disk images are never written to tmpfs (they are multi-GB; that would be
#     host RAM).
#   - Image files are only ever installed through --via-loopback.
#   - A bare-metal target must be typed out in full and confirmed twice, and
#     is refused if anything on it is mounted.
#
# Run with --dry-run to print every privileged or destructive command instead
# of executing it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REGISTRY="ghcr.io/danathar"
DRY_RUN=0

# ---------------------------------------------------------------- output ---

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

step() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '    %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2; exit 1; }

# Print a command, then run it -- unless --dry-run, in which case only print.
run() {
    printf '    %s$ %s%s\n' "${C_DIM}" "$*" "${C_RESET}"
    if [ "${DRY_RUN}" -eq 0 ]; then
        "$@"
    fi
}

# --------------------------------------------------------------- prompts ---

# ask <varname> <prompt> [default]
ask() {
    local __var="$1" __prompt="$2" __default="${3:-}" __reply=''
    if [ -n "${__default}" ]; then
        read -r -p "    ${__prompt} [${__default}]: " __reply || true
        __reply="${__reply:-${__default}}"
    else
        while [ -z "${__reply}" ]; do
            read -r -p "    ${__prompt}: " __reply || true
        done
    fi
    printf -v "${__var}" '%s' "${__reply}"
}

# ask_secret <varname> <prompt> -- reads twice, requires a match
ask_secret() {
    local __var="$1" __prompt="$2" __a='' __b=''
    while :; do
        read -r -s -p "    ${__prompt}: " __a || true; echo
        [ -z "${__a}" ] && { warn "cannot be empty"; continue; }
        read -r -s -p "    ${__prompt} (again): " __b || true; echo
        [ "${__a}" = "${__b}" ] && break
        warn "they did not match, try again"
    done
    printf -v "${__var}" '%s' "${__a}"
}

# choose <varname> <prompt> <option>... -- numbered menu
choose() {
    local __var="$1" __prompt="$2"; shift 2
    local __opts=("$@") __i __reply
    printf '    %s\n' "${__prompt}"
    for __i in "${!__opts[@]}"; do
        printf '      %s) %s\n' "$((__i + 1))" "${__opts[__i]}"
    done
    while :; do
        read -r -p "    choice [1]: " __reply || true
        __reply="${__reply:-1}"
        if [[ "${__reply}" =~ ^[0-9]+$ ]] && [ "${__reply}" -ge 1 ] && [ "${__reply}" -le "${#__opts[@]}" ]; then
            printf -v "${__var}" '%s' "${__opts[$((__reply - 1))]}"
            return
        fi
        warn "enter a number between 1 and ${#__opts[@]}"
    done
}

confirm() {
    local reply=''
    read -r -p "    $1 [y/N]: " reply || true
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# ----------------------------------------------------------- preflight ---

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH. $2"
}

# The disk image must not land on tmpfs -- a multi-GB qcow2 there is host RAM.
assert_not_tmpfs() {
    local dir="$1" fstype probe
    # Check the nearest existing ancestor so this works before the directory
    # is created (and so --dry-run creates nothing).
    probe="${dir}"
    while [ ! -d "${probe}" ] && [ "${probe}" != "/" ]; do
        probe="$(dirname "${probe}")"
    done
    fstype="$(findmnt -n -o FSTYPE -T "${probe}" 2>/dev/null || echo unknown)"
    case "${fstype}" in
        tmpfs|ramfs)
            die "${dir} is on ${fstype} (RAM). Pick a disk-backed directory instead."
            ;;
        unknown)
            warn "could not determine the filesystem behind ${dir}; continuing"
            ;;
        *)
            ok "${dir} is on ${fstype} (disk-backed)"
            ;;
    esac
    [ "${DRY_RUN}" -eq 1 ] || mkdir -p "${dir}"
}

# Whole-disk devices backing anything the running host depends on. Printed one
# per line; used to refuse a bare-metal target that would destroy this machine.
running_system_disks() {
    local mp src parent
    for mp in / /boot /boot/efi /var /usr /sysroot; do
        src="$(findmnt -no SOURCE --target "${mp}" 2>/dev/null | head -1 | sed 's/\[.*//')" || continue
        [ -n "${src}" ] && [ -b "${src}" ] || continue
        # Map a partition back to its parent disk; a whole-disk source maps to
        # itself.
        parent="$(lsblk -no PKNAME "${src}" 2>/dev/null | grep -v '^$' | head -1 || true)"
        if [ -n "${parent}" ]; then
            printf '/dev/%s\n' "${parent}"
        else
            printf '%s\n' "${src}"
        fi
    done | sort -u
}

# A name already defined on *either* libvirt connection is refused outright.
# Reusing one would clobber a VM this script did not create.
assert_vm_name_free() {
    local name="$1" conn existing
    for conn in "qemu:///session" "qemu:///system"; do
        existing="$(virsh -c "${conn}" list --all --name 2>/dev/null || true)"
        if printf '%s\n' "${existing}" | grep -qx -- "${name}"; then
            die "a VM named '${name}' already exists on ${conn}.
    This script never destroys or redefines an existing VM. Choose another name.
    Existing VMs on ${conn}:
$(printf '%s\n' "${existing}" | sed 's/^/      /')"
        fi
    done
    ok "VM name '${name}' is free on both libvirt connections"
}

# ------------------------------------------------------------ cloud-init ---

# Builds a NoCloud seed ISO. The image pins cloud-init to the NoCloud
# datasource, which looks for a filesystem labelled 'cidata' -- so attaching
# this as a CD-ROM is enough to have the admin user created during first boot.
make_seed_iso() {
    local outdir="$1" username="$2" pwhash="$3" sshkey="$4" iso="$5"
    local seeddir="${outdir}/seed"

    if [ "${DRY_RUN}" -eq 1 ]; then
        info "(dry run) would write ${seeddir}/{meta-data,user-data} for '${username}'"
    else
        # user-data carries the password hash, so keep it off other users'
        # eyes: 0700 dir, 0600 files, created before anything is written.
        mkdir -p "${seeddir}"
        chmod 700 "${seeddir}"
        install -m 600 /dev/null "${seeddir}/meta-data"
        install -m 600 /dev/null "${seeddir}/user-data"

        printf 'instance-id: arch-bootc-quickstart\nlocal-hostname: %s\n' "${VM_HOSTNAME}" \
            > "${seeddir}/meta-data"
        {
            printf '#cloud-config\nusers:\n'
            printf '  - name: %s\n' "${username}"
            printf '    uid: 1000\n'
            printf '    groups: [wheel]\n'
            printf '    shell: /bin/bash\n'
            printf '    lock_passwd: false\n'
            printf "    passwd: '%s'\n" "${pwhash}"
            if [ -n "${sshkey}" ]; then
                printf '    ssh_authorized_keys:\n'
                printf '      - %s\n' "${sshkey}"
            fi
        } > "${seeddir}/user-data"
    fi

    local mkiso=''
    for candidate in xorriso genisoimage mkisofs; do
        if command -v "${candidate}" >/dev/null 2>&1; then mkiso="${candidate}"; break; fi
    done
    [ -n "${mkiso}" ] || die "need one of xorriso, genisoimage or mkisofs to build the
    cloud-init seed image. Install one (e.g. 'sudo pacman -S libisoburn',
    'sudo apt install xorriso') and re-run."

    case "${mkiso}" in
        xorriso)
            run xorriso -as mkisofs -output "${iso}" -volid cidata -joliet -rock "${seeddir}"
            ;;
        *)
            run "${mkiso}" -output "${iso}" -volid cidata -joliet -rock "${seeddir}"
            ;;
    esac
    if [ "${DRY_RUN}" -eq 0 ]; then
        chmod 600 "${iso}"
        # The staging copy of user-data holds the same hash the ISO now
        # carries; drop it rather than leave a second copy lying around.
        rm -rf "${seeddir}"
    fi
    ok "cloud-init seed: ${iso}"
}

# ------------------------------------------------------ shared questions ---

collect_image() {
    local source flavor
    choose source "Which image?" \
        "Published image (no local build needed)" \
        "Locally built image (requires 'just build-*' first)"

    choose flavor "Which flavor?" "kde" "xfce" "base"
    FLAVOR="${flavor}"

    if [[ "${source}" == Published* ]]; then
        local registry
        ask registry "Registry namespace" "${DEFAULT_REGISTRY}"
        IMAGE="${registry}/arch-bootc-${FLAVOR}:latest"
        PULL_FLAG="--pull=newer"
    else
        # build-containerfile leaves kde unsuffixed; base/xfce get a suffix.
        if [ "${FLAVOR}" = "kde" ]; then
            IMAGE="localhost/arch-bootc:latest"
        else
            IMAGE="localhost/arch-bootc-${FLAVOR}:latest"
        fi
        PULL_FLAG="--pull=never"
        if [ "${DRY_RUN}" -eq 0 ] && ! sudo podman image exists "${IMAGE}"; then
            die "local image '${IMAGE}' not found.
    Build it first:  just build-${FLAVOR}   (or 'just build-containerfile' for kde)"
        fi
    fi
    ok "image: ${IMAGE}"
}

collect_admin_user() {
    local pw sshkey_path
    ask ADMIN_USER "Admin username to create at first boot" "${USER:-arch}"
    [[ "${ADMIN_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || die "'${ADMIN_USER}' is not a valid Linux username."
    ask_secret pw "Password for ${ADMIN_USER}"

    need_cmd openssl "Install openssl to hash the password."
    ADMIN_HASH="$(openssl passwd -6 "${pw}")"
    unset pw

    ADMIN_SSHKEY=""
    if [ -f "${HOME}/.ssh/id_ed25519.pub" ]; then
        sshkey_path="${HOME}/.ssh/id_ed25519.pub"
    elif [ -f "${HOME}/.ssh/id_rsa.pub" ]; then
        sshkey_path="${HOME}/.ssh/id_rsa.pub"
    else
        sshkey_path=""
    fi
    if [ -n "${sshkey_path}" ] && confirm "Add SSH key ${sshkey_path} to ${ADMIN_USER}?"; then
        ADMIN_SSHKEY="$(cat "${sshkey_path}")"
        ok "SSH key will be installed for ${ADMIN_USER}"
    fi
}

# ------------------------------------------------------------- VM flow ---

flow_vm() {
    need_cmd virsh       "Install libvirt client tools."
    need_cmd virt-install "Install virt-install (package 'virt-install' or 'virt-manager')."
    need_cmd qemu-img    "Install qemu-img (package 'qemu-img' or 'qemu-utils')."
    need_cmd findmnt     "Install util-linux."

    collect_image
    collect_admin_user

    step "VM settings"
    ask VM_NAME "VM name" "arch-bootc-quickstart"
    assert_vm_name_free "${VM_NAME}"
    VM_HOSTNAME="${VM_NAME}"

    ask DISK_SIZE "Disk size (sparse -- reserves nothing up front)" "100G"
    ask VM_MEMORY "Memory in MiB" "8192"
    ask VM_VCPUS  "vCPUs" "4"

    local default_dir="${REPO_ROOT}/output"
    ask WORK_DIR "Directory for the disk image" "${default_dir}"
    assert_not_tmpfs "${WORK_DIR}"

    local raw="${WORK_DIR}/${VM_NAME}.raw"
    local qcow="${WORK_DIR}/${VM_NAME}.qcow2"
    local seed_iso="${WORK_DIR}/${VM_NAME}-seed.iso"

    for existing in "${raw}" "${qcow}" "${seed_iso}"; do
        if [ -e "${existing}" ]; then
            confirm "${existing} exists. Overwrite?" || die "aborted; nothing was changed."
            run rm -f "${existing}"
        fi
    done

    step "Summary"
    info "image:      ${IMAGE}"
    info "VM:         ${VM_NAME} (${VM_MEMORY} MiB, ${VM_VCPUS} vCPU, qemu:///session)"
    info "disk:       ${qcow} (${DISK_SIZE}, sparse)"
    info "admin user: ${ADMIN_USER} (created by cloud-init at first boot)"
    echo
    confirm "Proceed?" || die "aborted; nothing was changed."

    step "Creating sparse disk image"
    # truncate, not fallocate: this must stay sparse so "100G" costs only what
    # the install actually writes.
    run truncate -s "${DISK_SIZE}" "${raw}"

    step "Installing image to disk (via loopback)"
    info "This runs bootc install to-disk inside the image itself; it needs sudo."
    run sudo podman run --rm -it --privileged --pid=host "${PULL_FLAG}" \
        --security-opt label=type:unconfined_t \
        -v /dev:/dev \
        -v "${WORK_DIR}:/data" \
        "${IMAGE}" \
        bootc install to-disk --composefs-backend --via-loopback \
        "/data/$(basename "${raw}")" --filesystem ext4 --wipe --bootloader systemd

    # The installer container releases its loop device on exit; make sure.
    if [ "${DRY_RUN}" -eq 0 ]; then
        if losetup -a 2>/dev/null | grep -q "$(basename "${raw}")"; then
            warn "a loop device still references ${raw}; detaching"
            run sudo losetup -D
        fi
    fi

    step "Converting to qcow2"
    run qemu-img convert -f raw -O qcow2 -S 4k "${raw}" "${qcow}"
    run rm -f "${raw}"

    step "Building cloud-init seed"
    make_seed_iso "${WORK_DIR}" "${ADMIN_USER}" "${ADMIN_HASH}" "${ADMIN_SSHKEY}" "${seed_iso}"

    step "Creating VM"
    run virt-install \
        --connect qemu:///session \
        --name "${VM_NAME}" \
        --memory "${VM_MEMORY}" \
        --vcpus "${VM_VCPUS}" \
        --cpu host-passthrough \
        --import \
        --disk "path=${qcow},format=qcow2,bus=virtio" \
        --disk "path=${seed_iso},device=cdrom" \
        --network user,model=virtio \
        --graphics spice \
        --video virtio \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no \
        --osinfo linux2024 \
        --noautoconsole

    step "Done"
    ok "VM '${VM_NAME}' created and booting."
    info "cloud-init creates '${ADMIN_USER}' during first boot -- give it a minute."
    echo
    info "Watch it come up:"
    info "  virsh -c qemu:///session qemu-agent-command ${VM_NAME} '{\"execute\":\"guest-ping\"}'"
    info "Open a console:"
    info "  virt-viewer -c qemu:///session ${VM_NAME}"
    info "Remove it again:"
    info "  virsh -c qemu:///session destroy ${VM_NAME}"
    info "  virsh -c qemu:///session undefine ${VM_NAME} --nvram"
    info "  rm -f ${qcow} ${seed_iso}"
}

# ------------------------------------------------------ bare-metal flow ---

flow_baremetal() {
    need_cmd lsblk "Install util-linux."

    warn "Bare-metal install ERASES the target disk completely."
    echo

    step "Available block devices"
    lsblk -d -o NAME,SIZE,TYPE,MODEL | sed 's/^/    /'
    echo
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/    /'

    step "Target disk"
    ask TARGET_DISK "Full device path to ERASE (e.g. /dev/nvme0n1)"

    [ -b "${TARGET_DISK}" ] || die "'${TARGET_DISK}' is not a block device."

    # Must be a whole disk. bootc install to-disk partitions its target, so a
    # partition path here would be wrong -- and typing /dev/sda1 when you meant
    # /dev/sda is an easy slip with expensive consequences.
    local devtype
    devtype="$(lsblk -dno TYPE "${TARGET_DISK}" 2>/dev/null || echo unknown)"
    if [ "${devtype}" != "disk" ]; then
        die "'${TARGET_DISK}' is a '${devtype}', not a whole disk.
    Pass the whole-disk device (e.g. /dev/nvme0n1, not /dev/nvme0n1p3)."
    fi

    # Belt and braces over the mount check below: refuse any disk backing a
    # filesystem this host is currently running from, however it is mounted.
    local sysdisk
    for sysdisk in $(running_system_disks); do
        if [ "${sysdisk}" = "${TARGET_DISK}" ]; then
            die "${TARGET_DISK} backs this running system (it holds one of / /boot /boot/efi /var /usr).
    Refusing outright -- this would destroy the machine you are typing on."
        fi
    done
    ok "${TARGET_DISK} does not back the running system"

    # Refuse anything currently mounted -- almost certainly the running system.
    local mounted
    mounted="$(lsblk -nlo MOUNTPOINT "${TARGET_DISK}" 2>/dev/null | grep -v '^$' || true)"
    if [ -n "${mounted}" ]; then
        die "${TARGET_DISK} has mounted partitions:
$(printf '%s\n' "${mounted}" | sed 's/^/      /')
    Refusing to install onto a disk that is in use."
    fi
    ok "${TARGET_DISK} has nothing mounted"

    # "Nothing mounted" is necessary but nowhere near sufficient. Members of a
    # ZFS pool, LVM volume group, MD array or LUKS container are normally NOT
    # mounted as themselves, so the check above waves them straight through --
    # and those are exactly the disks whose loss hurts most. Refuse them, and
    # make the user clear the signature deliberately if they really mean it.
    local sigs
    sigs="$(lsblk -nlo NAME,FSTYPE "${TARGET_DISK}" 2>/dev/null \
        | grep -Ew 'zfs_member|LVM2_member|linux_raid_member|crypto_LUKS|bcache|DDF_raid_member|isw_raid_member' || true)"
    if [ -n "${sigs}" ]; then
        die "${TARGET_DISK} carries storage-subsystem signatures:
$(printf '%s\n' "${sigs}" | sed 's/^/      /')
    This disk is part of a ZFS pool, LVM group, RAID array or LUKS container.
    Nothing is mounted, so it can look free while still holding live data.
    Refusing. If you are certain, clear the signature yourself first
    (e.g. 'sudo wipefs -a ${TARGET_DISK}') and re-run."
    fi
    ok "${TARGET_DISK} carries no ZFS/LVM/RAID/LUKS signatures"

    collect_image
    collect_admin_user

    step "Confirm destruction"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "${TARGET_DISK}" | sed 's/^/    /'
    echo
    local typed=''
    ask typed "Retype the device path exactly to confirm"
    [ "${typed}" = "${TARGET_DISK}" ] || die "'${typed}' does not match '${TARGET_DISK}'; aborted."
    read -r -p "    Type ERASE in capitals to proceed: " typed || true
    [ "${typed}" = "ERASE" ] || die "aborted; nothing was changed."

    step "Installing to ${TARGET_DISK}"
    run sudo podman run --rm -it --privileged --pid=host "${PULL_FLAG}" \
        --security-opt label=type:unconfined_t \
        -v /dev:/dev \
        "${IMAGE}" \
        bootc install to-disk --composefs-backend "${TARGET_DISK}" \
        --filesystem ext4 --wipe --bootloader systemd

    step "Seeding cloud-init for the first admin user"
    # Root is the third partition of a fresh install (ESP, boot, root).
    local rootpart
    if [[ "${TARGET_DISK}" =~ [0-9]$ ]]; then
        rootpart="${TARGET_DISK}p3"
    else
        rootpart="${TARGET_DISK}3"
    fi
    info "root partition: ${rootpart}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        info "(dry run) would mount ${rootpart} and write the NoCloud seed"
    else
        [ -b "${rootpart}" ] || die "expected root partition ${rootpart} not found after install."
        local mnt
        mnt="$(mktemp -d)"
        sudo mount "${rootpart}" "${mnt}"
        # Bail rather than guess if the layout is not what we expect.
        local deploy
        deploy="$(sudo find "${mnt}/state/deploy" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)"
        if [ -z "${deploy}" ]; then
            sudo umount "${mnt}"; rmdir "${mnt}"
            die "could not find a deployment under ${rootpart}:/state/deploy.
    The install may have used a different layout; seed cloud-init manually --
    see docs/first-boot.md."
        fi
        sudo mkdir -p "${deploy}/var/lib/cloud/seed/nocloud"
        # user-data below carries the password hash; create both files 0600
        # before writing rather than leaving them at the default mask.
        sudo install -m 600 /dev/null "${deploy}/var/lib/cloud/seed/nocloud/meta-data"
        sudo install -m 600 /dev/null "${deploy}/var/lib/cloud/seed/nocloud/user-data"
        printf 'instance-id: arch-bootc-quickstart\n' \
            | sudo tee "${deploy}/var/lib/cloud/seed/nocloud/meta-data" >/dev/null
        {
            printf '#cloud-config\nusers:\n'
            printf '  - name: %s\n' "${ADMIN_USER}"
            printf '    uid: 1000\n'
            printf '    groups: [wheel]\n'
            printf '    shell: /bin/bash\n'
            printf '    lock_passwd: false\n'
            printf "    passwd: '%s'\n" "${ADMIN_HASH}"
            if [ -n "${ADMIN_SSHKEY}" ]; then
                printf '    ssh_authorized_keys:\n'
                printf '      - %s\n' "${ADMIN_SSHKEY}"
            fi
        } | sudo tee "${deploy}/var/lib/cloud/seed/nocloud/user-data" >/dev/null
        sudo umount "${mnt}"
        rmdir "${mnt}"
        ok "cloud-init seeded into ${deploy}"
    fi

    step "Done"
    ok "${TARGET_DISK} is installed."
    info "Reboot and select it. cloud-init creates '${ADMIN_USER}' during first boot."
    info "Keep Secure Boot disabled unless you manage your own signed boot chain."
}

# ------------------------------------------------------------------ main ---

usage() {
    cat <<'EOF'
arch-bootc quickstart -- guided install to a VM or bare metal.

Usage: scripts/quickstart.sh [--dry-run] [--help]

  --dry-run   Print every privileged or destructive command instead of
              running it. Prompts still work, so this is the safe way to
              see exactly what the script would do.
  --help      Show this message.

Creates the first admin user via cloud-init, so no console login or
QEMU guest-agent bootstrap is needed.
EOF
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "unknown argument: $1" ;;
        esac
    done

    need_cmd podman "Install podman."

    printf '%s\n' "${C_BOLD}arch-bootc quickstart${C_RESET}"
    if [ "${DRY_RUN}" -eq 1 ]; then
        warn "dry run -- no command that changes anything will actually execute"
    fi

    local target
    step "What are we installing to?"
    choose target "Target:" \
        "A local VM (libvirt, qemu:///session)" \
        "Bare metal (ERASES a physical disk)"

    if [[ "${target}" == "A local VM"* ]]; then
        flow_vm
    else
        flow_baremetal
    fi
}

main "$@"
