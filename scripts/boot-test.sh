#!/usr/bin/env bash
set -euo pipefail

# Boot one published flavor in a throwaway VM and check, over SSH, that it
# finished booting with its network, firewall, login screen and bootc working.
#
# Every other check in this repository reads the image as files. build.yml
# proves each flavor builds and passes `bootc container lint`, and
# nightly-compliance.yml proves `:latest` is signed. Neither starts the image,
# so a flavor that no longer boots, or boots without networking or a display
# manager, would sit at `:latest` until a machine tracking it rebooted into it.
#
# What this does, in order:
#
#   1. Resolves the tag to a digest and reads the image's revision label. The
#      digest is what boots, because `:latest` can move while this runs; the
#      revision is printed so a reader can check the commit, as CLAUDE.md asks
#      of every VM test of this image.
#   2. Pulls that digest.
#   3. Boots it with `bcvk ephemeral run-ssh`. bcvk starts the image's own
#      kernel and initramfs in QEMU with the image as a read-only virtiofs root,
#      logs in as root with a key it provisions, and runs the check script.
#      Nothing is installed to a disk and nothing is upgraded.
#   4. Reads the results back from marked lines of the SSH session's output and
#      writes result.json and a summary.
#
# It reports; it gates nothing. .github/workflows/boot-test.yml runs it after
# build.yml on main, against whatever `:latest` is then.
#
# Exit status:
#   0  the flavor booted and every check passed
#   1  the boot or a check failed
#   2  usage error, missing tool, or the image could not be resolved or pulled

usage() {
  cat <<'USAGE'
Usage: boot-test.sh --image REF --flavor FLAVOR [--work DIR]

Boot a published arch-bootc image in a throwaway VM with bcvk and check it.

  --image REF      Image to boot, by tag or digest, e.g.
                   ghcr.io/danathar/arch-bootc-base:latest. Required.
  --flavor FLAVOR  base, kde or xfce: picks the checks. Required.
  --work DIR       Where logs, the check script and result.json go.
                   Defaults to ./boot-test.

Needs skopeo, podman, bcvk, jq, timeout, and /dev/kvm.

Exit status: 0 passed, 1 the boot or a check failed, 2 usage or setup error.
USAGE
}

# Every guest line the host reads starts with this, so results can be told
# apart from whatever else the SSH session carries (login banners, terminal
# queries). It is looked for anywhere in a line, not only at its start.
MARKER="ARCH-BOOTC-BOOT-"

VM_MEMORY="4G"
VM_VCPUS="2"
# Seconds the guest waits for boot to settle before it checks anyway. A unit
# that never finishes starting must not stop the other checks from running.
SETTLE_TIMEOUT_SECONDS=300
# Seconds for one whole boot, checks included. bcvk gives up on SSH by itself
# after four minutes; this bounds a VM that answers SSH and then hangs.
BOOT_TIMEOUT_SECONDS=$((15 * 60))
# A second boot absorbs nested-VM failures that have nothing to do with the
# image, such as a slow runner missing bcvk's SSH deadline. It is taken only
# when the guest reported no check at all. Once any check has reported, the VM
# booted and logged in, and that boot is the answer: a failed check that a
# later hang cut off before DONE must not be replaced by a second boot.
BOOT_ATTEMPTS=2
# bcvk mounts a --ro-bind directory at /run/virtiofs-mnt-<name> in the guest.
GUEST_SCRIPT_MOUNT="arch-bootc-checks"
LOG_TAIL_LINES=40
PULL_RETRIES=3

image=""
flavor=""
work="boot-test"

need_value() {
  if (($2 < 2)); then
    printf 'error: %s needs a value\n' "$1" >&2
    exit 2
  fi
}

while (($# > 0)); do
  case "$1" in
    --image)
      need_value "$1" "$#"
      image="$2"
      shift 2
      ;;
    --flavor)
      need_value "$1" "$#"
      flavor="$2"
      shift 2
      ;;
    --work)
      need_value "$1" "$#"
      work="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${image}" ]]; then
  echo "error: --image is required" >&2
  usage >&2
  exit 2
fi

