#!/usr/bin/env bash
set -uo pipefail

# Assert the repository invariants that AGENTS.md, CONTRIBUTING.md,
# docs/review-rubric.md and docs/security/SECURITY-AI.md describe in prose.
#
# Those documents say which properties are load-bearing and must not be weakened
# to make something pass. Nothing checked that they still hold: the build proves
# the image *builds*, and an image that has quietly lost `pam_wheel.so use_uid`
# or a signature requirement builds perfectly well. This script is the drift
# detector for exactly that class of change.
#
# It is static. It reads the checked-out tree and nothing else -- no root, no
# container runtime, no network -- so it runs anywhere the shell tests do.
#
# What it cannot see, stated plainly rather than left to be assumed:
#
#   - It reads the Containerfile as text. A step that has the right shape but
#     the wrong effect passes here. Only a VM boot test settles that; see
#     CLAUDE.md.
#   - It does not check that display managers refuse root. That behavior comes
#     from the packaged plasmalogin and lightdm units, not from anything in this
#     tree, so there is nothing here to assert against.
#   - A failure means an invariant is no longer visible where it was. It does
#     not by itself mean the change is wrong -- a deliberate change to the
#     security model updates this file in the same commit, and says so.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd -- "${REPO_ROOT}" || exit 1

CONTAINERFILE="Containerfile"
POLICY="system_files/etc/containers/policy.json"
REGISTRIES_D="system_files/etc/containers/registries.d/arch-bootc.yaml"
BUILD_WORKFLOW=".github/workflows/build.yml"
JUSTFILE="Justfile"

checks_run=0
failures=0

group() {
  printf '\n# %s\n' "$1"
}

