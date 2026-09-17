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

# Everything below this point is about a payload this repository does not write
# and cannot read at any revision: ublue-os/brew's /system_files, which arrives
# whole through a `COPY --from`. The checks come in that order -- first what the
# payload contains, then the two files out of it this repository acts on.
#
# The inventory is the outer one. The two checks after it read one named file
# each out of eleven, and the COPY lands further down the Containerfile than the
# root-login controls, so a payload that added /etc/sudoers.d/brew, an
# /etc/pam.d/ file or a second unit would satisfy both of them and ship anyway.
# brew-payload.manifest is the list somebody read; the build compares the
# payload against it and fails on any difference, before the COPY runs.
BREW_MANIFEST="brew-payload.manifest"

# Reading the payload without copying it needs it to be a named stage. Renovate
# tracks the digest on a `FROM` with the same `dockerfile` manager that tracked
# it on the `COPY --from=` (docs/renovate.md, "What is tracked"), so the pin is
# not weakened by moving -- but an unpinned or unnamed one would be.
assert_present "the brew payload arrives as a digest-pinned named stage" \
  "${CONTAINERFILE}" '^FROM ghcr\.io/ublue-os/brew:[^@[:space:]]+@sha256:[0-9a-f]{64} AS brew$' \
  "the payload is no longer a digest-pinned stage, so nothing can mount it to read it"

assert_present "the COPY takes the payload from that same stage" \
  "${CONTAINERFILE}" '^COPY --from=brew[[:space:]]+/system_files[[:space:]]+/$' \
  "the COPY names an image again, so what is inspected and what is copied can differ"

assert_present "the payload's whole file list is checked against a manifest" \
  "${CONTAINERFILE}" 'no longer matches brew-payload\.manifest' \
  "nothing compares the payload's file list, so a new file arrives unreviewed"

assert_present "the check reads the payload from the stage, not from a second copy" \
  "${CONTAINERFILE}" '--mount=type=bind,from=brew,source=/system_files' \
  "the inventory check no longer bind-mounts the stage it is supposed to inspect"

assert_present "the check reads the manifest out of the build context" \
  "${CONTAINERFILE}" "--mount=type=bind,source=${BREW_MANIFEST}," \
  "the manifest is not mounted, so the comparison has nothing to compare against"

# A walk restricted to regular files and symlinks is the shape of this check that
# looks right and is not: `COPY --from=brew` puts a FIFO, a socket or a device
# node in / as readily as a file, and one the walk never lists is one the
# comparison cannot fail on. Asserted both ways -- that the inverted form is
# there, and that the enumerated form has not come back -- because the second is
# what a well-meaning edit would reintroduce.
assert_present "the inventory counts every non-directory entry" \
  "${CONTAINERFILE}" "find \\. ! -type d -printf" \
  "the walk no longer covers FIFOs, sockets and device nodes in the payload"

assert_absent "the inventory does not enumerate the file types it accepts" \
  "${CONTAINERFILE}" 'find \. \\\( -type f' \
  "the walk is back to regular files and symlinks, so a special file would pass unseen"

# Checking after the COPY would still fail the build, but only after the
# unreviewed files were already in the image's root and the preset had run.
brew_copy_line="$(grep -n '^COPY --from=brew[[:space:]]' "${CONTAINERFILE}" | head -1 | cut -d: -f1)"
brew_inventory_line="$(grep -n 'no longer matches brew-payload.manifest' "${CONTAINERFILE}" |
  head -1 | cut -d: -f1)"
if [[ -n "${brew_copy_line}" && -n "${brew_inventory_line}" ]] &&
  ((brew_inventory_line < brew_copy_line)); then
  pass "the inventory check runs before the COPY that lands the payload"
else
  fail "the inventory check runs before the COPY that lands the payload" \
    "inventory check at line ${brew_inventory_line:-none}, COPY at line ${brew_copy_line:-none}"
fi

# The manifest's contents are not restated here -- a copy of a list checked
# against the list is not an assertion. What is checked is that it is still
# shaped like the thing the build compares against, and that it is joined to the
# two narrower checks below: those name files out of this same payload, and a
# manifest that stopped listing one of them would leave them green while the
# file they read had quietly gone.
if [[ ! -f "${BREW_MANIFEST}" ]]; then
  fail "the brew payload manifest exists" "${BREW_MANIFEST} is not in the tree"
else
  manifest_paths="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "${BREW_MANIFEST}" | grep -v '^$')"
  if [[ -z "${manifest_paths}" ]]; then
    fail "the brew payload manifest lists files" \
      "${BREW_MANIFEST} has no entries, so the build would reject every payload"
  else
    pass "the brew payload manifest lists files"
  fi

  # The build compares against `find -printf '%P\n'`, which is relative. A
  # leading slash fails the build rather than passing it, but it fails it in a
  # container build an hour into CI instead of here.
  absolute_entries="$(grep '^/' <<<"${manifest_paths}" || true)"
  if [[ -z "${absolute_entries}" ]]; then
    pass "every manifest entry is relative to the payload root"
  else
    fail "every manifest entry is relative to the payload root" \
      "absolute: ${absolute_entries//$'\n'/ | }"
  fi
fi

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

# Each of them is in the manifest too, because they do arrive; what proves they
# left again is the removal below. A manifest that stopped listing one would mean
# the payload had stopped shipping it -- at which point the removal is removing
# nothing, and the sweep beside it is the only thing left watching.
if [[ -n "${manifest_paths:-}" ]]; then
  unlisted=""
  for vendored in "${VENDORED_BREW_FRAGMENTS[@]}"; do
    grep -qxF -- "${vendored#/}" <<<"${manifest_paths}" || unlisted+="${vendored} "
  done
  if [[ -z "${unlisted}" ]]; then
    pass "the manifest lists the fragments the removal below deletes"
  else
    fail "the manifest lists the fragments the removal below deletes" \
      "not in ${BREW_MANIFEST}: ${unlisted}"
  fi
fi

# Removing them before the COPY that creates them is a no-op that leaves every
# assertion above green, so the order is asserted rather than assumed.
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

# Same join as the fragments above: the drop-in below and the build-time check
# beside it are written against a unit that comes from the payload, so the
# manifest listing it is what says that unit is still expected to arrive.
if [[ -n "${manifest_paths:-}" ]]; then
  if grep -qxF -- 'usr/lib/systemd/system/brew-setup.service' <<<"${manifest_paths}"; then
    pass "the manifest lists the unit the drop-in contains"
  else
    fail "the manifest lists the unit the drop-in contains" \
      "usr/lib/systemd/system/brew-setup.service is not in ${BREW_MANIFEST}"
  fi
fi

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
group "Vendored Flathub remote (docs/customizations.md, docs/renovate.md)"
# The second piece of third-party key material this repository ships, and the
# only one nothing read until now. `system_files/etc/flatpak/remotes.d/
# flathub.flatpakrepo` carries Flathub's signing key inline, and the
# `COPY system_files/ /` in base-core is the only thing that installs it: there
# is no `flatpak remote-add` anywhere in the tree, and docs/renovate.md records
# that the file is deliberately vendored rather than curled during the build,
# with no Renovate datasource watching it. So whatever this file says is what
# every desktop install trusts, and it changes only by hand.
#
# Every failure mode below is silent. flatpak reads the files under
# remotes.d/ while configuring remotes; one that it cannot parse -- wrong group
# header, a name that is not `*.flatpakrepo` -- simply does not become a remote,
# and the image builds, boots and passes every other check in this suite with
# no Flathub configured at all. A key that has been replaced is quieter still:
# the file keeps its shape, `grep GPGKey=` keeps matching, and the only thing
# that changed is which signatures the machine will accept.
#
# The fingerprint is therefore checked by computing it, not by grepping for a
# blob. That is plain OpenPGP: the decoded key starts with an old-format public
# key packet (tag 6, two-byte length), and a v4 fingerprint is the SHA-1 of
# 0x99, that length, and the packet body -- so coreutils is enough and no gpg
# binary has to be present for this to run everywhere the rest of the suite
# does.

FLATHUB_REMOTES_D="system_files/etc/flatpak/remotes.d"
FLATHUB_REPO="${FLATHUB_REMOTES_D}/flathub.flatpakrepo"
# Flathub's published signing-key fingerprint, and the repository URL the key
# signs for. Both are upstream constants: a diff that moves either of them is
# repointing every desktop install's application source and must be read as
# that rather than as a file edit.
FLATHUB_KEY_FINGERPRINT="6E5C05D979C76DAF93C081354184DD4D907A7CAE"
FLATHUB_URL="https://dl.flathub.org/repo/"

# A file in this directory whose name does not end in .flatpakrepo is not a
# remote definition; it is a file flatpak walks past. Catching that here is the
# difference between "the remote is missing" being a failed check and being a
# support question from someone whose `flatpak install` cannot find anything.
flathub_stray="$(find "${FLATHUB_REMOTES_D}" -type f ! -name '*.flatpakrepo' 2>/dev/null)"
if [[ -z "${flathub_stray}" ]]; then
  pass "every file under ${FLATHUB_REMOTES_D} is a .flatpakrepo definition"
else
  fail "every file under ${FLATHUB_REMOTES_D} is a .flatpakrepo definition" \
    "found: ${flathub_stray//$'\n'/ | }"
fi

# The remote's name comes from the filename, not from anything inside the file,
# and docs/customizations.md promises the remote is pre-configured -- which is
# only useful to a reader who can then type `flatpak install flathub ...`.
# Renaming the file renames the remote and leaves the documentation describing
# something that is not there.
flathub_definitions="$(find "${FLATHUB_REMOTES_D}" -type f -name '*.flatpakrepo' -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')"
assert_equal "the vendored definition is named for the 'flathub' remote" \
  "${flathub_definitions% }" "flathub.flatpakrepo"

if [[ ! -f "${FLATHUB_REPO}" ]]; then
  fail "${FLATHUB_REPO} exists" "the vendored Flathub remote is gone"
