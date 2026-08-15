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
#   - VM creation uses qemu:///session only. qemu:///system is inventoried
#     read-only solely to prevent a cross-connection name collision.
#   - A VM name that already exists on either connection is refused, never
#     reused or recreated, and an unreadable inventory fails closed.
#   - Disk images are never written to tmpfs (they are multi-GB; that would be
#     host RAM).
#   - Image files are only ever installed through --via-loopback.
#   - A bare-metal target must be typed out in full and confirmed twice, and
#     is refused if anything on it is mounted.
#
# Run with --dry-run to print shell-escaped mutating commands instead of
# executing them. Read-only host validation still runs.

set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REGISTRY="ghcr.io/danathar"
DRY_RUN=0
SEED_STAGING_DIR=''
BAREMETAL_MOUNT_DIR=''
ISO_TOOL=''

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
    printf '    %s$' "${C_DIM}"
    printf ' %q' "$@"
    printf '%s\n' "${C_RESET}"
    if [ "${DRY_RUN}" -eq 0 ]; then
        "$@"
    fi
}

# Remove only invocation-owned temporary resources. Persistent outputs (disk
# images, seed ISO, VM, and any libvirt pool) are deliberately never removed
# here: they are user-visible results or failure artifacts.
cleanup_task_resources() {
    local status=$?
    trap - EXIT

    if [ -n "${BAREMETAL_MOUNT_DIR}" ]; then
        if mountpoint -q -- "${BAREMETAL_MOUNT_DIR}" 2>/dev/null; then
            sudo umount -- "${BAREMETAL_MOUNT_DIR}" \
                || warn "could not unmount ${BAREMETAL_MOUNT_DIR}; remove it manually after checking it"
        fi
        if [ -d "${BAREMETAL_MOUNT_DIR}" ]; then
            rmdir -- "${BAREMETAL_MOUNT_DIR}" 2>/dev/null \
                || warn "temporary mount directory remains: ${BAREMETAL_MOUNT_DIR}"
        fi
    fi

    if [ -n "${SEED_STAGING_DIR}" ] && [ -d "${SEED_STAGING_DIR}" ]; then
        rm -f -- "${SEED_STAGING_DIR}/meta-data" "${SEED_STAGING_DIR}/user-data"
        rmdir -- "${SEED_STAGING_DIR}" 2>/dev/null \
            || warn "temporary seed directory remains: ${SEED_STAGING_DIR}"
    fi

    return "${status}"
}

trap cleanup_task_resources EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# --------------------------------------------------------------- prompts ---

# ask <varname> <prompt> [default]
ask() {
    local __var="$1" __prompt="$2" __default="${3:-}" __reply=''
    if [ -n "${__default}" ]; then
        read -r -p "    ${__prompt} [${__default}]: " __reply || die "input closed"
        __reply="${__reply:-${__default}}"
    else
        while [ -z "${__reply}" ]; do
            read -r -p "    ${__prompt}: " __reply || die "input closed"
        done
    fi
    printf -v "${__var}" '%s' "${__reply}"
}

# ask_secret <varname> <prompt> -- reads twice, requires a match
ask_secret() {
    local __var="$1" __prompt="$2" __a='' __b=''
    while :; do
        read -r -s -p "    ${__prompt}: " __a || { echo; die "input closed"; }
        echo
        [ -z "${__a}" ] && { warn "cannot be empty"; continue; }
        read -r -s -p "    ${__prompt} (again): " __b || { echo; die "input closed"; }
        echo
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
        read -r -p "    choice [1]: " __reply || die "input closed"
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
    read -r -p "    $1 [y/N]: " reply || return 1
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
    if ! fstype="$(findmnt -n -o FSTYPE -T "${probe}" 2>/dev/null)" || [ -z "${fstype}" ]; then
        die "could not determine the filesystem behind ${dir}; refusing to create a disk image"
    fi
    case "${fstype}" in
        tmpfs|ramfs)
            die "${dir} is on ${fstype} (RAM). Pick a disk-backed directory instead."
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
    local mp src ancestors
    for mp in / /boot /boot/efi /var /usr /sysroot; do
        src="$(findmnt -no SOURCE --target "${mp}" 2>/dev/null | head -1 | sed 's/\[.*//')" || continue
        [ -n "${src}" ] && [ -b "${src}" ] || continue
        # Walk through partitions and device-mapper layers to every physical
        # disk below the mounted source, rather than stopping after one parent.
        ancestors="$(lsblk -srnpo NAME,TYPE -- "${src}" 2>/dev/null)" || return 1
        awk '$2 == "disk" { print $1 }' <<< "${ancestors}"
    done | sort -u
}

