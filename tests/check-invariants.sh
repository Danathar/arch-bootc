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

# The invariant holds when PATTERN is present in FILE as an *active* line.
#
# Comment lines are stripped first, and that is the whole point rather than a
# detail. Every security control asserted below is described in a nearby
# rationale comment using the same words as the instruction that implements it:
# `PermitRootLogin prohibit-password` appears both in the sshd drop-in and in
# the comment above it, and `pam_wheel.so use_uid` appears in the sed that
# uncomments it and in three comments explaining why. A plain grep is therefore
# satisfied by the *explanation* of a control that has been deleted -- which is
# exactly backwards, since the comment is what survives a careless edit.
assert_present() {
  local description="$1" file="$2" pattern="$3" note="${4:-}"
  if [[ ! -f "${file}" ]]; then
    fail "${description}" "${file} does not exist"
    return
  fi
  # Deliberately not `grep -Ev ... | grep -Eq ...`. Under `set -o pipefail`
  # that pipeline is a race: `grep -q` exits the moment it matches, the
  # upstream grep takes SIGPIPE, and the pipeline reports 141 instead of 0 --
  # so the assertion fails at random on a tree that is perfectly fine. It was
  # observed failing roughly one run in eight before this was rewritten to use
  # a here-string, which involves no pipeline at all.
  local active
  active="$(grep -Ev '^[[:space:]]*#' "${file}")"
  if grep -Eq -- "${pattern}" <<<"${active}"; then
    pass "${description}"
  else
    fail "${description}" "${note:-no active (non-comment) line in ${file} matches: ${pattern}}"
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

# The invariant holds when PATTERN is absent from every file in FILES.
# Used where a property can be introduced from more than one place -- notably
# anything copied into the image through system_files/, which lands in the
# base stage before the desktop flavors run their own package installs.
assert_absent_in() {
  local description="$1" pattern="$2"
  shift 2
  local hits=""
  local file
  for file in "$@"; do
    [[ -f "${file}" ]] || continue
    while IFS= read -r hit; do
      hits+="${file}:${hit} "
    done < <(grep -En -- "${pattern}" "${file}" | grep -v '^[0-9]*:[[:space:]]*#')
  done
  if [[ -z "${hits}" ]]; then
    pass "${description}"
  else
    fail "${description}" "${hits}"
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

# Naming one PAM service is not enough, and the missing half is invisible to the
# assertion above because both files' lines read identically. util-linux's su
# authenticates a login shell against /etc/pam.d/su-l -- su(1) lists it as "PAM
# configuration file if --login is specified" -- and Arch ships that file with
# the same line commented out. Editing /etc/pam.d/su alone restricts `su root`
# and leaves `su - root` open to any local account, which is the form this
# repository's own prose reaches for when it describes the risk.
assert_present "the pam_wheel edit covers /etc/pam.d/su-l, which is what \`su -\` authenticates against" \
  "${CONTAINERFILE}" 'for pamfile in /etc/pam\.d/su /etc/pam\.d/su-l' \
  "a login shell uses /etc/pam.d/su-l; editing only /etc/pam.d/su leaves \`su - root\` unrestricted"

# `sed` exits 0 having changed nothing, and renovate.json automerges
# docker.io/archlinux/archlinux digest bumps, so an upstream change to either
# file's wording would turn the edit above into a no-op behind a green build.
# The check that the line ended up active is what makes that a red build.
assert_present "the pam_wheel edit is verified, not assumed" \
  "${CONTAINERFILE}" 'pam_wheel\.so use_uid is not active in' \
  "nothing fails the build when the sed matches nothing, which is how a base-image change removes this control silently"

assert_present "the root password is expired on first use" \
  "${CONTAINERFILE}" 'passwd --expire root'

# The default password must never be extended to a non-root account: Arch's
# sshd ships PasswordAuthentication yes, so a default *user* password would be
# remotely exploitable on every published image.
#
# `chpasswd` is how the Containerfile sets the root password today, but it is
# not the only spelling: `useradd -p` and `usermod -p` take a crypt hash
# directly and would set one without the word appearing anywhere. Both are
# matched too, so the assertion covers the property rather than one command.
#
# The root exclusion is anchored on a non-word character (or start of line)
# because a bare `root:` also matches an account named `svcroot`, `nonroot` or
# anything else ending in those four letters -- exactly the account this is
# supposed to refuse.
default_password_set="$(grep -En 'chpasswd|(useradd|usermod)[^|;&]*[[:space:]]-p[[:space:]]' "${CONTAINERFILE}" |
  grep -v '^[0-9]*:[[:space:]]*#' | grep -vE "(^|[^[:alnum:]_])root:")"
if [[ -z "${default_password_set}" ]]; then
  pass "no default password is set for a non-root account"
else
  fail "no default password is set for a non-root account" \
    "a password is set for something other than root: ${default_password_set//$'\n'/ | }"
fi

# Every assertion above reads the Containerfile, and the Containerfile is not
# the only way these files reach the image. `COPY system_files/ /` lands in
# base-core *before* the sshd drop-in and the pam_wheel sed below it, so a file
# committed under system_files/ can contradict each control without a single
# suspicious line appearing in the Containerfile -- the same blind spot the
# package-source group further down already reasons about, applied to the four
# closures the root password rests on:
#
#   - an sshd drop-in sorting ahead of 10-no-root-password.conf wins, because
#     sshd uses the first obtained value for a keyword and Arch's stock
#     sshd_config leaves PermitRootLogin commented;
#   - an /etc/pam.d/su with no pam_wheel line at all leaves the sed with
#     nothing to uncomment, and sed exits 0 having changed nothing;
#   - an /etc/shadow (or passwd/group) carries a credential directly, which the
#     check above cannot see because it reads the Containerfile.
#
# None of these exists today. Introducing one is a change to the root-login
# model whatever it contains, so it should be a decision rather than a diff
# nobody looked at -- the same standard the pacman configuration check holds.
shipped_login_config="$(find system_files \
  \( -path '*/etc/ssh*' \
  -o -path '*/etc/pam.d*' \
  -o -path '*/etc/security*' \
  -o -path '*/etc/sudoers*' \
  -o -name 'shadow' -o -name 'gshadow' -o -name 'passwd' -o -name 'group' \) \
  2>/dev/null)"
if [[ -z "${shipped_login_config}" ]]; then
  pass "no sshd, PAM, sudoers or account-database file is shipped through system_files/"
else
  fail "no sshd, PAM, sudoers or account-database file is shipped through system_files/" \
    "found: ${shipped_login_config//$'\n'/ | }"
fi

# ---------------------------------------------------------------------------
group "Homebrew shell integration (the fourth path to root, alongside the three above)"
# /etc/profile.d and /etc/fish/conf.d run in every login shell on the machine,
# root's included. The Homebrew prefix those fragments put on PATH is extracted
# for UID 1000, and Homebrew requires its prefix to be writable by the user
# running it, so the ownership guard in both fragments is the only thing
# stopping whoever owns that prefix from executing code in every other
# account's shell -- the same console-only argument the root password rests on,
# reached from a local session instead of a keyboard.
#
# It is asserted here because it has already been weakened once by accident.
# The first version tested the prefix with `[ -O ]`, which dereferences, so a
# symlink planted by the prefix owner answered for whatever root-owned target
# it pointed at. Nothing failed; the guard simply stopped guarding.

BREW_SETUP_DROPIN="system_files/usr/lib/systemd/system/brew-setup.service.d/10-private-tmp.conf"
BREW_SH="system_files/etc/profile.d/homebrew.sh"
BREW_FISH="system_files/etc/fish/conf.d/homebrew.fish"

for fragment in "${BREW_SH}" "${BREW_FISH}"; do
  assert_present "${fragment} reads each path entry's own owner" \
    "${fragment}" 'stat -c %u -- ' \
    "ownership is no longer read with a non-dereferencing stat"

  # `-O` and `-x` answer for a symlink's target, and `stat -L` asks the same
  # question the same way. Which target that is, is the prefix owner's choice.
  assert_absent "${fragment} makes no dereferencing ownership test" \
    "${fragment}" '(\[|test)[[:space:]]+-O[[:space:]]|stat[[:space:]]+[^|;&]*-L' \
    "a dereferencing test decides trust from a path the untrusted owner picked"

  # Removing a guard call and leaving the invocation behind is a one-line edit
  # that restores the original hole, and changes neither fragment's shape
  # enough for anything else in CI to notice. Neither fragment can carry a
  # coverage floor to catch it: .coverage-thresholds.json covers the shebanged
  # entry points under scripts/ and system_files/usr, and the cases that do
  # exercise these two source a copy of the fragment inside a mount namespace,
  # so the traced lines are not attributed to the checked-out path.
  fragment_active="$(grep -Ev '^[[:space:]]*#' "${fragment}")"
  guarded="$(grep -Ec -- '__arch_bootc_brew_trusted[[:space:]]+/' <<<"${fragment_active}")"
  invoked="$(grep -Ec -- 'brew shellenv' <<<"${fragment_active}")"
  assert_equal "${fragment} runs brew only behind the ownership guard" \
    "${guarded}" "${invoked}"
done

# Both fragments are executed by a test rather than only read by one. A test
# file that stops naming the fragment it covers, or stops existing, fails here.
assert_present "the POSIX fragment is executed by a test" \
  "tests/test-homebrew-profile.sh" 'system_files/etc/profile\.d/homebrew\.sh'

assert_present "the fish fragment is executed by a test" \
  "tests/test-homebrew-shell-integration.sh" 'system_files/etc/fish/conf\.d/homebrew\.fish'

# The image also receives shell integration this repository did not write.
# ublue-os/brew's /system_files carries /etc/profile.d/brew.sh,
# /etc/profile.d/brew-bash-completion.sh and
# /usr/share/fish/vendor_conf.d/ublue-brew.fish -- none guarded, all reading the
# prefix brew-setup.service chowns to 1000:1000 -- and it arrives through
# `COPY --from`. That is why the assertions above cannot reach it: they name
# files in this tree, and those three are not in this tree at any revision.
#
# The guarded fragments do not displace them either. The filenames differ, so
# all of them are sourced, and /etc/profile.d is read in collation order, which
# puts brew-bash-completion.sh and brew.sh ahead of homebrew.sh.
#
# What *is* in this tree is the Containerfile step that removes them and then
# fails the build on a fourth, so that is what is asserted here.
VENDORED_BREW_FRAGMENTS=(
  /etc/profile.d/brew.sh
  /etc/profile.d/brew-bash-completion.sh
  /usr/share/fish/vendor_conf.d/ublue-brew.fish
)

# Join line continuations first: the removal is one multi-line RUN, and a
# line-at-a-time grep would report the step present when only its first path
# survived an edit.
containerfile_joined="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "${CONTAINERFILE}")"
brew_removal="$(grep -E '^[[:space:]]*RUN[[:space:]]+rm -f' <<<"${containerfile_joined}" |
  grep -F -- '/etc/profile.d/brew.sh')"

