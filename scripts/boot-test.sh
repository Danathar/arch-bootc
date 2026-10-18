#!/usr/bin/env bash
set -euo pipefail

# Boot one published flavor in a throwaway VM and check, over SSH, that it
# finished booting with networking, a firewall, a login screen (on the desktop
# flavors) and a working `bootc`.
#
# Every other check in CI reads the image as files. build.yml proves each
# flavor builds and that `bootc container lint` passes inside the build, and
# nightly-compliance.yml proves `:latest` is signed. Neither starts the image,
# so a flavor that no longer boots, or boots without networking or a login
# screen, stayed at `:latest` until a machine running it rebooted into it.
#
# What it does, in order:
#
#   1. Resolves the tag to a digest, once, and boots that digest. `:latest` can
#      move while this runs, and the summary has to name exactly the artifact
#      that was booted, with its `org.opencontainers.image.revision` label, so a
#      reader can check it is the commit they expect (CLAUDE.md asks the same of
#      a manual VM test).
#   2. Pulls the digest with podman.
#   3. Boots it with `bcvk ephemeral run-ssh`, which starts the image as a VM
#      with no disk of its own, logs in as root with a key it provisions, and
#      runs one command. That command is a check script this file writes and
#      hands to the guest on a read-only virtiofs mount. The guest prints one
#      marked line per result; this file reads the results back from bcvk's
#      output.
#   4. Writes result.json and a Markdown summary (to stdout and, in Actions, to
#      the step summary), and exits non-zero when the boot failed a check.
#
# It reports; it gates nothing. The image is not changed, nothing is installed
# to a disk, and nothing is upgraded: the VM's root is the image itself and
# goes away with the VM. .github/workflows/boot-test.yml runs it once per
# flavor after each build of `main`, against whatever `:latest` is then.
#
# A boot is retried once, and only when the guest reported no check at all.
# That absorbs nested-VM failures that have nothing to do with the image, such
# as a slow runner missing bcvk's SSH deadline. Once any check has reported,
# the VM booted and logged in, and that boot is the answer: a failed check
# that a later hang cut off before the end must not be replaced by a second
# boot that might pass.
#
# Units that failed in the guest are listed in the summary and not judged.
# Several fail on every ephemeral boot for reasons that are the VM's, not the
# image's (there is no ESP for the prune timer, no disk for bootupd), and the
# checks below already name the services that matter.
#
# Exit status:
#   0  the VM booted and every check passed
#   1  the VM did not boot, or booted and a check failed
#   2  usage error, missing tool, or the image could not be resolved or pulled

usage() {
  cat <<'USAGE'
Usage: boot-test.sh --flavor FLAVOR --image REF [--work DIR]

Boot a published arch-bootc image in a throwaway VM with bcvk and check that
it finished booting, that NetworkManager and firewalld are active, that the
display manager is active (kde and xfce only), and that `bootc --version` runs.

  --flavor FLAVOR  base, kde or xfce. Decides whether the display manager is
                   checked. Required.
  --image REF      The image to boot, by tag or digest, e.g.
                   ghcr.io/danathar/arch-bootc-kde:latest. Required.
  --work DIR       Where the logs, the check script and result.json are
                   written. Defaults to artifacts/boot-test/FLAVOR.
  -h, --help       Show this help.

Needs skopeo, podman, bcvk, jq and timeout on PATH, and /dev/kvm.

Exit status: 0 passed, 1 the boot or a check failed, 2 usage or setup error.
USAGE
}

# Marks the guest's result lines in an SSH session that also carries whatever
# the image prints at login. It is looked for anywhere in a line, not only at
# its start, because a login shell can print terminal queries ahead of it.
MARKER="ARCH-BOOTC-BOOT-"