# A name already defined on *either* libvirt connection is refused outright.
# Reusing one would clobber a VM this script did not create.
assert_vm_name_free() {
    local name="$1" conn existing
    for conn in "qemu:///session" "qemu:///system"; do
        if ! existing="$(virsh -c "${conn}" list --all --name 2>/dev/null)"; then
            die "could not inventory VMs on ${conn}.
    Refusing to treat an unreadable connection as empty; check libvirt access and re-run."
        fi
        if printf '%s\n' "${existing}" | grep -qx -- "${name}"; then
            die "a VM named '${name}' already exists on ${conn}.
    This script never destroys or redefines an existing VM. Choose another name.
    Existing VMs on ${conn}:
$(printf '%s\n' "${existing}" | sed 's/^/      /')"
        fi
    done
    ok "VM name '${name}' is free on both libvirt connections"
}

list_session_pools() {
    local pools
    if ! pools="$(virsh -c qemu:///session pool-list --all --name 2>/dev/null)"; then
        die "could not inventory storage pools on qemu:///session"
    fi
    printf '%s\n' "${pools}" | sed '/^$/d' | sort -u
}

find_iso_tool() {
    local candidate
    for candidate in xorriso genisoimage mkisofs; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            ISO_TOOL="${candidate}"
            return
        fi
    done
    die "need one of xorriso, genisoimage or mkisofs to build the
    cloud-init seed image. Install one (e.g. 'sudo pacman -S libisoburn',
    'sudo apt install xorriso') and re-run."
}

prepare_image() {
    if [ "${IMAGE_NEEDS_PULL}" -eq 1 ]; then
        step "Pulling the selected image before changing storage"
        run sudo podman pull "${IMAGE}"
    fi
}

block_identity() {
    lsblk -dnP -o MAJ:MIN,SIZE,MODEL,SERIAL,WWN -- "$1" 2>/dev/null
}

validate_baremetal_target() {
    local disk="$1" devtype sysdisks sysdisk mounted sigs

    [ -b "${disk}" ] || die "'${disk}' is not a block device."

    if ! devtype="$(lsblk -dno TYPE -- "${disk}" 2>/dev/null)"; then
        die "could not determine the device type for ${disk}"
    fi
    if [ "${devtype}" != "disk" ]; then
        die "'${disk}' is a '${devtype}', not a whole disk.
    Pass the whole-disk device (e.g. /dev/nvme0n1, not /dev/nvme0n1p3)."
    fi

    if ! sysdisks="$(running_system_disks)"; then
        die "could not map the running system's filesystems to their backing disks"
    fi
    while IFS= read -r sysdisk; do
        [ -n "${sysdisk}" ] || continue
        if [ "${sysdisk}" = "${disk}" ]; then
            die "${disk} backs this running system (it holds one of / /boot /boot/efi /var /usr).
    Refusing outright -- this would destroy the machine you are typing on."
        fi
    done <<< "${sysdisks}"
    ok "${disk} does not back the running system"

    if ! mounted="$(lsblk -nrpo MOUNTPOINTS -- "${disk}" 2>/dev/null)"; then
        die "could not inspect mounts below ${disk}"
    fi
    mounted="$(printf '%s\n' "${mounted}" | sed '/^$/d')"
    if [ -n "${mounted}" ]; then
        die "${disk} has mounted partitions or active swap:
$(printf '%s\n' "${mounted}" | sed 's/^/      /')
    Refusing to install onto a disk that is in use."
    fi
    ok "${disk} has nothing mounted and no active swap"

    if ! sigs="$(lsblk -nrpo NAME,FSTYPE -- "${disk}" 2>/dev/null)"; then
        die "could not inspect storage signatures on ${disk}"
    fi
    sigs="$(printf '%s\n' "${sigs}" \
        | grep -Ew 'zfs_member|LVM2_member|linux_raid_member|crypto_LUKS|bcache|DDF_raid_member|isw_raid_member' || true)"
    if [ -n "${sigs}" ]; then
        die "${disk} carries storage-subsystem signatures:
$(printf '%s\n' "${sigs}" | sed 's/^/      /')
    This disk is part of a ZFS pool, LVM group, RAID array or LUKS container.
    Nothing is mounted, so it can look free while still holding live data.
    Refusing. If you are certain, clear the signature yourself first
    (e.g. 'sudo wipefs -a ${disk}') and re-run."
    fi
    ok "${disk} carries no ZFS/LVM/RAID/LUKS signatures"
}