else
  pass "${FLATHUB_REPO} exists"

  # GKeyFile syntax: the keys are only read under this exact group header.
  flathub_first_line="$(grep -m1 -v '^[[:space:]]*$' "${FLATHUB_REPO}")"
  assert_equal "the definition opens with the [Flatpak Repo] group header" \
    "${flathub_first_line}" "[Flatpak Repo]"

  flathub_url_count="$(grep -c '^Url=' "${FLATHUB_REPO}")"
  flathub_key_count="$(grep -c '^GPGKey=' "${FLATHUB_REPO}")"
  assert_equal "the definition sets Url exactly once" "${flathub_url_count}" "1"
  assert_equal "the definition sets GPGKey exactly once" "${flathub_key_count}" "1"

  flathub_url="$(sed -n 's/^Url=//p' "${FLATHUB_REPO}" | head -1)"
  assert_equal "the remote points at Flathub's repository" \
    "${flathub_url}" "${FLATHUB_URL}"

  flathub_key_b64="$(sed -n 's/^GPGKey=//p' "${FLATHUB_REPO}" | head -1)"
  if [[ ! "${flathub_key_b64}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
    fail "GPGKey is a single line of base64" \
      "the value is empty, wrapped across lines, or contains non-base64 characters"
  else
    pass "GPGKey is a single line of base64"

    flathub_work="$(mktemp -d)"
    # Decoded with a redirect rather than a pipeline on purpose: under
    # `set -o pipefail` a reader that stops early (od -N3, head -c) sends
    # base64 a SIGPIPE and the pipeline reports 141 on a tree that is fine --
    # the same race the assert_present comment at the top of this file
    # describes.
    flathub_key_bin="${flathub_work}/flathub-key.gpg"
    if ! base64 -d <<<"${flathub_key_b64}" >"${flathub_key_bin}" 2>/dev/null; then
      fail "GPGKey decodes as base64" "base64 -d rejected the value"
    else
      pass "GPGKey decodes as base64"

      # 0x99 = old-format packet header, tag 6 (public key), two-byte length.
      flathub_header="$(od -An -tu1 -N3 "${flathub_key_bin}")"
      read -r flathub_tag flathub_len_hi flathub_len_lo <<<"${flathub_header}"
      if [[ "${flathub_tag:-}" != "153" || -z "${flathub_len_lo:-}" ]]; then
        fail "the decoded key begins with an OpenPGP public-key packet" \
          "first bytes were '${flathub_header// /,}', expected a 153 (0x99) tag"
      else
        pass "the decoded key begins with an OpenPGP public-key packet"

        flathub_packet_bytes=$((3 + flathub_len_hi * 256 + flathub_len_lo))
        flathub_decoded_bytes="$(wc -c <"${flathub_key_bin}")"
        if (( flathub_decoded_bytes < flathub_packet_bytes )); then
          fail "the public-key packet is complete" \
            "header claims ${flathub_packet_bytes} bytes, only ${flathub_decoded_bytes} decoded"
        else
          pass "the public-key packet is complete"

          flathub_fingerprint="$(head -c "${flathub_packet_bytes}" "${flathub_key_bin}" \
            | sha1sum | cut -d' ' -f1 | tr 'a-f' 'A-F')"
          assert_equal "the vendored key is Flathub's published signing key" \
            "${flathub_fingerprint}" "${FLATHUB_KEY_FINGERPRINT}"
        fi
      fi
    fi
    rm -rf -- "${flathub_work}"
  fi
fi

# Vendoring is the point: docs/renovate.md and docs/customizations.md both say
# this file is not fetched over the network during the build. A reintroduced
# fetch would restore exactly the build-time dependency on an unauthenticated
# download that vendoring removed, and would do it while both documents went on
# claiming otherwise.
assert_absent "the Flathub definition is not fetched during the build" \
  "${CONTAINERFILE}" 'dl\.flathub\.org|flathub\.flatpakrepo' \
  "an active Containerfile line fetches or writes the repo definition that system_files/ already vendors"

assert_absent "no build step adds the remote imperatively" \
  "${CONTAINERFILE}" 'flatpak[[:space:]]+remote-add'

# Nothing else installs it. If this COPY moves or narrows, the file is in the
# repository and on no image, and every check above still passes.
assert_present "system_files/ is copied into the image" \
  "${CONTAINERFILE}" '^COPY[[:space:]]+system_files/[[:space:]]+/$'

# The Containerfile comment beside the remote calls `base` "the flatpak-less
# CLI image" and says the definition is inert there. That is a claim about the
# package lists, which live in different files and move independently, so join
# the two: the desktop flavors install flatpak, base does not.
flathub_flavors_with_flatpak=""
for list in packages-base.txt packages-kde.txt packages-xfce.txt; do
  [[ -f "${list}" ]] || continue
  if grep -Eq '^[[:space:]]*flatpak[[:space:]]*$' "${list}"; then
    flathub_flavors_with_flatpak+="${list} "
  fi
done
assert_equal "the flavors that install flatpak are the desktop ones, and base is not among them" \
  "${flathub_flavors_with_flatpak% }" "packages-kde.txt packages-xfce.txt"

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

# `systemd-analyze verify` is the only thing that parses the unit files this
# repo ships, and it runs from two places that disagree about how they pick
# what to verify. The Containerfile derives the list (`find ... -maxdepth 1
# -type f`), so it cannot go stale. The Justfile's `lint` recipe names the two
# units literally, so a third unit file is verified by the image build and by
# nothing a developer runs locally -- and `just lint` is what CONTRIBUTING.md
# tells them to run before pushing.
UNIT_SRC_DIR="system_files/usr/lib/systemd/system"
shipped_units="$(find "${UNIT_SRC_DIR}" -maxdepth 1 -type f -exec basename {} \; \
  | sort | tr '\n' ' ')"
lint_units="$(grep -o 'systemd-analyze verify [^\\]*' "${JUSTFILE}" \
  | sed 's/^systemd-analyze verify //' \
  | tr ' ' '\n' | sed -n 's|^/usr/lib/systemd/system/||p' | sort | tr '\n' ' ')"
assert_equal "\`just lint\` verifies exactly the unit files this repo ships" \
  "${lint_units}" "${shipped_units}"

# The other half of that pair: if the image build ever grows a literal list too,
# both copies go stale together and nothing is left to notice.
assert_present "the image build derives its systemd-analyze list from the shipped units" \
  "${CONTAINERFILE}" 'find /tmp/shipped-units -maxdepth 1 -type f' \
  "the build no longer computes the unit list, so a new unit file can be skipped silently"

# `-maxdepth 1 -type f` means neither list reaches a drop-in, and a drop-in
# directory named for a unit that does not exist is not an error anywhere: not
# at build time, not at boot. It simply never applies. The directory name is the
# entire binding, so require that something else in the tree spells the unit it
# claims to extend -- the prune drop-in is bound by `Before=` in
# arch-bootc-prune-esp.service, the brew drop-in by the verification step in the
# Containerfile.
while IFS= read -r dropin_dir; do
  [[ -n "${dropin_dir}" ]] || continue
  dropin_unit="$(basename "${dropin_dir}")"
  dropin_unit="${dropin_unit%.d}"
  namers="$(grep -rlF -- "${dropin_unit}" "${CONTAINERFILE}" "${UNIT_SRC_DIR}" \
    | grep -v "^${dropin_dir}/" | tr '\n' ' ')"
  if [[ -n "${namers}" ]]; then
    pass "the ${dropin_unit} drop-in extends a unit this tree names elsewhere"
  else
    fail "the ${dropin_unit} drop-in extends a unit this tree names elsewhere" \
      "nothing outside ${dropin_dir} mentions ${dropin_unit}, so the drop-in may apply to nothing"
  fi
done < <(find "${UNIT_SRC_DIR}" -mindepth 1 -maxdepth 1 -type d -name '*.d' | sort)

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
group "Test execution allow-list (.claude/settings.json allows ./tests/run-tests.sh unprompted)"

# The lint lists above are about coverage. This group is about consent.
#
# `Bash(./tests/run-tests.sh)` and `Bash(just test)` are in the `allow` array of
# .claude/settings.json, so both run without a prompt, and run-tests.sh reaches
# its test files by glob. Writing one file into tests/ was therefore enough to
# execute anything the same file's `deny` and `ask` arrays exist to gate --
# `podman system prune`, `buildah rm --all`, the `virsh ... destroy`/`undefine`/
# `pool-delete`/`vol-wipe` set, `git reset --hard`, `git clean`,
# `git push --force`, `sudo`, `gh pr merge` -- with no confirmation, through a
# command that file marks safe. Those entries are how AGENTS.md's "treat every
# container, image, VM, pool, block device and untracked file as user data" is
# actually enforced; prose does not stop a subprocess.
#
# tests/test-manifest is what the glob is now checked against, and these
# assertions are the static half of that check: the runner still refuses at
# runtime, but a mismatch fails CI here too, without waiting for a test file to
# be executed first.
TEST_MANIFEST="tests/test-manifest"
RUN_TESTS="tests/run-tests.sh"

if [[ -f "${TEST_MANIFEST}" ]]; then
  pass "${TEST_MANIFEST} exists"
else
  fail "${TEST_MANIFEST} exists" "the runner has nothing to check its glob against"
fi

assert_present "run-tests.sh refuses a test file that is not in the manifest" \
  "${RUN_TESTS}" 'do not match \$\{MANIFEST\}' \
  "an unlisted file in tests/ must stop the run, not be executed by it"

assert_present "run-tests.sh refuses to run at all when the manifest is missing" \
  "${RUN_TESTS}" 'is missing, so there is nothing to check the' \
  "deleting the list must not be the way to opt out of it"

shopt -s nullglob
discovered_tests=(tests/test-*.sh tests/e2e/test-*.sh)
shopt -u nullglob

manifest_entries=()
if [[ -f "${TEST_MANIFEST}" ]]; then
  while IFS= read -r manifest_line; do
    manifest_line="${manifest_line%%#*}"
    manifest_line="${manifest_line#"${manifest_line%%[![:space:]]*}"}"
    manifest_line="${manifest_line%"${manifest_line##*[![:space:]]}"}"
    [[ -n "${manifest_line}" ]] || continue
    manifest_entries+=("${manifest_line}")
  done <"${TEST_MANIFEST}"
fi

unlisted_tests=""
for discovered_test in "${discovered_tests[@]+"${discovered_tests[@]}"}"; do
  listed_test="${discovered_test#tests/}"
  found_test=""
  for manifest_entry in "${manifest_entries[@]+"${manifest_entries[@]}"}"; do
    [[ "${manifest_entry}" == "${listed_test}" ]] && found_test="yes" && break
  done
  [[ -n "${found_test}" ]] || unlisted_tests+="${listed_test} "
done

if [[ -z "${unlisted_tests}" ]]; then
  pass "every test file in tests/ is listed in ${TEST_MANIFEST}"
else
  fail "every test file in tests/ is listed in ${TEST_MANIFEST}" \
    "unlisted: ${unlisted_tests}"
fi

stale_entries=""
for manifest_entry in "${manifest_entries[@]+"${manifest_entries[@]}"}"; do
  [[ -f "tests/${manifest_entry}" ]] || stale_entries+="${manifest_entry} "
done

if [[ -z "${stale_entries}" ]]; then
  pass "every ${TEST_MANIFEST} entry names a test file that exists"
else
  fail "every ${TEST_MANIFEST} entry names a test file that exists" \
    "no such file: ${stale_entries}"
fi

# ---------------------------------------------------------------------------
group "Read boundary on allowed Bash (.claude/settings.json: an allowed command must not read what Read(...) denies)"

# The group above is about what an allowed command may *execute*. This one is
# about what an allowed command may *read*.
#
# .claude/settings.json denies the Read tool this repository's secret-shaped
# paths -- `Read(./cosign.key)`, `Read(./.env)`, `Read(./**/*.pem)`,
# `Read(./**/id_ed25519)` -- and allows, with no prompt, `Bash(git diff*)`.
#
# `git diff <a> <b>` in its two-path mode compares the operands as plain files
# rather than as repository content. It works on untracked files, on gitignored
# files, and on paths outside the checkout entirely, and it prints their
# contents as `+` lines. The two halves are not the same tool: the deny rules
# gate the Read tool and have nothing to say about what an allowed Bash command
# then opens, so they are not weakened here -- they are simply never consulted.
# `cat ./cosign.key` would prompt; the diff form would not.
#
# No permission pattern closes that, because patterns match by command prefix
# and flags may appear in any order: `Bash(git diff --no-index*)` matches one
# spelling and misses `git diff --stat --no-index ...` and
# `git --no-pager diff --no-index ...`, and a rule that looks like a control
# while gating one argument ordering is worse than no rule. A `PreToolUse` hook
# is handed the whole command, so it can look at the invocation rather than at
# a prefix of it.
#
# Two ways a hook that merely searched the command string for `--no-index`
# still let the read through, both asserted below because both were once true
# of the hook in this repository:
#
#   * The mode needs no flag. Git enters it on its own when two operands are
#     given and either one is not repository content, so
#     `git diff /dev/null ./cosign.key` prints the file with `--no-index`
#     nowhere in the command.
#   * The shell rewrites the command before git sees it. `--no-'index'` and
#     `--no-\index` reach git as `--no-index` while a substring test on the
#     spelling that was typed finds neither.
#   * `--` does not end the mode. Git's own scan consumes a leading `--` and
#     applies the two-operand test to what follows, so
#     `git diff -- /dev/null ./cosign.key` prints the file too. Only an operand
#     before the `--` stops that scan (`git diff HEAD -- path` is safe).
#
# So the hook resolves the operands instead: two operands where any one of them
# is not a revision is the plain-file form, which is what separates
# `git diff main feature` from `git diff /dev/null ./cosign.key`. After a bare
# `--`, where no word can be a revision, it applies git's own test: two or more
# words with any one outside the working tree.
#
# The hook below is extracted with jq and *run*, not grepped. A hook asserted
# by grep is a hook asserted by its own comment: the string can be present and
# the hook still never refuse anything. It is also run with jq off PATH, since
# a gate that reads its input with a tool it does not check for is a gate that
# disappears on any host that lacks it.
#
# What this cannot see: a command that builds its arguments at runtime
# (`git diff $x $y`), one that leaves the repository first, and anything a
# command reads once it has started. This re-gates the one pre-approved command
# that reaches past the deny list; it is not a sandbox.
CLAUDE_SETTINGS=".claude/settings.json"

settings_readable=0
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is available to read ${CLAUDE_SETTINGS}" \
    "jq is not on PATH, so none of the permission invariants below could run"
elif ! jq -e 'type == "object"' "${CLAUDE_SETTINGS}" >/dev/null 2>&1; then
  fail "${CLAUDE_SETTINGS} parses as a JSON object" "jq could not parse ${CLAUDE_SETTINGS}"
else
  pass "${CLAUDE_SETTINGS} parses as a JSON object"
  settings_readable=1
fi

if ((settings_readable)); then
  # First, that the exposure is real rather than asserted. If this ever stops
  # printing the fixture, the rest of the group is about nothing.
  no_index_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${no_index_dir}/fake.key"
  no_index_output="$(git diff --no-index -- /dev/null "${no_index_dir}/fake.key" 2>/dev/null)"
  # And again with no flag at all, which is the form the first version of this
  # hook missed. Run from inside the checkout, the way the agent would.
  implicit_output="$(git diff /dev/null "${no_index_dir}/fake.key" 2>/dev/null)"
  # And behind a bare `--`, which a version of the hook read as the start of
  # repository pathspecs and stopped inspecting.
  dashdash_output="$(git diff -- /dev/null "${no_index_dir}/fake.key" 2>/dev/null)"
  rm -rf "${no_index_dir}"
  if grep -q '^+SECRET-LINE-1$' <<<"${no_index_output}"; then
    pass "git diff --no-index prints the contents of a plain file outside the index"
  else
    fail "git diff --no-index prints the contents of a plain file outside the index" \
      "this git no longer reads the path that way; re-derive what the hook below is for"
  fi

  if grep -q '^+SECRET-LINE-1$' <<<"${implicit_output}"; then
    pass "git diff prints the same contents with no --no-index flag present"
  else
    fail "git diff prints the same contents with no --no-index flag present" \
      "this git no longer enters the mode implicitly; re-derive the operand check in the hook"
  fi

  if grep -q '^+SECRET-LINE-1$' <<<"${dashdash_output}"; then
    pass "git diff prints the same contents with the two paths behind a bare --"
  else
    fail "git diff prints the same contents with the two paths behind a bare --" \
      "this git no longer enters the mode behind --; re-derive the after-dashdash check in the hook"
  fi

  # The same again for the *write* primitive in the same command family, which
  # is a separate exposure and not a variation on the one above. `--output=FILE`
  # sends the diff to the path it names instead of to stdout, so an allowed,
  # unprompted call overwrites any file this uid can reach -- `cosign.pub`, the
  # signature trust anchor copied into the image, `.claude/settings.json`, the
  # hook itself. Everything is written inside a temporary directory of this
  # fixture's own; nothing in the checkout is touched.
  output_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${output_dir}/fake.key"
  printf 'ORIGINAL-CONTENT\n' >"${output_dir}/victim-diff"
  printf 'ORIGINAL-CONTENT\n' >"${output_dir}/victim-log"
  printf 'ORIGINAL-CONTENT\n' >"${output_dir}/victim-show"
  git diff --output="${output_dir}/victim-diff" -- /dev/null "${output_dir}/fake.key" >/dev/null 2>&1

  # git log and git show are run against a repository this fixture builds
  # rather than against this checkout, and the difference is not fastidiousness:
  # CI checks out a single grafted *merge* commit, and git refuses `--output`
  # for a combined diff -- git 2.39 only after truncating the file it named,
  # git 2.55 before opening it. Which of those a host does is not the property
  # under test. One ordinary commit is, and it is also the shape the issue
  # describes: author a commit, then write its diff over the target, so the `+`
  # lines carry what the caller chose.
  payload_repo="${output_dir}/repo"
  git -c init.defaultBranch=main init --quiet "${payload_repo}" >/dev/null 2>&1
  printf 'PAYLOAD-LINE-1\n' >"${payload_repo}/committed"
  git -C "${payload_repo}" add committed >/dev/null 2>&1
  git -C "${payload_repo}" -c user.name=invariants \
    -c user.email=invariants@example.invalid -c commit.gpgsign=false \
    commit --quiet -m fixture >/dev/null 2>&1
  # No `diff` anywhere in this one: git log carries the same flag, and the
  # operand scan in the hook only ever tracked the diff subcommand.
  git -C "${payload_repo}" log -p --output="${output_dir}/victim-log" -1 >/dev/null 2>&1
  # And git show, which the issue reports as not writing at all. It does: it
  # rejects the flag only for a combined diff, and writes an ordinary commit's
  # diff in full -- which is why "git show rejects --output" is not a reason to
  # leave it ungated.
  git -C "${payload_repo}" show --output="${output_dir}/victim-show" HEAD >/dev/null 2>&1

  output_diff_written="$(cat "${output_dir}/victim-diff" 2>/dev/null)"
  output_log_written="$(cat "${output_dir}/victim-log" 2>/dev/null)"
  output_show_written="$(cat "${output_dir}/victim-show" 2>/dev/null)"
  rm -rf "${output_dir}"

  if grep -q '^+SECRET-LINE-1$' <<<"${output_diff_written}"; then
    pass "git diff --output=FILE writes content the caller chose over the file it names"
  else
    fail "git diff --output=FILE writes content the caller chose over the file it names" \
      "this git no longer redirects the diff to that path; re-derive the --output refusal in the hook"
  fi

  if grep -q '^+PAYLOAD-LINE-1$' <<<"${output_log_written}"; then
    pass "git log --output=FILE writes a committed payload over the file it names, with no git diff in the command"
  else
    fail "git log --output=FILE writes a committed payload over the file it names, with no git diff in the command" \
      "the file does not hold the commit's + lines; re-derive why the refusal covers the whole git invocation"
  fi

  if grep -q '^+PAYLOAD-LINE-1$' <<<"${output_show_written}"; then
    pass "git show --output=FILE writes a committed payload over the file it names"
  else
    fail "git show --output=FILE writes a committed payload over the file it names" \
      "this git no longer accepts --output for an ordinary commit; re-derive the git show case"
  fi

  # The hook's rationale is that these three entries stay exactly as they are.
  # If Bash(git diff*) leaves the allow list the hook is redundant; if either
  # Read deny rule goes, there is nothing left for the hook to be a route
  # around.
  assert_equal "Bash(git diff*) is still allowed without a prompt" \
    "$(jq -r '[.permissions.allow[]? | select(. == "Bash(git diff*)")] | length' "${CLAUDE_SETTINGS}")" "1"

  assert_equal "Read(./cosign.key) is still denied" \
    "$(jq -r '[.permissions.deny[]? | select(. == "Read(./cosign.key)")] | length' "${CLAUDE_SETTINGS}")" "1"

  assert_equal "Read(./.env) is still denied" \
    "$(jq -r '[.permissions.deny[]? | select(. == "Read(./.env)")] | length' "${CLAUDE_SETTINGS}")" "1"

  # And these two, which are what make the write above unprompted. They are
  # separate entries from Bash(git diff*) and the write primitive reaches the
  # same place through either of them, so each is asserted on its own rather
  # than inferred from the diff rule.
  assert_equal "Bash(git log*) is still allowed without a prompt" \
    "$(jq -r '[.permissions.allow[]? | select(. == "Bash(git log*)")] | length' "${CLAUDE_SETTINGS}")" "1"

  assert_equal "Bash(git show*) is still allowed without a prompt" \
    "$(jq -r '[.permissions.allow[]? | select(. == "Bash(git show*)")] | length' "${CLAUDE_SETTINGS}")" "1"

  # A prefix deny for the flag would read as coverage while gating exactly one
  # argument ordering. The hook is the control; a rule that looks like a second
  # one is a liability.
  no_index_deny="$(jq -r '[.permissions.deny[]? | select(test("--no-index"))] | join(" ")' "${CLAUDE_SETTINGS}")"
  if [[ -z "${no_index_deny}" ]]; then
    pass "no deny pattern claims to gate --no-index by prefix"
  else
    fail "no deny pattern claims to gate --no-index by prefix" \
      "a prefix rule matches one flag ordering and reads as coverage: ${no_index_deny}"
  fi

  # The same argument for the write half: `Bash(git diff --output*)` would
  # match one spelling of one subcommand and miss `git log -p --output=`,
  # `git --no-pager diff --output=` and every other ordering.
  output_deny="$(jq -r '[.permissions.deny[]? | select(test("--output"))] | join(" ")' "${CLAUDE_SETTINGS}")"
  if [[ -z "${output_deny}" ]]; then
    pass "no deny pattern claims to gate --output by prefix"
  else
    fail "no deny pattern claims to gate --output by prefix" \
      "a prefix rule matches one flag ordering and reads as coverage: ${output_deny}"
  fi

  bash_hooks=()
  while IFS= read -r hook_command; do
    [[ -n "${hook_command}" ]] && bash_hooks+=("${hook_command}")
  done < <(jq -r '.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]? | select(.type == "command") | .command' "${CLAUDE_SETTINGS}")

  if ((${#bash_hooks[@]} > 0)); then
    pass "${CLAUDE_SETTINGS} declares a PreToolUse command hook on Bash"
  else
    fail "${CLAUDE_SETTINGS} declares a PreToolUse command hook on Bash" \
      "nothing is handed the command string, so every flag ordering above is unprompted"
  fi

  # Runs every Bash PreToolUse hook against PAYLOAD on stdin, the way Claude
  # Code invokes them. Exit status 2 is what Claude Code reads as "refuse this
  # call and show stderr to the agent", so a refusal is the highest status seen
  # plus the text the agent would be shown.
  hook_status=0
  hook_stderr=""
  run_bash_hooks() {
    local payload="$1"
    local hook err rc
    hook_status=0
    hook_stderr=""
    for hook in "${bash_hooks[@]+"${bash_hooks[@]}"}"; do
      err="$(printf '%s' "${payload}" | bash -c "${hook}" 2>&1 >/dev/null)"
      rc=$?
      ((rc > hook_status)) && hook_status="${rc}"
      [[ -n "${err}" ]] && hook_stderr+="${err} "
    done
    return 0
  }

  assert_hook_refuses() {
    local description="$1" command="$2"
    local payload
    payload="$(jq -nc --arg c "${command}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${payload}"
    if ((hook_status == 2)) && [[ -n "${hook_stderr}" ]]; then
      pass "${description}"
    else
      fail "${description}" \
        "exit ${hook_status} with stderr '${hook_stderr:-<none>}'; wanted exit 2 and an explanation"
    fi
  }

  # Exit 2 alone cannot tell this hook's two refusals apart, and the space form
  # `git diff --output /tmp/x HEAD~1 HEAD` was already refused before there was
  # a rule for it -- by accident, because the operand scan counted the path as
  # a second unresolved operand. Asserting which refusal fired is what
  # separates "refused for the stated reason" from "refused today, and
  # permitted the moment that accident stops holding".
  assert_hook_refuses_naming() {
    local description="$1" command="$2" wanted="$3"
    local payload
    payload="$(jq -nc --arg c "${command}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${payload}"
    if ((hook_status == 2)) && [[ "${hook_stderr}" == *"${wanted}"* ]]; then
      pass "${description}"
    else
      fail "${description}" \
        "exit ${hook_status} with stderr '${hook_stderr:-<none>}'; wanted exit 2 naming '${wanted}'"
    fi
  }

  assert_hook_payload_permits() {
    local description="$1" payload="$2"
    run_bash_hooks "${payload}"
    if ((hook_status == 0)) && [[ -z "${hook_stderr}" ]]; then
      pass "${description}"
    else
      fail "${description}" \
        "exit ${hook_status} with stderr '${hook_stderr:-<none>}'; wanted a silent exit 0"
    fi
  }

  assert_hook_permits() {
    local description="$1" command="$2"
    local payload
    payload="$(jq -nc --arg c "${command}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    assert_hook_payload_permits "${description}" "${payload}"
  }

  # The spelling the allow rule admits today, plus the orderings a prefix deny
  # would miss.
  assert_hook_refuses "the hook refuses git diff --no-index against ./cosign.key" \
    'git diff --no-index -- /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the flag after another flag" \
    'git diff --stat --no-index -- /dev/null ./.env'
  assert_hook_refuses "the hook refuses the flag behind a git-level option" \
    'git --no-pager diff --no-index -- /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the flag reached outside the checkout" \
    'git diff --no-color --no-index -- /dev/null /home/someone/.ssh/id_ed25519'

  # The flagless form. Git enters the same mode on its own, so a gate that only
  # matched the flag string left the disclosure route exactly as it found it.
  assert_hook_refuses "the hook refuses the two-path form with no flag at all" \
    'git diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the flagless form reached outside the checkout" \
    'git diff /dev/null /home/someone/.ssh/id_ed25519'
  assert_hook_refuses "the hook refuses two bare operands that are not revisions" \
    'git diff cosign.key .env'
  assert_hook_refuses "the hook refuses the flagless form behind another command" \
    'ls -l && git diff /dev/null ./cosign.key'

  # The same mode behind a bare `--`. Git consumes a leading `--` and applies
  # its two-operand test to the words after it, so treating them as pathspecs
  # that never open a plain file let this exact form through once.
  assert_hook_refuses "the hook refuses the two-path form behind a bare --" \
    'git diff -- /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the -- form after another flag" \
    'git diff --stat -- /dev/null ./.env'
  assert_hook_refuses "the hook refuses the -- form reached outside the checkout" \
    'git diff -- /dev/null /home/someone/.ssh/id_ed25519'
  assert_hook_refuses "the hook refuses the -- form with one operand inside the checkout" \
    'git diff -- ./AGENTS.md /home/someone/.ssh/id_ed25519'
  assert_hook_refuses "the hook refuses the -- form that climbs out of the checkout" \
    'git diff -- ../outside ./cosign.key'

  # Spellings the shell rewrites before git sees them. Each of these reaches
  # git as --no-index while the literal string is absent from the command.
  assert_hook_refuses "the hook refuses a quoted spelling of the flag" \
    "git diff --no-'index' -- /dev/null ./cosign.key"
  assert_hook_refuses "the hook refuses a backslash spelling of the flag" \
    'git diff --no-\index -- /dev/null ./cosign.key'

  # The write half of the same family. `--output=FILE` is a destination, not a
  # filter, and the fixtures above show what it does to the file it names. The
  # refusal is asserted by its message rather than by exit status alone,
  # because the operand scan refuses some of these spellings for an unrelated
  # reason that would stop holding if it were ever rewritten.
  assert_hook_refuses_naming "the hook refuses git diff --output=FILE" \
    'git diff --output=/tmp/written HEAD~1 HEAD' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses the space form of --output" \
    'git diff --output /tmp/written HEAD~1 HEAD' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output behind a git-level option" \
    'git --no-pager diff --output=/tmp/written' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output after another diff flag" \
    'git diff --stat --output=/tmp/written' '--output=FILE'
  # git log is outside the operand scan entirely -- it tracks the diff
  # subcommand and nothing else -- so these two are the reason the refusal sits
  # ahead of it and covers the whole git invocation.
  assert_hook_refuses_naming "the hook refuses --output on git log" \
    'git log -p --output=/tmp/written -1' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses the space form on git log" \
    'git log -p --output /tmp/written -1' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output on git show" \
    'git show --output=/tmp/written HEAD' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output behind another command" \
    'ls -l && git log -p --output=/tmp/written -1' '--output=FILE'
  # The shell rewrites this one exactly as it rewrites --no-'index'.
  assert_hook_refuses_naming "the hook refuses a requoted spelling of --output" \
    "git diff --out'put'=/tmp/written" '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output written to the trust anchor" \
    'git log -p --output=cosign.pub -1' '--output=FILE'

  # A two-token git global option used to make the operand scan lose track of
  # git altogether: the directory word was read as the subcommand, `seen_git`
  # was cleared, and the scan below never started. Nothing auto-approves these
  # spellings today -- no allow rule matches them, so they prompt -- but a gate
  # whose coverage rests on an allow rule's exact prefix is one allow-list edit
  # from silence.
  assert_hook_refuses "the hook refuses the plain-file form reached through git -C" \
    'git -C / diff /dev/null etc/shadow'
  assert_hook_refuses "the hook refuses the plain-file form reached through --git-dir" \
    'git --git-dir /tmp/elsewhere/.git diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the plain-file form reached through --work-tree" \
    'git --work-tree /tmp/elsewhere diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the plain-file form behind git -c" \
    'git -c core.pager=cat diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the plain-file form behind --namespace" \
    'git --namespace ns diff /dev/null ./cosign.key'
  assert_hook_refuses_naming "the hook refuses --output reached through git -C" \
    'git -C /tmp diff --output=/tmp/written' '--output=FILE'

  # Shell operators need no whitespace around them, and this scan splits on
  # whitespace. `git log -1 && (git log -p --output=cosign.pub -1)` tokenizes
  # as `(git`, which is not the word `git`: the second command was not
  # recognized as a git invocation at all, so every test above stayed switched
  # off for it and the hook exited 0 while the trust anchor was overwritten.
  assert_hook_refuses_naming "the hook refuses --output inside an attached subshell" \
    'git log -1 && (git log -p --output=cosign.pub -1)' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output where the subshell opens the command" \
    '(git log -p --output=cosign.pub -1)' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output behind an unspaced &&" \
    'ls&&git log -p --output=cosign.pub -1' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses --output behind an unspaced ;" \
    'ls;git log -p --output=cosign.pub -1' '--output=FILE'
  # shellcheck disable=SC2016 # the literal $( is the point: this is the
  # command string the hook is handed, not one this script expands.
  assert_hook_refuses_naming "the hook refuses --output inside a command substitution" \
    'echo $(git log -p --output=cosign.pub -1)' '--output=FILE'
  # And an operator sitting inside an argument must not end the git invocation
  # either, which is why the git latch is not cleared at a command boundary:
  # the pipe here would otherwise hand the write primitive back unwatched.
  assert_hook_refuses_naming "the hook refuses --output after an operator inside an argument" \
    'git log --grep=a|b --output=cosign.pub -1' '--output=FILE'
  # The read half had the same hole, with no flag and an ordinary path.
  assert_hook_refuses "the hook refuses the plain-file form behind an unspaced &&" \
    'ls&&git diff /dev/null ./cosign.key'
  assert_hook_refuses "the hook refuses the plain-file form inside an attached subshell" \
    '(git diff /dev/null ./cosign.key)'
  assert_hook_refuses "the hook refuses the plain-file form behind a bare -- and an unspaced ;" \
    'ls;git diff -- /dev/null ./cosign.key'

  # And has not quietly traded the allow rule back for a prompt: the ordinary
  # reads this repository does all day must stay silent.
  assert_hook_permits "an ordinary git diff is still unprompted" 'git diff'
  assert_hook_permits "git diff --stat is still unprompted" 'git diff --stat'
  assert_hook_permits "a scoped diff against history is still unprompted" \
    'git diff HEAD~1 -- system_files/'
  assert_hook_permits "git status --short is still unprompted" 'git status --short'
  # Two operands are the plain-file form unless both resolve as revisions, so
  # the check is against the repository, not against the shape of the word. A
  # name that is not a revision here is treated as a path and refused, which is
  # the conservative side of that call.
  # HEAD twice rather than HEAD~1 or a branch name: CI checks out at depth 1,
  # where neither of those resolves, and the point of the assertion is that two
  # revisions are permitted, not which two.
  assert_hook_permits "a two-revision diff is still unprompted" 'git diff HEAD HEAD'
  assert_hook_permits "a diff of one tracked path is still unprompted" 'git diff ./AGENTS.md'
  assert_hook_permits "a pathspec after -- is still unprompted" 'git diff -- ./cosign.key'
  # Two pathspecs inside the working tree are an ordinary diff: git's own
  # test only enters the plain-file mode when one of them lies outside it.
  assert_hook_permits "two pathspecs after -- inside the checkout are still unprompted" \
    'git diff -- ./AGENTS.md ./tests/'
  assert_hook_permits "a revision before -- keeps later pathspecs unprompted" \
    'git diff HEAD -- ./AGENTS.md ./tests/'
  assert_hook_permits "the word diff outside a git call is not a git diff" \
    'grep diff a.txt b.txt'
  # Reading history is the whole point of the two commands the write refusal
  # now also covers, so both must stay silent.
  assert_hook_permits "an ordinary git log -p is still unprompted" 'git log -p -1'
  assert_hook_permits "git show of a revision is still unprompted" 'git show HEAD'
  # --output-indicator-* changes the character in column one, not where the
  # output goes. It is not the write primitive and a gate that cannot tell the
  # two apart would be refusing ordinary formatting.
  assert_hook_permits "git diff --output-indicator-new is still unprompted" \
    'git diff --output-indicator-new=%'
  assert_hook_permits "git log --output-indicator-old is still unprompted" \
    'git log --output-indicator-old=- -1'
  # The refusal is scoped to git invocations. --output is an ordinary flag on
  # other tools, and this hook is not a general write gate -- a command like
  # this one is not on the allow list and prompts on its own account.
  assert_hook_permits "--output on a command that is not git is still unprompted" \
    'sort --output=/tmp/sorted packages-base.txt'
  # Splitting on operator characters must not cost the chained reads this
  # repository does all day: a command boundary restarts the operand scan.
  assert_hook_permits "chained ordinary git reads are still unprompted" \
    'git status && git log --oneline -5'
  assert_hook_permits "an ordinary git read inside a subshell is still unprompted" \
    '(git log -p -1)'
  # Two-token git global options, now that the scan follows them: an ordinary
  # diff behind one is still an ordinary diff.
  assert_hook_permits "a two-revision diff behind git -C is still unprompted" \
    'git -C . diff HEAD HEAD'
  assert_hook_permits "git -c ... diff --stat is still unprompted" \
    'git -c core.pager=cat diff --stat'

  # PreToolUse fires for every Bash call, so a payload shaped differently from
  # the expected one must not block the session.
  assert_hook_payload_permits "an empty payload does not block the session" '{}'
  assert_hook_payload_permits "a payload with no command does not block the session" \
    '{"tool_input":{}}'
  assert_hook_payload_permits "an empty command does not block the session" \
    '{"tool_input":{"command":""}}'
  # Fail closed on a host that cannot inspect the payload. These hooks run
  # wherever a contributor runs Claude Code, not only on the jq-equipped CI
  # runner, and AGENTS.md requires that a control of this kind fail closed
  # rather than wave the call through when a dependency is missing.
  no_jq_dir="$(mktemp -d)"
  for no_jq_tool in bash env git cat; do
    no_jq_path="$(command -v "${no_jq_tool}" 2>/dev/null)" || continue
    ln -sf "${no_jq_path}" "${no_jq_dir}/${no_jq_tool}"
  done

  no_jq_status=0
  no_jq_stderr=""
  for hook_command in "${bash_hooks[@]+"${bash_hooks[@]}"}"; do
    no_jq_payload="$(jq -nc '{tool_name: "Bash", tool_input: {command: "git diff --no-index -- /dev/null ./cosign.key"}}')"
    no_jq_err="$(printf '%s' "${no_jq_payload}" | PATH="${no_jq_dir}" bash -c "${hook_command}" 2>&1 >/dev/null)"
    no_jq_rc=$?
    ((no_jq_rc > no_jq_status)) && no_jq_status="${no_jq_rc}"
    [[ -n "${no_jq_err}" ]] && no_jq_stderr+="${no_jq_err} "
  done
  rm -rf "${no_jq_dir}"

  if ((no_jq_status == 2)) && [[ -n "${no_jq_stderr}" ]]; then
    pass "the hook refuses rather than passing the call through when jq is missing"
  else
    fail "the hook refuses rather than passing the call through when jq is missing" \
      "exit ${no_jq_status} with stderr '${no_jq_stderr:-<none>}'; a missing dependency silently disables the gate"
  fi

  # A malformed payload is the same case: the hook cannot tell what the call
  # does, so it must not decide that it is safe.
  run_bash_hooks 'not json at all'
  if ((hook_status == 2)) && [[ -n "${hook_stderr}" ]]; then
    pass "the hook refuses a payload it cannot parse"
  else
    fail "the hook refuses a payload it cannot parse" \
      "exit ${hook_status} with stderr '${hook_stderr:-<none>}'; an unparseable payload passed uninspected"
  fi

  # The hook is a file in the repository now, so the settings entry pointing at
  # a path that does not exist, or at one nothing can execute, is a way for
  # every assertion above to keep passing against a gate that never runs.
  if [[ -x .claude/hooks/gate-git-diff.sh ]]; then
    pass ".claude/hooks/gate-git-diff.sh exists and is executable"
  else
    fail ".claude/hooks/gate-git-diff.sh exists and is executable" \
      "the settings entry names a hook that cannot run, so Bash calls go uninspected"
  fi

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
group "Installation runbook (docs/installation.md is a hand copy of the Justfile, the Containerfile targets and scripts/quickstart.sh)"

# docs/installation.md is the document a new user follows, and every literal in
# it -- recipe names, `BUILD_*` variables, the default disk size, the flavor
# suffixes, the published image names, the exact `bootc install to-disk` flag
# set, and the list of things the quickstart refuses to do -- is a hand copy of
# something else in this tree. Nothing read it: it is not shell, so
# tests/check-coverage.sh cannot see it, and no test file mentioned it. A
# renamed recipe, a different default, or a guardrail deleted from
# scripts/quickstart.sh left the documented procedure describing a repository
# that no longer exists, with every check still green.
#
# What follows joins the doc to the things it claims, in both directions where
# a one-way check would pass on an empty extraction.

INSTALL_DOC="docs/installation.md"
QUICKSTART="scripts/quickstart.sh"

# Commands the doc actually tells a reader to run: fenced blocks plus inline
# code spans. Prose is excluded deliberately -- "this project uses `just` as a
# command runner" is not an instruction to run a recipe named `as`.
install_doc_commands="$( {
  awk '/^```/ { in_block = !in_block; next } in_block' "${INSTALL_DOC}"
  # The backticks are markdown, not command substitution.
  # shellcheck disable=SC2016
  grep -o '`[^`]*`' "${INSTALL_DOC}" | tr -d '`'
} )"

# Recipe names the Justfile defines. `:=` assignments are variables, not
# recipes, and recipe bodies are indented, so an unindented name followed by a
# `:` is the whole grammar that matters here.
justfile_recipes="$(grep -v ':=' "${JUSTFILE}" |
  sed -n 's/^\([a-z][a-zA-Z0-9_-]*\)\([[:space:]][^:]*\)\{0,1\}:.*$/\1/p' | sort -u)"
documented_recipes="$(grep -Eo '(^|[^[:alnum:]_.-])just [a-z][a-zA-Z0-9-]*' <<<"${install_doc_commands}" |
  sed 's/.*just //' | sort -u)"

# The load-bearing subset has to still be named, or deleting the lines that
# name a recipe would satisfy the "every documented recipe exists" check by
# documenting nothing at all.
missing_from_doc=""
for recipe in build-base build-containerfile build-xfce generate-bootable-image quickstart; do
  grep -qx -- "${recipe}" <<<"${documented_recipes}" || missing_from_doc+="${recipe} "
done
if [[ -z "${missing_from_doc}" ]]; then
  pass "the installation runbook still names the build, image and quickstart recipes"
else
  fail "the installation runbook still names the build, image and quickstart recipes" \
    "${INSTALL_DOC} no longer runs: ${missing_from_doc}"
fi

undefined_recipes=""
while IFS= read -r recipe; do
  [[ -n "${recipe}" ]] || continue
  grep -qx -- "${recipe}" <<<"${justfile_recipes}" || undefined_recipes+="${recipe} "
done <<<"${documented_recipes}"
if [[ -z "${undefined_recipes}" ]]; then
  pass "every \`just\` recipe docs/installation.md tells a reader to run is defined in the Justfile"
else
  fail "every \`just\` recipe docs/installation.md tells a reader to run is defined in the Justfile" \
    "documented but not a recipe: ${undefined_recipes}"
fi

# `BUILD_*` knobs. The Justfile reads them through env(); a renamed variable
# leaves the documented override silently doing nothing, because `just` accepts
# an unknown environment variable without complaint.
documented_build_env="$(grep -Eo 'BUILD_[A-Z_]+' "${INSTALL_DOC}" | sort -u)"
unread_build_env=""
while IFS= read -r var; do
  [[ -n "${var}" ]] || continue
  grep -q "env(\"${var}\"" "${JUSTFILE}" || unread_build_env+="${var} "
done <<<"${documented_build_env}"
if [[ -z "${unread_build_env}" ]]; then
  pass "every BUILD_* override docs/installation.md documents is read by the Justfile"
else
  fail "every BUILD_* override docs/installation.md documents is read by the Justfile" \
    "documented but never read: ${unread_build_env}"
fi

for var in BUILD_DISK_SIZE BUILD_FLAVOR; do
  if grep -qx -- "${var}" <<<"${documented_build_env}"; then
    pass "docs/installation.md still documents ${var}"
  else
    fail "docs/installation.md still documents ${var}" \
      "the override exists in the Justfile but the runbook no longer mentions it"
  fi
done

# Disk size. The doc's `truncate` line, the qcow2 filename it uses from there
# on, and the Justfile default are three copies of one number.
just_disk_size="$(sed -n 's/^disk_size[[:space:]]*:=[[:space:]]*env("BUILD_DISK_SIZE",[[:space:]]*"\([^"]*\)").*/\1/p' "${JUSTFILE}")"
doc_truncate_size="$(grep -Eo 'truncate -s [0-9]+[A-Za-z]?' "${INSTALL_DOC}" | awk '{ print $3 }' | sort -u | tr '\n' ' ')"
doc_truncate_size="${doc_truncate_size% }"
if [[ -z "${just_disk_size}" ]]; then
  fail "the Justfile still defaults the generated disk size" "no disk_size := env(\"BUILD_DISK_SIZE\", ...) line"
else
  assert_equal "docs/installation.md creates the raw disk at the Justfile's default size" \
    "${doc_truncate_size}" "${just_disk_size}"
  doc_qcow_size="$(grep -Eo 'arch-bootc-[0-9]+[a-z]?\.qcow2' "${INSTALL_DOC}" | sed 's/^arch-bootc-//; s/\.qcow2$//' | sort -u | tr '\n' ' ')"
  doc_qcow_size="${doc_qcow_size% }"
  assert_equal "the qcow2 filename docs/installation.md carries forward names that same size" \
    "${doc_qcow_size}" "${just_disk_size,,}"
  # The quickstart prompts for the same default, so a reader who takes the
  # guided path lands on the disk the manual path describes.
  quickstart_disk_default="$(sed -n 's/^[[:space:]]*ask DISK_SIZE .*"\([0-9]*[A-Za-z]\)"[[:space:]]*$/\1/p' "${QUICKSTART}")"
  assert_equal "scripts/quickstart.sh offers the same default disk size" \
    "${quickstart_disk_default}" "${just_disk_size}"
fi

# Flavors. The doc names three published images; the Containerfile defines the
# targets and .github/workflows/build.yml builds the matrix. All three lists
# are maintained by hand.
containerfile_flavors="$(sed -n 's/^FROM base-core AS \([a-z0-9-]*\).*/\1/p' "${CONTAINERFILE}" | sort -u | tr '\n' ' ')"
containerfile_flavors="${containerfile_flavors% }"
workflow_flavors="$(sed -n 's/^[[:space:]]*flavor:[[:space:]]*\[\(.*\)\].*/\1/p' "${BUILD_WORKFLOW}" |
  tr -d ' ' | tr ',' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
workflow_flavors="${workflow_flavors% }"
doc_flavors="$(grep -Eo 'arch-bootc-[a-z]+' "${INSTALL_DOC}" | sed 's/^arch-bootc-//' | sort -u | tr '\n' ' ')"
doc_flavors="${doc_flavors% }"
if [[ -z "${containerfile_flavors}" || -z "${workflow_flavors}" || -z "${doc_flavors}" ]]; then
  fail "the flavor list can be read from the Containerfile, the build workflow and the runbook" \
    "Containerfile: '${containerfile_flavors}', workflow: '${workflow_flavors}', doc: '${doc_flavors}'"
else
  assert_equal "the build workflow builds exactly the Containerfile's flavor targets" \
    "${workflow_flavors}" "${containerfile_flavors}"
  assert_equal "docs/installation.md names exactly the published flavors" \
    "${doc_flavors}" "${workflow_flavors}"
fi

# Local tag vs published name. This asymmetry is the one thing in the doc most
# likely to be "tidied" into consistency: a locally built kde image is
# *unsuffixed* (`arch-bootc:latest`), while every published image -- kde
# included -- carries its flavor suffix.
assert_present "the Justfile leaves the kde flavor's local tag unsuffixed" \
  "${JUSTFILE}" 'image_ref[[:space:]]*:=[[:space:]]*if flavor == "kde"' \
  "docs/installation.md tells the reader a local kde build is arch-bootc:latest"
just_image_name="$(sed -n 's/^image_name[[:space:]]*:=[[:space:]]*env("BUILD_IMAGE_NAME",[[:space:]]*"\([^"]*\)").*/\1/p' "${JUSTFILE}")"
just_image_tag="$(sed -n 's/^image_tag[[:space:]]*:=[[:space:]]*env("BUILD_IMAGE_TAG",[[:space:]]*"\([^"]*\)").*/\1/p' "${JUSTFILE}")"
if [[ -z "${just_image_name}" || -z "${just_image_tag}" ]]; then
  fail "the Justfile defaults the local image name and tag" \
    "name: '${just_image_name}', tag: '${just_image_tag}'"
elif grep -qF -- "${just_image_name}:${just_image_tag}" "${INSTALL_DOC}"; then
  pass "docs/installation.md names the local kde tag the Justfile actually builds"
else
  fail "docs/installation.md names the local kde tag the Justfile actually builds" \
    "the runbook never mentions ${just_image_name}:${just_image_tag}"
fi

# build.yml publishes ${IMAGE_NAME}-${flavor} for every flavor, so an
# unsuffixed ghcr.io reference in the runbook points at a package that is never
# pushed -- a 404 for the reader, on the very first command of Path A.
assert_absent "docs/installation.md never points at an unsuffixed published image" \
  "${INSTALL_DOC}" 'ghcr\.io/[^ /]+/arch-bootc:' \
  "the workflow publishes arch-bootc-<flavor>; an unsuffixed ghcr.io tag does not exist"
assert_present "the build workflow still suffixes the published image with the flavor" \
  "${BUILD_WORKFLOW}" 'IMAGE_NAME=\$\{IMAGE_NAME,,\}-\$\{\{ matrix\.flavor \}\}'

# The `bootc install to-disk` flag set. The doc prints it twice (to a file via
# loopback, and straight at a device), the Justfile runs the first form and
# scripts/quickstart.sh runs both. Flags here are not cosmetic: dropping
# --wipe, --composefs-backend or --bootloader changes what gets installed.
#
# Continuation lines are joined first, then everything from `bootc install
# to-disk` onwards is read, so the surrounding `podman run` flags are not
# mistaken for installer flags.
bootc_install_flags() {
  local want="$1" invocation flags
  sed -e 's/^[[:space:]]*#.*$//' -e ':a' -e '/\\$/N' -e 's/\\\n[[:space:]]*/ /' -e 'ta' |
    grep -o 'bootc install to-disk.*' |
    while IFS= read -r invocation; do
      flags="$(grep -Eo -- '--[a-z-]+' <<<"${invocation}" | sort -u | tr '\n' ' ')"
      flags="${flags% }"
      [[ -n "${flags}" ]] || continue
      case "${flags}" in
        *--via-loopback*) [[ "${want}" == "loopback" ]] && printf '%s\n' "${flags}" ;;
        *) [[ "${want}" == "device" ]] && printf '%s\n' "${flags}" ;;
      esac
    done | sort -u | tr '\n' '/'
}

doc_loopback_flags="$(printf '%s\n' "${install_doc_commands}" | bootc_install_flags loopback)"
doc_device_flags="$(printf '%s\n' "${install_doc_commands}" | bootc_install_flags device)"
just_loopback_flags="$(bootc_install_flags loopback <"${JUSTFILE}")"
quickstart_loopback_flags="$(bootc_install_flags loopback <"${QUICKSTART}")"
quickstart_device_flags="$(bootc_install_flags device <"${QUICKSTART}")"

if [[ -z "${doc_loopback_flags}" || -z "${doc_device_flags}" ]]; then
  fail "docs/installation.md still prints both bootc install forms" \
    "loopback: '${doc_loopback_flags}', device: '${doc_device_flags}'"
else
  assert_equal "the documented loopback install runs the flags \`just generate-bootable-image\` runs" \
    "${doc_loopback_flags}" "${just_loopback_flags}"
  assert_equal "the documented loopback install runs the flags the quickstart runs" \
    "${doc_loopback_flags}" "${quickstart_loopback_flags}"
  assert_equal "the documented bare-metal install runs the flags the quickstart runs" \
    "${doc_device_flags}" "${quickstart_device_flags}"
fi

# --via-loopback is a guardrail, not a detail: the doc promises image *files*
# are only ever installed through it, and the difference between the two forms
# above is exactly that promise.
if [[ "${doc_device_flags}" == *"--via-loopback"* ]]; then
  fail "the documented bare-metal install writes at the device, not through a loop device" \
    "--via-loopback appeared in the device form"
else
  pass "the documented bare-metal install writes at the device, not through a loop device"
fi

# The filesystem the installer is told to create is spelled out in the doc and
# defaulted in the Justfile.
just_filesystem="$(sed -n 's/^filesystem[[:space:]]*:=[[:space:]]*env("BUILD_FILESYSTEM",[[:space:]]*"\([^"]*\)").*/\1/p' "${JUSTFILE}")"
doc_filesystem="$(grep -Eo '\-\-filesystem [a-z0-9]+' "${INSTALL_DOC}" | awk '{ print $2 }' | sort -u | tr '\n' ' ')"
doc_filesystem="${doc_filesystem% }"
quickstart_filesystem="$(grep -Eo '\-\-filesystem [a-z0-9]+' "${QUICKSTART}" | awk '{ print $2 }' | sort -u | tr '\n' ' ')"
quickstart_filesystem="${quickstart_filesystem% }"
if [[ -z "${just_filesystem}" ]]; then
  fail "the Justfile defaults the installed filesystem" "no filesystem := env(\"BUILD_FILESYSTEM\", ...) line"
else
  assert_equal "docs/installation.md installs the filesystem the Justfile defaults to" \
    "${doc_filesystem}" "${just_filesystem}"
  assert_equal "scripts/quickstart.sh installs that same filesystem" \
    "${quickstart_filesystem}" "${just_filesystem}"
fi

# ---------------------------------------------------------------------------
group "Quickstart guardrails (docs/installation.md: 'enforced in code rather than left to you to remember')"

# Each assertion below is one sentence of the doc's "What it refuses to do"
# list. The doc is the only place that states these as promises, so a guardrail
# deleted from scripts/quickstart.sh leaves the promise standing alone.

assert_present "the quickstart refuses a disk image on tmpfs or ramfs" \
  "${QUICKSTART}" 'tmpfs\|ramfs\)' \
  "docs/installation.md: 'Refuses to put a multi-GB disk image on tmpfs'"
tmpfs_guard_calls="$(grep -c 'assert_not_tmpfs' "${QUICKSTART}")"
if ((tmpfs_guard_calls >= 2)); then
  pass "the tmpfs guard is called, not merely defined"
else
  fail "the tmpfs guard is called, not merely defined" \
    "assert_not_tmpfs appears ${tmpfs_guard_calls} time(s); a definition with no call enforces nothing"
fi

assert_present "the quickstart checks a VM name against both libvirt connections" \
  "${QUICKSTART}" 'for conn in "qemu:///session" "qemu:///system"'
assert_present "an unreadable libvirt inventory fails closed" \
  "${QUICKSTART}" 'could not inventory VMs on' \
  "docs/installation.md: 'An unreadable inventory fails closed; it never destroys, undefines or recreates an existing VM'"
assert_absent "the quickstart never mutates qemu:///system" \
  "${QUICKSTART}" 'qemu:///system.*(destroy|undefine|define |create|pool-|vol-|--connect)' \
  "docs/installation.md: 'It performs a read-only name-collision check against qemu:///system, but never modifies that shared connection'"

assert_present "the quickstart snapshots session storage pools before creating a VM" \
  "${QUICKSTART}" 'list_session_pools'
assert_absent "the quickstart never removes a storage pool itself" \
  "${QUICKSTART}" 'run[[:space:]]+(sudo[[:space:]]+)?virsh[^|;&]*pool-(destroy|undefine|delete)' \
  "docs/installation.md: 'it never removes a pool automatically' -- the cleanup commands are printed for the reader to run"

assert_present "a bare-metal target is refused when it backs the running system" \
  "${QUICKSTART}" 'backs this running system'
assert_present "a bare-metal target is refused when anything on it is mounted" \
  "${QUICKSTART}" 'has mounted partitions or active swap'
assert_present "the reader retypes the resolved device path" \
  "${QUICKSTART}" 'Retype the resolved device path'
assert_present "the reader then types ERASE in capitals" \
  "${QUICKSTART}" '"ERASE"'

# The signature families the doc names by initialism, joined to the blkid
# strings the script actually greps for. A family dropped from that -E list is
# a disk the script stops refusing, and the doc still promises it does.
doc_signature_families="$(grep -Eo '(ZFS|LVM|RAID|LUKS)( / (ZFS|LVM|RAID|LUKS))+' "${INSTALL_DOC}" |
  head -1 | tr '/' '\n' | tr -d ' ' | sed '/^$/d' | sort -u)"
quickstart_signature_tokens="$(grep -Eo "grep -Ew '[^']+'" "${QUICKSTART}" | head -1 | tr "'" '\n' |
  grep -F '_' | tr '|' '\n' | sed '/^$/d')"
if [[ -z "${doc_signature_families}" || -z "${quickstart_signature_tokens}" ]]; then
  fail "the refused storage signatures can be read from both the runbook and the quickstart" \
    "doc: '${doc_signature_families//$'\n'/ }', quickstart: '${quickstart_signature_tokens//$'\n'/ }'"
else
  unrefused_families=""
  while IFS= read -r family; do
    [[ -n "${family}" ]] || continue
    grep -qi -- "${family}" <<<"${quickstart_signature_tokens}" || unrefused_families+="${family} "
  done <<<"${doc_signature_families}"
  if [[ -z "${unrefused_families}" ]]; then
    pass "every storage-signature family docs/installation.md promises is refused is one the quickstart greps for"
  else
    fail "every storage-signature family docs/installation.md promises is refused is one the quickstart greps for" \
      "promised but not matched by scripts/quickstart.sh: ${unrefused_families}"
  fi
fi

# "It captures the device identity and repeats every safety check after pulling
# the image, immediately before --wipe." Pull, then re-check, then install: the
# order is the claim, because a check that runs only before a minutes-long pull
# is a check against a stale view of the disk.
baremetal_body_start="$(grep -n '^flow_baremetal()' "${QUICKSTART}" | head -1 | cut -d: -f1)"
if [[ -z "${baremetal_body_start}" ]]; then
  fail "scripts/quickstart.sh still has a bare-metal flow" "no flow_baremetal() definition"
else
  baremetal_body="$(tail -n "+${baremetal_body_start}" "${QUICKSTART}" | sed -n '1,/^}$/p')"
  prepare_line="$(grep -n '^[[:space:]]*prepare_image$' <<<"${baremetal_body}" | head -1 | cut -d: -f1)"
  identity_line="$(grep -n 'assert_target_identity "' <<<"${baremetal_body}" | head -1 | cut -d: -f1)"
  revalidate_line="$(grep -n 'validate_baremetal_target "' <<<"${baremetal_body}" | tail -1 | cut -d: -f1)"
  install_line="$(grep -n 'bootc install to-disk' <<<"${baremetal_body}" | head -1 | cut -d: -f1)"
  if [[ -z "${prepare_line}" || -z "${identity_line}" || -z "${revalidate_line}" || -z "${install_line}" ]]; then
    fail "the bare-metal flow pulls, re-checks, then installs" \
      "prepare_image: '${prepare_line}', identity: '${identity_line}', revalidate: '${revalidate_line}', install: '${install_line}'"
  elif ((prepare_line < identity_line && identity_line < install_line && revalidate_line > prepare_line && revalidate_line < install_line)); then
    pass "the bare-metal flow re-checks the target identity and the target itself after pulling the image, before installing"
  else
    fail "the bare-metal flow re-checks the target identity and the target itself after pulling the image, before installing" \
      "order was prepare_image:${prepare_line} identity:${identity_line} revalidate:${revalidate_line} install:${install_line}"
  fi
fi

# "For VM installs, one of xorriso, genisoimage, or mkisofs is also required."
# Both directions: a tool the script would accept but the doc does not list
# sends a reader installing something they do not need, and a tool the doc
# lists that the script no longer accepts fails after they installed it.
# The backticks are markdown, not command substitution: the doc has to name
# each tool as code, so prose mentioning one in passing is not counted.
# shellcheck disable=SC2016
doc_iso_tools="$(grep -Eo '`(xorriso|genisoimage|mkisofs)`' "${INSTALL_DOC}" | tr -d '`' | sort -u | tr '\n' ' ')"
doc_iso_tools="${doc_iso_tools% }"
quickstart_iso_tools="$(sed -n 's/^[[:space:]]*for candidate in \(.*\); do$/\1/p' "${QUICKSTART}" |
  head -1 | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
quickstart_iso_tools="${quickstart_iso_tools% }"
if [[ -z "${quickstart_iso_tools}" ]]; then
  fail "scripts/quickstart.sh still searches for a seed-ISO tool" "no 'for candidate in ...' loop found"
else
  assert_equal "docs/installation.md lists exactly the seed-ISO tools the quickstart accepts" \
    "${doc_iso_tools}" "${quickstart_iso_tools}"
fi

# "The quickstart checks all required tools before changing storage." Every
# need_cmd and the ISO-tool search have to come before the first mutation in
# the VM flow, or the reader loses a partly written disk image to a missing
# tool.
vm_body_start="$(grep -n '^flow_vm()' "${QUICKSTART}" | head -1 | cut -d: -f1)"
if [[ -z "${vm_body_start}" ]]; then
  fail "scripts/quickstart.sh still has a VM flow" "no flow_vm() definition"
else
  vm_body="$(tail -n "+${vm_body_start}" "${QUICKSTART}" | sed -n '1,/^}$/p')"
  last_tool_check="$(grep -n 'need_cmd \|find_iso_tool' <<<"${vm_body}" | tail -1 | cut -d: -f1)"
  first_mutation="$(grep -n '^[[:space:]]*run \|^[[:space:]]*confirm ' <<<"${vm_body}" | head -1 | cut -d: -f1)"
  if [[ -z "${last_tool_check}" || -z "${first_mutation}" ]]; then
    fail "the VM flow checks its tools before touching storage" \
      "last tool check: '${last_tool_check}', first mutation: '${first_mutation}'"
  else
    assert_equal "the VM flow checks every required tool before the first mutating step" \
      "$((last_tool_check < first_mutation))" "1"
  fi
fi

# --dry-run is documented as performing the same read-only validation while
# creating nothing. `run` is the single chokepoint that makes that true.
assert_present "scripts/quickstart.sh accepts --dry-run" \
  "${QUICKSTART}" '\-\-dry-run\) DRY_RUN=1'
assert_present "--dry-run prints a mutating command instead of running it" \
  "${QUICKSTART}" 'DRY_RUN.*-eq 1' \
  "docs/installation.md: '--dry-run ... does not create, modify, or delete resources'"

# ---------------------------------------------------------------------------
group "Cross-document links (docs/installation.md hands the reader to three other documents)"

# Every relative link in the runbook, and every anchor on one. A heading
# renamed in vm-workflow.md or first-boot.md silently turns the hand-off into a
# link that lands at the top of the page -- or, for a renamed file, at a 404.
#
# The empty case is a failure, not a pass: a document whose hand-offs were all
# deleted has nothing left to resolve, and "every link resolves" would be
# vacuously true of it.
assert_doc_links_resolve() {
  local doc="$1" empty_note="$2"
  local doc_dir="${doc%/*}"
  local link target anchor target_file slugs
  local doc_link_failures="" doc_links_checked=0
  while IFS= read -r link; do
    [[ -n "${link}" ]] || continue
    target="${link%%#*}"
    anchor="${link#*#}"
    [[ "${link}" == *#* ]] || anchor=""
    if [[ -n "${target}" ]]; then
      target_file="${doc_dir}/${target}"
    else
      target_file="${doc}"
    fi
    doc_links_checked=$((doc_links_checked + 1))
    if [[ ! -f "${target_file}" ]]; then
      doc_link_failures+="${link} (no such file) "
      continue
    fi
    [[ -n "${anchor}" ]] || continue
    # GitHub's slug: lowercase, drop anything that is not a letter, digit, space
    # or hyphen, then spaces to hyphens. Explicit <a id="..."> anchors count too.
    slugs="$(grep -E '^#{1,6} ' "${target_file}" | sed -E 's/^#{1,6} //' |
      tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 -]//g; s/ /-/g')"
    slugs+=$'\n'"$(grep -o 'id="[^"]*"' "${target_file}" | sed 's/^id="//; s/"$//')"
    grep -qx -- "${anchor}" <<<"${slugs}" || doc_link_failures+="${link} (no such anchor) "
  done < <(grep -oE '\]\([^):]*\)' "${doc}" | sed 's/^](//; s/)$//' | sort -u)

  if ((doc_links_checked == 0)); then
    fail "${doc} still links to the documents it hands off to" "${empty_note}"
  elif [[ -z "${doc_link_failures}" ]]; then
    pass "every relative link and anchor in ${doc} resolves"
  else
    fail "every relative link and anchor in ${doc} resolves" "${doc_link_failures}"
  fi
}

assert_doc_links_resolve "${INSTALL_DOC}" \
  "no relative links found; the hand-off to vm-workflow.md and first-boot.md is gone"

# ---------------------------------------------------------------------------
group "Day-2 runbook (docs/updating.md is a hand copy of the bootc pin, the published images, packages-base.txt and ostree-pkg-diff)"

# docs/updating.md is what an operator reads after the machine is already
# installed: the image to `bootc switch` to, the bootc version that fixes a
# composefs GC failure, which package ships `crun`, whether this repository
# ships an /etc/containers/storage.conf, and what `ostree-pkg-diff` does to the
# deployments it compares. Nothing read it. It is not shell, so
# tests/check-coverage.sh cannot see it, and no test file mentioned it.
#
# Two of its claims are live: `BOOTC_VERSION` is bumped by Renovate on a
# schedule, and the flavor matrix decides which image names exist at all. The
# rest are one-way copies that a change elsewhere silences rather than breaks.
# Every assertion below joins the doc to the thing it is a copy of.

UPDATING_DOC="docs/updating.md"
PKG_DIFF="system_files/usr/bin/ostree-pkg-diff"

# Fenced blocks by info string. The doc uses ```bash for commands the reader
# runs and ```text for output and file content it reads, and the two carry
# different obligations -- the `driver`/`runroot`/`graphroot` triple appears in
# both, once as "these values mean the file is redundant" and once as "write
# this file yourself", so a single undifferentiated extraction would conflate
# the check with the fix.
updating_fenced() {
  local want="$1"
  awk -v want="${want}" '
    /^```/ { if (in_block) { in_block = 0 } else { in_block = (substr($0, 4) == want) } ; next }
    in_block' "${UPDATING_DOC}"
}

# Section headings, fenced blocks excluded: a `# comment` inside a ```bash
# block is a shell comment, not a Markdown heading.
updating_headings="$(awk '/^```/ { in_block = !in_block; next } !in_block && /^#{1,6} /' "${UPDATING_DOC}")"

if [[ ! -f "${UPDATING_DOC}" ]]; then
  fail "the day-2 runbook exists" "${UPDATING_DOC} is missing; README.md's documentation table links to it"
else
  # README.md's table is the only index of what this document covers. Assert the
  # three subjects it advertises are still sections here, or every extraction
  # below starts passing by finding nothing to check.
  missing_sections=""
  while IFS= read -r want; do
    grep -qi -- "${want}" <<<"${updating_headings}" || missing_sections+="${want}; "
  done <<'SECTIONS'
Updating Installed Systems
composefs garbage collection
rootless podman
Comparing packages between deployments
SECTIONS
  if [[ -z "${missing_sections}" ]]; then
    pass "docs/updating.md still has the sections README.md's table advertises"
  else
    fail "docs/updating.md still has the sections README.md's table advertises" \
      "no heading matches: ${missing_sections}"
  fi
fi

# --- The image the reader is told to switch to ------------------------------
#
# Same trap as the installation runbook, one command later: build.yml publishes
# ${IMAGE_NAME}-${flavor}, so a `bootc switch` at an unsuffixed or unknown-flavor
# reference sends an already-installed machine at a package that was never
# pushed.
doc_switch_refs="$(grep -Eo 'bootc switch ghcr\.io/[^ `]+' "${UPDATING_DOC}" | sed 's/^bootc switch //' | sort -u)"
if [[ -z "${doc_switch_refs}" ]]; then
  fail "docs/updating.md still tells the reader how to switch an installed system" \
    "no 'bootc switch ghcr.io/...' command found"
elif [[ -z "${workflow_flavors}" ]]; then
  fail "the published flavors can be read from ${BUILD_WORKFLOW}" "the flavor matrix extraction is empty"
else
  unpublished_refs=""
  while IFS= read -r ref; do
    [[ -n "${ref}" ]] || continue
    image="${ref##*/}"
    flavor="${image%%:*}"
    flavor="${flavor#arch-bootc-}"
    tag="${image##*:}"
    grep -qw -- "${flavor}" <<<"${workflow_flavors}" || unpublished_refs+="${ref} (flavor '${flavor}' is not in the build matrix) "
    [[ "${tag}" == "${image}" ]] && unpublished_refs+="${ref} (no tag) "
  done <<<"${doc_switch_refs}"
  if [[ -z "${unpublished_refs}" ]]; then
    pass "every image docs/updating.md switches an installed system to is a flavor the build publishes"
  else
    fail "every image docs/updating.md switches an installed system to is a flavor the build publishes" \
      "${unpublished_refs}"
  fi
fi

assert_absent "docs/updating.md never switches to an unsuffixed published image" \
  "${UPDATING_DOC}" 'ghcr\.io/[^ /]+/arch-bootc:' \
  "the workflow publishes arch-bootc-<flavor>; an unsuffixed ghcr.io tag does not exist"

# The tag. build.yml repoints DEFAULT_TAG on every publish, and that is the tag
# an operator should be tracking; a doc that names a dated tag instead pins a
# machine to one build forever.
workflow_default_tag="$(sed -n 's/^[[:space:]]*DEFAULT_TAG:[[:space:]]*"\{0,1\}\([A-Za-z0-9._-]*\)"\{0,1\}[[:space:]]*$/\1/p' "${BUILD_WORKFLOW}" | head -1)"
doc_switch_tags="$(while IFS= read -r ref; do [[ -n "${ref}" ]] && printf '%s\n' "${ref##*:}"; done <<<"${doc_switch_refs}" | sort -u | tr '\n' ' ')"
doc_switch_tags="${doc_switch_tags% }"
if [[ -z "${workflow_default_tag}" ]]; then
  fail "the build workflow still defines DEFAULT_TAG" "no DEFAULT_TAG: line in ${BUILD_WORKFLOW}"
else
  assert_equal "docs/updating.md switches to the tag the build workflow repoints on every publish" \
    "${doc_switch_tags}" "${workflow_default_tag}"
fi

# --- The bootc pin the composefs section depends on -------------------------
#
# "Fix -- build `bootc vX.Y.Z` or newer" is the whole point of that section,
# and the sentence after it ("This image builds bootc well past that version")
# is a claim about ARG BOOTC_VERSION. Renovate bumps that ARG on its own
# schedule, so this is the one join here that can be broken by an automerged
# pull request: a pin moved back below the fix version silently turns the
# troubleshooting section into an instruction to do what the image already
# fails to do.
# The backticks are markdown, not command substitution.
# shellcheck disable=SC2016
doc_bootc_fix="$(grep -Eo 'build `bootc v[0-9]+\.[0-9]+\.[0-9]+` or newer' "${UPDATING_DOC}" |
  grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
containerfile_bootc="$(sed -n 's/^ARG BOOTC_VERSION=\(v[0-9][0-9.]*\)[[:space:]]*$/\1/p' "${CONTAINERFILE}" | head -1)"
if [[ -z "${doc_bootc_fix}" || -z "${containerfile_bootc}" ]]; then
  fail "the composefs fix version can be read from the runbook and the Containerfile" \
    "doc: '${doc_bootc_fix}', Containerfile: '${containerfile_bootc}'"
else
  # sort -V puts the older version first; equal is fine, older is not.
  oldest="$(printf '%s\n%s\n' "${doc_bootc_fix#v}" "${containerfile_bootc#v}" | sort -V | head -1)"
  if [[ "${containerfile_bootc#v}" == "${doc_bootc_fix#v}" || "${oldest}" == "${doc_bootc_fix#v}" ]]; then
    pass "the Containerfile's BOOTC_VERSION is at or past the version docs/updating.md names as the composefs GC fix"
  else
    fail "the Containerfile's BOOTC_VERSION is at or past the version docs/updating.md names as the composefs GC fix" \
      "the runbook says ${doc_bootc_fix} or newer; the Containerfile pins ${containerfile_bootc}"
  fi
fi

# The same section's first sentence: "This image installs with the native
# composefs backend." Both halves of that are in this tree -- the installer
# flag, and the prepare-root.conf the image ships -- and the read-only /sysroot
# the recovery steps warn about is the second half of the same file.
#
# Continuation lines are joined first, and an invocation with no flags at all
# is dropped: `info "This runs bootc install to-disk inside the image itself"`
# is prose the quickstart prints, not an installer command.
install_invocation_flags() {
  local invocation flags
  sed -e 's/^[[:space:]]*#.*$//' -e ':a' -e '/\\$/N' -e 's/\\\n[[:space:]]*/ /' -e 'ta' |
    grep -o 'bootc install to-disk.*' |
    while IFS= read -r invocation; do
      flags="$(grep -Eo -- '--[a-z-]+' <<<"${invocation}" | sort -u | tr '\n' ' ')"
      [[ -n "${flags}" ]] || continue
      printf '%s\n' "${flags}"
    done
}
tree_install_flags="$( { install_invocation_flags <"${JUSTFILE}"; install_invocation_flags <"${QUICKSTART}"; } )"
composefs_installs="$(grep -c . <<<"${tree_install_flags}")"
[[ -n "${tree_install_flags}" ]] || composefs_installs=0
composefs_backend="$(grep -c -- '--composefs-backend' <<<"${tree_install_flags}")"
[[ -n "${tree_install_flags}" ]] || composefs_backend=0
if ((composefs_installs == 0)); then
  fail "the tree still installs with the composefs backend docs/updating.md describes" \
    "no 'bootc install to-disk' invocation in ${JUSTFILE} or ${QUICKSTART}"
else
  assert_equal "every bootc install in the tree uses the native composefs backend docs/updating.md assumes" \
    "${composefs_backend}" "${composefs_installs}"
fi
assert_present "the image ships a prepare-root.conf that enables composefs" \
  "${CONTAINERFILE}" '\[composefs\]\\nenabled = yes' \
  "docs/updating.md: 'This image installs with the native composefs backend'"
assert_present "that same prepare-root.conf mounts /sysroot read-only" \
  "${CONTAINERFILE}" '\[sysroot\]\\nreadonly = true' \
  "docs/updating.md: '/sysroot is mounted read-only; bootc remounts it rw during its own operations'"

# --- The rootless-podman section --------------------------------------------
#
# "crun is installed (it is in packages-base.txt)" is the sentence that tells a
# reader the missing-runtime message is a lie. Both directions: crun moved to a
# flavor package list would make the doc name the wrong file, and crun dropped
# entirely would make the whole section wrong.
crun_package_files="$(for f in packages-*.txt; do grep -qx 'crun' "${f}" && printf '%s ' "${f}"; done)"
crun_package_files="${crun_package_files% }"
if [[ -z "${crun_package_files}" ]]; then
  fail "crun is still installed in the base package set" \
    "docs/updating.md tells the reader crun is present; no packages-*.txt lists it"
else
  assert_equal "docs/updating.md names the package list that actually installs crun" \
    "${crun_package_files}" "packages-base.txt"
  if grep -qF -- "${crun_package_files}" "${UPDATING_DOC}"; then
    pass "docs/updating.md still points the reader at ${crun_package_files}"
  else
    fail "docs/updating.md still points the reader at ${crun_package_files}" \
      "the section no longer names the file that proves crun is installed"
  fi
fi

# "Neither this repository nor the pinned Arch base image creates the file --
# ... so a fresh install is unaffected." This repository's half of that is
# assertable, and it is worth asserting: system_files/etc/containers already
# exists, so adding a storage.conf beside policy.json is a one-file change that
# would redirect rootless podman at root's storage on every fresh install --
# the exact failure this section exists to explain, reintroduced by the image.
if [[ -e "system_files/etc/containers/storage.conf" ]]; then
  fail "the image ships no /etc/containers/storage.conf" \
    "docs/updating.md tells the reader a fresh install is unaffected; system_files/etc/containers/storage.conf exists"
else
  pass "the image ships no /etc/containers/storage.conf"
fi
assert_absent_in "nothing in the build writes /etc/containers/storage.conf" \
  '/etc/containers/storage\.conf' "${CONTAINERFILE}" "${JUSTFILE}" "${QUICKSTART}"

# The "safe to remove only if all three values match these exactly" block is a
# deletion gate: the doc's own reasoning is that those values are podman's
# built-in rootful defaults, so removing a file that pins them changes nothing.
# The evidence it offers for what those defaults are is the debug output it
# printed earlier in the same section. If the two drift apart, the doc tells a
# reader to delete a file on the strength of numbers it never showed them.
safe_to_remove="$(updating_fenced text | grep -E '^(driver|runroot|graphroot) = ')"
debug_graphroot="$(grep -Eo 'Using graph root [^ ]+' "${UPDATING_DOC}" | awk '{ print $4 }' | head -1)"
debug_runroot="$(grep -Eo 'Using run root [^ ]+' "${UPDATING_DOC}" | awk '{ print $4 }' | head -1)"
safe_graphroot="$(sed -n 's/^graphroot = "\(.*\)"$/\1/p' <<<"${safe_to_remove}" | head -1)"
safe_runroot="$(sed -n 's/^runroot = "\(.*\)"$/\1/p' <<<"${safe_to_remove}" | head -1)"
if [[ -z "${debug_graphroot}" || -z "${debug_runroot}" || -z "${safe_graphroot}" || -z "${safe_runroot}" ]]; then
  fail "docs/updating.md still shows both the observed storage paths and the safe-to-remove values" \
    "observed: '${debug_graphroot}' '${debug_runroot}', safe-to-remove: '${safe_graphroot}' '${safe_runroot}'"
else
  assert_equal "the graphroot docs/updating.md calls safe to remove is the one its own debug output showed" \
    "${safe_graphroot}" "${debug_graphroot}"
  assert_equal "the runroot docs/updating.md calls safe to remove is the one its own debug output showed" \
    "${safe_runroot}" "${debug_runroot}"
fi

# The per-user override is the branch for readers who must not touch /etc, and
# it is the one command in this document that writes a file. Its correctness is
# entirely in its quoting: the doc says the delimiter is unquoted "so $(id -u)
# and $HOME expand as you run it", and warns in the next paragraph not to
# hardcode 1000. A tidied-up `<<'EOF'` writes a storage.conf containing the
# literal characters `$(id -u)`, and a hardcoded uid writes one pointing into
# another user's runtime directory -- reproducing the permission-denied failure
# this whole section is about.
override_block="$(updating_fenced bash | awk '/^cat > .*containers\/storage\.conf/ { emit = 1 } emit { print } emit && /^EOF$/ { exit }')"
if [[ -z "${override_block}" ]]; then
  fail "docs/updating.md still offers the per-user storage.conf override" \
    "no 'cat > ~/.config/containers/storage.conf' heredoc found"
else
  if grep -qE "^cat > [^|;&]*<<[[:space:]]*EOF$" <<<"${override_block}"; then
    pass "the per-user override's heredoc delimiter is unquoted, so \$(id -u) and \$HOME expand"
  else
    fail "the per-user override's heredoc delimiter is unquoted, so \$(id -u) and \$HOME expand" \
      "a quoted delimiter writes the literal text instead: ${override_block%%$'\n'*}"
  fi
  # `$(id -u)` and `$HOME` as written, not a uid or a path someone filled in.
  # `$(id -u)` and `$HOME` are the literal text the doc must carry, not
  # something for this script to expand.
  # shellcheck disable=SC2016
  if grep -q 'runroot = "/run/user/\$(id -u)/containers"' <<<"${override_block}" &&
    grep -q 'graphroot = "\$HOME/' <<<"${override_block}"; then
    pass "the per-user override derives both paths from the running user, not a hardcoded uid"
  else
    fail "the per-user override derives both paths from the running user, not a hardcoded uid" \
      "docs/updating.md: 'Do not hardcode 1000'; the block reads: ${override_block//$'\n'/ | }"
  fi
fi

# --- ostree-pkg-diff --------------------------------------------------------
#
# The last section is three sentences, and each one is a promise about a script
# in this tree. The command name is the only copy of the installed path outside
# system_files/, and the two behavioral claims -- it self-elevates, and it is
# read-only -- are the reason an operator is willing to run it on a machine
# they care about.
#
# Every command the document tells the reader to run, taken from the ```bash
# blocks: the first word of each unindented line, `sudo` stripped, heredoc
# bodies skipped (the storage.conf the reader writes is content, not commands).
# Anything that is not part of a base Arch install has to be a file this
# repository ships into a PATH directory -- which is what makes a renamed or
# deleted helper a red run instead of a reader typing a command that does not
# exist.
base_system_commands="bootc cat find grep mkdir mv pacman podman reboot systemctl"
doc_run_commands="$(updating_fenced bash |
  awk '
    /<<[[:space:]]*'"'"'*EOF/ { in_heredoc = 1; next }
    in_heredoc { if ($0 == "EOF") { in_heredoc = 0 } ; next }
    /^[[:space:]]/ || /^#/ || /^$/ { next }
    { sub(/^sudo[[:space:]]+/, ""); print $1 }' | sort -u)"
if [[ -z "${doc_run_commands}" ]]; then
  fail "docs/updating.md still tells the reader commands to run" "no command found in any bash block"
else
  unshipped_commands=""
  shipped_commands=""
  while IFS= read -r cmd; do
    [[ -n "${cmd}" ]] || continue
    grep -qw -- "${cmd}" <<<"${base_system_commands}" && continue
    if [[ -x "system_files/usr/bin/${cmd}" ]]; then
      shipped_commands+="${cmd} "
    else
      unshipped_commands+="${cmd} "
    fi
  done <<<"${doc_run_commands}"
  if [[ -z "${unshipped_commands}" ]]; then
    pass "every command docs/updating.md tells the reader to run is a base-system tool or is shipped in system_files/usr/bin"
  else
    fail "every command docs/updating.md tells the reader to run is a base-system tool or is shipped in system_files/usr/bin" \
      "not shipped and not a base-system command: ${unshipped_commands}"
  fi
  # And the other direction, or deleting the section that runs it would leave
  # the check above satisfied by a document that runs nothing of ours.
  if [[ -n "${shipped_commands}" ]]; then
    pass "docs/updating.md still runs a command this repository ships: ${shipped_commands% }"
  else
    fail "docs/updating.md still runs a command this repository ships" \
      "no command in any bash block resolves to system_files/usr/bin; the day-2 tooling section runs nothing"
  fi
fi

assert_present "ostree-pkg-diff self-elevates instead of requiring the reader to type sudo" \
  "${PKG_DIFF}" '\$\{EUID\}" -ne 0' \
  "docs/updating.md: 'The command self-elevates with sudo when needed'"
# The literal text of the exec line, not an expansion of this script's own $0.
# shellcheck disable=SC2016
assert_present "the self-elevation re-executes this script, so the whole run is privileged" \
  "${PKG_DIFF}" 'exec sudo bash "\$0" "\$@"'

# "It mounts both deployments read-only and never modifies anything on disk."
# Both deployments: two mounts, and a count is what makes "both" checkable.
# Read-only: every one of them carries `ro`, which is the option that stops a
# diff of a rollback deployment from being able to damage it.
pkg_diff_mounts="$(grep -En '(^|[^[:alnum:]_-])mount[[:space:]]' "${PKG_DIFF}" | grep -v '^[0-9]*:[[:space:]]*#' |
  grep -v 'umount\|mountpoint')"
pkg_diff_mount_count="$(grep -c . <<<"${pkg_diff_mounts}")"
[[ -n "${pkg_diff_mounts}" ]] || pkg_diff_mount_count=0
if ((pkg_diff_mount_count < 2)); then
  fail "ostree-pkg-diff mounts both deployments" \
    "docs/updating.md says both; found ${pkg_diff_mount_count} mount command(s)"
else
  pass "ostree-pkg-diff mounts both deployments"
  writable_mounts="$(grep -Ev -- '-o [^ ]*(^|,)ro(,|$|[^a-z])|-o [^ ]*,ro |-o ro' <<<"${pkg_diff_mounts}" |
    grep -Ev -- "-o [a-z,]*\bro\b")"
  if [[ -z "${writable_mounts}" ]]; then
    pass "every deployment ostree-pkg-diff mounts is mounted read-only"
  else
    fail "every deployment ostree-pkg-diff mounts is mounted read-only" \
      "docs/updating.md: 'it mounts both deployments read-only': ${writable_mounts//$'\n'/ | }"
  fi
fi
assert_absent "ostree-pkg-diff never mounts or remounts anything writable" \
  "${PKG_DIFF}" '-o[[:space:]][a-z,]*rw' \
  "docs/updating.md: 'The tool is read-only ... never modifies anything on disk'"

# "between the running deployment and the previous deployment" -- the booted
# one and its rollback, not an arbitrary pair.
for accessor in status_booted_os status_booted_boot; do
  assert_present "ostree-pkg-diff reads the booted deployment's ${accessor#status_booted_} from ostree admin status" \
    "${PKG_DIFF}" "${accessor}\(\)"
done
assert_present "ostree-pkg-diff prefers the deployment ostree itself marks as the rollback" \
  "${PKG_DIFF}" '\\\(rollback\\\)' \
  "docs/updating.md: 'between the running deployment and the previous deployment'"

# ---------------------------------------------------------------------------
group "Cross-document links (docs/updating.md hands the reader to the Renovate reference)"

# The composefs section's fix is "see BOOTC_VERSION in the Containerfile, kept
# current by [Renovate](renovate.md)" -- the version assertion above is only
# reassuring because something keeps that pin moving, and this link is the
# doc's own pointer at what that something is.
assert_doc_links_resolve "${UPDATING_DOC}" \
  "no relative links found; the pointer at the Renovate reference is gone"

# ---------------------------------------------------------------------------
group "Process metrics (docs/metrics.md is a set of runnable gh/jq commands, a hand-recomputed snapshot, and four copies of the build machine)"

# docs/metrics.md is not prose about intentions: it tells a reader to run nine
# `gh ... --jq` commands and says every figure in it was produced that way.
# Nothing read it. tests/check-coverage.sh traces shipped shell only, so a
# Markdown file moves no percentage, and no test named it.
#
# Three separate things can rot here, and each is asserted below:
#
#   - The commands themselves. A jq program that no longer parses, or that
#     reads a field the paired `--json` never requested, fails only in the
#     reader's terminal -- and a filter reading an unrequested field does not
#     even fail there, it silently computes over `null`.
#   - The snapshot table. It is recomputed by hand, so its totals, its
#     percentages and the prose that restates them are four copies of the same
#     numbers with nothing keeping them equal.
#   - The claims about the machine: the workflow it names, the branch it reads,
#     the daily schedule plus PACMAN_CACHE_BUST it credits for genuinely fresh
#     packages, the per-script floors it defers to, and its statement that
#     nothing in this repository writes these numbers on a schedule.

METRICS_DOC="docs/metrics.md"

# Fenced blocks by info string, matching the extractor used for the runbooks
# above. Only ```bash blocks are commands.
metrics_fenced() {
  local want="$1"
  awk -v want="${want}" '
    /^```/ { if (in_block) { in_block = 0 } else { in_block = (substr($0, 4) == want) } ; next }
    in_block' "${METRICS_DOC}"
}

# Headings with fenced blocks excluded: `# Review comments per merged PR` is a
# shell comment inside a ```bash block, not a Markdown heading.
metrics_headings="$(awk '/^```/ { in_block = !in_block; next } !in_block && /^#{1,6} /' "${METRICS_DOC}")"

if [[ ! -f "${METRICS_DOC}" ]]; then
  fail "the metrics reference exists" "${METRICS_DOC} is missing; README.md's documentation table links to it"
else

# README.md's table advertises "PR acceptance, time to merge, and CI health".
# Assert those are still sections, or every scoped extraction below starts
# passing by extracting nothing.
metrics_missing_sections=""
while IFS= read -r want; do
  grep -qi -- "${want}" <<<"${metrics_headings}" || metrics_missing_sections+="${want}; "
done <<'METRICS_SECTIONS'
^## PR acceptance
^## Time to merge
^## Review friction
^## CI health
^## Snapshot
^## What is deliberately not measured
METRICS_SECTIONS
if [[ -z "${metrics_missing_sections}" ]]; then
  pass "docs/metrics.md still has the sections README.md's table advertises"
else
  fail "docs/metrics.md still has the sections README.md's table advertises" \
    "missing: ${metrics_missing_sections}"
fi

assert_present "README.md's documentation table still links to the metrics reference" \
  "README.md" '\]\(docs/metrics\.md\)'

assert_doc_links_resolve "${METRICS_DOC}" \
  "no relative links found; the hand-off to quality.md is gone"

# -- The commands -----------------------------------------------------------
#
# Every gh invocation in the document, as a (requested fields, jq program)
# pair. Continuation lines are joined first; the jq programs themselves span
# several physical lines inside their quotes, so the whole block set is read as
# one string rather than line by line. A new invocation starts at each `gh`
# token, which is what separates the `gh api` inside the review-friction loop
# from the `gh pr list` that feeds it.
metrics_jq_records() {
  metrics_fenced bash | awk -v RS=$'\a' '
    {
      text = $0
      sep = sprintf("%c", 2)
      fieldsep = sprintf("%c", 3)
      recsep = sprintf("%c", 4)
      quote = sprintf("%c", 39)
      gsub(/\\\n[ \t]*/, " ", text)
      gsub(/(^|[ \t(\n])gh /, sep "&", text)
      n = split(text, segment, sep)
      for (i = 1; i <= n; i++) {
        seg = segment[i]
        jqre = "--jq " quote
        if (!match(seg, jqre)) continue
        rest = substr(seg, RSTART + RLENGTH)
        end = index(rest, quote)
        if (end == 0) continue
        program = substr(rest, 1, end - 1)
        fields = ""
        if (match(seg, /--json [A-Za-z0-9,]+/))
          fields = substr(seg, RSTART + 7, RLENGTH - 7)
        printf "%s%s%s%s", fields, fieldsep, program, recsep
      }
    }
  '
}

# Field names a jq program reads. Only the head of a dotted chain counts:
# `.author.login` reads the `author` object gh was asked for, and `login` is a
# key inside it rather than a second thing to request.
metrics_program_fields() {
  awk -v RS=$'\a' '
    {
      text = $0
      while (match(text, /\.[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*/)) {
        chain = substr(text, RSTART + 1, RLENGTH - 1)
        split(chain, part, ".")
        print part[1]
        text = substr(text, RSTART + RLENGTH)
      }
    }
  ' | sort -u
}

# A fixture shaped exactly like what `gh ... --json <fields>` returns: three
# records, with the values varied so group_by, select and sort all have
# something to do. An unrecognised field is a failure rather than a null,
# because a null silently satisfies every assertion that follows.
metrics_unknown_fields=""
metrics_fixture() {
  local fields="$1"
  local -a requested
  local i field value object out=""
  local -a states=("MERGED" "CLOSED" "OPEN")
  local -a logins=("app/renovate" "Danathar" "copilot-swe-agent")
  local -a conclusions=("success" "failure" "success")
  IFS=',' read -ra requested <<<"${fields}"
  for i in 0 1 2; do
    object=""
    for field in "${requested[@]}"; do
      case "${field}" in
        state) value="\"${states[i]}\"" ;;
        author) value="{\"login\":\"${logins[i]}\"}" ;;
        createdAt) value="\"2026-09-0$((i + 1))T10:00:00Z\"" ;;
        mergedAt) value="\"2026-09-0$((i + 1))T12:00:00Z\"" ;;
        updatedAt) value="\"2026-09-0$((i + 1))T11:30:00Z\"" ;;
        number | databaseId) value="$((100 + i))" ;;
        conclusion) value="\"${conclusions[i]}\"" ;;
        workflowName) value="\"Build container image\"" ;;
        *)
          metrics_unknown_fields+="${field} "
          value="null"
          ;;
      esac
      object+="\"${field}\":${value},"
    done
    out+="{${object%,}},"
  done
  printf '[%s]' "${out%,}"
}