# What each check runs in the guest. Exit 0 passes, and the first line it
# prints is kept as the detail.
#
# - boot:finished: systemd left `starting`. `degraded` passes because failed
#   units are listed separately and not judged: several fail on every
#   ephemeral boot for reasons that are the VM's, not the image's.
# - unit:NetworkManager and unit:firewalld are enabled by base-core in the
#   Containerfile for every flavor.
# - unit:display-manager is the alias plasmalogin (kde) and lightdm (xfce)
#   declare; base has none.
# - bootc:version runs the bootc base-core compiled from source.
#
# sshd is not checked here because the session itself is the check: this
# script does not start sshd, so a login proves the image enabled it.
checks=(
  "boot:finished|case \"\${state}\" in running | degraded) echo \"\${state}\" ;; *) echo \"\${state:-timeout}\"; false ;; esac"
  "unit:NetworkManager|systemctl is-active NetworkManager.service"
  "unit:firewalld|systemctl is-active firewalld.service"
)
case "${flavor}" in
  base) ;;
  kde | xfce)
    checks+=("unit:display-manager|systemctl is-active display-manager.service")
    ;;
  "")
    echo "error: --flavor is required" >&2
    usage >&2
    exit 2
    ;;
  *)
    printf 'error: --flavor must be base, kde or xfce, got %s\n' "${flavor}" >&2
    exit 2
    ;;
esac
checks+=("bootc:version|bootc --version")

for tool in skopeo podman bcvk jq timeout; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf 'error: %s is required\n' "${tool}" >&2
    exit 2
  fi
done

# The check script the guest runs once SSH is up.
guest_script() {
  local entry name command
  cat <<EOF
set -u
# bcvk gives the session a terminal, so systemctl would page its output through
# less and wait for a key that never comes.
export SYSTEMD_PAGER= PAGER=cat
state="\$(timeout ${SETTLE_TIMEOUT_SECONDS} systemctl is-system-running --wait 2>/dev/null)"
echo "${MARKER}STATE \${state:-timeout}"
echo "${MARKER}INFO kernel \$(uname -r)"
EOF
  for entry in "${checks[@]}"; do
    name="${entry%%|*}"
    command="${entry#*|}"
    cat <<EOF
if out="\$(${command} 2>&1)"; then status=pass; else status=fail; fi
echo "${MARKER}CHECK ${name} \${status} \$(printf '%s\n' "\${out}" | head -n 1)"
EOF
  done
  cat <<EOF
systemctl --failed --plain --no-legend --full | while read -r unit _; do
  echo "${MARKER}FAILED-UNIT \${unit}"
done
echo "${MARKER}DONE"
EOF
}

# Two units injected into the boot so bcvk can log in. They go into this boot
# only: the image is unchanged, and nothing here reaches an installed system.
#
# - arch-bootc-roothome.service. bcvk provisions root's SSH key through a
#   systemd credential that tmpfiles writes to /root/.ssh. /root is a symlink to
#   /var/roothome here (the Containerfile's directory restructuring step), and
#   an ephemeral /var starts empty. The unit creates the directory before
#   tmpfiles runs, so the key does not depend on the order tmpfiles applies its
#   own `d /var/roothome` line. atomic-image-builder, zfs-kinoite-complex and
#   zfs-aurora-complex inject the same unit.
# - arch-bootc-root-unexpire.service. The Containerfile expires root's
#   password on purpose (`passwd --expire root`, part of the security model in
#   AGENTS.md), so pam_unix answers every root login, a key login included,
#   with "expired password for user root (root enforced)" and sshd closes the
#   session for the password change. bcvk's session is not interactive, so
#   without this unit it never runs a command: hosted run 39136185733 booted
#   kde and xfce to that point and timed out. The unit clears the expiry in this
#   boot's /etc before sshd starts. It does not set or reveal a password, and
#   does not touch the sshd and PAM settings the security model rests on.
ROOTHOME_UNIT='[Unit]
Description=Create /var/roothome so systemd credentials can provision /root/.ssh
DefaultDependencies=no
After=local-fs.target
Before=systemd-tmpfiles-setup.service
ConditionPathExists=!/var/roothome

[Service]
Type=oneshot
ExecStart=/usr/bin/mkdir -p -m 0700 /var/roothome

[Install]
WantedBy=default.target'

UNEXPIRE_UNIT='[Unit]
Description=Clear root password expiry for the boot test login (this boot only)
After=local-fs.target
Before=sshd.service systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/usr/bin/chage --lastday -1 root

[Install]
WantedBy=default.target'