VM_MEMORY="4G"
VM_VCPUS="2"
# Seconds the guest waits for boot to settle before it checks anyway. A unit
# that never finishes starting must not stop the other checks from running.
SETTLE_TIMEOUT_SECONDS=300
# Seconds for one whole boot, checks included. bcvk gives up on SSH by itself
# after four minutes; this bounds a VM that answers SSH and then hangs.
BOOT_TIMEOUT_SECONDS=$((15 * 60))
BOOT_ATTEMPTS=2
# bcvk mounts a --ro-bind directory at /run/virtiofs-mnt-<name> in the guest.
GUEST_SCRIPT_MOUNT="arch-bootc-checks"
LOG_TAIL_LINES=40
PULL_RETRIES=3

die() {
  printf 'boot-test: %s\n' "$1" >&2
  exit "${2:-2}"
}

# The checks the guest runs, one `name|command` per line: exit 0 passes, and
# the first line the command prints is kept as the detail. `$state` is the
# guest's `systemctl is-system-running --wait` answer, set before any check.
#
# - boot:finished is boot settling at all. `degraded` passes: it means a unit
#   failed, and failed units are listed, not judged (see the header).
# - service:NetworkManager and service:firewalld are the network stack and the
#   firewall every flavor enables in the shared base stage of the
#   Containerfile.
# - service:display-manager is the login screen, plasmalogin on kde and lightdm
#   on xfce, each aliased to display-manager.service. base has none.
# - bootc:version is the tool every later `bootc upgrade` depends on, built
#   from source in the Containerfile.
guest_checks() {
  local flavor="$1"
  # shellcheck disable=SC2016 # $state is expanded by the guest, not here
  printf '%s\n' \
    'boot:finished|case "${state}" in running | degraded) echo "${state}" ;; *) echo "${state:-timeout}"; false ;; esac' \
    'service:NetworkManager|systemctl is-active NetworkManager.service 2>&1' \
    'service:firewalld|systemctl is-active firewalld.service 2>&1'
  if [[ "${flavor}" != "base" ]]; then
    printf '%s\n' 'service:display-manager|systemctl is-active display-manager.service 2>&1'
  fi
  printf '%s\n' 'bootc:version|bootc --version 2>&1'
}

# The checks as a bash script the guest runs once SSH is up.
guest_script() {
  local flavor="$1" name check
  # shellcheck disable=SC2016 # the script's own expansions run in the guest
  {
    printf '%s\n' \
      'set -u' \
      '# bcvk gives the session a terminal, so systemctl would page its output' \
      '# through less and wait for a key that never comes.' \
      'export SYSTEMD_PAGER= PAGER=cat' \
      "state=\"\$(timeout ${SETTLE_TIMEOUT_SECONDS} systemctl is-system-running --wait 2>/dev/null)\"" \
      "echo \"${MARKER}STATE \${state:-timeout}\"" \
      "echo \"${MARKER}INFO kernel \$(uname -r)\""
    while IFS='|' read -r name check; do
      printf '%s\n' \
        "if out=\"\$(${check})\"; then status=pass; else status=fail; fi" \
        "echo \"${MARKER}CHECK ${name} \${status} \$(printf %s \"\${out}\" | head -n 1)\""
    done < <(guest_checks "${flavor}")
    printf '%s\n' \
      'systemctl --failed --plain --no-legend --full | while read -r unit _; do' \
      "  echo \"${MARKER}FAILED-UNIT \${unit}\"" \
      'done' \
      "echo \"${MARKER}DONE\""
  }
}

