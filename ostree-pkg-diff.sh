#!/usr/bin/env bash
set -euo pipefail

# Compare package set between booted and previous ostree deployments.
# Output:
#   + pkg version      (added in current boot)
#   - pkg version      (removed from current boot)
#   ! pkg old -> new   (version changed)

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo --preserve-env=PATH bash "$0" "$@"
fi

cleanup_mnt_old=""
cleanup_mnt_new=""
cleanup_list_old=""
cleanup_list_new=""

cleanup() {
  if [[ -n "${cleanup_mnt_old}" ]] && mountpoint -q "${cleanup_mnt_old}" 2>/dev/null; then
    umount "${cleanup_mnt_old}" || true
  fi
  if [[ -n "${cleanup_mnt_new}" ]] && mountpoint -q "${cleanup_mnt_new}" 2>/dev/null; then
    umount "${cleanup_mnt_new}" || true
  fi
  [[ -n "${cleanup_mnt_old}" ]] && rmdir "${cleanup_mnt_old}" 2>/dev/null || true
  [[ -n "${cleanup_mnt_new}" ]] && rmdir "${cleanup_mnt_new}" 2>/dev/null || true
  [[ -n "${cleanup_list_old}" ]] && rm -f "${cleanup_list_old}" || true
  [[ -n "${cleanup_list_new}" ]] && rm -f "${cleanup_list_new}" || true
}

run_db_diff() {
  local old_db="$1"
  local new_db="$2"

  if [[ ! -d "${old_db}" || ! -d "${new_db}" ]]; then
    echo "Pacman DB path not found." >&2
    echo "old: ${old_db}" >&2
    echo "new: ${new_db}" >&2
    exit 1
  fi

  cleanup_list_old="$(mktemp)"
  cleanup_list_new="$(mktemp)"
  trap cleanup EXIT

  pacman --dbpath "${old_db}" -Q | sort >"${cleanup_list_old}"
  pacman --dbpath "${new_db}" -Q | sort >"${cleanup_list_new}"

  join -a1 -a2 -e "-" -o 0,1.2,2.2 "${cleanup_list_old}" "${cleanup_list_new}" | awk '
$2=="-" { printf("+ %s %s\n", $1, $3); next }
$3=="-" { printf("- %s %s\n", $1, $2); next }
$2!=$3   { printf("! %s %s -> %s\n", $1, $2, $3) }
'
}

# Composefs-native layout (common with modern bootc): use composefs image IDs.
composefs_id="$(tr ' ' '\n' </proc/cmdline | awk -F= '$1=="composefs" {print $2; exit}')"

composefs_root=""
for candidate in "${OSTREE_SYSROOT:-}" "/" "/sysroot" "/sysroot/state" "/mnt"; do
  [[ -n "${candidate}" ]] || continue
  root="${candidate%/}"
  [[ -n "${root}" ]] || root="/"
  if [[ -d "${root%/}/composefs/images" && -d "${root%/}/state/deploy" ]]; then
    composefs_root="${root}"
    break
  fi
done

if [[ -n "${composefs_id}" && -n "${composefs_root}" ]]; then
  composefs_images="${composefs_root%/}/composefs/images"
  state_deploy="${composefs_root%/}/state/deploy"

  current="${composefs_id}"
  if [[ ! -e "${composefs_images}/${current}" ]]; then
    echo "Current composefs image id from kernel args not found: ${current}" >&2
    exit 1
  fi

  previous="$(find "${state_deploy}" -mindepth 1 -maxdepth 1 -type d -printf '%f %T@\n' \
    | sort -k2,2nr \
    | awk -v current="${current}" '$1!=current {print $1; exit}')"
  if [[ -z "${previous}" ]]; then
    echo "No previous deployment found under ${state_deploy}." >&2
    exit 1
  fi
  if [[ ! -e "${composefs_images}/${previous}" ]]; then
    echo "Previous deployment '${previous}' has no matching ${composefs_images} entry." >&2
    exit 1
  fi

  current_img="$(readlink -f "${composefs_images}/${current}")"
  previous_img="$(readlink -f "${composefs_images}/${previous}")"
  if [[ ! -f "${current_img}" || ! -f "${previous_img}" ]]; then
    echo "Unable to resolve composefs image files." >&2
    echo "current: ${current_img}" >&2
    echo "previous: ${previous_img}" >&2
    exit 1
  fi

  cleanup_mnt_old="$(mktemp -d)"
  cleanup_mnt_new="$(mktemp -d)"
  trap cleanup EXIT

  mount -t erofs -o loop,ro "${previous_img}" "${cleanup_mnt_old}"
  mount -t erofs -o loop,ro "${current_img}" "${cleanup_mnt_new}"

  run_db_diff "${cleanup_mnt_old}/usr/lib/sysimage/lib/pacman" "${cleanup_mnt_new}/usr/lib/sysimage/lib/pacman"
  exit 0
