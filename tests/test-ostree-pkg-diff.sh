#!/usr/bin/env bash
set -uo pipefail

# Tests for system_files/usr/bin/ostree-pkg-diff: its pure helpers, and the
# deployment discovery below the "real program" marker.
#
# The script splits into two halves: parsing helpers at the top, then a "real
# program" marker after which everything mounts erofs images, shells out to
# pacman, and re-executes itself under sudo. Sourcing returns at that marker, so
# the helper tests get the helpers without any of that -- no root, no mounts, no
# loop devices, no pacman, no network.
#
# test_sourcing_does_not_run_the_program below is what keeps that true. If the
# guard is ever removed, sourcing this script as a non-root user would exec
# sudo, so that test runs the source through a stub `sudo` on PATH rather than
# risking a real password prompt in the middle of a test run.
#
# The "whole-program deployment discovery" section at the end runs the other
# half -- the half sourcing deliberately skips -- as a program, in a user and
# mount namespace with every system command stubbed. See the block comment
# there for why a namespace is the only way in and what it does and does not
# grant. It still takes no real privilege, mounts no real filesystem, opens no
# loop device and reads no real package database.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PKG_DIFF="${REPO_ROOT}/system_files/usr/bin/ostree-pkg-diff"

# Set up cleanup and a fail-closed sudo stub before sourcing the production
# script. If its sourcing guard ever regresses, the script must hit this stub
# rather than re-execing the test through the host's real sudo.
cleanup_work_dir() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
WORK_DIR="$(mktemp -d)"
trap cleanup_work_dir EXIT

SOURCE_STUB_DIR="${WORK_DIR}/source-stub-bin"
mkdir -p "${SOURCE_STUB_DIR}"
printf '#!/usr/bin/env bash\necho SUDO_WAS_CALLED >&2\nexit 97\n' \
  >"${SOURCE_STUB_DIR}/sudo"
chmod +x "${SOURCE_STUB_DIR}/sudo"
PATH="${SOURCE_STUB_DIR}:${PATH}"

# The path is built at runtime, so shellcheck cannot follow it without -x; the
# source= hint below is for anyone who does run it that way.
# shellcheck source=../system_files/usr/bin/ostree-pkg-diff disable=SC1091
source "${PKG_DIFF}"
# The script sets -e for its own use as a program. Tests deliberately run
# helpers that are expected to fail or produce nothing, so turn it back off
# immediately; leaving it on aborts the run at the first such assertion.
set +e

failures=0
tests_run=0

fail() {
  printf 'not ok - %s\n' "$*" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'ok - %s\n' "$*"
}

check() {
  # check <description> <condition-result> [detail...]
  local desc="$1" result="$2"
  shift 2
  tests_run=$((tests_run + 1))
  if [[ "${result}" == "0" ]]; then
    pass "${desc}"
  else
    fail "${desc}${*:+: $*}"
  fi
}

# Record an assertion that could not be attempted here. It counts as run and
# does not fail the suite, and the reason goes to stderr as well as into the
# TAP line so a run that quietly stopped exercising something is visible in the
# job log rather than only in a diff of the assertion count.
skip() {
  local desc="$1" reason="$2"
  tests_run=$((tests_run + 1))
  printf 'ok - %s # SKIP %s\n' "${desc}" "${reason}"
  printf 'SKIPPED: %s: %s\n' "${desc}" "${reason}" >&2
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "expected '${expected}', got '${actual}'"
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "${actual}" ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "expected no output, got '${actual}'"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    check "${desc}" 0
  else
    check "${desc}" 1 "output did not contain '${needle}'; got: ${haystack}"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    check "${desc}" 1 "output unexpectedly contained '${needle}'; got: ${haystack}"
  else
    check "${desc}" 0
  fi
}

# A stub only creates its log when it is called, so the absence of the file is
# the assertion that the command was never run.
assert_missing() {
  local desc="$1" path="$2"
  if [[ -e "${path}" ]]; then
    check "${desc}" 1 "${path} exists: $(tr '\n' '|' <"${path}")"
  else
    check "${desc}" 0
  fi
}

# Write a /proc/cmdline fixture (single space-separated line) and print its path.
write_cmdline() {
  # Separate `local` statements on purpose: bash expands every right-hand side
  # in a single `local` before binding any of the names, so a later one cannot
  # refer to an earlier one -- under `set -u` that is an unbound-variable error.
  local name="$1" content="$2"
  local path="${WORK_DIR}/${name}"
  printf '%s\n' "${content}" >"${path}"
  printf '%s\n' "${path}"
}