# jq prints a string result with its quotes and with newlines escaped; the
# programs here are laid out across several lines for readability, so compare
# the values rather than the whitespace the document happens to use.
metrics_norm() {
  tr '\n' ' ' | sed 's/\\n/ /g; s/"//g' | tr -s ' ' | sed 's/^ //; s/ $//'
}

metrics_prs='[
  {"state":"MERGED","author":{"login":"app/renovate"}},
  {"state":"MERGED","author":{"login":"app/renovate"}},
  {"state":"CLOSED","author":{"login":"app/renovate"}},
  {"state":"MERGED","author":{"login":"Danathar"}},
  {"state":"OPEN","author":{"login":"Danathar"}},
  {"state":"CLOSED","author":{"login":"copilot-swe-agent"}}
]'
metrics_merged='[
  {"createdAt":"2026-09-01T10:00:00Z","mergedAt":"2026-09-01T20:00:00Z","author":{"login":"app/renovate"}},
  {"createdAt":"2026-09-02T10:00:00Z","mergedAt":"2026-09-02T11:00:00Z","author":{"login":"Danathar"}},
  {"createdAt":"2026-09-03T10:00:00Z","mergedAt":"2026-09-03T12:00:00Z","author":{"login":"Danathar"}}
]'
metrics_runs='[
  {"conclusion":"success","workflowName":"Build container image"},
  {"conclusion":"failure","workflowName":"Build container image"},
  {"conclusion":"success","workflowName":"Nightly compliance"}
]'
metrics_durations='[
  {"databaseId":1,"createdAt":"2026-09-01T10:00:00Z","updatedAt":"2026-09-01T11:30:00Z"}
]'