write_units() {
  local dir="$1" unit
  mkdir -p "${dir}/system/default.target.wants"
  printf '%s\n' "${ROOTHOME_UNIT}" >"${dir}/system/arch-bootc-roothome.service"
  printf '%s\n' "${UNEXPIRE_UNIT}" >"${dir}/system/arch-bootc-root-unexpire.service"
  for unit in arch-bootc-roothome.service arch-bootc-root-unexpire.service; do
    ln -sfn "../${unit}" "${dir}/system/default.target.wants/${unit}"
  done
}

# The marked lines of one boot's output, with whatever preceded the marker on
# the same line dropped.
marked_lines() {
  grep -aoE "${MARKER}[A-Z-]+( .*)?" "$1" | sed -E "s/^${MARKER}//; s/\r$//" || true
}

# result.json's `report`, built from one boot's output.
parse_report() {
  local log="$1" line kind rest state="" kernel="" finished=false
  local -a check_rows=() failed_units=()
  while IFS= read -r line; do
    kind="${line%% *}"
    rest=""
    [[ "${line}" == *" "* ]] && rest="${line#* }"
    case "${kind}" in
      DONE) finished=true ;;
      STATE) state="${rest}" ;;
      INFO)
        if [[ "${rest}" == "kernel "* ]]; then kernel="${rest#kernel }"; fi
        ;;
      CHECK) check_rows+=("${rest}") ;;
      FAILED-UNIT) [[ -n "${rest}" ]] && failed_units+=("${rest}") ;;
    esac
  done < <(marked_lines "${log}")
  jq -n \
    --argjson finished "${finished}" \
    --arg state "${state}" \
    --arg kernel "${kernel}" \
    --args '{
      done: $finished,
      state: $state,
      kernel: $kernel,
      checks: [$ARGS.positional[] | select(startswith("C ")) | .[2:]
        | capture("^(?<name>[^ ]+) (?<status>[^ ]+) ?(?<detail>.*)$")],
      failed_units: [$ARGS.positional[] | select(startswith("U ")) | .[2:]]
    }' \
    "${check_rows[@]/#/C }" "${failed_units[@]/#/U }"
}

# Passed or not, and why, from a report and the checks this flavor expects.
judge() {
  local report="$1"
  jq -r --args '
    ($ARGS.positional) as $expected
    | (.checks | map({key: .name, value: .status}) | from_entries) as $ran
    | [$expected[] | select($ran[.] == null)] as $missing
    | [.checks[] | select(.status != "pass") | .name] as $failed
    | if (.done | not) then
        "fail\tThe VM never reached the point where the checks finish (no SSH, or the checks hung)."
      elif ($missing + $failed | length) > 0 then
        "fail\tBooted and logged in, but "
          + ([(if ($missing | length) > 0 then "checks with no result: " + ($missing | join(", ")) else empty end),
              (if ($failed | length) > 0 then "failed checks: " + ($failed | join(", ")) else empty end)]
             | join("; ")) + "."
      else
        "pass\tBooted, logged in over SSH, and every check passed."
      end' "${check_names[@]}" <<<"${report}"
}

check_names=()
for entry in "${checks[@]}"; do
  check_names+=("${entry%%|*}")
done

mkdir -p "${work}"
work="$(cd -- "${work}" && pwd)"

# Boot a digest, not the tag: `:latest` can move while this runs, and the
# summary must name exactly the artifact that was booted.
if ! inspected="$(skopeo inspect --retry-times "${PULL_RETRIES}" \
  --format '{{.Digest}} {{index .Labels "org.opencontainers.image.revision"}}' \
  "docker://${image}")"; then
  printf 'error: could not resolve %s to a digest\n' "${image}" >&2
  exit 2
fi
digest="${inspected%% *}"
revision="${inspected#* }"
if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  printf 'error: %s resolved to %s, which is not a digest\n' "${image}" "${digest}" >&2
  exit 2
fi
if [[ -z "${revision}" || "${revision}" == "<no value>" ]]; then
  revision="unknown"
fi
repository="${image%%@*}"
if [[ "${repository##*/}" == *:* ]]; then
  repository="${repository%:*}"
fi
pinned="${repository}@${digest}"
echo "Booting ${pinned} (revision ${revision})"