# Write a `pacman -Q` listing fixture and print its path. Sorted on the way in
# with the same `sort` the script itself uses, because join only pairs lines
# when both inputs are ordered the same way.
write_list() {
  local name="$1"
  local path="${WORK_DIR}/${name}"
  shift
  if (($# > 0)); then
    printf '%s\n' "$@" | sort >"${path}"
  else
    : >"${path}"
  fi
  printf '%s\n' "${path}"
}

# A representative `ostree admin status` output: booted entry marked with `*`,
# rollback entry marked `(rollback)`, indented detail lines in between.
STATUS_TYPICAL="$(
  cat <<'EOF'
* arch e4f2c1a0b3d5.0
    Version: 20260903.0
    origin: <unknown origin type>
  arch 9a8b7c6d5e4f.1 (rollback)
    Version: 20260902.0
    origin: <unknown origin type>
EOF
)"

# --- karg_value ------------------------------------------------------------

test_karg_value_reads_composefs() {
  local cmdline
  cmdline="$(write_cmdline composefs-cmdline \
    'root=UUID=1234 composefs=abc123def456 rw quiet')"
  assert_eq "composefs= value is extracted" \
    "abc123def456" "$(karg_value composefs "${cmdline}")"
}

test_karg_value_reads_ostree() {
  local cmdline
  cmdline="$(write_cmdline ostree-cmdline \
    'BOOT_IMAGE=/vmlinuz ostree=/ostree/boot.1/arch/abc123/0 rw')"
  assert_eq "ostree= value is extracted" \
    "/ostree/boot.1/arch/abc123/0" "$(karg_value ostree "${cmdline}")"
}

test_karg_value_absent_key_is_empty() {
  local cmdline
  cmdline="$(write_cmdline plain-cmdline 'root=UUID=1234 rw quiet')"
  assert_empty "absent key yields no value" "$(karg_value composefs "${cmdline}")"
}

test_karg_value_does_not_match_suffixed_key() {
  # rd.composefs= must not satisfy a lookup of composefs=; the parse splits on
  # `=` and compares the whole key, and this is what keeps that honest.
  local cmdline
  cmdline="$(write_cmdline suffixed-cmdline 'rd.composefs=nope rw')"
  assert_empty "a longer key ending in the same name does not match" \
    "$(karg_value composefs "${cmdline}")"
}

test_karg_value_bare_flag_has_no_value() {
  local cmdline
  cmdline="$(write_cmdline bare-cmdline 'quiet composefs rw')"
  assert_empty "a bare key with no = yields no value" \
    "$(karg_value composefs "${cmdline}")"
}

test_karg_value_takes_first_occurrence() {
  # Pins existing behaviour rather than endorsing it: the parse stops at the
  # first match, so a duplicated key resolves to the earlier one.
  local cmdline
  cmdline="$(write_cmdline dup-cmdline 'composefs=first rw composefs=second')"
  assert_eq "a repeated key resolves to the first occurrence" \
    "first" "$(karg_value composefs "${cmdline}")"
}

test_karg_value_missing_file_is_empty() {
  assert_empty "an unreadable cmdline file yields no value" \
    "$(karg_value composefs "${WORK_DIR}/does-not-exist")"
}

# --- parse_ostree_karg -----------------------------------------------------

test_parse_ostree_karg_splits_os_and_boot() {
  assert_eq "ostree karg splits into stateroot and deployment id" \
    "arch abc123.0" "$(parse_ostree_karg /ostree/boot.1/arch/abc123/0)"
}

test_parse_ostree_karg_multi_digit_boot_index() {
  assert_eq "multi-digit boot.N is accepted" \
    "arch abc123.2" "$(parse_ostree_karg /ostree/boot.12/arch/abc123/2)"
}

test_parse_ostree_karg_rejects_wrong_prefix() {
  assert_empty "a non-ostree path is rejected" \
    "$(parse_ostree_karg /boot/vmlinuz-linux)"
}

test_parse_ostree_karg_rejects_non_numeric_serial() {
  assert_empty "a non-numeric serial is rejected" \
    "$(parse_ostree_karg /ostree/boot.1/arch/abc123/x)"
}

test_parse_ostree_karg_rejects_extra_segments() {
  assert_empty "a path with extra segments is rejected" \
    "$(parse_ostree_karg /ostree/boot.1/arch/abc123/0/extra)"
}

test_parse_ostree_karg_rejects_empty() {
  assert_empty "an empty karg is rejected" "$(parse_ostree_karg "")"
}

# --- ostree admin status parsing -------------------------------------------

test_status_booted_fields() {
  assert_eq "booted stateroot is read from the * line" \
    "arch" "$(status_booted_os "${STATUS_TYPICAL}")"
  assert_eq "booted deployment id is read from the * line" \
    "e4f2c1a0b3d5.0" "$(status_booted_boot "${STATUS_TYPICAL}")"
}

test_status_booted_when_not_first_entry() {
  local status
  status="$(
    cat <<'EOF'
  arch 9a8b7c6d5e4f.1
    Version: 20260902.0
* arch e4f2c1a0b3d5.0
    Version: 20260903.0
EOF
  )"
  assert_eq "booted stateroot found when * is not the first entry" \
    "arch" "$(status_booted_os "${status}")"
  assert_eq "booted id found when * is not the first entry" \
    "e4f2c1a0b3d5.0" "$(status_booted_boot "${status}")"
}