fi

# Ostree-repo layout fallback.
if [[ -n "${OSTREE_SYSROOT:-}" ]]; then
  sysroot="${OSTREE_SYSROOT%/}"
  [[ -n "${sysroot}" ]] || sysroot="/"
elif [[ -d "/sysroot/ostree/repo" ]]; then
  sysroot="/sysroot"
elif [[ -d "/ostree/repo" ]]; then
  sysroot="/"
elif [[ -d "/mnt/ostree/repo" ]]; then
  sysroot="/mnt"
elif [[ -d "/sysroot/state/ostree/repo" ]]; then
  sysroot="/sysroot/state"
else
  repo_guess="$(find / -maxdepth 5 -type d -path '*/ostree/repo' 2>/dev/null | head -n1 || true)"
  if [[ -n "${repo_guess}" ]]; then
    sysroot="${repo_guess%/ostree/repo}"
    [[ -n "${sysroot}" ]] || sysroot="/"
  else
    echo "No composefs deployment layout or ostree repo found." >&2
    echo "Set OSTREE_SYSROOT=/path if your repo lives elsewhere." >&2
    exit 1
  fi
fi

os=""
boot=""
last=""

if status="$(ostree admin --sysroot="${sysroot}" status 2>/dev/null)"; then
  os="$(awk '/^\*/{print $2; exit}' <<<"${status}")"
  boot="$(awk '/^\*/{print $3; exit}' <<<"${status}")"

  if [[ -n "${os}" && -n "${boot}" ]]; then
    last="$(awk -v os="${os}" '$1==os && /\(rollback\)/ {print $2; exit}' <<<"${status}")"
    if [[ -z "${last}" ]]; then
      last="$(awk -v os="${os}" -v boot="${boot}" '$1==os && $2!=boot {print $2; exit}' <<<"${status}")"
    fi
  fi
fi

if [[ -z "${os}" || -z "${boot}" ]]; then
  ostree_karg="$(tr ' ' '\n' </proc/cmdline | awk -F= '$1=="ostree" {print $2; exit}')"
  if [[ "${ostree_karg}" =~ ^/ostree/boot\.[0-9]+/([^/]+)/([^/]+)/([0-9]+)$ ]]; then
    os="${BASH_REMATCH[1]}"
    boot="${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  fi
fi

if [[ -z "${os}" || -z "${boot}" ]]; then
  echo "Failed to determine booted deployment for ostree layout." >&2
  exit 1
fi

if [[ -z "${last}" ]]; then
  base_probe="${sysroot%/}/ostree/deploy/${os}/deploy"
  if [[ -d "${base_probe}" ]]; then
    last="$(find "${base_probe}" -mindepth 1 -maxdepth 1 -type d -printf '%f %T@\n' \
      | sort -k2,2nr \
      | awk -v boot="${boot}" '$1!=boot {print $1; exit}')"
  fi
fi

if [[ -z "${last}" ]]; then
  echo "No previous deployment found for stateroot '${os}'." >&2
  exit 1
fi

base="${sysroot%/}/ostree/deploy/${os}/deploy"
run_db_diff "${base}/${last}/usr/lib/sysimage/lib/pacman" "${base}/${boot}/usr/lib/sysimage/lib/pacman"