if [[ -z "${brew_removal}" ]]; then
  fail "the Containerfile removes ublue-os/brew's own shell integration" \
    "no RUN step removes /etc/profile.d/brew.sh"
else
  not_removed=""
  for vendored in "${VENDORED_BREW_FRAGMENTS[@]}"; do
    grep -qF -- "${vendored}" <<<"${brew_removal}" || not_removed+="${vendored} "
  done
  if [[ -z "${not_removed}" ]]; then
    pass "the Containerfile removes ublue-os/brew's own shell integration"
  else
    fail "the Containerfile removes ublue-os/brew's own shell integration" \
      "still shipped: ${not_removed}"
  fi
fi

# Removing them before the COPY that creates them is a no-op that leaves every
# assertion above green, so the order is asserted rather than assumed.
brew_copy_line="$(grep -n 'COPY --from=ghcr.io/ublue-os/brew' "${CONTAINERFILE}" | head -1 | cut -d: -f1)"
brew_removal_line="$(grep -n 'rm -f /etc/profile.d/brew.sh' "${CONTAINERFILE}" | head -1 | cut -d: -f1)"
if [[ -n "${brew_copy_line}" && -n "${brew_removal_line}" ]] &&
  ((brew_removal_line > brew_copy_line)); then
  pass "the removal runs after the COPY that brings the fragments in"