test_status_booted_absent_marker_is_empty() {
  local status
  status="$(printf '  arch 9a8b7c6d5e4f.1\n    Version: 20260902.0\n')"
  assert_empty "no * line yields no stateroot" "$(status_booted_os "${status}")"
  assert_empty "no * line yields no deployment id" "$(status_booted_boot "${status}")"
}

test_status_previous_prefers_rollback_marker() {
  assert_eq "the (rollback) entry is chosen as previous" \
    "9a8b7c6d5e4f.1" \
    "$(status_previous "${STATUS_TYPICAL}" arch e4f2c1a0b3d5.0)"
}

test_status_previous_prefers_rollback_over_earlier_entry() {
  # The rollback marker wins even when a different non-booted deployment of the
  # same stateroot is listed ahead of it.
  local status
  status="$(
    cat <<'EOF'
* arch aaaaaaaa.0
  arch bbbbbbbb.1
  arch cccccccc.2 (rollback)
EOF
  )"
  assert_eq "marked rollback beats an earlier unmarked entry" \
    "cccccccc.2" "$(status_previous "${status}" arch aaaaaaaa.0)"
}

test_status_previous_falls_back_to_first_other_deployment() {
  local status
  status="$(
    cat <<'EOF'
* arch aaaaaaaa.0
    Version: 20260903.0
  arch bbbbbbbb.1
    Version: 20260902.0
EOF
  )"
  assert_eq "unmarked previous deployment is used when no rollback marker" \
    "bbbbbbbb.1" "$(status_previous "${status}" arch aaaaaaaa.0)"
}

test_status_previous_ignores_other_stateroots() {
  local status
  status="$(
    cat <<'EOF'
* arch aaaaaaaa.0
  fedora dddddddd.0
  arch bbbbbbbb.1
EOF
  )"
  assert_eq "a different stateroot is not a rollback candidate" \
    "bbbbbbbb.1" "$(status_previous "${status}" arch aaaaaaaa.0)"
}

test_status_previous_single_deployment_is_empty() {
  local status
  status="$(printf '* arch aaaaaaaa.0\n    Version: 20260903.0\n')"
  assert_empty "a sole deployment has no previous" \
    "$(status_previous "${status}" arch aaaaaaaa.0)"
}

# --- emit_pkg_diff ---------------------------------------------------------

test_emit_pkg_diff_reports_each_change_kind() {
  local old new expected
  old="$(write_list old-mixed 'bash 5.2' 'coreutils 9.5' 'vim 9.1')"
  new="$(write_list new-mixed 'bash 5.2' 'coreutils 9.6' 'zsh 5.9')"
  expected="$(printf '%s\n' '! coreutils 9.5 -> 9.6' '- vim 9.1' '+ zsh 5.9')"
  assert_eq "upgrade, removal and addition are each reported" \
    "${expected}" "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_identical_lists_are_silent() {
  local old new
  old="$(write_list old-same 'bash 5.2' 'coreutils 9.5')"
  new="$(write_list new-same 'bash 5.2' 'coreutils 9.5')"
  assert_empty "identical package sets produce no output" \
    "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_empty_old_list_is_all_additions() {
  local old new expected
  old="$(write_list old-empty)"
  new="$(write_list new-only 'bash 5.2' 'vim 9.1')"
  expected="$(printf '%s\n' '+ bash 5.2' '+ vim 9.1')"
  assert_eq "every package is an addition against an empty old list" \
    "${expected}" "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_empty_new_list_is_all_removals() {
  local old new expected
  old="$(write_list old-only 'bash 5.2' 'vim 9.1')"
  new="$(write_list new-empty)"
  expected="$(printf '%s\n' '- bash 5.2' '- vim 9.1')"
  assert_eq "every package is a removal against an empty new list" \
    "${expected}" "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_both_empty_is_silent() {
  local old new
  old="$(write_list old-both-empty)"
  new="$(write_list new-both-empty)"
  assert_empty "two empty lists produce no output" \
    "$(emit_pkg_diff "${old}" "${new}")"
}

test_emit_pkg_diff_downgrade_is_reported() {
  local old new
  old="$(write_list old-downgrade 'linux 6.11')"
  new="$(write_list new-downgrade 'linux 6.10')"
  assert_eq "a version going backwards is still reported as a change" \
    "! linux 6.11 -> 6.10" "$(emit_pkg_diff "${old}" "${new}")"
}

# --- run_db_diff guard -----------------------------------------------------
#
# run_db_diff calls exit on a bad path, so each of these runs it in a subshell.
# Only the guard is exercised; past it the function shells out to pacman.

test_run_db_diff_rejects_missing_old_db() {
  local output status
  output="$( (run_db_diff "${WORK_DIR}/nope" "${WORK_DIR}") 2>&1 )"
  status=$?
  assert_eq "a missing old DB path exits 1" "1" "${status}"
  assert_contains "a missing old DB path is reported" \
    "${output}" "Pacman DB path not found."
}

test_run_db_diff_rejects_missing_new_db() {
  local output status
  output="$( (run_db_diff "${WORK_DIR}" "${WORK_DIR}/nope") 2>&1 )"
  status=$?
  assert_eq "a missing new DB path exits 1" "1" "${status}"
  assert_contains "a missing new DB path is reported" \
    "${output}" "Pacman DB path not found."
}