metrics_programs=0
metrics_value_checks=0
metrics_broken=""
metrics_unrequested=""
while IFS= read -r -d $'\004' metrics_record; do
  metrics_fields="${metrics_record%%$'\003'*}"
  metrics_program="${metrics_record#*$'\003'}"
  [[ -n "${metrics_program}" ]] || continue
  metrics_programs=$((metrics_programs + 1))

  # The program runs, against exactly the fields its own command requested.
  if [[ -n "${metrics_fields}" ]]; then
    metrics_out="$(metrics_fixture "${metrics_fields}" | jq "${metrics_program}" 2>&1)" ||
      metrics_broken+="[${metrics_fields}] ${metrics_out//$'\n'/ } | "
    [[ -n "${metrics_out}" ]] ||
      metrics_broken+="[${metrics_fields}] produced no output | "

    # Every field the filter reads was asked for. gh returns only the
    # requested keys, so a filter that reads one more computes over null and
    # reports a wrong number instead of an error.
    while IFS= read -r metrics_read_field; do
      [[ -n "${metrics_read_field}" ]] || continue
      grep -qx -- "${metrics_read_field}" <<<"${metrics_fields//,/$'\n'}" ||
        metrics_unrequested+="${metrics_read_field} (not in --json ${metrics_fields}) "
    done < <(printf '%s' "${metrics_program}" | metrics_program_fields)
  fi

  # The headline figures, computed by the document's own filters.
  metrics_sorted_fields="$(tr ',' '\n' <<<"${metrics_fields}" | sort | paste -sd, -)"
  case "${metrics_sorted_fields}" in
    state)
      metrics_value_checks=$((metrics_value_checks + 1))
      assert_equal "docs/metrics.md's PR-state breakdown counts each state" \
        "$(jq "${metrics_program}" <<<"${metrics_prs}" | metrics_norm)" \
        "CLOSED: 2 MERGED: 3 OPEN: 1"
      ;;
    author,state)
      metrics_value_checks=$((metrics_value_checks + 1))
      if [[ "${metrics_program}" == *'startswith("app/")'* ]]; then
        assert_equal "docs/metrics.md's non-bot acceptance filter excludes app/ logins and nothing else" \
          "$(jq -c "${metrics_program}" <<<"${metrics_prs}")" \
          '{"total":3,"merged":1,"closed":1,"open":1}'
      else
        assert_equal "docs/metrics.md's per-author split totals each author's states" \
          "$(jq "${metrics_program}" <<<"${metrics_prs}" | metrics_norm)" \
          "Danathar: total 2, merged 1, closed 0 app/renovate: total 3, merged 2, closed 1 copilot-swe-agent: total 1, merged 0, closed 1"
      fi
      ;;
    createdAt,mergedAt)
      metrics_value_checks=$((metrics_value_checks + 1))
      assert_equal "docs/metrics.md's time-to-merge reports the median and p90 in hours, not the mean" \
        "$(jq -c "${metrics_program}" <<<"${metrics_merged}")" \
        '{"count":3,"median":2,"p90":10}'
      ;;
    author,createdAt,mergedAt)
      metrics_value_checks=$((metrics_value_checks + 1))
      assert_equal "docs/metrics.md's review-latency median drops the bot PRs first" \
        "$(jq -c "${metrics_program}" <<<"${metrics_merged}")" \
        '{"count":2,"median":2}'
      ;;
    conclusion,workflowName)
      metrics_value_checks=$((metrics_value_checks + 1))
      assert_equal "docs/metrics.md's CI health counts successes per workflow" \
        "$(jq "${metrics_program}" <<<"${metrics_runs}" | metrics_norm)" \
        "Build container image: 1/2 green Nightly compliance: 1/1 green"
      ;;
    createdAt,databaseId,updatedAt)
      metrics_value_checks=$((metrics_value_checks + 1))
      assert_equal "docs/metrics.md's run-duration filter reports whole minutes" \
        "$(jq "${metrics_program}" <<<"${metrics_durations}" | metrics_norm)" \
        "90"
      ;;
  esac