else
  fail "the removal runs after the COPY that brings the fragments in" \
    "COPY at line ${brew_copy_line:-none}, removal at line ${brew_removal_line:-none}"
fi

# The list above is this digest's inventory. The sweep is what covers the next
# one: it fails the build on anything under the three shell-integration
# directories that names brew and is not one of the two guarded fragments.
assert_present "an unguarded fragment from a later brew digest fails the build" \
  "${CONTAINERFILE}" 'unguarded Homebrew shell integration in the image' \
  "the sweep that catches a fragment the removal list does not name is gone"

assert_present "the sweep exempts only this repository's two guarded fragments" \
  "${CONTAINERFILE}" 'grep -vxF -e /etc/profile\.d/homebrew\.sh -e /etc/fish/conf\.d/homebrew\.fish' \
  "the sweep's allowlist no longer names exactly the two guarded fragments"

# The same payload's brew-setup.service creates that prefix, and it stages a
# 154MB tarball through the fixed path /tmp/homebrew as root. `mkdir -p` exits 0
# on an existing symlink, so an account that claims the name first has root
# extract through it and has its own files copied into the prefix the unit then
# chowns to UID 1000 -- which the ownership guard above cannot refuse, because
# after the chown they are owned by the user whose shell it is. The drop-in is
# the containment; these three assertions are what notices if it, or the
# build-time check backstopping it, goes away.
assert_present "brew-setup.service stages the payload in a private /tmp" \
  "${BREW_SETUP_DROPIN}" '^PrivateTmp=yes$' \
  "the drop-in no longer contains the staging path the payload uses"