# --- whole-program deployment discovery ------------------------------------
#
# Everything below the "real program" marker -- the EUID gate, the composefs
# layout branch and the ostree-repo fallback -- decides which two deployments
# get compared, and sourcing skips every line of it. These cases run the
# program instead.
#
# Three things stand between a test and that half of the script, and each has
# exactly one answer:
#
#   * The script re-executes itself under sudo when EUID is not 0.
#     `unshare --map-root-user` makes EUID 0 inside a user namespace, so the
#     program does its work in process. That grants no privilege over anything
#     outside the namespace -- the only uid mapped into it is the unprivileged
#     one already running the suite.
#   * `karg_value composefs` is called with no path argument, so it reads
#     /proc/cmdline, and the host's own kernel arguments would decide which
#     branch the program takes. `--mount` adds a mount namespace, and a bind
#     mount puts a fixture at that path for this process tree only.
#   * Every branch ends in mount, pacman or ostree. Each is a stub earlier on
#     PATH, so nothing is mounted for real, no loop device is opened and no
#     package database is read. TMPDIR points into the per-case directory, so
#     the mount points the program creates with `mktemp -d` are cleaned up with
#     the rest of the fixtures.
#
# A kernel can refuse to create either namespace (unprivileged user namespaces
# are disableable, and some sandboxes do disable them). These cases then skip
# loudly rather than reporting a pass they never attempted.

# True when this host lets an unprivileged user create the user and mount
# namespaces the cases below need. On failure NAMESPACE_ERROR carries what the
# kernel actually said, because "namespaces are unavailable" is not a diagnosis:
# a missing unshare, a refused user namespace and a refused mount namespace are
# three different problems with three different answers, and the skip reason is
# the only place a CI log will ever show which one it hit.
NAMESPACE_ERROR=""

namespaces_available() {
  if ! command -v unshare >/dev/null 2>&1; then
    NAMESPACE_ERROR="unshare is not installed"
    return 1
  fi
  local message
  if ! message="$(unshare --map-root-user true 2>&1)"; then
    NAMESPACE_ERROR="user namespace refused: ${message:-no message}"
    return 1
  fi
  if ! message="$(unshare --map-root-user --mount true 2>&1)"; then
    NAMESPACE_ERROR="mount namespace refused: ${message:-no message}"
    return 1
  fi
  return 0
}

# Create a per-case directory under WORK_DIR and print its path.
case_dir() {
  local path="${WORK_DIR}/$1"
  mkdir -p "${path}"
  printf '%s\n' "${path}"
}

# Write an executable stub of ${name} into ${dir}, with its body on stdin. Each
# stub resolves its own directory into ${stub_dir}, so it can log its argv and
# read its fixtures without any path being interpolated into it here.
write_stub() {
  local dir="$1" name="$2"
  {
    printf '#!/usr/bin/env bash\n'
    # Written verbatim into the stub, to be expanded when the stub runs -- so
    # the single quotes are the point.
    # shellcheck disable=SC2016
    printf 'stub_dir="$(cd -- "$(dirname -- "$0")" && pwd)"\n'
    cat
  } >"${dir}/${name}"
  chmod +x "${dir}/${name}"
}