assert_target_identity() {
    local input="$1" expected_path="$2" expected_identity="$3"
    local current_path current_identity

    if ! current_path="$(readlink -f -- "${input}")"; then
        die "could not resolve ${input} during final target validation"
    fi
    if [ "${current_path}" != "${expected_path}" ]; then
        die "the target path changed while the installer was waiting:
    expected: ${expected_path}
    current:  ${current_path}
    Refusing to erase a different device."
    fi
    if ! current_identity="$(block_identity "${expected_path}")" || [ -z "${current_identity}" ]; then
        die "could not re-read the identity of ${expected_path}"
    fi
    if [ "${current_identity}" != "${expected_identity}" ]; then
        die "the target device identity changed while the installer was waiting:
    expected: ${expected_identity}
    current:  ${current_identity}
    Refusing to erase it."
    fi
}

# ------------------------------------------------------------ cloud-init ---

# Builds a NoCloud seed ISO. The image pins cloud-init to the NoCloud
# datasource, which looks for a filesystem labelled 'cidata' -- so attaching
# this as a CD-ROM is enough to have the admin user created during first boot.
make_seed_iso() {
    local outdir="$1" username="$2" pwhash="$3" sshkey="$4" iso="$5"
    local seeddir

    if [ "${DRY_RUN}" -eq 1 ]; then
        seeddir="${outdir}/.arch-bootc-seed.<temporary>"
        info "(dry run) would write ${seeddir}/{meta-data,user-data} for '${username}'"
    else
        # user-data carries the password hash, so keep it off other users'
        # eyes. mktemp proves this invocation owns the staging directory, and
        # the EXIT trap removes only its two known files if ISO creation fails.
        SEED_STAGING_DIR="$(mktemp -d "${outdir}/.arch-bootc-seed.XXXXXX")"
        seeddir="${SEED_STAGING_DIR}"
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

    case "${ISO_TOOL}" in
        xorriso)
            run xorriso -as mkisofs -output "${iso}" -volid cidata -joliet -rock "${seeddir}"
            ;;
        *)
            run "${ISO_TOOL}" -output "${iso}" -volid cidata -joliet -rock "${seeddir}"
            ;;
    esac
    if [ "${DRY_RUN}" -eq 0 ]; then
        chmod 600 "${iso}"
        rm -f -- "${seeddir}/meta-data" "${seeddir}/user-data"
        rmdir -- "${seeddir}"
        SEED_STAGING_DIR=''
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
        IMAGE_NEEDS_PULL=1
    else
        # build-containerfile leaves kde unsuffixed; base/xfce get a suffix.
        if [ "${FLAVOR}" = "kde" ]; then
            IMAGE="localhost/arch-bootc:latest"
        else
            IMAGE="localhost/arch-bootc-${FLAVOR}:latest"
        fi
        IMAGE_NEEDS_PULL=0
        if [ "${DRY_RUN}" -eq 0 ] && ! sudo podman image exists "${IMAGE}"; then
            die "local image '${IMAGE}' not found.
    Build it first:  just build-${FLAVOR}   (or 'just build-containerfile' for kde)"
        fi
    fi
    ok "image: ${IMAGE}"
}