assert_present "a missing or weakened drop-in fails the build" \
  "${CONTAINERFILE}" 'is missing or does not set PrivateTmp=yes' \
  "nothing checks that the drop-in reached the image"

# PrivateTmp= contains /tmp and /var/tmp and nothing else, and the unit is not in
# this tree at any revision -- only the build sees the digest that landed.
assert_present "a payload that stages elsewhere fails the build" \
  "${CONTAINERFILE}" 'no longer stages under /tmp or /var/tmp' \
  "a payload bump could move staging out of PrivateTmp's reach unnoticed"

# Checking before the COPY reads the previous digest's unit, or no unit at all,
# and leaves every assertion above green.
brew_staging_line="$(grep -n 'no longer stages under /tmp or /var/tmp' "${CONTAINERFILE}" |
  head -1 | cut -d: -f1)"
if [[ -n "${brew_copy_line}" && -n "${brew_staging_line}" ]] &&
  ((brew_staging_line > brew_copy_line)); then
  pass "the staging check runs after the COPY that brings the unit in"
else
  fail "the staging check runs after the COPY that brings the unit in" \
    "COPY at line ${brew_copy_line:-none}, staging check at line ${brew_staging_line:-none}"
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
# Here-string rather than a pipe into `grep -q`, for the SIGPIPE reason
# explained in assert_present above.
mismatch_branch="$(grep -A3 -E 'if \[ "\$\{bootc_head\}" != "\$\{BOOTC_COMMIT\}" \]' "${CONTAINERFILE}")"
if grep -q 'exit 1' <<<"${mismatch_branch}"; then
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