# Install the stubs for every system command the program half can reach.
write_program_stubs() {
  local dir="$1"
  mkdir -p "${dir}"

  # Records the mount and populates the mount point the way an erofs image
  # would: the package database the image carries is the `.listing` file beside
  # the image, so a case controls what the program will read by writing that.
  write_stub "${dir}" mount <<'STUB'
args=("$@")
printf '%s\n' "$*" >>"${stub_dir}/mount.argv"
image="${args[$# - 2]}"
target="${args[$# - 1]}"
mkdir -p "${target}/usr/lib/sysimage/lib/pacman"
if [[ -f "${image}.listing" ]]; then
  cp "${image}.listing" "${target}/usr/lib/sysimage/lib/pacman/listing"
fi
STUB

  # Nothing is really mounted, so the honest answer is "not a mount point".
  # cleanup() then takes its skip-the-umount path.
  write_stub "${dir}" mountpoint <<'STUB'
printf '%s\n' "$*" >>"${stub_dir}/mountpoint.argv"
exit 1
STUB

  write_stub "${dir}" umount <<'STUB'
printf '%s\n' "$*" >>"${stub_dir}/umount.argv"
STUB

  # Replays the `listing` file of whichever fake database it was handed.
  write_stub "${dir}" pacman <<'STUB'
printf '%s\n' "$*" >>"${stub_dir}/pacman.argv"
dbpath=""
while (($#)); do
  case "$1" in
    --dbpath)
      dbpath="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "${dbpath}" ]] || exit 1
cat "${dbpath}/listing"
STUB

  # `ostree admin status` succeeds with the fixture a case wrote, and fails the
  # way it does on a host with no ostree repo when no case wrote one.
  write_stub "${dir}" ostree <<'STUB'
printf '%s\n' "$*" >>"${stub_dir}/ostree.argv"
if [[ -f "${stub_dir}/ostree.status" ]]; then
  cat "${stub_dir}/ostree.status"
  exit 0
fi
exit 1
STUB

  # Fail-closed: inside the namespace EUID is 0, so the program must never
  # reach its sudo re-exec. If it does, this makes that visible as a failed
  # assertion instead of a password prompt.
  write_stub "${dir}" sudo <<'STUB'
echo SUDO_WAS_CALLED >&2
exit 97
STUB
}

# Build a composefs deployment layout under ${root}: one image file and one
# state/deploy entry per id.
write_composefs_layout() {
  local root="$1"
  shift
  mkdir -p "${root}/composefs/images" "${root}/state/deploy"
  local id
  for id in "$@"; do
    printf 'erofs image %s\n' "${id}" >"${root}/composefs/images/${id}"
    mkdir -p "${root}/state/deploy/${id}"
  done
}

# Build an ostree-repo deployment layout under ${root}: the repo directory the
# sysroot probes look for, plus a pacman database directory per deployment id.
write_ostree_layout() {
  local root="$1" os="$2"
  shift 2
  mkdir -p "${root}/ostree/repo"
  local id
  for id in "$@"; do
    mkdir -p "${root}/ostree/deploy/${os}/deploy/${id}/usr/lib/sysimage/lib/pacman"
  done
}

# Write a `pacman -Q` listing, deliberately unordered: run_db_diff pipes pacman
# through `sort` precisely so that `join` sees ordered input, and unordered
# fixtures are what proves that sort is still in the pipeline.
write_db_listing() {
  local path="$1"
  shift
  mkdir -p "$(dirname -- "${path}")"
  printf '%s\n' "$@" >"${path}"
}

# Path of the listing an ostree-layout deployment's fake pacman database serves.
ostree_db_listing() {
  local root="$1" os="$2" id="$3"
  printf '%s\n' "${root}/ostree/deploy/${os}/deploy/${id}/usr/lib/sysimage/lib/pacman/listing"
}

# Run ostree-pkg-diff as a program with ${cmdline} bound over /proc/cmdline and
# ${stub_bin} first on PATH. When ${mnt_source} is non-empty its contents are
# copied onto a namespace-local tmpfs at /mnt, and /sysroot and /ostree are
# masked with empty tmpfs mounts, so the sysroot probe resolves to /mnt no
# matter what the host has at those paths. Remaining arguments are NAME=value
# pairs put into the program's environment. Prints the program's combined
# output and returns its exit status -- a global would not survive, because
# every caller runs this inside a command substitution.
run_program() {
  local cmdline="$1" stub_bin="$2" tmp_dir="$3" mnt_source="$4"
  shift 4
  mkdir -p "${tmp_dir}"
  local output
  # The bash -c body is a program for the shell inside the namespace, and its
  # positional parameters are the ones passed after it, so it must reach that
  # shell unexpanded.
  # shellcheck disable=SC2016
  output="$(
    unshare --map-root-user --mount \
      env "$@" "TMPDIR=${tmp_dir}" \
      "${BASH}" -c '
        # Before PATH is redirected at the stubs, so this is the real mount.
        mount --bind "$1" /proc/cmdline || exit 99
        if [[ -n "$4" ]]; then
          for masked in /sysroot /ostree; do
            if [[ -d "${masked}" ]]; then
              mount -t tmpfs none "${masked}" || exit 98
            fi
          done
          mount -t tmpfs none /mnt || exit 98
          cp -a "$4/." /mnt/ || exit 98
        fi
        PATH="$2:${PATH}"
        # "$5", not a bare `bash`: run-tests.sh hands every test file the one
        # interpreter the run is reporting on, and the program under test has
        # to be run by it too.
        exec "$5" "$3"
      ' _ "${cmdline}" "${stub_bin}" "${PKG_DIFF}" "${mnt_source}" "${BASH}" 2>&1
  )"
  local status=$?
  printf '%s\n' "${output}"
  return "${status}"
}

test_program_composefs_diffs_previous_against_booted() {
  local dir bin root cmdline output first_mount second_mount status
  dir="$(case_dir composefs-happy)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  write_program_stubs "${bin}"
  write_composefs_layout "${root}" old111 new222
  write_db_listing "${root}/composefs/images/old111.listing" \
    'kept 1.0' 'gone 2.0' 'bumped 1.0'
  write_db_listing "${root}/composefs/images/new222.listing" \
    'kept 1.0' 'bumped 2.0' 'added 3.0'
  cmdline="$(write_cmdline composefs-happy-cmdline \
    'root=UUID=1234 composefs=new222 rw quiet')"

  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "" \
    "OSTREE_SYSROOT=${root}")"
  status=$?

  assert_eq "a composefs layout diff exits 0" "0" "${status}"
  assert_contains "the package added in the booted image is reported" \
    "${output}" "+ added 3.0"
  assert_contains "the package dropped since the previous image is reported" \
    "${output}" "- gone 2.0"
  assert_contains "the upgraded package is reported" \
    "${output}" "! bumped 1.0 -> 2.0"
  assert_not_contains "an unchanged package is not reported" \
    "${output}" "kept"

  first_mount="$(sed -n 1p "${bin}/mount.argv")"
  second_mount="$(sed -n 2p "${bin}/mount.argv")"
  assert_contains "the previous image is mounted first, as the old side" \
    "${first_mount}" "old111"
  assert_contains "the booted image is mounted second, as the new side" \
    "${second_mount}" "new222"
  assert_contains "the images are mounted read-only through a loop device" \
    "${first_mount}" "-o loop,ro"
  assert_contains "the images are mounted as erofs" "${first_mount}" "-t erofs"
  assert_eq "exactly two images are mounted" \
    "2" "$(wc -l <"${bin}/mount.argv")"
}