# Two things bcvk needs from the guest, injected into the boot (the image itself
# is not changed):
#
# - bcvk provisions root's SSH key through a systemd credential that tmpfiles
#   writes under /root/.ssh. In this image /root is a symlink to /var/roothome,
#   which an installed system has from its deployment but an ephemeral /var
#   built from the image may not have when tmpfiles reaches /root. This unit
#   creates it first, and does nothing when it already exists.
# - bcvk connects to TCP port 22, so sshd.service has to run. The shared base
#   stage already enables it for multi-user.target; the extra default.target
#   link makes the test not depend on that.
write_units() {
  local directory="$1"
  local wants="${directory}/system/default.target.wants"
  mkdir -p "${wants}"
  cat >"${directory}/system/arch-bootc-boot-test-roothome.service" <<'UNIT'
[Unit]
Description=Create /var/roothome so systemd credentials can provision /root/.ssh
DefaultDependencies=no
After=local-fs.target
Before=systemd-tmpfiles-setup.service
ConditionPathExists=!/var/roothome

[Service]
Type=oneshot
ExecStart=/usr/bin/mkdir -p -m 0700 /var/roothome

[Install]
WantedBy=default.target
UNIT
  ln -sfn ../arch-bootc-boot-test-roothome.service "${wants}/arch-bootc-boot-test-roothome.service"
  ln -sfn /usr/lib/systemd/system/sshd.service "${wants}/sshd.service"
}

# `image` with its tag (or digest) replaced by `digest`. A colon in the last
# path component is a tag; one earlier is a registry port.
pinned_reference() {
  local image="$1" digest="$2" repository
  repository="${image%%@*}"
  if [[ "${repository##*/}" == *:* ]]; then
    repository="${repository%:*}"
  fi
  printf '%s@%s\n' "${repository}" "${digest}"
}

# Read the guest's marked lines out of one boot's output into the report_*
# globals. A line is trimmed of the carriage return a terminal session adds.
parse_guest_output() {
  local file="$1" line rest kind
  report_done=0
  report_state=""
  report_kernel=""
  check_names=()
  check_statuses=()
  check_details=()
  failed_units=()
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == *"${MARKER}"* ]] || continue
    rest="${line#*"${MARKER}"}"
    rest="${rest//$'\r'/}"
    rest="${rest%"${rest##*[![:space:]]}"}"
    kind="${rest%% *}"
    if [[ "${rest}" == *" "* ]]; then
      rest="${rest#* }"
    else
      rest=""
    fi
    case "${kind}" in
      DONE) report_done=1 ;;
      STATE) report_state="${rest}" ;;
      INFO)
        if [[ "${rest}" == "kernel "* ]]; then
          report_kernel="${rest#kernel }"
        fi
        ;;
      CHECK)
        check_names+=("${rest%% *}")
        rest="${rest#* }"
        check_statuses+=("${rest%% *}")
        if [[ "${rest}" == *" "* ]]; then
          check_details+=("${rest#* }")
        else
          check_details+=("")
        fi
        ;;
      FAILED-UNIT)
        if [[ -n "${rest}" ]]; then
          failed_units+=("${rest}")
        fi
        ;;
    esac
  done <"${file}"
  # The loop's status is its last body command's, which can be a test that
  # did not match; under errexit that would end the caller.
  return 0
}

# Sets `passed` (0 or 1) and `summary` from the report. Every expected check
# must have run and passed.
judge() {
  local flavor="$1" name check index found missing="" failed=""
  passed=0
  if ((report_done == 0)); then
    summary="The VM never reached the point where the checks finish (no SSH, or the checks hung)."
    return 0
  fi
  # shellcheck disable=SC2034 # check is read only to split name from it
  while IFS='|' read -r name check; do
    found=0
    for index in "${!check_names[@]}"; do
      [[ "${check_names[index]}" == "${name}" ]] && found=1
    done
    ((found)) || missing+="${missing:+, }${name}"
  done < <(guest_checks "${flavor}")
  for index in "${!check_names[@]}"; do
    [[ "${check_statuses[index]}" == "pass" ]] || failed+="${failed:+, }${check_names[index]}"
  done
  if [[ -z "${missing}${failed}" ]]; then
    passed=1
    summary="Booted, logged in over SSH, and every check passed."
    return 0
  fi
  summary="Booted and logged in, but"
  [[ -n "${missing}" ]] && summary+=" checks with no result: ${missing}"
  [[ -n "${missing}" && -n "${failed}" ]] && summary+=";"
  [[ -n "${failed}" ]] && summary+=" failed checks: ${failed}"
  summary+="."
}