if ! podman pull --quiet --retry "${PULL_RETRIES}" "${pinned}"; then
  printf 'error: could not pull %s\n' "${pinned}" >&2
  exit 2
fi

write_units "${work}/units"
# The script travels as a file on a read-only virtiofs mount rather than inside
# the SSH command line, so what the guest ran is in the artifact.
mkdir -p "${work}/checks"
guest_script >"${work}/checks/checks.sh"

report=""
log=""
attempts=0
for ((attempt = 1; attempt <= BOOT_ATTEMPTS; attempt++)); do
  attempts="${attempt}"
  log_dir="${work}/boot-${attempt}"
  mkdir -p "${log_dir}"
  log="${log_dir}/bcvk.log"
  name="arch-bootc-boot-test-$$-${attempt}"
  # Every path is absolute: a relative --systemd-units path was silently
  # ignored in zfs-kinoite-complex's local runs.
  command=(
    bcvk ephemeral run-ssh
    --name "${name}"
    --memory "${VM_MEMORY}"
    --vcpus "${VM_VCPUS}"
    --systemd-units "${work}/units"
    --ro-bind "${work}/checks:${GUEST_SCRIPT_MOUNT}"
    --log-dir "journal,console=${log_dir}/"
    "${pinned}"
    --
    "bash /run/virtiofs-mnt-${GUEST_SCRIPT_MOUNT}/checks.sh"
  )
  printf '+ %s\n' "${command[*]}"
  status=0
  timeout --kill-after=30 "${BOOT_TIMEOUT_SECONDS}" "${command[@]}" >"${log}" 2>&1 </dev/null || status=$?
  if ((status == 124)); then
    printf '\nbcvk timed out after %ss\n' "${BOOT_TIMEOUT_SECONDS}" >>"${log}"
  fi
  # A killed bcvk leaves the VM's container running, holding its memory through
  # the next attempt.
  podman rm --force --ignore "${name}" >/dev/null 2>&1 || true
  report="$(parse_report "${log}")"
  if [[ "$(jq -r '.done or (.checks | length > 0)' <<<"${report}")" == "true" ]]; then
    break
  fi
done

verdict="$(judge "${report}")"
outcome="${verdict%%$'\t'*}"
summary="${verdict#*$'\t'}"

jq -n \
  --arg image "${image}" \
  --arg flavor "${flavor}" \
  --arg booted "${pinned}" \
  --arg revision "${revision}" \
  --argjson passed "$([[ "${outcome}" == pass ]] && echo true || echo false)" \
  --arg summary "${summary}" \
  --argjson attempts "${attempts}" \
  --argjson report "${report}" \
  '{image: $image, flavor: $flavor, booted: $booted, revision: $revision,
    passed: $passed, summary: $summary, attempts: $attempts, report: $report}' \
  >"${work}/result.json"

render_summary() {
  jq -r '
    "## Boot test: \(.flavor)",
    "",
    "**\(if .passed then "Passed" else "Failed" end)**: \(.summary)",
    "",
    "| | |",
    "|---|---|",
    "| Image | `\(.image)` |",
    "| Booted | `\(.booted)` |",
    "| Revision | `\(.revision)` |",
    "| Boots | \(.attempts) |",
    "| Kernel | `\(.report.kernel | if . == "" then "unknown" else . end)` |",
    "| systemd state | `\(.report.state | if . == "" then "unknown" else . end)` |",
    (if (.report.checks | length) > 0 then
      "", "| Check | Result | Detail |", "|---|---|---|",
      (.report.checks[] | "| `\(.name)` | \(.status) | `\(.detail)` |")
    else empty end),
    (if (.report.failed_units | length) > 0 then
      "", "Failed units (not judged): \(.report.failed_units | map("`\(.)`") | join(", "))"
    else empty end)
  ' "${work}/result.json"
  if [[ "${outcome}" != pass ]]; then
    printf '\n<details><summary>bcvk output (tail)</summary>\n\n```\n'
    tail -n "${LOG_TAIL_LINES}" "${log}"
    printf '```\n\n</details>\n'
  fi
}

text="$(render_summary)"
printf '%s\n' "${text}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '%s\n' "${text}" >>"${GITHUB_STEP_SUMMARY}"
fi

if [[ "${outcome}" != pass ]]; then
  printf 'error: boot test failed for %s: %s\n' "${pinned}" "${summary}" >&2
  exit 1
fi