test_program_composefs_rejects_an_unknown_booted_image() {
  local dir bin root cmdline output status
  dir="$(case_dir composefs-unknown-current)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  write_program_stubs "${bin}"
  write_composefs_layout "${root}" old111 new222
  cmdline="$(write_cmdline composefs-unknown-cmdline \
    'root=UUID=1234 composefs=missing999 rw')"

  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "" \
    "OSTREE_SYSROOT=${root}")"
  status=$?

  assert_eq "a composefs id with no image exits 1" "1" "${status}"
  assert_contains "the unresolvable composefs id is named" \
    "${output}" "Current composefs image id from kernel args not found: missing999"
}

test_program_composefs_rejects_a_sole_deployment() {
  local dir bin root cmdline output status
  dir="$(case_dir composefs-sole-deployment)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  write_program_stubs "${bin}"
  write_composefs_layout "${root}" new222
  cmdline="$(write_cmdline composefs-sole-cmdline \
    'root=UUID=1234 composefs=new222 rw')"

  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "" \
    "OSTREE_SYSROOT=${root}")"
  status=$?

  assert_eq "nothing to diff against exits 1" "1" "${status}"
  assert_contains "the searched deployment directory is named" \
    "${output}" "No previous deployment found under ${root}/state/deploy."
}

test_program_composefs_rejects_a_previous_without_an_image() {
  local dir bin root cmdline output status
  dir="$(case_dir composefs-orphan-previous)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  write_program_stubs "${bin}"
  write_composefs_layout "${root}" new222
  # A deployment directory whose image has already been pruned: the state entry
  # is the newest thing that is not the booted one, so it is selected, and the
  # image lookup is what has to catch it.
  mkdir -p "${root}/state/deploy/orphan333"
  cmdline="$(write_cmdline composefs-orphan-cmdline \
    'root=UUID=1234 composefs=new222 rw')"

  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "" \
    "OSTREE_SYSROOT=${root}")"
  status=$?

  assert_eq "a previous deployment with no image exits 1" "1" "${status}"
  assert_contains "the deployment missing an image is named" \
    "${output}" "Previous deployment 'orphan333' has no matching"
}

test_program_composefs_rejects_an_image_that_is_not_a_file() {
  local dir bin root cmdline output status
  dir="$(case_dir composefs-unresolvable-image)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  write_program_stubs "${bin}"
  write_composefs_layout "${root}" new222
  # Present to `-e`, so the two existence checks above pass, but not a file to
  # mount. Only the `-f` check on the resolved path stands between this and a
  # mount call.
  mkdir -p "${root}/composefs/images/dir444" "${root}/state/deploy/dir444"
  cmdline="$(write_cmdline composefs-unresolvable-cmdline \
    'root=UUID=1234 composefs=new222 rw')"

  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "" \
    "OSTREE_SYSROOT=${root}")"
  status=$?

  assert_eq "an image that is not a file exits 1" "1" "${status}"
  assert_contains "the unresolved image paths are reported" \
    "${output}" "Unable to resolve composefs image files."
  assert_missing "no mount is attempted for an unresolvable image" \
    "${bin}/mount.argv"
}

test_program_ostree_layout_diffs_the_rollback_deployment() {
  local dir bin root cmdline output status
  dir="$(case_dir ostree-rollback)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  write_program_stubs "${bin}"
  printf '%s\n' "${STATUS_TYPICAL}" >"${bin}/ostree.status"
  write_ostree_layout "${root}" arch e4f2c1a0b3d5.0 9a8b7c6d5e4f.1
  write_db_listing "$(ostree_db_listing "${root}" arch 9a8b7c6d5e4f.1)" \
    'kept 1.0' 'gone 2.0'
  write_db_listing "$(ostree_db_listing "${root}" arch e4f2c1a0b3d5.0)" \
    'kept 1.0' 'added 3.0'
  cmdline="$(write_cmdline ostree-rollback-cmdline 'root=UUID=1234 rw quiet')"

  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "" \
    "OSTREE_SYSROOT=${root}")"
  status=$?

  assert_eq "an ostree-layout diff exits 0" "0" "${status}"
  assert_contains "ostree admin status is asked about the resolved sysroot" \
    "$(cat "${bin}/ostree.argv")" "admin --sysroot=${root} status"
  assert_contains "the rollback deployment supplies the old package set" \
    "${output}" "- gone 2.0"
  assert_contains "the booted deployment supplies the new package set" \
    "${output}" "+ added 3.0"
  assert_contains "the rollback deployment's database is the one queried" \
    "$(cat "${bin}/pacman.argv")" \
    "$(dirname -- "$(ostree_db_listing "${root}" arch 9a8b7c6d5e4f.1)")"
}