# Boot `pinned` once and run the checks. The output goes to the attempt's
# log directory, and is parsed from there.
boot() {
  local pinned="$1" work="$2" attempt="$3" flavor="$4"
  local log_dir="${work}/boot-${attempt}"
  local name="arch-bootc-boot-test-${flavor}-$$-${attempt}"
  local status=0
  mkdir -p "${log_dir}"
  boot_log="${log_dir}/bcvk.log"
  # Every path is absolute: bcvk silently ignored a relative --systemd-units
  # path in a local run, and the VM booted without the injected units.
  local bcvk_command=(
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
  printf '+ %s\n' "${bcvk_command[*]}"
  timeout --kill-after=30 "${BOOT_TIMEOUT_SECONDS}" "${bcvk_command[@]}" >"${boot_log}" 2>&1 || status=$?
  if ((status == 124 || status == 137)); then
    printf '\nbcvk timed out after %ss\n' "${BOOT_TIMEOUT_SECONDS}" >>"${boot_log}"
  fi
  # A killed bcvk leaves the VM's container running, holding its memory
  # through the next attempt.
  podman rm --force --ignore "${name}" >/dev/null 2>&1 || true
  parse_guest_output "${boot_log}"
}

# A Markdown table cell: one line, with no bare pipe to split the row.
cell() {
  local text="${1//$'\n'/ }"
  printf '%s' "${text//|/\\|}"
}

# shellcheck disable=SC2016 # the backticks are Markdown, printed literally
render_summary() {
  local flavor="$1" image="$2" pinned="$3" revision="$4" attempts="$5" log="$6" index units=""
  printf '## Boot test: %s\n\n' "${flavor}"
  if ((passed)); then
    printf '**Passed**: %s\n\n' "${summary}"
  else
    printf '**Failed**: %s\n\n' "${summary}"
  fi
  printf '| | |\n|---|---|\n'
  printf '| Image | `%s` |\n' "$(cell "${image}")"
  printf '| Booted | `%s` |\n' "$(cell "${pinned}")"
  printf '| Revision | `%s` |\n' "$(cell "${revision:-unknown}")"
  printf '| Boots | %s |\n' "${attempts}"
  printf '| Kernel | `%s` |\n' "$(cell "${report_kernel:-unknown}")"
  printf '| systemd state | `%s` |\n' "$(cell "${report_state:-unknown}")"
  if ((${#check_names[@]} > 0)); then
    printf '\n| Check | Result | Detail |\n|---|---|---|\n'
    for index in "${!check_names[@]}"; do
      printf '| `%s` | %s | `%s` |\n' "$(cell "${check_names[index]}")" \
        "$(cell "${check_statuses[index]}")" "$(cell "${check_details[index]}")"
    done
  fi
  if ((${#failed_units[@]} > 0)); then
    for index in "${!failed_units[@]}"; do
      units+="${units:+, }\`${failed_units[index]}\`"
    done
    printf '\nFailed units (not judged): %s\n' "${units}"
  fi
  if ((passed == 0)); then
    printf '\n<details><summary>bcvk output (tail)</summary>\n\n```\n'
    if [[ -f "${log}" ]]; then
      tail -n "${LOG_TAIL_LINES}" -- "${log}"
    fi
    printf '```\n\n</details>\n'
  fi
}

write_result() {
  local file="$1" flavor="$2" image="$3" pinned="$4" revision="$5" attempts="$6"
  local checks_json='[]' units_json='[]' index passed_json=false done_json=false
  if ((passed)); then passed_json=true; fi
  if ((report_done)); then done_json=true; fi
  for index in "${!check_names[@]}"; do
    checks_json="$(jq -c --arg name "${check_names[index]}" --arg status "${check_statuses[index]}" \
      --arg detail "${check_details[index]}" '. + [{name: $name, status: $status, detail: $detail}]' \
      <<<"${checks_json}")"
  done
  for index in "${!failed_units[@]}"; do
    units_json="$(jq -c --arg unit "${failed_units[index]}" '. + [$unit]' <<<"${units_json}")"
  done
  jq -n \
    --arg flavor "${flavor}" --arg image "${image}" --arg booted "${pinned}" \
    --arg revision "${revision}" --argjson passed "${passed_json}" \
    --arg summary "${summary}" --argjson attempts "${attempts}" \
    --argjson done "${done_json}" \
    --arg state "${report_state}" --arg kernel "${report_kernel}" \
    --argjson checks "${checks_json}" --argjson failed_units "${units_json}" '
      {flavor: $flavor, image: $image, booted: $booted, revision: $revision,
       passed: $passed, summary: $summary, attempts: $attempts,
       report: {done: $done, state: $state, kernel: $kernel,
                checks: $checks, failed_units: $failed_units}}' >"${file}"
}

main() {
  local flavor="" image="" work="" tool inspect digest revision pinned attempt attempts=0
  while (($# > 0)); do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      --flavor | --image | --work)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "$1 needs a value"
        case "$1" in
          --flavor) flavor="$2" ;;
          --image) image="$2" ;;
          --work) work="$2" ;;
        esac
        shift 2
        ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
  case "${flavor}" in
    base | kde | xfce) ;;
    "") die "--flavor is required (base, kde or xfce)" ;;
    *) die "unknown flavor '${flavor}' (base, kde or xfce)" ;;
  esac
  [[ -n "${image}" ]] || die "--image is required"
  for tool in skopeo podman bcvk jq timeout; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not on PATH"
  done
  work="${work:-artifacts/boot-test/${flavor}}"
  mkdir -p "${work}"
  work="$(cd -- "${work}" && pwd)"

  # One inspect of the tag gives the digest and the labels of the same
  # manifest, so the revision reported is the booted image's even if the tag
  # moves between here and the pull.
  inspect="$(skopeo inspect --retry-times "${PULL_RETRIES}" "docker://${image}")" ||
    die "could not inspect ${image}"
  digest="$(jq -r '.Digest // empty' <<<"${inspect}")"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "${image} did not resolve to a sha256 digest (got '${digest}')"
  revision="$(jq -r '.Labels["org.opencontainers.image.revision"] // empty' <<<"${inspect}")"
  pinned="$(pinned_reference "${image}" "${digest}")"
  printf 'boot-test: %s resolves to %s (revision %s)\n' "${image}" "${pinned}" "${revision:-unknown}"
  # podman retries a failed layer transfer itself; the job's timeout-minutes
  # bounds a pull that stalls instead.
  podman pull --quiet --retry "${PULL_RETRIES}" "${pinned}" >/dev/null ||
    die "could not pull ${pinned}"

  write_units "${work}/units"
  # The script travels as a file on a read-only virtiofs mount rather than
  # inside the SSH command line, so what the guest ran is in the artifact.
  mkdir -p "${work}/checks"
  guest_script "${flavor}" >"${work}/checks/checks.sh"

  for ((attempt = 1; attempt <= BOOT_ATTEMPTS; attempt++)); do
    attempts="${attempt}"
    boot "${pinned}" "${work}" "${attempt}" "${flavor}"
    if ((report_done || ${#check_names[@]} > 0)); then
      break
    fi
    if ((attempt < BOOT_ATTEMPTS)); then
      printf 'boot-test: boot %s reported no check; booting once more\n' "${attempt}"
    fi
  done

  judge "${flavor}"
  write_result "${work}/result.json" "${flavor}" "${image}" "${pinned}" "${revision}" "${attempts}"
  render_summary "${flavor}" "${image}" "${pinned}" "${revision}" "${attempts}" "${boot_log}" >"${work}/summary.md"
  cat -- "${work}/summary.md"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat -- "${work}/summary.md" >>"${GITHUB_STEP_SUMMARY}"
  fi
  if ((passed == 0)); then
    printf 'boot-test: FAILED for %s: %s\n' "${pinned}" "${summary}" >&2
    return 1
  fi
  return 0
}

main "$@"