done < <(metrics_jq_records)

assert_equal "every gh command in docs/metrics.md still carries a jq program" \
  "${metrics_programs}" "9"
assert_equal "every figure docs/metrics.md quotes is still computed by one of its own filters" \
  "${metrics_value_checks}" "7"

if [[ -z "${metrics_broken}" ]]; then
  pass "every jq program in docs/metrics.md runs against the fields its command requests"
else
  fail "every jq program in docs/metrics.md runs against the fields its command requests" \
    "${metrics_broken}"
fi

if [[ -z "${metrics_unknown_fields}" ]]; then
  pass "every --json field docs/metrics.md requests has a fixture shape here"
else
  fail "every --json field docs/metrics.md requests has a fixture shape here" \
    "unknown field(s): ${metrics_unknown_fields}-- add them to metrics_fixture or the filters run against null"
fi

if [[ -z "${metrics_unrequested}" ]]; then
  pass "no jq program in docs/metrics.md reads a field its --json never requested"
else
  fail "no jq program in docs/metrics.md reads a field its --json never requested" \
    "${metrics_unrequested}"
fi

# -- The claims about the machine -------------------------------------------

# "gh run list --workflow <name>" matches on the workflow's `name:`, not its
# filename, so renaming the workflow turns this command into an empty table
# rather than an error.
metrics_workflow_names="$(grep -oE -- '--workflow "[^"]+"' "${METRICS_DOC}" | sed 's/^--workflow "//; s/"$//' | sort -u)"
if [[ -z "${metrics_workflow_names}" ]]; then
  fail "docs/metrics.md still names a workflow to measure" \
    "no --workflow argument found; the CI duration command is gone"
else
  metrics_missing_workflows=""
  while IFS= read -r want; do
    grep -qxF -- "name: ${want}" .github/workflows/*.y*ml || metrics_missing_workflows+="${want}; "
  done <<<"${metrics_workflow_names}"
  if [[ -z "${metrics_missing_workflows}" ]]; then
    pass "every workflow docs/metrics.md measures by name exists under .github/workflows/"
  else
    fail "every workflow docs/metrics.md measures by name exists under .github/workflows/" \
      "no workflow declares: ${metrics_missing_workflows}"
  fi
fi

# "--branch main" is only the right question while main is what the workflows
# build.
metrics_branches="$(grep -oE -- '--branch [A-Za-z0-9._/-]+' "${METRICS_DOC}" | awk '{print $2}' | sort -u)"
if [[ -z "${metrics_branches}" ]]; then
  fail "docs/metrics.md still reads CI health from a branch" "no --branch argument found"
else
  metrics_missing_branches=""
  while IFS= read -r want; do
    awk -v want="${want}" '
      /^  push:/ { in_push = 1; next }
      in_push && /^  [a-z_]+:/ { in_push = 0 }
      in_push && $0 ~ ("^      - " want "$") { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "${BUILD_WORKFLOW}" || metrics_missing_branches+="${want}; "
  done <<<"${metrics_branches}"
  if [[ -z "${metrics_missing_branches}" ]]; then
    pass "the branch docs/metrics.md measures is one the build workflow runs on push"
  else
    fail "the branch docs/metrics.md measures is one the build workflow runs on push" \
      "${BUILD_WORKFLOW} does not build: ${metrics_missing_branches}"
  fi
fi

# "the daily schedule plus PACMAN_CACHE_BUST mean every build genuinely pulls
# today's packages" -- both halves, or the sentence is wrong in a way that
# makes a rising failure rate look like a bad commit.
metrics_cron="$(grep -oE -- '- cron: "[^"]+"' "${BUILD_WORKFLOW}" | sed 's/^- cron: "//; s/"$//')"
if [[ -z "${metrics_cron}" ]]; then
  fail "the build workflow still runs on a schedule" \
    "docs/metrics.md: 'the daily schedule ... mean every build genuinely pulls today's packages'"
elif [[ "$(awk '{print $3, $4, $5}' <<<"${metrics_cron}")" == "* * *" ]]; then
  pass "the build workflow's schedule fires daily, as docs/metrics.md's CI-health reading assumes"
else
  fail "the build workflow's schedule fires daily, as docs/metrics.md's CI-health reading assumes" \
    "cron '${metrics_cron}' restricts the day of month, month or weekday"
fi

assert_present "the build workflow still passes PACMAN_CACHE_BUST, which docs/metrics.md credits for fresh packages" \
  "${BUILD_WORKFLOW}" 'PACMAN_CACHE_BUST=' \
  "docs/metrics.md reads a rising failure rate as Arch moving, which only holds while the cache is busted per build"

assert_present "the Containerfile still declares the PACMAN_CACHE_BUST argument the build passes" \
  "${CONTAINERFILE}" '^ARG PACMAN_CACHE_BUST'

# "The coverage floors in .coverage-thresholds.json already gate this per
# script" -- the document's stated reason for not measuring test count. Every
# key must still name a script that exists, or the floor gates nothing.
metrics_thresholds=".coverage-thresholds.json"
if [[ ! -f "${metrics_thresholds}" ]]; then
  fail "the per-script coverage floors docs/metrics.md defers to exist" \
    "${metrics_thresholds} is missing"
else
  metrics_missing_scripts=""
  while IFS= read -r script; do
    [[ -n "${script}" ]] || continue
    [[ -f "${script}" ]] || metrics_missing_scripts+="${script}; "
  done < <(jq -r 'keys[]' "${metrics_thresholds}")
  if [[ -z "${metrics_missing_scripts}" ]]; then
    pass "every script docs/metrics.md's coverage floors gate still exists"
  else
    fail "every script docs/metrics.md's coverage floors gate still exists" \
      "${metrics_missing_scripts}"
  fi
  assert_present "the coverage floors are read by the checker CI runs, not just recorded" \
    "tests/check-coverage.sh" 'coverage-thresholds\.json'
fi

# "There is no metrics service and no scheduled job writing numbers anywhere."
# The scheduled jobs in this repository are nightly-compliance.yml and the
# build itself; neither may acquire a step that regenerates this file.
metrics_writers="$(grep -rl -- 'metrics\.md' .github scripts system_files Justfile 2>/dev/null)"
if [[ -z "${metrics_writers}" ]]; then
  pass "nothing in the build machine reads or rewrites docs/metrics.md, as the document states"
else
  fail "nothing in the build machine reads or rewrites docs/metrics.md, as the document states" \
    "docs/metrics.md: 'no scheduled job writing numbers anywhere', but: ${metrics_writers//$'\n'/ | }"
fi

# "Bot PRs automerge on a green build" -- the reason the document tells a
# reader to filter them out before calling the median a review latency.
assert_present "Renovate still automerges, which is why docs/metrics.md reads bot time-to-merge as CI duration" \
  "renovate.json" '"automerge": true'

# -- The snapshot -----------------------------------------------------------
#
# Recomputed by hand, in four places that must agree: the table's counts, the
# acceptance rates derived from them, the by-author line, and the prose below
# the table that restates two of the figures in different units.
metrics_row() {
  grep -E "^\| $1 \|" "${METRICS_DOC}" | head -1 | awk -F'|' '{print $3}' | sed 's/^ *//; s/ *$//'
}