test_program_ostree_layout_falls_back_to_the_kernel_argument() {
  local dir bin root cmdline output status
  dir="$(case_dir ostree-karg-fallback)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  # No ostree.status fixture: `ostree admin status` fails, the way it does when
  # the binary is missing or the sysroot is not one it understands. The booted
  # deployment then has to come from the kernel command line.
  write_program_stubs "${bin}"
  write_ostree_layout "${root}" arch abc123.0 def456.1
  write_db_listing "$(ostree_db_listing "${root}" arch def456.1)" 'gone 2.0'
  write_db_listing "$(ostree_db_listing "${root}" arch abc123.0)" 'added 3.0'
  cmdline="$(write_cmdline ostree-karg-cmdline \
    'BOOT_IMAGE=/vmlinuz ostree=/ostree/boot.1/arch/abc123/0 rw')"

  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "" \
    "OSTREE_SYSROOT=${root}")"
  status=$?

  assert_eq "the kernel-argument fallback exits 0" "0" "${status}"
  assert_contains "the deployment named by the kernel argument is the new side" \
    "${output}" "+ added 3.0"
  assert_contains "the other deployment on disk is the old side" \
    "${output}" "- gone 2.0"
}

test_program_ostree_layout_rejects_an_undeterminable_deployment() {
  local dir bin root cmdline output status
  dir="$(case_dir ostree-no-booted)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  write_program_stubs "${bin}"
  write_ostree_layout "${root}" arch abc123.0
  cmdline="$(write_cmdline ostree-no-booted-cmdline 'root=UUID=1234 rw quiet')"

  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "" \
    "OSTREE_SYSROOT=${root}")"
  status=$?

  assert_eq "no status and no ostree karg exits 1" "1" "${status}"
  assert_contains "the undeterminable booted deployment is reported" \
    "${output}" "Failed to determine booted deployment for ostree layout."
}

test_program_ostree_layout_rejects_a_sole_deployment() {
  local dir bin root cmdline output status
  dir="$(case_dir ostree-sole-deployment)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  write_program_stubs "${bin}"
  printf '* arch e4f2c1a0b3d5.0\n    Version: 20260903.0\n' >"${bin}/ostree.status"
  write_ostree_layout "${root}" arch e4f2c1a0b3d5.0
  cmdline="$(write_cmdline ostree-sole-cmdline 'root=UUID=1234 rw quiet')"

  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "" \
    "OSTREE_SYSROOT=${root}")"
  status=$?

  assert_eq "a stateroot with one deployment exits 1" "1" "${status}"
  assert_contains "the stateroot with nothing to diff is named" \
    "${output}" "No previous deployment found for stateroot 'arch'."
  assert_missing "no package database is queried" "${bin}/pacman.argv"
}

test_program_discovers_the_sysroot_at_mnt() {
  local dir bin root output status
  dir="$(case_dir ostree-mnt-sysroot)"
  bin="${dir}/bin"
  root="${dir}/sysroot"
  write_program_stubs "${bin}"
  printf '%s\n' "${STATUS_TYPICAL}" >"${bin}/ostree.status"
  write_ostree_layout "${root}" arch e4f2c1a0b3d5.0 9a8b7c6d5e4f.1
  write_db_listing "$(ostree_db_listing "${root}" arch 9a8b7c6d5e4f.1)" 'gone 2.0'
  write_db_listing "$(ostree_db_listing "${root}" arch e4f2c1a0b3d5.0)" 'added 3.0'
  local cmdline
  cmdline="$(write_cmdline ostree-mnt-cmdline 'root=UUID=1234 rw quiet')"

  # OSTREE_SYSROOT is deliberately not set: this is the probe that finds a
  # deployment mounted at /mnt, which is where the documented recovery workflow
  # mounts one from a live environment.
  output="$(run_program "${cmdline}" "${bin}" "${dir}/tmp" "${root}")"
  status=$?

  assert_eq "a sysroot found at /mnt exits 0" "0" "${status}"
  assert_contains "the sysroot probe resolves to /mnt" \
    "$(cat "${bin}/ostree.argv")" "admin --sysroot=/mnt status"
  assert_contains "the deployments under /mnt are the ones compared" \
    "${output}" "+ added 3.0"
}