collect_admin_user() {
    local pw sshkey_path key_type key_blob
    ask ADMIN_USER "Admin username to create at first boot" "${USER:-arch}"
    [[ "${ADMIN_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || die "'${ADMIN_USER}' is not a valid Linux username."
    [ "${#ADMIN_USER}" -le 32 ] || die "Linux usernames must be 32 characters or fewer."
    ask_secret pw "Password for ${ADMIN_USER}"

    need_cmd openssl "Install openssl to hash the password."
    ADMIN_HASH="$(printf '%s\n' "${pw}" | openssl passwd -6 -stdin)"
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
        read -r key_type key_blob _ < "${sshkey_path}" || die "could not read ${sshkey_path}"
        case "${key_type}" in
            ssh-*|ecdsa-*|sk-*) ;;
            *) die "${sshkey_path} does not start with a recognized OpenSSH public-key type" ;;
        esac
        [[ "${key_blob}" =~ ^[A-Za-z0-9+/=]+$ ]] \
            || die "${sshkey_path} does not contain a valid public-key payload"
        # Comments are not needed for authorization and can contain YAML
        # metacharacters, so seed only the validated type and key payload.
        ADMIN_SSHKEY="${key_type} ${key_blob}"
        ok "SSH key will be installed for ${ADMIN_USER}"
    fi
}

# ------------------------------------------------------------- VM flow ---