metrics_opened="$(metrics_row 'PRs opened, all time')"
metrics_merged_count="$(metrics_row 'Merged')"
metrics_closed_count="$(metrics_row 'Closed unmerged')"
metrics_open_count="$(metrics_row 'Open')"

if [[ "${metrics_opened}" =~ ^[0-9]+$ && "${metrics_merged_count}" =~ ^[0-9]+$ &&
  "${metrics_closed_count}" =~ ^[0-9]+$ && "${metrics_open_count}" =~ ^[0-9]+$ ]]; then
  assert_equal "docs/metrics.md's snapshot accounts for every PR it says was opened" \
    "$((metrics_merged_count + metrics_closed_count + metrics_open_count))" \
    "${metrics_opened}"

  # The all-time commands are capped at --limit 200. A snapshot taken past the
  # cap is silently a count of the most recent 200 PRs, not of all of them.
  metrics_limit="$(grep -oE -- '--state all --limit [0-9]+' "${METRICS_DOC}" | awk '{print $NF}' | sort -n | head -1)"
  if [[ -z "${metrics_limit}" ]]; then
    fail "docs/metrics.md's all-time commands still carry a --limit" "no '--state all --limit N' found"
  elif ((metrics_limit >= metrics_opened)); then
    pass "docs/metrics.md's --limit still covers every PR its snapshot counts"
  else
    fail "docs/metrics.md's --limit still covers every PR its snapshot counts" \
      "--limit ${metrics_limit} truncates a repository with ${metrics_opened} PRs; the snapshot would undercount"
  fi