test_program_reexecutes_itself_under_sudo_when_not_root() {
  # Outside the namespace, and therefore not root: the program must hand itself
  # to sudo rather than carrying on and failing later at the first mount. The
  # stub stands in for sudo so nothing is really re-executed.
  local dir bin output status
  dir="$(case_dir sudo-reexec)"
  bin="${dir}/bin"
  mkdir -p "${bin}"
  write_stub "${bin}" sudo <<'STUB'
printf 'SUDO_ARGV %s\n' "$*"
STUB

  output="$(PATH="${bin}:${PATH}" "${BASH}" "${PKG_DIFF}" </dev/null 2>&1)"
  status=$?

  assert_eq "the re-exec keeps sudo's exit status" "0" "${status}"
  assert_contains "an unprivileged run re-executes itself under sudo" \
    "${output}" "SUDO_ARGV"
  assert_contains "PATH is preserved across the re-exec" \
    "${output}" "--preserve-env=PATH"
  assert_contains "the re-exec runs this script again" \
    "${output}" "bash ${PKG_DIFF}"
}

# --- sourcing guard --------------------------------------------------------

test_sourcing_does_not_run_the_program() {
  # Sourcing must stop at the "real program" marker. A stub sudo on PATH makes
  # a regression here visible as a failed assertion instead of a real sudo
  # password prompt hanging the suite.
  local stub_dir output
  stub_dir="${WORK_DIR}/stub-bin"
  mkdir -p "${stub_dir}"
  printf '#!/usr/bin/env bash\necho SUDO_WAS_CALLED\n' >"${stub_dir}/sudo"
  chmod +x "${stub_dir}/sudo"

  output="$(PATH="${stub_dir}:${PATH}" bash -c \
    'source "$1" && echo SOURCE_RETURNED' _ "${PKG_DIFF}" </dev/null 2>&1)"

  assert_contains "sourcing returns to the caller" "${output}" "SOURCE_RETURNED"
  if [[ "${output}" == *"SUDO_WAS_CALLED"* ]]; then
    check "sourcing does not re-exec under sudo" 1 "got: ${output}"
  else
    check "sourcing does not re-exec under sudo" 0
  fi
}

main() {
  local test_fn
  for test_fn in \
    test_karg_value_reads_composefs \
    test_karg_value_reads_ostree \
    test_karg_value_absent_key_is_empty \
    test_karg_value_does_not_match_suffixed_key \
    test_karg_value_bare_flag_has_no_value \
    test_karg_value_takes_first_occurrence \
    test_karg_value_missing_file_is_empty \
    test_parse_ostree_karg_splits_os_and_boot \
    test_parse_ostree_karg_multi_digit_boot_index \
    test_parse_ostree_karg_rejects_wrong_prefix \
    test_parse_ostree_karg_rejects_non_numeric_serial \
    test_parse_ostree_karg_rejects_extra_segments \
    test_parse_ostree_karg_rejects_empty \
    test_status_booted_fields \
    test_status_booted_when_not_first_entry \
    test_status_booted_absent_marker_is_empty \
    test_status_previous_prefers_rollback_marker \
    test_status_previous_prefers_rollback_over_earlier_entry \
    test_status_previous_falls_back_to_first_other_deployment \
    test_status_previous_ignores_other_stateroots \
    test_status_previous_single_deployment_is_empty \
    test_emit_pkg_diff_reports_each_change_kind \
    test_emit_pkg_diff_identical_lists_are_silent \
    test_emit_pkg_diff_empty_old_list_is_all_additions \
    test_emit_pkg_diff_empty_new_list_is_all_removals \
    test_emit_pkg_diff_both_empty_is_silent \
    test_emit_pkg_diff_downgrade_is_reported \
    test_run_db_diff_rejects_missing_old_db \
    test_run_db_diff_rejects_missing_new_db \
    test_sourcing_does_not_run_the_program \
    test_program_reexecutes_itself_under_sudo_when_not_root; do
    printf '# %s\n' "${test_fn}"
    "${test_fn}"
  done

  # The rest run the program itself, which needs a user and mount namespace.
  local program_tests=(
    test_program_composefs_diffs_previous_against_booted
    test_program_composefs_rejects_an_unknown_booted_image
    test_program_composefs_rejects_a_sole_deployment
    test_program_composefs_rejects_a_previous_without_an_image
    test_program_composefs_rejects_an_image_that_is_not_a_file
    test_program_ostree_layout_diffs_the_rollback_deployment
    test_program_ostree_layout_falls_back_to_the_kernel_argument
    test_program_ostree_layout_rejects_an_undeterminable_deployment
    test_program_ostree_layout_rejects_a_sole_deployment
    test_program_discovers_the_sysroot_at_mnt
  )
  if namespaces_available; then
    for test_fn in "${program_tests[@]}"; do
      printf '# %s\n' "${test_fn}"
      "${test_fn}"
    done
  else
    for test_fn in "${program_tests[@]}"; do
      skip "${test_fn}" \
        "no unprivileged user + mount namespace here (${NAMESPACE_ERROR})"
    done
  fi

  printf '\n1..%d\n' "${tests_run}"
  if ((failures > 0)); then
    printf '%d of %d assertions failed\n' "${failures}" "${tests_run}" >&2
    return 1
  fi
  printf 'all %d assertions passed\n' "${tests_run}"
}

main "$@"