flow_vm() {
    need_cmd sudo        "Install sudo."
    need_cmd virsh       "Install libvirt client tools."
    need_cmd virt-install "Install virt-install (package 'virt-install' or 'virt-manager')."
    need_cmd qemu-img    "Install qemu-img (package 'qemu-img' or 'qemu-utils')."
    need_cmd findmnt     "Install util-linux."
    need_cmd losetup     "Install util-linux."
    need_cmd realpath    "Install coreutils."
    need_cmd truncate    "Install coreutils."
    need_cmd mktemp      "Install coreutils."
    need_cmd install     "Install coreutils."
    need_cmd basename    "Install coreutils."
    find_iso_tool

    collect_image
    collect_admin_user

    step "VM settings"
    ask VM_NAME "VM name" "arch-bootc-quickstart"
    [[ "${VM_NAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
        || die "'${VM_NAME}' is not a safe single-label VM name/hostname.
    Use 1-63 letters, digits, or hyphens, starting with a letter or digit."
    assert_vm_name_free "${VM_NAME}"
    VM_HOSTNAME="${VM_NAME}"

    ask DISK_SIZE "Disk size (sparse -- reserves nothing up front)" "100G"
    ask VM_MEMORY "Memory in MiB" "8192"
    ask VM_VCPUS  "vCPUs" "4"
    [[ "${DISK_SIZE}" =~ ^[1-9][0-9]*[KMGTPE]?$ ]] \
        || die "disk size must be a positive integer with an optional K/M/G/T/P/E suffix"
    [[ "${VM_MEMORY}" =~ ^[1-9][0-9]*$ ]] || die "memory must be a positive number of MiB"
    [[ "${VM_VCPUS}" =~ ^[1-9][0-9]*$ ]] || die "vCPUs must be a positive integer"

    local default_dir="${REPO_ROOT}/output"
    ask WORK_DIR "Directory for the disk image" "${default_dir}"
    assert_not_tmpfs "${WORK_DIR}"
    WORK_DIR="$(realpath -m -- "${WORK_DIR}")"

    local raw="${WORK_DIR}/${VM_NAME}.raw"
    local qcow="${WORK_DIR}/${VM_NAME}.qcow2"
    local seed_iso="${WORK_DIR}/${VM_NAME}-seed.iso"
    local -a replace_outputs=()
    local existing

    # Collect overwrite consent now, but do not remove anything until after the
    # final summary and image pull. Aborting at either point must preserve all
    # pre-existing outputs.
    for existing in "${raw}" "${qcow}" "${seed_iso}"; do
        if [ -e "${existing}" ] || [ -L "${existing}" ]; then
            if [ ! -f "${existing}" ] && [ ! -L "${existing}" ]; then
                die "refusing to replace non-file output path: ${existing}"
            fi
            confirm "${existing} exists. Overwrite?" || die "aborted; nothing was changed."
            replace_outputs+=("${existing}")
        fi
    done

    step "Summary"
    info "image:      ${IMAGE}"
    info "VM:         ${VM_NAME} (${VM_MEMORY} MiB, ${VM_VCPUS} vCPU, qemu:///session)"
    info "disk:       ${qcow} (${DISK_SIZE}, sparse)"
    info "admin user: ${ADMIN_USER} (created by cloud-init at first boot)"
    if [ "${#replace_outputs[@]}" -gt 0 ]; then
        warn "the following existing outputs will be replaced only after final confirmation:"
        printf '      %s\n' "${replace_outputs[@]}"
    fi
    echo
    confirm "Proceed?" || die "aborted; nothing was changed."

    prepare_image

    for existing in "${replace_outputs[@]}"; do
        run rm -f -- "${existing}"
    done

    step "Creating sparse disk image"
    # truncate, not fallocate: this must stay sparse so "100G" costs only what
    # the install actually writes.
    run truncate -s "${DISK_SIZE}" -- "${raw}"
    [ "${DRY_RUN}" -eq 1 ] || chmod 600 "${raw}"

    step "Installing image to disk (via loopback)"
    info "This runs bootc install to-disk inside the image itself; it needs sudo."
    local install_status=0
    run sudo podman run --rm -it --privileged --pid=host --pull=never \
        --security-opt label=type:unconfined_t \
        -v /dev:/dev \
        -v "${WORK_DIR}:/data" \
        "${IMAGE}" \
        bootc install to-disk --composefs-backend --via-loopback \
        "/data/$(basename "${raw}")" --filesystem ext4 --wipe --bootloader systemd \
        || install_status=$?

    # The installer container releases its loop device on exit; make sure.
    if [ "${DRY_RUN}" -eq 0 ]; then
        local leaked_loops remaining_loops loopdev
        if ! leaked_loops="$(losetup -j "${raw}" -n -O NAME 2>/dev/null)"; then
            die "could not verify whether the installer released its loop device for ${raw}"
        fi
        if [ -n "${leaked_loops}" ]; then
            warn "the installer left loop devices attached to ${raw}; detaching only those exact devices"
            while IFS= read -r loopdev; do
                [ -n "${loopdev}" ] || continue
                run sudo losetup -d -- "${loopdev}"
            done <<< "${leaked_loops}"
            if ! remaining_loops="$(losetup -j "${raw}" -n -O NAME 2>/dev/null)"; then
                die "could not verify loop-device cleanup for ${raw}"
            fi
            [ -z "${remaining_loops}" ] \
                || die "loop devices still reference ${raw}: ${remaining_loops}"
        fi
    fi
    [ "${install_status}" -eq 0 ] \
        || die "bootc install failed with status ${install_status}; ${raw} was preserved for inspection"

    step "Converting to qcow2"
    run qemu-img convert -f raw -O qcow2 -S 4k "${raw}" "${qcow}"
    [ "${DRY_RUN}" -eq 1 ] || chmod 600 "${qcow}"
    run rm -f -- "${raw}"

    step "Building cloud-init seed"
    make_seed_iso "${WORK_DIR}" "${ADMIN_USER}" "${ADMIN_HASH}" "${ADMIN_SSHKEY}" "${seed_iso}"

    # Recheck immediately before creation in case another process claimed the
    # name while the image was installed and converted.
    assert_vm_name_free "${VM_NAME}"
    # virt-install can create a persistent, autostart storage pool for an
    # absolute disk path, even when it later fails. Snapshot before and inspect
    # afterward so that side effect is always named rather than hidden.
    local pools_before pools_after new_pools='' pool
    pools_before="$(list_session_pools)"

    step "Creating VM"
    local virt_install_status=0
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
        --noautoconsole \
        || virt_install_status=$?

    if [ "${DRY_RUN}" -eq 0 ]; then
        pools_after="$(list_session_pools)"
        while IFS= read -r pool; do
            [ -n "${pool}" ] || continue
            if ! grep -Fxq -- "${pool}" <<< "${pools_before}"; then
                new_pools+="${pool}"$'\n'
            fi
        done <<< "${pools_after}"
        new_pools="${new_pools%$'\n'}"
    fi

    if [ -n "${new_pools}" ]; then
        warn "virt-install created these qemu:///session storage pools:"
        while IFS= read -r pool; do
            info "  ${pool}"
            info "  virsh -c qemu:///session pool-destroy $(printf '%q' "${pool}")"
            info "  virsh -c qemu:///session pool-undefine $(printf '%q' "${pool}")"
        done <<< "${new_pools}"
        warn "pool removal is separate cleanup; inspect each pool before running those commands"
    elif [ "${DRY_RUN}" -eq 0 ]; then
        info "No new qemu:///session storage pool was detected."
    fi

    [ "${virt_install_status}" -eq 0 ] \
        || die "virt-install failed with status ${virt_install_status}; disk, seed ISO, and any reported pool were preserved"

    step "Done"
    if [ "${DRY_RUN}" -eq 1 ]; then
        ok "dry run complete; VM '${VM_NAME}' was not created and no files were changed."
        info "The commands above would create '${ADMIN_USER}' through cloud-init."
    else
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
        info "  rm -f $(printf '%q' "${qcow}") $(printf '%q' "${seed_iso}")"
    fi
}

# ------------------------------------------------------ bare-metal flow ---

flow_baremetal() {
    need_cmd sudo      "Install sudo."
    need_cmd lsblk     "Install util-linux."
    need_cmd findmnt   "Install util-linux."
    need_cmd readlink  "Install coreutils."
    need_cmd mktemp    "Install coreutils."
    need_cmd mount     "Install util-linux."
    need_cmd umount    "Install util-linux."
    need_cmd mountpoint "Install util-linux."
    need_cmd find      "Install findutils."
    need_cmd install   "Install coreutils."
    need_cmd tee       "Install coreutils."
    need_cmd awk       "Install awk."

    warn "Bare-metal install ERASES the target disk completely."
    echo

    step "Available block devices"
    lsblk -d -o NAME,SIZE,TYPE,MODEL | sed 's/^/    /'
    echo
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/    /'

    step "Target disk"
    local target_input target_identity
    ask target_input "Full device path to ERASE (e.g. /dev/nvme0n1)"
    if ! TARGET_DISK="$(readlink -f -- "${target_input}")"; then
        die "could not resolve '${target_input}' to a block device"
    fi
    [ "${target_input}" = "${TARGET_DISK}" ] \
        || info "resolved target: ${target_input} -> ${TARGET_DISK}"

    validate_baremetal_target "${TARGET_DISK}"
    if ! target_identity="$(block_identity "${TARGET_DISK}")" || [ -z "${target_identity}" ]; then
        die "could not capture a stable identity for ${TARGET_DISK}"
    fi
    info "target identity: ${target_identity}"

    collect_image
    collect_admin_user

    step "Confirm destruction"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "${TARGET_DISK}" | sed 's/^/    /'
    info "identity: ${target_identity}"
    echo
    local typed=''
    ask typed "Retype the resolved device path ${TARGET_DISK} exactly to confirm"
    [ "${typed}" = "${TARGET_DISK}" ] || die "'${typed}' does not match '${TARGET_DISK}'; aborted."
    typed=''
    read -r -p "    Type ERASE in capitals to proceed: " typed || die "input closed; aborted"
    [ "${typed}" = "ERASE" ] || die "aborted; nothing was changed."

    # Pulling can take minutes. Do it before the final identity and in-use
    # checks, then force the privileged installer command to use the local copy.
    prepare_image
    assert_target_identity "${target_input}" "${TARGET_DISK}" "${target_identity}"
    validate_baremetal_target "${TARGET_DISK}"

    step "Installing to ${TARGET_DISK}"
    run sudo podman run --rm -it --privileged --pid=host --pull=never \
        --security-opt label=type:unconfined_t \
        -v /dev:/dev \
        "${IMAGE}" \
        bootc install to-disk --composefs-backend "${TARGET_DISK}" \
        --filesystem ext4 --wipe --bootloader systemd

    step "Seeding cloud-init for the first admin user"
    # Query partition number 3 from lsblk rather than constructing a path from
    # the user's spelling; /dev/disk/by-id and other symlinks cannot be suffixed.
    local partitions rootpart rootparts
    if [ "${DRY_RUN}" -eq 1 ]; then
        info "(dry run) would discover partition number 3, mount it, and write the NoCloud seed"
    else
        if ! partitions="$(lsblk -nrpo NAME,PARTN -- "${TARGET_DISK}" 2>/dev/null)"; then
            die "could not inspect the new partition table on ${TARGET_DISK}"
        fi
        rootparts="$(awk '$2 == "3" { print $1 }' <<< "${partitions}")"
        if [ "$(printf '%s\n' "${rootparts}" | sed '/^$/d' | wc -l)" -ne 1 ]; then
            die "expected exactly one partition number 3 on ${TARGET_DISK}; found:
${rootparts:-      none}"
        fi
        rootpart="${rootparts}"
        info "root partition: ${rootpart}"
        [ -b "${rootpart}" ] || die "expected root partition ${rootpart} not found after install."
        BAREMETAL_MOUNT_DIR="$(mktemp -d)"
        sudo mount -- "${rootpart}" "${BAREMETAL_MOUNT_DIR}"
        # Bail rather than guess if the layout is not what we expect.
        local deploy deployments
        if ! deployments="$(sudo find "${BAREMETAL_MOUNT_DIR}/state/deploy" \
            -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)"; then
            die "could not inspect deployments under ${rootpart}:/state/deploy"
        fi
        if [ "$(printf '%s\n' "${deployments}" | sed '/^$/d' | wc -l)" -ne 1 ]; then
            die "expected exactly one deployment under ${rootpart}:/state/deploy; found:
${deployments:-      none}
    The install may have used a different layout; seed cloud-init manually --
    see docs/first-boot.md."
        fi
        deploy="${deployments}"
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
        sudo umount -- "${BAREMETAL_MOUNT_DIR}"
        rmdir -- "${BAREMETAL_MOUNT_DIR}"
        BAREMETAL_MOUNT_DIR=''
        ok "cloud-init seeded into the fresh deployment's /var"
    fi

    step "Done"
    if [ "${DRY_RUN}" -eq 1 ]; then
        ok "dry run complete; ${TARGET_DISK} was not changed."
    else
        ok "${TARGET_DISK} is installed."
        info "Reboot and select it. cloud-init creates '${ADMIN_USER}' during first boot."
        info "Keep Secure Boot disabled unless you manage your own signed boot chain."
    fi
}

# ------------------------------------------------------------------ main ---

usage() {
    cat <<'EOF'
arch-bootc quickstart -- guided install to a VM or bare metal.

Usage: scripts/quickstart.sh [--dry-run] [--help]

  --dry-run   Print every mutating command instead of running it. Prompts and
              read-only host validation still run, so device and VM collision
              checks remain real while no resources are changed.
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
        warn "dry run -- mutating commands are printed; read-only validation still executes"
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