# Both of these have to look beyond the Containerfile. `COPY system_files/ /`
# lands in the base stage *before* the KDE and XFCE stages run their own
# `pacman -Syu`, so a pacman.conf or pacman.d fragment copied in through that
# tree can redirect those installs without a single suspicious line appearing
# in the Containerfile itself.
shopt -s globstar nullglob
copied_files=("${CONTAINERFILE}" system_files/**)
shopt -u globstar nullglob

assert_absent_in "no third-party pacman signing key is imported" \
  'pacman-key' "${copied_files[@]}"

assert_absent_in "no third-party pacman repository is configured" \
  '^[^#]*Server[[:space:]]*=[[:space:]]*(https?|rsync)://' "${copied_files[@]}"

# A pacman configuration file arriving through system_files/ is a change to
# where packages come from, which is T3 whatever its contents. None exists
# today; introducing one should be a decision, not a diff nobody looked at.
pacman_config="$(find system_files -path '*pacman*' 2>/dev/null)"
if [[ -z "${pacman_config}" ]]; then
  pass "no pacman configuration is shipped through system_files/"
else
  fail "no pacman configuration is shipped through system_files/" \
    "found: ${pacman_config//$'\n'/ | }"
fi

# ---------------------------------------------------------------------------
group "Service enablement layout (AGENTS.md: 'Service enablement policy')"

assert_absent "systemctl preset-all is not used" \
  "${CONTAINERFILE}" 'systemctl preset-all'

# Enablement symlinks belong in /usr/lib/systemd/system/<target>.wants/, not in
# /etc, which is machine-local state subject to a three-way merge on upgrade.
# `systemctl mask` legitimately writes to /etc and is exempt -- it is the
# documented exception, and the only thing that reliably survives a package
# upgrade.
#
# There is more than one route to the forbidden state, so match the state
# rather than one spelling of it: any reference to a .wants directory under
# /etc catches `ln -s` however it is split across lines, `install -d`, a
# redirect, or anything else that writes there.
assert_absent "nothing writes to a .wants directory under /etc/systemd/system" \
  "${CONTAINERFILE}" '/etc/systemd/system/[^[:space:]]*\.wants'

# `systemctl enable` writes its symlink under /etc by design, which is the
# state the layout policy exists to avoid. `mask` and `disable` are not
# affected.
assert_absent "systemctl enable is not used (enablement goes under /usr/lib)" \
  "${CONTAINERFILE}" '^[^#]*systemctl[[:space:]]+enable'

# The same state can be committed directly rather than created at build time.
etc_wants="$(find system_files/etc/systemd -path '*.wants*' 2>/dev/null)"
if [[ -z "${etc_wants}" ]]; then
  pass "no enablement symlink is committed under system_files/etc/systemd"
else
  fail "no enablement symlink is committed under system_files/etc/systemd" \
    "found: ${etc_wants//$'\n'/ | }"
fi

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
group "Renovate pin tracking (docs/renovate.md: 'nothing will fail; updates just stop arriving')"

# Every version pin in this tree that is not a container reference or an action
# SHA is moved by a hand-written regex in renovate.json. That file is the only
# place those rules exist, and its failure mode is silence: a matchString that
# no longer matches its pin does not error, it just stops producing PRs, and a
# packageRule whose matchPackageNames no longer names a real dependency stops
# applying without saying so. docs/renovate.md states this outright for the
# bootc manager -- "nothing will fail; updates just stop arriving" -- and the
# same is true of every other manager and rule in the file.
#
# So the checks below run renovate.json's own regexes against the tree, rather
# than restating the pins here. A restated pin is a second hand-maintained copy
# with the same drift problem; a regex executed against the file it claims to
# match is the join itself.
#
# What this cannot see: Renovate's matchStrings are RE2/JS regexes and these
# run under PCRE (`grep -P`). The two agree on everything used here -- named
# groups, `\s`, `\d`, bounded repeats -- but a future matchString using a
# construct where they differ would be checked under the wrong engine.
RENOVATE="renovate.json"
ZIZMOR_WORKFLOW=".github/workflows/zizmor.yaml"

renovate_readable=0
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is available to read ${RENOVATE}" \
    "jq is not on PATH, so none of the Renovate invariants below could run"
elif ! jq -e 'type == "object"' "${RENOVATE}" >/dev/null 2>&1; then
  fail "${RENOVATE} parses as a JSON object" "jq could not parse ${RENOVATE}"
else
  pass "${RENOVATE} parses as a JSON object"
  renovate_readable=1
fi

if ((renovate_readable)); then
  repo_files=()
  while IFS= read -r repo_file; do
    repo_files+=("${repo_file#./}")
  done < <(find . -path ./.git -prune -o -type f -print | sort)

  # This repo is a fork, and Renovate skips forks unless told not to. Without
  # this single line nothing below runs at all -- no manager matches anything,
  # because no run happens.
  assert_equal "renovate is enabled on this fork" \
    "$(jq -r '.forkProcessing // "unset"' "${RENOVATE}")" "enabled"

  # docs/renovate.md, "Why merging is Renovate's job": GitHub's native
  # auto-merge gates only on *required* checks, `main` here is unprotected, so
  # there are none -- flipping this to true would let a Renovate PR merge the
  # moment it opens, about twenty minutes before its build finishes. Renovate's
  # own documentation warns about exactly this configuration.
  #
  # Read with has() rather than `.platformAutomerge // "unset"`: jq's `//`
  # treats `false` as empty, so the alternative form reports the correct
  # setting as missing and the missing setting as correct.
  assert_equal "merging waits for the build instead of GitHub's auto-merge" \
    "$(jq -r 'if has("platformAutomerge") then (.platformAutomerge | tostring) else "unset" end' "${RENOVATE}")" "false"

  manager_count="$(jq -r '.customManagers | length' "${RENOVATE}")"
  if ((manager_count == 0)); then
    fail "${RENOVATE} still declares custom regex managers" \
      "customManagers is empty, so every hand-written pin is untracked"
  else
    pass "${RENOVATE} still declares custom regex managers"
  fi

  # Collected while walking the managers, checked against the packageRules
  # afterwards: docs/renovate.md records that a `docker` datasource whose
  # matchStrings capture no digest must have digest updates disabled, because
  # Renovate's default digest pinning then finds nowhere to write the digest
  # and errors the branch. That happened twice for real (chunkah in #18, and
  # the shellcheck image in #68), so the rule is derived from the managers
  # here rather than listing today's two names.
  needs_digest_exclusion=()

  for ((manager_index = 0; manager_index < manager_count; manager_index++)); do
    dep="$(jq -r ".customManagers[${manager_index}].depNameTemplate // \"\"" "${RENOVATE}")"
    datasource="$(jq -r ".customManagers[${manager_index}].datasourceTemplate // \"\"" "${RENOVATE}")"
    if [[ -z "${dep}" ]]; then
      fail "custom manager ${manager_index} names a dependency" \
        "depNameTemplate is missing, so its updates cannot be matched by any packageRule"
      continue
    fi

    file_patterns=()
    while IFS= read -r file_pattern; do
      file_patterns+=("${file_pattern}")
    done < <(jq -r ".customManagers[${manager_index}].managerFilePatterns[]" "${RENOVATE}")

    match_strings=()
    while IFS= read -r match_string; do
      match_strings+=("${match_string}")
    done < <(jq -r ".customManagers[${manager_index}].matchStrings[]" "${RENOVATE}")

    targets=()
    while IFS= read -r target; do
      targets+=("${target}")
    done < <(
      for file_pattern in "${file_patterns[@]}"; do
        file_regex="${file_pattern#/}"
        file_regex="${file_regex%/}"
        printf '%s\n' "${repo_files[@]}" | grep -P -- "${file_regex}" || true
      done | sort -u
    )

    if ((${#targets[@]} == 0)); then
      fail "the ${dep} manager selects a file that exists" \
        "no file in the tree matches ${file_patterns[*]}"
      continue
    fi
    pass "the ${dep} manager selects a file that exists"

    strict_matches=0
    loose_matches=0
    literal_ok=1
    for match_string in "${match_strings[@]}"; do
      # The literal head of the matchString -- everything before its first
      # regex metacharacter. It is what a human writing the pin types, and
      # counting it separately is what distinguishes "the pin moved" (both
      # counts drop) from "the pin is still there but the regex no longer
      # matches it" (only the strict count drops), which is the silent case.
      literal="$(printf '%s' "${match_string}" | sed -E 's/[\\([?*+{|^$.].*$//')"
      if [[ -z "${literal}" ]]; then
        literal_ok=0
        fail "the ${dep} matchString begins with a literal" \
          "it starts with a regex metacharacter, so no independent count of its pin is possible"
        continue
      fi
      for target in "${targets[@]}"; do
        # -z makes grep treat the file as one NUL-terminated record, which is
        # what lets a matchString spanning two lines (bootc's tag + commit
        # pair) match at all; -o then emits one NUL-terminated match each, so
        # counting NULs counts matches.
        strict_matches=$((strict_matches + $(grep -Pzo -- "${match_string}" "${target}" 2>/dev/null | tr -dc '\0' | wc -c)))
        # Comments are stripped on this side only. Prose *about* a pin is not a
        # pin -- nightly-compliance.yml explains the cosign manager using the
        # words `cosign-release: vX.Y.Z` -- while the strict side deliberately
        # reads the raw file, because that is what Renovate reads.
        loose_matches=$((loose_matches + $(grep -Ev '^[[:space:]]*#' "${target}" | grep -Fc -- "${literal}" || true)))
      done
    done

    if ((strict_matches > 0)); then
      pass "the ${dep} regex still matches the pin it tracks"
    else
      fail "the ${dep} regex still matches the pin it tracks" \
        "no match in ${targets[*]}; Renovate would stop bumping ${dep} without reporting anything"
    fi

    if ((literal_ok)); then
      assert_equal "every ${dep} pin in the tree is one the regex matches" \
        "${strict_matches}" "${loose_matches}"
    fi

    if [[ "${datasource}" == "docker" ]]; then
      captures_digest=0
      for match_string in "${match_strings[@]}"; do
        [[ "${match_string}" == *'<currentDigest>'* ]] && captures_digest=1
      done
      ((captures_digest)) || needs_digest_exclusion+=("${dep}")
    fi
  done

  # Every check above is per-manager, so deleting a manager outright passes all
  # of them: the pin stays in the tree, nothing claims to track it, and updates
  # stop. docs/renovate.md's "What is tracked" table is the only other place
  # the set of custom managers is written down, so the two are joined by count
  # here -- a manager added or removed without the table moving with it fails.
  documented_managers="$(grep -c '^|.*custom regex manager' docs/renovate.md || true)"
  assert_equal "docs/renovate.md lists every custom regex manager" \
    "${documented_managers}" "${manager_count}"

  manager_deps=()
  while IFS= read -r manager_dep; do
    manager_deps+=("${manager_dep}")
  done < <(jq -r '[.customManagers[].depNameTemplate] | unique[]' "${RENOVATE}")

  # Exact string membership, deliberately not `grep -Fw`. A dependency name
  # here is full of characters grep treats as word separators, so `-w` reports
  # `bootc-dev/bootc` as present in `bootc-dev/bootc-src` -- which is precisely
  # the rename this check exists to catch.
  contains_exactly() {
    local needle="$1" candidate
    shift
    for candidate in "$@"; do
      [[ "${candidate}" == "${needle}" ]] && return 0
    done
    return 1
  }

  # A packageRule that names a dependency no custom manager produces is a rule
  # that matches nothing. Renovate does not warn about it, and the two rules
  # here that carry a safety decision -- never digest-pin chunkah/shellcheck,
  # never automerge a major bootc -- would both fail open that way.
  unmatched_rule_deps=""
  while IFS= read -r ruled_dep; do
    [[ -z "${ruled_dep}" ]] && continue
    contains_exactly "${ruled_dep}" "${manager_deps[@]}" \
      || unmatched_rule_deps+="${ruled_dep} "
  done < <(jq -r '[.packageRules[] | (.matchPackageNames // [])[]] | unique[]' "${RENOVATE}")
  assert_equal "every packageRule names a dependency some manager produces" \
    "${unmatched_rule_deps}" ""

  digest_disabled=()
  while IFS= read -r disabled_dep; do
    digest_disabled+=("${disabled_dep}")
  done < <(jq -r '
    [ .packageRules[]
      | select(.enabled == false)
      | select((.matchUpdateTypes // []) | index("digest"))
      | (.matchPackageNames // [])[] ] | unique[]' "${RENOVATE}")
  missing_exclusion=""
  for dep in "${needs_digest_exclusion[@]}"; do
    contains_exactly "${dep}" "${digest_disabled[@]}" \
      || missing_exclusion+="${dep} "
  done
  assert_equal "every digest-less docker manager has digest updates disabled" \
    "${missing_exclusion}" ""

  # Disabling `digest` alone is not enough: `pin` and `pinDigest` reach the
  # same code path, and it was a pinDigest update that errored the branch the
  # first time.
  assert_equal "the exclusion covers pin and pinDigest as well as digest" \
    "$(jq -r '["digest","pin","pinDigest"] - ([.packageRules[] | select(.enabled == false) | (.matchUpdateTypes // [])[]] | unique) | join(" ")' "${RENOVATE}")" \
    ""

  # Renovate applies packageRules in order and the last match wins, so the
  # blanket automerge rule and the bootc-major exception are only correct in
  # this order. Swap them and a major bootc bump automerges on a build that
  # never boots the image -- the one update docs/renovate.md says must never
  # merge on its own.
  blanket_index="$(jq -r 'first(.packageRules | to_entries[] | select(.value.automerge == true and ((.value | has("matchPackageNames")) | not)) | .key) // -1' "${RENOVATE}")"
  if [[ "${blanket_index}" == "-1" ]]; then
    fail "a blanket rule automerges every tracked update" \
      "no packageRule sets automerge without narrowing to specific packages"
  else
    pass "a blanket rule automerges every tracked update"
  fi

  last_bootc_rule="$(jq -r '
    [ .packageRules | to_entries[]
      | select(.value | has("automerge"))
      | select(((.value.matchPackageNames // []) | length == 0)
               or ((.value.matchPackageNames // []) | index("bootc-dev/bootc")))
      | select(((.value.matchUpdateTypes // []) | length == 0)
               or ((.value.matchUpdateTypes // []) | index("major")))
      | .key ] | last // -1' "${RENOVATE}")"
  bootc_major_index="$(jq -r '
    first(.packageRules | to_entries[]
      | select(.value.automerge == false)
      | select((.value.matchPackageNames // []) | index("bootc-dev/bootc"))
      | select((.value.matchUpdateTypes // []) | index("major"))
      | .key) // -1' "${RENOVATE}")"
  if [[ "${bootc_major_index}" == "-1" ]]; then
    fail "a major bootc bump never automerges" \
      "no packageRule sets automerge:false for a major bootc-dev/bootc update"
  else
    pass "a major bootc bump never automerges"
  fi
  assert_equal "the bootc exception is the last automerge rule that applies to it" \
    "${last_bootc_rule}" "${bootc_major_index}"
fi

# The reproduce-locally commands in docs/ci-cd.md are labelled as matching CI.
# They are a hand-written copy of a pinned version, so Renovate bumps the
# workflow and leaves the documented command behind, and the next person to
# reproduce a finding runs a different analyzer than the one that reported it.
zizmor_pin="$(sed -n 's/^[[:space:]]*ZIZMOR_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' "${ZIZMOR_WORKFLOW}")"
if [[ -z "${zizmor_pin}" ]]; then
  fail "${ZIZMOR_WORKFLOW} pins a zizmor version" "no ZIZMOR_VERSION line found"
else
  pass "${ZIZMOR_WORKFLOW} pins a zizmor version"
  documented_zizmor="$(grep -ho 'zizmor@[0-9][0-9.]*' docs/*.md | sed 's/^zizmor@//' | sort -u | tr '\n' ' ')"
  documented_zizmor="${documented_zizmor% }"
  if [[ -z "${documented_zizmor}" ]]; then
    fail "the documented zizmor command names a version" \
      "no 'zizmor@X.Y.Z' invocation found under docs/"
  else
    assert_equal "the documented zizmor command runs the version CI pins" \
      "${documented_zizmor}" "${zizmor_pin}"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n1..%d\n' "${checks_run}"
if ((failures > 0)); then
  printf 'invariants: %d of %d check(s) failed\n' "${failures}" "${checks_run}" >&2
  exit 1
fi
printf 'invariants: all %d check(s) passed\n' "${checks_run}"