else
  fail "docs/metrics.md's snapshot table still reports whole PR counts" \
    "opened='${metrics_opened}' merged='${metrics_merged_count}' closed='${metrics_closed_count}' open='${metrics_open_count}'"
fi

# "106 / 110 resolved (96%)" -- numerator, denominator and percentage, each
# derivable from the counts above.
metrics_rate_all="$(metrics_row 'Acceptance rate, all authors')"
if [[ "${metrics_rate_all}" =~ ^([0-9]+)\ /\ ([0-9]+)\ resolved\ \(([0-9]+)%\)$ ]]; then
  assert_equal "docs/metrics.md's all-author acceptance numerator is its own merged count" \
    "${BASH_REMATCH[1]}" "${metrics_merged_count}"
  assert_equal "docs/metrics.md's all-author acceptance denominator counts resolved PRs only" \
    "${BASH_REMATCH[2]}" "$((metrics_merged_count + metrics_closed_count))"
  assert_equal "docs/metrics.md's all-author acceptance percentage matches its own fraction" \
    "${BASH_REMATCH[3]}" \
    "$((BASH_REMATCH[1] * 100 / BASH_REMATCH[2]))"
else
  fail "docs/metrics.md records the all-author acceptance rate as 'N / M resolved (P%)'" \
    "found '${metrics_rate_all}'"