pass() {
  checks_run=$((checks_run + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  checks_run=$((checks_run + 1))
  failures=$((failures + 1))
  printf 'not ok - %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf '  # %s\n' "$2" >&2
  return 0
}

# The invariant holds when PATTERN is present in FILE.
assert_present() {
  local description="$1" file="$2" pattern="$3" note="${4:-}"
  if [[ ! -f "${file}" ]]; then
    fail "${description}" "${file} does not exist"
    return
  fi
  if grep -Eq -- "${pattern}" "${file}"; then
    pass "${description}"
  else
    fail "${description}" "${note:-no line in ${file} matches: ${pattern}}"
  fi
}

# The invariant holds when PATTERN is absent from FILE.
assert_absent() {
  local description="$1" file="$2" pattern="$3" note="${4:-}"
  if [[ ! -f "${file}" ]]; then
    fail "${description}" "${file} does not exist"
    return
  fi
  local hits
  hits="$(grep -En -- "${pattern}" "${file}" | grep -v '^[0-9]*:[[:space:]]*#')"
  if [[ -z "${hits}" ]]; then
    pass "${description}"
  else
    fail "${description}" "${note:-${file} matches ${pattern}}: ${hits//$'\n'/ | }"
  fi
}

assert_equal() {
  local description="$1" actual="$2" expected="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    pass "${description}"
  else
    fail "${description}" "expected '${expected}', found '${actual}'"
  fi
}

# ---------------------------------------------------------------------------
group "Root-login model (AGENTS.md: 'Do not weaken the image's security model')"
# The image ships a known default root password. That is safe only because every
# remote, graphical and local-escalation path to root is closed at the same
# time. Three of the four closures live in this tree; the fourth (display
# managers refusing root) comes from the packaged units.

assert_present "sshd refuses root password authentication" \
  "${CONTAINERFILE}" 'PermitRootLogin[[:space:]]+prohibit-password' \
  "the sshd drop-in no longer pins PermitRootLogin prohibit-password"

assert_present "the sshd drop-in is written under /etc/ssh/sshd_config.d/" \
  "${CONTAINERFILE}" '/etc/ssh/sshd_config\.d/'

assert_present "pam_wheel.so use_uid is enabled in /etc/pam.d/su" \
  "${CONTAINERFILE}" 'pam_wheel\\?\.so use_uid' \
  "Arch ships this line commented out; without the sed that uncomments it, any local account can su to root"

assert_present "the root password is expired on first use" \
  "${CONTAINERFILE}" 'passwd --expire root'

# The default password must never be extended to a non-root account: Arch's
# sshd ships PasswordAuthentication yes, so a default *user* password would be
# remotely exploitable on every published image.
non_root_chpasswd="$(grep -En 'chpasswd' "${CONTAINERFILE}" |
  grep -v '^[0-9]*:[[:space:]]*#' | grep -v "root:")"
if [[ -z "${non_root_chpasswd}" ]]; then
  pass "no default password is set for a non-root account"
else
  fail "no default password is set for a non-root account" \
    "chpasswd targets something other than root: ${non_root_chpasswd//$'\n'/ | }"
fi

# ---------------------------------------------------------------------------
group "Signature chain (docs/ci-cd.md, docs/security/SECURITY-AI.md)"

assert_present "the published namespace requires a sigstore signature" \
  "${POLICY}" '"type": "sigstoreSigned"'

assert_present "the signature is bound to the repository that published it" \
  "${POLICY}" '"signedIdentity": \{"type": "matchRepository"\}'

# cosign.pub at the repository root is the single source of truth; the
# Containerfile COPYs it to the path policy.json names. If those two paths ever
# disagree, verification fails closed on the installed system rather than here,
# so compare them directly.
policy_key_path="$(sed -nE 's/.*"keyPath": "([^"]+)".*/\1/p' "${POLICY}" | head -1)"
copied_key_path="$(sed -nE 's/^COPY[[:space:]]+cosign\.pub[[:space:]]+([^[:space:]]+).*/\1/p' "${CONTAINERFILE}" | head -1)"
assert_equal "policy.json keyPath matches where the Containerfile copies cosign.pub" \
  "${copied_key_path}" "${policy_key_path}"

assert_present "cosign.pub is a public key" "cosign.pub" 'BEGIN PUBLIC KEY'

# The key must not be duplicated under system_files/: two copies rot apart on
# rotation, and the Containerfile comment says so explicitly.
duplicated_keys="$(find system_files -name 'cosign.pub' -o -name '*.pub' -type f 2>/dev/null)"
if [[ -z "${duplicated_keys}" ]]; then
  pass "cosign.pub is not duplicated under system_files/"
else
  fail "cosign.pub is not duplicated under system_files/" \
    "found: ${duplicated_keys//$'\n'/ | }"
fi

# The namespace that requires a signature and the namespace configured to
# locate signatures have to be the same one.
policy_namespace="$(sed -nE 's/.*"(ghcr\.io\/[a-z0-9._-]+)".*/\1/p' "${POLICY}" | head -1)"
if [[ -n "${policy_namespace}" ]] && grep -Fq "${policy_namespace}" "${REGISTRIES_D}"; then
  pass "registries.d configures the same namespace policy.json protects (${policy_namespace})"
else
  fail "registries.d configures the same namespace policy.json protects" \
    "policy.json protects '${policy_namespace}', which does not appear in ${REGISTRIES_D}"
fi

# ---------------------------------------------------------------------------
group "bootc provenance (AGENTS.md: 'bootc provenance')"

bootc_version="$(sed -nE 's/^ARG BOOTC_VERSION=(.+)$/\1/p' "${CONTAINERFILE}" | head -1)"
bootc_commit="$(sed -nE 's/^ARG BOOTC_COMMIT=(.+)$/\1/p' "${CONTAINERFILE}" | head -1)"

if [[ "${bootc_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "BOOTC_VERSION is a pinned release tag (${bootc_version})"
else
  fail "BOOTC_VERSION is a pinned release tag" "found '${bootc_version}'"
fi

if [[ "${bootc_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  pass "BOOTC_COMMIT is a full 40-character commit SHA"
else
  fail "BOOTC_COMMIT is a full 40-character commit SHA" "found '${bootc_commit}'"
fi

assert_present "bootc is built from the canonical upstream repository" \
  "${CONTAINERFILE}" 'git clone .*https://github\.com/bootc-dev/bootc\.git'

# The tag-to-commit check is a supply-chain control, not a formality: a git tag
# is mutable and bootc runs as root on every machine booting this image. It has
# to refuse the build, not warn.
if grep -A3 -E 'if \[ "\$\{bootc_head\}" != "\$\{BOOTC_COMMIT\}" \]' "${CONTAINERFILE}" |
  grep -q 'exit 1'; then
  pass "a re-pointed bootc tag fails the build rather than warning"
else
  fail "a re-pointed bootc tag fails the build rather than warning" \
    "the BOOTC_COMMIT mismatch branch does not exit non-zero"
fi

# ---------------------------------------------------------------------------
group "Package freshness and sources (AGENTS.md: 'Package freshness and the build cache')"

assert_present "PACMAN_CACHE_BUST is declared" \
  "${CONTAINERFILE}" '^ARG PACMAN_CACHE_BUST='

# The cache bust has to precede the first full system upgrade. If package
# installation ever moves above it, a cached layer silently ships a stale,
# unpatched package set -- the remote layer cache cannot know Arch's live
# repositories changed underneath it.
# The literal string searched for is a Containerfile ARG reference, so it must
# stay unexpanded here.
# shellcheck disable=SC2016
cache_bust_line="$(grep -n 'cache-bust ${PACMAN_CACHE_BUST}' "${CONTAINERFILE}" | head -1 | cut -d: -f1)"
first_syu_line="$(grep -n 'pacman -Syu' "${CONTAINERFILE}" | grep -v ':[[:space:]]*#' | head -1 | cut -d: -f1)"
if [[ -n "${cache_bust_line}" && -n "${first_syu_line}" ]] && ((cache_bust_line < first_syu_line)); then
  pass "the cache bust precedes the first pacman -Syu (line ${cache_bust_line} before ${first_syu_line})"
else
  fail "the cache bust precedes the first pacman -Syu" \
    "cache bust at line '${cache_bust_line:-none}', first pacman -Syu at line '${first_syu_line:-none}'"
fi

assert_absent "no third-party pacman signing key is imported" \
  "${CONTAINERFILE}" 'pacman-key'

assert_absent "no third-party pacman repository is added" \
  "${CONTAINERFILE}" '^[^#]*Server[[:space:]]*=[[:space:]]*(https?|rsync)://'

# ---------------------------------------------------------------------------
group "Service enablement layout (AGENTS.md: 'Service enablement policy')"

assert_absent "systemctl preset-all is not used" \
  "${CONTAINERFILE}" 'systemctl preset-all'

# Enablement symlinks belong in /usr/lib/systemd/system/<target>.wants/, not in
# /etc, which is machine-local state subject to a three-way merge on upgrade.
# `systemctl mask` legitimately writes to /etc and is exempt -- it is the
# documented exception, and it is what actually survives a package upgrade.
assert_absent "enablement symlinks are not created under /etc/systemd/system" \
  "${CONTAINERFILE}" '^[^#]*ln -s[^&|]*/etc/systemd/system/[^[:space:]]*\.wants/'

# ---------------------------------------------------------------------------
group "Workflow hygiene (docs/quality.md: zizmor findings that are easy to reintroduce)"

shopt -s nullglob
workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob

if ((${#workflows[@]} == 0)); then
  fail "workflow files were found to check" "no files matched .github/workflows/*.y*ml"
fi

unpinned=""
for workflow in "${workflows[@]}"; do
  while IFS= read -r line; do
    unpinned+="${workflow}: ${line}"$'\n'
  done < <(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "${workflow}" |
    grep -vE 'uses:[[:space:]]*[^@]+@[0-9a-f]{40}([[:space:]]|$)')
done
if [[ -z "${unpinned}" ]]; then
  pass "every action is pinned to a full commit SHA"
else
  fail "every action is pinned to a full commit SHA" "${unpinned//$'\n'/ | }"
fi

# zizmor already catches these two, but they are the specific findings this
# repository has fixed once and could reintroduce, and this check runs on
# changes zizmor's path filter does not select.
checkout_steps="$(grep -c 'uses: actions/checkout@' "${workflows[@]}" 2>/dev/null | awk -F: '{total += $NF} END {print total + 0}')"
persist_false="$(grep -c 'persist-credentials: false' "${workflows[@]}" 2>/dev/null | awk -F: '{total += $NF} END {print total + 0}')"
assert_equal "every actions/checkout sets persist-credentials: false" \
  "${persist_false}" "${checkout_steps}"

for workflow in "${workflows[@]}"; do
  assert_absent "${workflow} does not use a privileged trigger" \
    "${workflow}" '^[[:space:]]*(pull_request_target|workflow_run):'
done

# Without an explicit cap a hung job runs until GitHub's 360-minute default
# kills it, holding the workflow's concurrency group for most of a day.
missing_timeouts=""
for workflow in "${workflows[@]}"; do
  job_count="$(awk '/^jobs:/ {in_jobs = 1; next} in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:/ {count++} END {print count + 0}' "${workflow}")"
  timeout_count="$(grep -c '^[[:space:]]*timeout-minutes:' "${workflow}")"
  if ((timeout_count < job_count)); then
    missing_timeouts+="${workflow} has ${job_count} job(s) but ${timeout_count} timeout-minutes "
  fi
done
if [[ -z "${missing_timeouts}" ]]; then
  pass "every workflow job sets timeout-minutes"
else
  fail "every workflow job sets timeout-minutes" "${missing_timeouts}"
fi

# ---------------------------------------------------------------------------
group "Lint manifests (docs/quality.md: 'the two lists are maintained by hand')"

# A new test file is picked up automatically by run-tests.sh, which globs, but
# not by either ShellCheck invocation -- both list files explicitly. This has
# already reached main once: tests/test-ostree-pkg-diff-db.sh was in the
# Justfile list but not the CI one, and went ungated in CI until review caught
# it. Both lists are checked here so the next one cannot.
shopt -s nullglob
lintable=(
  tests/*.sh
  tests/e2e/*.sh
  scripts/*.sh
  system_files/usr/bin/*
  system_files/usr/libexec/*
  system_files/etc/profile.d/*.sh
)
shopt -u nullglob

missing_from_just=""
missing_from_ci=""
for target in "${lintable[@]}"; do
  [[ -f "${target}" ]] || continue
  grep -Fq -- "${target}" "${JUSTFILE}" || missing_from_just+="${target} "
  grep -Fq -- "/mnt/${target}" "${BUILD_WORKFLOW}" || missing_from_ci+="${target} "
done

if [[ -z "${missing_from_just}" ]]; then
  pass "every shell file is listed in the Justfile lint recipe"
else
  fail "every shell file is listed in the Justfile lint recipe" "missing: ${missing_from_just}"
fi

if [[ -z "${missing_from_ci}" ]]; then
  pass "every shell file is listed in the CI ShellCheck step"
else
  fail "every shell file is listed in the CI ShellCheck step" "missing: ${missing_from_ci}"
fi

# ---------------------------------------------------------------------------
printf '\n1..%d\n' "${checks_run}"
if ((failures > 0)); then
  printf 'invariants: %d of %d check(s) failed\n' "${failures}" "${checks_run}" >&2
  exit 1
fi
printf 'invariants: all %d check(s) passed\n' "${checks_run}"