fi

metrics_rate_nonbot="$(metrics_row 'Acceptance rate, excluding bots')"
if [[ "${metrics_rate_nonbot}" =~ ^([0-9]+)\ /\ ([0-9]+)\ resolved\ \(([0-9]+)%\)$ ]]; then
  assert_equal "docs/metrics.md's non-bot acceptance percentage matches its own fraction" \
    "${BASH_REMATCH[3]}" \
    "$((BASH_REMATCH[1] * 100 / BASH_REMATCH[2]))"
  # The prose under the table restates this one in words.
  assert_present "the caveat under the table restates the non-bot acceptance rate the table reports" \
    "${METRICS_DOC}" "a ${BASH_REMATCH[3]}% non-bot acceptance rate" \
    "the table and the paragraph explaining it disagree"
else
  fail "docs/metrics.md records the non-bot acceptance rate as 'N / M resolved (P%)'" \
    "found '${metrics_rate_nonbot}'"
fi

# "By author: Renovate 81 (76 merged, 3 closed), ..." -- the same population,
# split. Its parts must add back up to the table.
metrics_author_totals=0
metrics_author_merged=0
metrics_author_closed=0
metrics_author_entries=0
while read -r total merged closed; do
  metrics_author_entries=$((metrics_author_entries + 1))
  metrics_author_totals=$((metrics_author_totals + total))
  metrics_author_merged=$((metrics_author_merged + merged))
  metrics_author_closed=$((metrics_author_closed + closed))
done < <(grep -oE '[0-9]+ \([0-9]+ merged(, [0-9]+ closed)?\)' "${METRICS_DOC}" |
  sed -E 's/^([0-9]+) \(([0-9]+) merged(, ([0-9]+) closed)?\)$/\1 \2 \4/' |
  awk '{print $1, $2, ($3 == "" ? 0 : $3)}')

if ((metrics_author_entries == 0)); then
  fail "docs/metrics.md still splits its snapshot by author" \
    "no 'N (M merged, C closed)' entries found; the by-author line is gone"
else
  assert_equal "docs/metrics.md's by-author totals add up to the PRs it says were opened" \
    "${metrics_author_totals}" "${metrics_opened}"
  assert_equal "docs/metrics.md's by-author merged counts add up to its merged row" \
    "${metrics_author_merged}" "${metrics_merged_count}"
  assert_equal "docs/metrics.md's by-author closed counts add up to its closed row" \
    "${metrics_author_closed}" "${metrics_closed_count}"
fi

# "Median time to merge, excluding bots | ~0.4 h" against "The non-bot median
# of about 24 minutes" three paragraphs later: same number, two units.
metrics_median_hours="$(metrics_row 'Median time to merge, excluding bots' | tr -d '~h ')"
metrics_median_minutes="$(grep -oE 'median of about [0-9]+ minutes' "${METRICS_DOC}" | awk '{print $4}')"
if [[ "${metrics_median_hours}" =~ ^[0-9.]+$ && "${metrics_median_minutes}" =~ ^[0-9]+$ ]]; then
  assert_equal "docs/metrics.md's non-bot median reads the same in hours and in minutes" \
    "${metrics_median_minutes}" \
    "$(awk -v h="${metrics_median_hours}" 'BEGIN { printf "%d", h * 60 + 0.5 }')"
else
  fail "docs/metrics.md states the non-bot median in both hours and minutes" \
    "table='${metrics_median_hours}' prose='${metrics_median_minutes}'"
fi

# The snapshot is explicitly a dated hand recomputation. A date that does not
# parse is a snapshot nobody can place, and one in the future is a typo.
metrics_asof="$(grep -oE '^\*\*As of [0-9]{4}-[0-9]{2}-[0-9]{2}:\*\*$' "${METRICS_DOC}" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"
if [[ -z "${metrics_asof}" ]]; then
  fail "docs/metrics.md dates its snapshot" \
    "no '**As of YYYY-MM-DD:**' line; the table reads as current when it is not"
elif [[ "${metrics_asof}" > "$(date -u +%F)" ]]; then
  fail "docs/metrics.md's snapshot date is not in the future" "as of ${metrics_asof}"
else
  pass "docs/metrics.md dates its snapshot, and the date has passed"
fi

fi
# ---------------------------------------------------------------------------
printf '\n1..%d\n' "${checks_run}"
if ((failures > 0)); then
  printf 'invariants: %d of %d check(s) failed\n' "${failures}" "${checks_run}" >&2
  exit 1
fi
printf 'invariants: all %d check(s) passed\n' "${checks_run}"
