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
# uncomments it and in one comment explaining why. A plain grep is therefore
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
#   * A lone `-` is an operand, not a flag: git reads it as stdin and counts it
#     toward the same two-operand test, so `git diff /etc/shadow -` prints the
#     file. Skipping every dash-prefixed word -- correct for `--stat` and `-U0`,
#     which git would reject if they were not flags -- left the count one short
#     of the refusal. `git diff ../<checkout>/cosign.key -` reaches a denied
#     path inside this repository by the same route, because git's
#     inside-the-repo test works on the spelling and a `..` that climbs out and
#     back in reads as outside.
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
  # And with the second operand written as `-`, which git reads as stdin and
  # counts like any other operand. stdin is closed here so the fixture cannot
  # block; the file's own lines are what git prints, on the `-` side of the
  # comparison rather than the `+` side.
  stdin_operand_output="$(git diff "${no_index_dir}/fake.key" - 2>/dev/null </dev/null)"
  # Use only synthetic contents, including for paths inside this checkout.
  # Git treats a spelling that climbs out and returns by name as outside;
  # realpath -m -s erases that distinction. Keep both operands in the checkout
  # so an already-outside operand cannot accidentally make the hook test pass.
  path_fixture_dir="$(mktemp -d "${REPO_ROOT}/tests/.git-diff-paths.XXXXXX")"
  path_fixture="${path_fixture_dir#"${REPO_ROOT}/"}"
  checkout_name="$(basename -- "$(git rev-parse --show-toplevel)")"
  printf 'SYNTHETIC-PATH-FIXTURE\n' >"${path_fixture_dir}/fake.key"
  : >"${path_fixture_dir}/empty"
  mkdir "${path_fixture_dir}/inside"
  ln -s "${no_index_dir}" "${path_fixture_dir}/outside"
  ln -s inside "${path_fixture_dir}/inside-link"
  ln -s "${path_fixture_dir}" "${no_index_dir}/back-inside"
  reentry_path="../${checkout_name}/${path_fixture}"
  reentry_output="$(git diff -- "${reentry_path}/fake.key" "${reentry_path}/empty" 2>/dev/null)"
  reentry_stdin_output="$(git diff -- "${reentry_path}/fake.key" - 2>/dev/null </dev/null)"
  inside_stdin_output="$(git diff -- "${path_fixture}/fake.key" - 2>/dev/null </dev/null)"
  if grep -q '^-SYNTHETIC-PATH-FIXTURE$' <<<"${reentry_output}"; then
    pass "git diff behind -- prints an inside file spelled as a climb out and back in"
  else
    fail "git diff behind -- prints an inside file spelled as a climb out and back in" \
      "this git no longer treats the re-entry spelling as outside; re-derive the lexical check"
  fi
  if grep -q '^-SYNTHETIC-PATH-FIXTURE$' <<<"${reentry_stdin_output}"; then
    pass "git diff behind -- prints the re-entry file against stdin too"
  else
    fail "git diff behind -- prints the re-entry file against stdin too" \
      "the re-entry path plus stdin did not print the synthetic contents"
  fi
  assert_equal "an inside spelling against stdin does not print the untracked fixture" \
    "${inside_stdin_output}" ""
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

  if grep -q '^-SECRET-LINE-1$' <<<"${stdin_operand_output}"; then
    pass "git diff prints the same contents when the second operand is the stdin dash"
  else
    fail "git diff prints the same contents when the second operand is the stdin dash" \
      "this git no longer counts a lone - as an operand; re-derive why the operand scan stops skipping it"
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

  # Brace expansion, which rebuilds both exposures above out of four
  # characters. Bash expands braces before it splits words, so one word in a
  # scan that reads the typed string is several words to git: the operand count
  # stays at one while git receives two, and a flag name split down the middle
  # matches nothing while git receives it whole. Neither needs a variable or a
  # subshell, so neither is one of the runtime-built arguments the hook says it
  # cannot see. Demonstrated rather than described, in a temporary directory of
  # this fixture's own.
  brace_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${brace_dir}/fake.key"
  printf 'ORIGINAL-CONTENT\n' >"${brace_dir}/victim-brace"

  brace_repo="${brace_dir}/repo"
  git -c init.defaultBranch=main init --quiet "${brace_repo}" >/dev/null 2>&1
  printf 'PAYLOAD-LINE-1\n' >"${brace_repo}/committed"
  git -C "${brace_repo}" add committed >/dev/null 2>&1
  git -C "${brace_repo}" -c user.name=invariants \
    -c user.email=invariants@example.invalid -c commit.gpgsign=false \
    commit --quiet -m fixture >/dev/null 2>&1

  # The braces are literal to this script -- they sit inside double quotes --
  # and are expanded by the inner shell, which is the point being shown.
  # </dev/null so a host where the brace stops expanding cannot leave the run
  # waiting on the stdin operand.
  brace_read="$(bash -c "git diff {/dev/null,${brace_dir}/fake.key}" 2>/dev/null </dev/null)"
  bash -c "git -C '${brace_repo}' log -p --outpu{t,t}=${brace_dir}/victim-brace -1" \
    >/dev/null 2>&1 </dev/null
  brace_written="$(cat "${brace_dir}/victim-brace" 2>/dev/null)"
  rm -rf "${brace_dir}"

  if grep -q '^+SECRET-LINE-1$' <<<"${brace_read}"; then
    pass "one braced word reaches git as the two operands of the plain-file read"
  else
    fail "one braced word reaches git as the two operands of the plain-file read" \
      "this shell no longer expands the brace into two operands; re-derive the brace refusal in the hook"
  fi

  if grep -q '^+PAYLOAD-LINE-1$' <<<"${brace_written}"; then
    pass "a brace split through --outpu{t,t}= reaches git as --output and writes the file it names"
  else
    fail "a brace split through --outpu{t,t}= reaches git as --output and writes the file it names" \
      "the file does not hold the commit's + lines; re-derive why a split flag name still reaches git"
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

  # #297: classify the spelling before normalizing it, then also resolve
  # symlinks. The symlink and bare-stdin refusals are conservative: Git 2.55
  # keeps the inside spellings as pathspecs, but we require both containment
  # checks to agree rather than depend on that treatment.
  assert_hook_refuses "the hook refuses two re-entry paths behind --" \
    "git diff -- ../${checkout_name}/cosign.key ../${checkout_name}/AGENTS.md"
  assert_hook_refuses "the hook refuses a re-entry path against stdin behind --" \
    "git diff -- ../${checkout_name}/cosign.key -"
  assert_hook_refuses "the hook refuses re-entry starting inside tests behind --" \
    "git diff -- ./tests/../../${checkout_name}/cosign.key -"
  assert_hook_refuses "the hook refuses the demonstrated synthetic re-entry comparison" \
    "git diff -- ${reentry_path}/fake.key ${reentry_path}/empty"
  assert_hook_refuses "the hook counts stdin as outside even with an inside first operand" \
    'git diff -- ./AGENTS.md -'
  assert_hook_refuses "the hook counts stdin as outside in the first position too" \
    'git diff -- - ./AGENTS.md'
  assert_hook_refuses "the hook refuses a leading symlink directory pointing outside" \
    "git diff -- ${path_fixture}/outside/fake.key ${path_fixture}/empty"
  assert_hook_refuses "the hook refuses an outside spelling that resolves back inside" \
    "git diff -- ${no_index_dir}/back-inside/fake.key ${path_fixture}/empty"
  assert_hook_permits "a directory symlink staying inside the checkout is still unprompted" \
    "git diff -- ${path_fixture}/inside-link ./AGENTS.md"
  assert_hook_permits "a nonexistent inside path still works as a repository pathspec" \
    "git diff -- ${path_fixture}/missing ./AGENTS.md"
  assert_hook_permits "two dots within a filename are not a parent component" \
    'git diff -- ./file..name ./AGENTS.md'
  rm -rf -- "${path_fixture_dir}" "${no_index_dir}"

  # The stdin operand. `-` is the one word git diff counts as an operand and an
  # option scan drops, so these forms reached the plain-file mode with the
  # operand count stuck at one. The last of them is the same route back into a
  # path the deny rules name: git's inside-the-repo test reads the spelling, so
  # a `..` that leaves the checkout and returns to it counts as outside.
  assert_hook_refuses "the hook refuses the stdin dash as the second operand" \
    'git diff /etc/shadow -'
  assert_hook_refuses "the hook refuses the stdin dash reached outside the checkout" \
    'git diff /home/someone/.ssh/id_ed25519 -'
  assert_hook_refuses "the hook refuses the stdin dash after another flag" \
    'git diff --stat /etc/shadow -'
  assert_hook_refuses "the hook refuses the stdin dash as the first operand" \
    'git diff - /etc/shadow'
  assert_hook_refuses "the hook refuses the stdin dash behind an unspaced &&" \
    'ls&&git diff /etc/shadow -'
  assert_hook_refuses "the hook refuses a denied path spelled as a climb out of the checkout" \
    'git diff ../elsewhere/cosign.key -'

  # Brace expansion. Asserted by message rather than by exit status, because
  # several of these spellings are refused for an unrelated reason today -- the
  # operand scan counts the unbraced words on either side -- and that accident
  # stops holding the moment the braced word is the whole comparison.
  assert_hook_refuses_naming "the hook refuses two operands folded into one braced word" \
    'git diff {/dev/null,./cosign.key}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses the braced two-operand form behind a bare --" \
    'git diff -- {/dev/null,./cosign.key}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace inside one operand of a comparison" \
    'git diff /dev/nul{l,l} ./cosign.key' 'expands braces'
  assert_hook_refuses_naming "the hook refuses the braced form behind an unspaced &&" \
    'ls&&git diff {/dev/null,./cosign.key}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace that rebuilds --no-index" \
    'git diff --no-inde{x,x} -- /dev/null ./cosign.key' 'expands braces'
  # The write half, which needs no operand arithmetic at all: a brace anywhere
  # in the flag name hands git --output whole.
  assert_hook_refuses_naming "the hook refuses a brace that rebuilds --output on git log" \
    'git log -p --outpu{t,t}=cosign.pub -1' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace that rebuilds --output on git show" \
    'git show --outpu{t,t}=/tmp/written HEAD' 'expands braces'
  # #313: the brace scope ends where bash ends the command. The first version
  # of this rule latched on the word `git` and held to the end of the string,
  # so a jq filter or awk program in a *later* command of the same string was
  # refused as though git would receive it -- `git log -1 && jq '{a:1}'` was
  # blocked outright. A brace is git's only between a `git` word and the next
  # unquoted `;`, `&`, `|`, `(`, `)`, newline or backtick; the scope reopens
  # at the next `git` word, so a second git command in the string is held to
  # the same rule and one that is piped into is not excused by the command in
  # front of it.
  assert_hook_permits "a brace in a later non-git command of the same string is unprompted (#313)" \
    'git status --short && awk "{print}" packages-base.txt'
  assert_hook_permits "a jq filter after a git call is unprompted (#313)" \
    "git log -1 && jq '{a:1}'"
  assert_hook_permits "an awk program piped from git diff is unprompted" \
    "git diff HEAD | awk '{print \$1}'"
  assert_hook_permits "a jq filter piped from a reflog diff is unprompted" \
    "git diff HEAD@{1} | jq '{a,b}'"
  assert_hook_permits "a brace in the command piped into git is unprompted" \
    "jq '{a,b}' < f | git diff --stat"
  assert_hook_refuses_naming "the hook refuses a brace in a second git command after ;" \
    'git log -1; git diff {a,b}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace in a git command that is piped into" \
    'echo x | git diff {a,b}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace in a git command on a second line" \
    $'git log -1\ngit diff {a,b}' 'expands braces'
  # shellcheck disable=SC2016 # the literal backticks are the command string
  # handed to the hook, not anything this script expands.
  assert_hook_refuses_naming "the hook refuses a brace in a git command inside backticks" \
    'git log -1 `git diff {a,b}`' 'expands braces'
  # And the refusal is scoped to git invocations, so a brace in a command
  # string that never calls git is untouched. These are the ordinary shapes --
  # an awk program, a jq filter -- that a whole-string brace refusal would
  # have broken.
  assert_hook_permits "an awk program in braces is still unprompted" \
    'awk "{print}" packages-base.txt'
  assert_hook_permits "a jq object filter in braces is still unprompted" \
    'jq "{forkProcessing: .forkProcessing}" renovate.json'
  assert_hook_permits "a brace expansion outside a git call is still unprompted" \
    'ls packages-{base,kde}.txt'

  # #312: bash expands a brace only when a comma or a `..` range sits inside
  # it. Every other brace is a literal, and git's own `@{...}` revision syntax
  # -- `HEAD@{1}`, `main@{upstream}`, `@{-1}`, `@{2.days.ago}` -- is spelled
  # with exactly that literal form, so refusing every brace blocked the
  # ordinary diff against the previous commit for no gain. One operand each,
  # so nothing here depends on the reflog this checkout happens to have; the
  # last case pins that a `{` which never closes is a literal too.
  assert_hook_permits "git diff against @{upstream} is unprompted (#312)" \
    'git diff @{upstream}'
  assert_hook_permits "git log of a reflog entry is unprompted (#312)" \
    'git log HEAD@{2}'
  assert_hook_permits "git diff HEAD@{1} with a pathspec is unprompted" \
    'git diff HEAD@{1} -- AGENTS.md'
  assert_hook_permits "git log main@{upstream} is unprompted" \
    'git log main@{upstream} -1'
  assert_hook_permits "git rev-parse @{-1} is unprompted" \
    'git rev-parse @{-1}'
  assert_hook_permits "git log @{2.days.ago} is unprompted" \
    'git log @{2.days.ago} -1'
  assert_hook_permits "an unclosed brace in a git word is a literal and unprompted" \
    'git log HEAD@{1 -1'
  # The line is drawn where bash draws it, and errs toward refusing: `@{1,2}`
  # reads as revision syntax and is two words to bash; `{x..x}` is a
  # one-element sequence that rebuilds a flag; a comma nested one level down
  # still expands; `${VAR}` is a runtime-built argument; bash pairs a `{` with
  # the last `}` it can, so `{a},b}` expands and a depth counter that closed
  # at the first `}` never saw the comma; a quoted `;` inside the brace is
  # part of the word bash expands, while a split on the quote-stripped string
  # cut the word in two before the brace test saw it. A `..` between two
  # reflog entries has the refused shape and is refused although bash would
  # leave it alone; the message names the spelling to use instead.
  assert_hook_refuses_naming "the hook refuses @{1,2}, which bash expands" \
    'git diff HEAD@{1,2}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a one-element range that rebuilds --no-index" \
    'git diff --no-inde{x..x} /dev/null ./AGENTS.md' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a nested brace expansion" \
    'git diff {{/dev/null,./cosign.key}}' 'expands braces'
  # shellcheck disable=SC2016 # the literal ${SECRET} is the point
  assert_hook_refuses_naming "the hook refuses \${VAR} inside a git invocation" \
    'git diff ${SECRET} HEAD' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace closed at its last }" \
    'git diff {a},b} /dev/null ./cosign.key' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace that rebuilds --output on git log via {}" \
    'git log {--format=%h},--output=cosign.pub} -1' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a quoted operator inside a brace" \
    "git diff {/tmp/reference';',./cosign.key}" 'expands braces'
  assert_hook_refuses_naming "the hook refuses a quoted space inside a brace" \
    "git log -p --outpu{t,'t '}=cosign.pub -1" 'expands braces'
  assert_hook_refuses_naming "the hook refuses .. between two reflog entries and names HEAD~2..HEAD~1" \
    'git log HEAD@{2}..HEAD@{1}' 'HEAD~2..HEAD~1'

  # The brace rule against bash itself rather than against a label. Each
  # corpus word is handed to bash verbatim, as an agent would type it, and
  # bash says whether it becomes more than one word; every word bash expands
  # must be refused, and every word of the literal set must be allowed. A word
  # in neither class is held only to the first rule, so an over-refusal there
  # is not a failure. The counts keep the check from going vacuous if the
  # corpus shrinks or bash reads it differently. `OPERANDS` is set so that
  # `${OPERANDS}` splits into two words the way a runtime-built argument would.
  literal_brace_words=(
    'HEAD@{1}'
    'main@{upstream}'
    '@{-1}'
    '@{2.days.ago}'
    'HEAD@{1'
  )
  # shellcheck disable=SC2016 # every word here is a spelling handed to bash
  # verbatim; ${OPERANDS} and '{print $1}' are meant to reach it unexpanded.
  brace_corpus=(
    "${literal_brace_words[@]}"
    'HEAD@{2}..HEAD@{1}'
    '{a,b}'
    '{1..3}'
    'x{1..3}y'
    'a{,b}'
    '{{a,b}}'
    '--no-inde{x,x}'
    '--outpu{t,t}=FILE'
    'HEAD@{1,2}'
    '{--src-prefix=x},--no-index}'
    '{a},b}'
    "{/tmp/reference';',./cosign.key}"
    '{a",",b}'
    '{a\,b,c}'
    '"{a,b}"'
    "'{a,b}'"
    '{a,b'
    '{a,b}}'
    '{{a,b}'
    '${OPERANDS}'
    '--output={a,b}'
    '--output=x{,}'
    "'{print \$1}'"
    "'{a:1}'"
    "'{a: .x, b: .y}'"
  )
  bash_expands() {
    local expanded
    expanded="$(OPERANDS='/dev/null ./cosign.key' bash --norc --noprofile -c 'printf "%s\0" '"$1" 2>/dev/null | tr -cd '\0' | wc -c)" || return 1
    ((expanded > 1))
  }
  corpus_expanding=0
  corpus_refused=1
  corpus_failed=''
  for corpus_word in "${brace_corpus[@]}"; do
    bash_expands "${corpus_word}" || continue
    corpus_expanding=$((corpus_expanding + 1))
    corpus_payload="$(jq -nc --arg c "git diff ${corpus_word}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${corpus_payload}"
    if ((hook_status != 2)) || [[ "${hook_stderr}" != *'expands braces'* ]]; then
      corpus_refused=0
      corpus_failed+="${corpus_word} (exit ${hook_status}) "
    fi
  done
  if ((${#brace_corpus[@]} >= 25 && corpus_expanding >= 15)); then
    pass "the brace corpus is large enough to mean something (${#brace_corpus[@]} words, ${corpus_expanding} that bash expands)"
  else
    fail "the brace corpus is large enough to mean something (${#brace_corpus[@]} words, ${corpus_expanding} that bash expands)" \
      "wanted at least 25 words of which bash expands at least 15; the check has gone vacuous"
  fi
  if ((corpus_refused)); then
    pass "every corpus word bash expands is refused inside a git invocation"
  else
    fail "every corpus word bash expands is refused inside a git invocation" \
      "bash expands these into more than one word and the hook let them through: ${corpus_failed}"
  fi
  literal_allowed=1
  literal_failed=''
  for literal_word in "${literal_brace_words[@]}"; do
    if bash_expands "${literal_word}"; then
      literal_allowed=0
      literal_failed+="${literal_word} (bash expands it) "
      continue
    fi
    corpus_payload="$(jq -nc --arg c "git log ${literal_word} -1" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${corpus_payload}"
    if ((hook_status != 0)) || [[ -n "${hook_stderr}" ]]; then
      literal_allowed=0
      literal_failed+="${literal_word} (exit ${hook_status}) "
    fi
  done
  if ((literal_allowed)); then
    pass "every literal-brace word bash leaves alone is unprompted inside a git invocation"
  else
    fail "every literal-brace word bash leaves alone is unprompted inside a git invocation" \
      "${literal_failed}"
  fi

  # An unquoted leading `~` is $HOME to bash and a literal `~` to the gate,
  # which `realpath -m -s` resolved to `<checkout>/~/...`, an inside path. So
  # `git diff -- ~/.aws/credentials ~/.bashrc` counted two operands, found
  # both inside the working tree, and exited 0, and bash then handed git two
  # files from the home directory, which it printed as a plain-file diff. The
  # ShellCheck operand scan below already refuses that word; the git scope now
  # does the same. Shown first, against a throwaway HOME of this fixture's
  # own -- never the real $HOME.
  git_tilde_home="$(mktemp -d)"
  mkdir -p "${git_tilde_home}/.aws"
  printf 'SYNTHETIC_GIT_TILDE_SECRET=synthetic-value-4\n' >"${git_tilde_home}/.aws/credentials"
  printf 'export FIXTURE=1\n' >"${git_tilde_home}/.bashrc"
  git_tilde_output="$(HOME="${git_tilde_home}" bash --norc --noprofile -c 'git diff -- ~/.aws/credentials ~/.bashrc' 2>&1 </dev/null || true)"
  rm -rf "${git_tilde_home}"
  if grep -q '^-SYNTHETIC_GIT_TILDE_SECRET=synthetic-value-4$' <<<"${git_tilde_output}"; then
    pass "git diff -- ~/path ~/path prints the files under \$HOME, which is not the literal ~ the gate resolves"
  else
    fail "git diff -- ~/path ~/path prints the files under \$HOME, which is not the literal ~ the gate resolves" \
      "the synthetic line did not appear; re-derive why an unquoted leading ~ is refused in a git invocation"
  fi
  for tilde_command in \
    'git diff -- ~/.aws/credentials ~/.bashrc' \
    'git diff ~/.bashrc ~/.aws/credentials' \
    'git diff -- ~ ~/.bashrc' \
    'git diff -- ~root/.bashrc ./cosign.pub' \
    'git log -p -- ~/.ssh/config' \
    'git show HEAD -- ~/.ssh/config' \
    'git diff HEAD -- ~/.bashrc' \
    'git status; git diff -- ~/.aws/credentials ~/.bashrc' \
    'echo x | git diff -- ~/.aws/credentials ~/.bashrc'; do
    assert_hook_refuses_naming "the hook refuses an unquoted leading ~ in a git invocation: ${tilde_command}" \
      "${tilde_command}" 'unquoted leading ~'
  done
  for tilde_command in \
    'git diff HEAD@{1}' \
    'git diff HEAD~1' \
    "git diff -- 'lit~eral'" \
    "git diff -- '~/x'" \
    'git diff -- "~/x"' \
    'git diff -- \~/x' \
    'git diff HEAD -- x~' \
    'git show HEAD:~/x' \
    'ls ~/.bashrc; git diff HEAD' \
    'echo x > out; git diff HEAD'; do
    assert_hook_permits "a quoted, escaped or non-leading ~ is the literal word and is unprompted: ${tilde_command}" \
      "${tilde_command}"
  done
  # The containment test never resolves a leading `~` inside the tree, quoted
  # or not, so two quoted tildes after a `--` are refused as the plain-file
  # form although bash would hand git two literal paths: the stricter
  # direction, taken on purpose (review on zfs-kinoite-complex#220).
  assert_hook_refuses_naming "two quoted tildes after -- are refused as the plain-file form" \
    "git diff -- '~/x' '~/y'" 'plain files'
  # The tilde rule against bash itself, the way the brace corpus is checked:
  # every word bash rewrites must be refused, every word of the literal set
  # must be allowed, and a word in neither class is held only to the first
  # rule. Each word is handed to bash verbatim under a HOME that does not
  # exist, which changes nothing about whether bash expands it.
  literal_tilde_words=(
    "'~/x'"
    '"~/x"'
    '\~/x'
    'HEAD~1'
    'HEAD~2..HEAD~1'
    'lit~eral'
    'x~'
  )
  # shellcheck disable=SC2088 # the quoted tildes are corpus words, not paths this fixture opens
  tilde_corpus=(
    "${literal_tilde_words[@]}"
    '~'
    '~/.aws/credentials'
    '~/.bashrc'
    '~root/.bashrc'
    '~/'
  )
  bash_rewrites() {
    local typed stripped
    typed="$(HOME=/nonexistent-home bash --norc --noprofile -c 'printf "%s" '"$1" 2>/dev/null)" || return 1
    stripped="${1//[\'\"\\]/}"
    [[ "${typed}" != "${stripped}" ]]
  }
  tilde_rewritten=0
  tilde_refused=1
  tilde_failed=''
  for corpus_word in "${tilde_corpus[@]}"; do
    bash_rewrites "${corpus_word}" || continue
    tilde_rewritten=$((tilde_rewritten + 1))
    corpus_payload="$(jq -nc --arg c "git diff -- ${corpus_word} ./cosign.pub" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${corpus_payload}"
    if ((hook_status != 2)) || [[ "${hook_stderr}" != *'unquoted leading ~'* ]]; then
      tilde_refused=0
      tilde_failed+="${corpus_word} (exit ${hook_status}) "
    fi
  done
  if ((tilde_rewritten >= 4)); then
    pass "the tilde corpus is large enough to mean something (${#tilde_corpus[@]} words, ${tilde_rewritten} that bash rewrites)"
  else
    fail "the tilde corpus is large enough to mean something (${#tilde_corpus[@]} words, ${tilde_rewritten} that bash rewrites)" \
      "wanted at least 4 words bash rewrites; the check has gone vacuous"
  fi
  if ((tilde_refused)); then
    pass "every corpus word bash tilde-expands is refused inside a git invocation"
  else
    fail "every corpus word bash tilde-expands is refused inside a git invocation" \
      "bash rewrites these and the hook let them through: ${tilde_failed}"
  fi
  tilde_literal_allowed=1
  tilde_literal_failed=''
  for literal_word in "${literal_tilde_words[@]}"; do
    if bash_rewrites "${literal_word}"; then
      tilde_literal_allowed=0
      tilde_literal_failed+="${literal_word} (bash rewrites it) "
      continue
    fi
    corpus_payload="$(jq -nc --arg c "git log -1 -- ${literal_word}" '{tool_name: "Bash", tool_input: {command: $c}}')"
    run_bash_hooks "${corpus_payload}"
    if ((hook_status != 0)) || [[ -n "${hook_stderr}" ]]; then
      tilde_literal_allowed=0
      tilde_literal_failed+="${literal_word} (exit ${hook_status}) "
    fi
  done
  if ((tilde_literal_allowed)); then
    pass "every literal-tilde word bash leaves alone is unprompted inside a git invocation"
  else
    fail "every literal-tilde word bash leaves alone is unprompted inside a git invocation" \
      "${tilde_literal_failed}"
  fi

  # #316: a quoted operator inside a git diff flag must not end the command.
  # The first split stripped quotes and then cut the string at every operator
  # character, so `--src-prefix='x|'` ended the git invocation as far as the
  # operand scan was concerned, the count reset at the `|`, and `/dev/null
  # ./cosign.key` were never counted -- while bash handed git the ordinary
  # two-operand plain-file read. Demonstrated first, in a temporary directory
  # of this fixture's own: git really prints the file beside that flag.
  quoted_op_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${quoted_op_dir}/fake.key"
  quoted_op_read="$(bash --norc --noprofile -c "git diff --src-prefix='x|' /dev/null ${quoted_op_dir}/fake.key" 2>/dev/null </dev/null)"
  if grep -q '^+SECRET-LINE-1$' <<<"${quoted_op_read}"; then
    pass "git diff prints a plain file beside a flag carrying a quoted operator"
  else
    fail "git diff prints a plain file beside a flag carrying a quoted operator" \
      "this git no longer enters the plain-file mode behind --src-prefix='x|'; re-derive the quote-aware split"
  fi
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a quoted pipe in a flag (#316)" \
    "git diff --src-prefix='x|' /dev/null ./cosign.key" 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a quoted semicolon in a flag (#316)" \
    "git diff --src-prefix='x;' /dev/null ./cosign.key" 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a quoted regex pipe (#316)" \
    "git diff --word-diff-regex='.|.' /dev/null ./cosign.key" 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a double-quoted operator" \
    'git diff --src-prefix="x&" /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read behind a backslash-escaped operator" \
    'git diff --src-prefix=x\| /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses --output after a quoted pipe in an earlier flag" \
    "git log --grep='a|b' --output=cosign.pub -1" '--output=FILE'
  # The unquoted spelling of the same string is two commands to bash -- `git
  # log --grep=a` piped into `b --output=...` -- and the --output latch still
  # holds to the end of the string, so it stays refused.
  assert_hook_refuses_naming "the hook still refuses --output after an unquoted pipe" \
    'git log --grep=a|b --output=cosign.pub -1' '--output=FILE'
  assert_hook_permits "a quoted operator in an ordinary one-operand diff flag is unprompted" \
    "git diff --src-prefix='x|' HEAD"
  assert_hook_permits "a quoted regex in git log --grep is unprompted" \
    "git log --grep='fix|feat' --oneline -5"

  # A redirection is not a separator, and its descriptor and target are the
  # shell's words rather than git's. A split that counted every unquoted `&`
  # as a separator closed the brace scope at the `&` of `2>&1`, and counted
  # the `2` and `1` of it as diff operands, refusing every `git diff ... 2>&1`
  # while letting `git diff 2>&1 /dev/null ./cosign.key` through with neither
  # operand counted. `>&`, `<&`, `&>`, `&>>` and `>|` are redirections; `|&`
  # is a pipe and still ends the command.
  assert_hook_permits "git diff HEAD 2>&1 is unprompted" 'git diff HEAD 2>&1'
  assert_hook_permits "git diff HEAD@{1} 2>&1 piped into jq is unprompted" \
    "git diff HEAD@{1} 2>&1 | jq '{a,b}'"
  assert_hook_permits "git diff HEAD |& jq is unprompted" "git diff HEAD |& jq '{a,b}'"
  assert_hook_permits "an input redirection on git diff is unprompted" 'git diff HEAD </dev/null'
  assert_hook_permits "a spaced input redirection on git diff is unprompted" 'git diff HEAD < /dev/null'
  assert_hook_permits "git diff --stat with 2>&1 piped into head is unprompted" \
    'git diff --stat HEAD -- AGENTS.md 2>&1 | head'
  assert_hook_refuses_naming "the hook refuses the plain-file read with 2>&1 before the operands" \
    'git diff 2>&1 /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read with 2>&1 after the operands" \
    'git diff /dev/null ./cosign.key 2>&1' 'plain files'
  assert_hook_refuses_naming "the hook refuses a brace behind 2>&1 on git log" \
    'git log 2>&1 --outpu{t,t}=cosign.pub -1' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace behind &>" \
    'git diff &>/dev/null {a,b}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace behind <&0" \
    'git diff <&0 {a,b}' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace behind >| in the same command" \
    'git log -1 >| out --outpu{t,t}=cosign.pub' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace in a git command behind |&" \
    'git log -1 |& git diff {a,b}' 'expands braces'

  # The shell's own spelling of the write primitive: `git diff HEAD
  # >cosign.pub` truncates the file before git starts. The split above learned
  # to skip a redirection's target so `2>&1` is not two operands -- and with
  # that, the target of `>` was skipped too and the command passed. Shown
  # first, in a temporary directory: the redirection really empties the file.
  redirect_dir="$(mktemp -d)"
  printf 'ORIGINAL-CONTENT\n' >"${redirect_dir}/victim"
  bash --norc --noprofile -c "git diff HEAD HEAD >${redirect_dir}/victim" >/dev/null 2>&1 </dev/null
  redirect_written="$(cat "${redirect_dir}/victim" 2>/dev/null)"
  rm -rf "${redirect_dir}"
  if [[ "${redirect_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "an output redirection on git diff truncates the file it names before git runs"
  else
    fail "an output redirection on git diff truncates the file it names before git runs" \
      "the file kept its contents; re-derive why the redirection refusal exists"
  fi
  for redirect_command in \
    'git diff HEAD >cosign.pub' \
    'git diff HEAD > cosign.pub' \
    'git log -1 >> out' \
    'git diff 2>err' \
    'git diff &>/dev/null' \
    'git diff &>>/dev/null' \
    'git show HEAD >| x' \
    'git diff HEAD > .claude/settings.json' \
    'git diff HEAD > .claude/hooks/gate-git-diff.sh' \
    'git diff HEAD >&cosign.pub' \
    'git diff HEAD >& cosign.pub' \
    'git diff HEAD <>cosign.pub' \
    'git diff HEAD 2>&1 >cosign.pub' \
    'git log -1; git diff HEAD >cosign.pub' \
    'echo x | git diff HEAD >cosign.pub' \
    'git diff HEAD 2>&1 | jq . ; git log -1 >out'; do
    assert_hook_refuses_naming "the hook refuses an output redirection inside a git invocation: ${redirect_command}" \
      "${redirect_command}" 'output redirection'
  done
  for redirect_command in \
    'git diff HEAD >&2' \
    'git diff HEAD 1>&2' \
    'git diff HEAD >&-' \
    'git diff HEAD 2>&-' \
    'git diff HEAD <&0' \
    "git diff HEAD <<<''" \
    'echo x > out; git diff HEAD' \
    'echo x >> out && git diff HEAD' \
    'git diff HEAD | jq . > out'; do
    assert_hook_permits "a descriptor, input or other-command redirection is unprompted: ${redirect_command}" \
      "${redirect_command}"
  done
  # Bash lets a redirection precede the command name, and the two spellings
  # are the same command: `>cosign.pub git diff HEAD` truncates the file
  # exactly as `git diff HEAD >cosign.pub` does. A scope that opened at the
  # `git` word had not yet seen the target, so `git status; >cosign.pub git
  # diff HEAD` -- allowed on its `git status` prefix -- went through (review
  # on #317). Shown first: the prefix form really truncates the file.
  prefix_dir="$(mktemp -d)"
  printf 'ORIGINAL-CONTENT\n' >"${prefix_dir}/victim"
  bash --norc --noprofile -c "git status --short >/dev/null; >${prefix_dir}/victim git diff HEAD HEAD" >/dev/null 2>&1 </dev/null
  prefix_written="$(cat "${prefix_dir}/victim" 2>/dev/null)"
  rm -rf "${prefix_dir}"
  if [[ "${prefix_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a redirection written before the git word truncates the file it names"
  else
    fail "a redirection written before the git word truncates the file it names" \
      "the file kept its contents; re-derive why prefix redirections are carried to the command name"
  fi
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for redirect_command in \
    '>cosign.pub git diff HEAD' \
    'git status; >cosign.pub git diff HEAD' \
    '2>err git log -1' \
    '>> out git show HEAD' \
    'FOO=bar >out git diff HEAD' \
    'git status; >cosign.pub /usr/bin/git diff HEAD' \
    'git status; {fd}>cosign.pub git diff HEAD' \
    'git diff HEAD {fd}>cosign.pub' \
    'git status; >$(printf cosign.pub) git diff HEAD' \
    '>$(printf cosign.pub) git diff HEAD'; do
    assert_hook_refuses_naming "the hook refuses a redirection written before the git word: ${redirect_command}" \
      "${redirect_command}" 'output redirection'
  done
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for redirect_command in \
    '</dev/null git diff HEAD' \
    '2>&1 git diff HEAD' \
    '>&2 git diff HEAD' \
    '>out echo x; git diff HEAD' \
    '>out cat f | git diff --stat' \
    'git status; >out printf %s git' \
    '>out echo git; git diff HEAD' \
    '>$(printf out) echo x; git diff HEAD' \
    '{fd}>out echo x; git diff HEAD' \
    'x=$(date); git diff HEAD' \
    'echo $(date) *.sh; git status' \
    'echo $(git log -1) | git diff HEAD'; do
    assert_hook_permits "a prefix redirection that writes no path, or belongs to another command, is unprompted: ${redirect_command}" \
      "${redirect_command}"
  done
  # An expanding brace means the words here are not the words git would
  # receive, so its message comes first; the redirection is refused once the
  # brace is gone.
  assert_hook_refuses_naming "a brace wins over a redirection refusal" \
    'git diff HEAD >cosign.{pub,key}' 'expands braces'

  # The write primitive is not git's alone. Six other allow rows end in `*`
  # -- "this command with any arguments" -- and a shell output redirection
  # is part of the string that rule matches, so `shellcheck
  # tests/run-tests.sh >cosign.pub` truncated the trust anchor before a line
  # was linted and `podman images >.claude/settings.json` overwrote the file
  # holding these rules, neither prompted (zfs-kinoite-complex#224, the same
  # hook). Shown first, against a stand-in in a temporary directory: bash
  # opens the target before the command runs, so the file is emptied even
  # when the command then fails. `bash -n` is used because it is always
  # present; shellcheck may not be.
  gated_dir="$(mktemp -d)"
  printf 'ORIGINAL-CONTENT\n' >"${gated_dir}/victim"
  (cd "${gated_dir}" && bash --norc --noprofile -c 'bash -n ./no-such-script.sh >victim' >/dev/null 2>&1 </dev/null)
  gated_written="$(cat "${gated_dir}/victim" 2>/dev/null)"
  # And the flag form: `-n` reads a script without running it, and a later
  # `+n` on the same command line turns that back off, so the linter's allow
  # rule runs whatever follows.
  noexec_ran="$(bash --norc --noprofile -c "bash -n +n -c 'printf RAN-UNDER-BASH-N'" 2>/dev/null </dev/null)"
  # And the glob form (review on aurora-zfs-simple#211): beside a file named
  # `+n`, `?n` reaches bash as `+n`.
  touch "${gated_dir}/+n"
  glob_ran="$(cd "${gated_dir}" && bash --norc --noprofile -c "bash -n ?n -c 'printf RAN-VIA-GLOB'" 2>/dev/null </dev/null)"
  # And a process substitution as the redirection's target: bash connects the
  # command's output to a command of its own, which writes wherever it likes
  # (review on #322).
  printf 'ORIGINAL-CONTENT\n' >"${gated_dir}/victim2"
  (cd "${gated_dir}" && bash --norc --noprofile -c 'df -T > >(cat >victim2); wait' >/dev/null 2>&1 </dev/null)
  subst_written="$(cat "${gated_dir}/victim2" 2>/dev/null)"
  # A process substitution as an ordinary argument runs its body as part of
  # the approved string, and the body is held to no rule; and a wrapper's
  # option before the name (`command -p bash -n +n ...`) is still that
  # command (review on #322).
  printf 'ORIGINAL-CONTENT\n' >"${gated_dir}/victim3"
  (cd "${gated_dir}" && bash --norc --noprofile -c 'df -T >(cat >victim3); wait' >/dev/null 2>&1 </dev/null)
  arg_subst_written="$(cat "${gated_dir}/victim3" 2>/dev/null)"
  wrapper_ran="$(bash --norc --noprofile -c "command -p bash -n +n -c 'printf RAN-BEHIND-WRAPPER'" 2>/dev/null </dev/null)"
  time_ran="$(bash --norc --noprofile -c "time -p bash -n +n -c 'printf RAN-BEHIND-TIME'" 2>/dev/null </dev/null)"
  printf 'ORIGINAL-CONTENT\n' >"${gated_dir}/victim4"
  (cd "${gated_dir}" && bash --norc --noprofile -c 'df -T $(printf x >victim4)' >/dev/null 2>&1 </dev/null)
  cmd_subst_written="$(cat "${gated_dir}/victim4" 2>/dev/null)"
  rm -rf "${gated_dir}"
  if [[ "${gated_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "an output redirection on an allow-listed non-git command truncates the file it names"
  else
    fail "an output redirection on an allow-listed non-git command truncates the file it names" \
      "the file kept its contents; re-derive why the gated-prefix refusal exists"
  fi
  if [[ "${noexec_ran}" == "RAN-UNDER-BASH-N" ]]; then
    pass "bash -n +n -c COMMAND runs the command the -n was meant to keep from running"
  else
    fail "bash -n +n -c COMMAND runs the command the -n was meant to keep from running" \
      "got '${noexec_ran}'; re-derive why the +n refusal exists"
  fi
  if [[ "${glob_ran}" == "RAN-VIA-GLOB" ]]; then
    pass "bash -n ?n -c COMMAND runs the command when a file named +n exists"
  else
    fail "bash -n ?n -c COMMAND runs the command when a file named +n exists" \
      "got '${glob_ran}'; re-derive why the glob refusal exists"
  fi
  if [[ "${subst_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a redirection onto a process substitution writes the file the substitution names"
  else
    fail "a redirection onto a process substitution writes the file the substitution names" \
      "the file kept its contents; re-derive why a substitution after a redirection is its target"
  fi
  if [[ "${arg_subst_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a process substitution argument writes the file its body names"
  else
    fail "a process substitution argument writes the file its body names" \
      "the file kept its contents; re-derive why a substitution in a gated command is refused"
  fi
  if [[ "${wrapper_ran}" == "RAN-BEHIND-WRAPPER" ]]; then
    pass "command -p bash -n +n -c COMMAND runs the command behind the wrapper's option"
  else
    fail "command -p bash -n +n -c COMMAND runs the command behind the wrapper's option" \
      "got '${wrapper_ran}'; re-derive why the prefix restarts at a later candidate name"
  fi
  if [[ "${time_ran}" == "RAN-BEHIND-TIME" ]]; then
    pass "time -p bash -n +n -c COMMAND runs the command behind time's option"
  else
    fail "time -p bash -n +n -c COMMAND runs the command behind time's option" \
      "got '${time_ran}'; re-derive why the name scan steps over time's -p"
  fi
  if [[ "${cmd_subst_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a command substitution argument writes the file its body names"
  else
    fail "a command substitution argument writes the file its body names" \
      "the file kept its contents; re-derive why a substitution in a gated command is refused"
  fi
  # A here-document with an unquoted delimiter is expanded before the
  # command runs, so a substitution on a body line runs under the prefix
  # (review on #322).
  heredoc_dir="$(mktemp -d)"
  printf 'ORIGINAL-CONTENT\n' >"${heredoc_dir}/victim5"
  (cd "${heredoc_dir}" && bash --norc --noprofile -c $'df -T <<EOF\n$(printf x >victim5)\nEOF' >/dev/null 2>&1 </dev/null)
  heredoc_written="$(cat "${heredoc_dir}/victim5" 2>/dev/null)"
  rm -rf "${heredoc_dir}"
  if [[ "${heredoc_written}" != *ORIGINAL-CONTENT* ]]; then
    pass "a substitution on the body line of an unquoted heredoc writes the file it names"
  else
    fail "a substitution on the body line of an unquoted heredoc writes the file it names" \
      "the file kept its contents; re-derive why an unquoted heredoc on a gated command is refused"
  fi
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for heredoc_command in \
    $'df -T <<EOF\necho $(printf x >cosign.pub)\nEOF' \
    $'podman images <<EOF\nplain text\nEOF' \
    $'bash -n <<-EOF\n\tx\nEOF' \
    $'git status; findmnt <<EOF\nx\nEOF'; do
    assert_hook_refuses_naming "the hook refuses an unquoted here-document on an allow-listed command: ${heredoc_command//$'\n'/ | }" \
      "${heredoc_command}" 'Quote the delimiter'
  done
  # An assignment before the name is an environment the command runs
  # under, and for these commands that changes what runs or where it goes
  # (review on sensi#244, the Python twin of this hook); git keeps
  # `FOO=bar git diff`.
  for assigned_command in \
    'LD_PRELOAD=x.so shellcheck tests/run-tests.sh' \
    'BASH_ENV=f bash -n tests/run-tests.sh' \
    'CONTAINERS_CONF=f podman ps' \
    'FOO=1 df -T' \
    'git status; FOO=1 findmnt'; do
    assert_hook_refuses_naming "the hook refuses an assignment before an allow-listed command: ${assigned_command}" \
      "${assigned_command}" 'assignment before'
  done
  for assigned_command in \
    'FOO=bar git diff HEAD' \
    'PAGER=cat git log -1' \
    'FOO=1 echo x; podman images' \
    'x=1; podman images'; do
    assert_hook_permits "an assignment before git, or on another command, is unprompted: ${assigned_command}" \
      "${assigned_command}"
  done
  # shellcheck disable=SC2016 # the substitution is a spelling handed to the hook, not run here
  for heredoc_command in \
    $'bash -n <<\'EOF\'\necho hi\nEOF' \
    $'bash -n <<"EOF"\necho $(id)\nEOF' \
    $'cat <<EOF\nplain\nEOF; podman images' \
    'podman images <in'; do
    assert_hook_permits "a quoted here-document, or one on another command, is unprompted: ${heredoc_command//$'\n'/ | }" \
      "${heredoc_command}"
  done
  # shellcheck disable=SC2016 # the substitution is a spelling handed to the hook, not run here
  for subst_command in \
    'df -T >(cat >cosign.pub)' \
    '>(cat >cosign.pub) df -T' \
    'podman ps <(true)' \
    'bash -n <(printf x >written)' \
    'bash -n >(cat) tests/run-tests.sh' \
    'git status; findmnt -J >(tee cosign.pub)' \
    'echo $(podman images >(cat >cosign.pub))' \
    'df -T $(touch cosign.pub)' \
    'podman images `printf x >cosign.pub`' \
    'findmnt $(pwd) >cosign.pub' \
    'df -T < <(printf x >cosign.pub)' \
    'podman images <"$(printf x >cosign.pub)"' \
    'df -T <<<"$(printf x >cosign.pub)"' \
    'podman images <`printf in`' \
    'shellcheck tests/run-tests.sh <"$(printf x >cosign.pub)"' \
    'shellcheck tests/run-tests.sh < <(printf x >cosign.pub)' \
    'df -T "$(printf x >cosign.pub)"' \
    'podman images $X' \
    'findmnt "$FLAGS"' \
    "podman images 'a \$b'"; do
    assert_hook_refuses_naming "the hook refuses a substitution in an allow-listed command: ${subst_command}" \
      "${subst_command}" 'substitution'
  done
  # The list of gated commands lives in the hook; this is what keeps it from
  # drifting. The commands are derived from the settings file rather than
  # restated, so an allow rule added there with a trailing `*` fails here
  # until the hook lists it. The git rows are the scan above's; the exact
  # rows (`just test`, the virsh inventories) carry no `*`, so a redirection
  # makes the string match no row and Claude Code prompts.
  gated_rows=0
  while IFS= read -r gated_prefix; do
    [[ -n "${gated_prefix}" ]] || continue
    [[ "${gated_prefix}" == "git "* ]] && continue
    gated_rows=$((gated_rows + 1))
    assert_hook_refuses_naming "every allow rule with arguments is refused a writing redirection: ${gated_prefix} >cosign.pub" \
      "${gated_prefix} >cosign.pub" 'allow-listed command'
  done < <(jq -r '.permissions.allow[]? | select(startswith("Bash(") and endswith("*)")) | .[5:-2] | sub(" $"; "")' "${CLAUDE_SETTINGS}")
  if ((gated_rows >= 6)); then
    pass "the settings file still carries the allow rows the gated-prefix scan covers (${gated_rows})"
  else
    fail "the settings file still carries the allow rows the gated-prefix scan covers" \
      "found ${gated_rows} Bash(...*) rows other than git's; expected at least 6"
  fi
  # Every operator that opens a path, in every position bash accepts it: after
  # the command, before its name, after an assignment or `time`, carried
  # across a `$(...)` in the same command, and on the longer last word the
  # `df -T*` row also matches.
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for redirect_command in \
    'shellcheck tests/run-tests.sh >cosign.pub' \
    'shellcheck tests/run-tests.sh >> out' \
    'shellcheck tests/run-tests.sh 2>.claude/settings.json' \
    'shellcheck >| cosign.pub' \
    'bash -n tests/run-tests.sh &>cosign.pub' \
    'bash -n tests/run-tests.sh &>>cosign.pub' \
    'podman images >&cosign.pub' \
    'podman ps -a <>cosign.pub' \
    'podman ps {fd}>cosign.pub' \
    'findmnt -J >/dev/null' \
    'df -T >cosign.pub' \
    'df -Th > .claude/hooks/gate-git-diff.sh' \
    'podman images 2>&1 >cosign.pub' \
    '>cosign.pub shellcheck tests/run-tests.sh' \
    'git status; >cosign.pub podman images' \
    'FOO=bar shellcheck tests/run-tests.sh >cosign.pub' \
    'FOO=bar >cosign.pub shellcheck tests/run-tests.sh' \
    'time shellcheck tests/run-tests.sh >cosign.pub' \
    'command podman images >cosign.pub' \
    'echo $(podman images >cosign.pub)' \
    'ls | podman images >cosign.pub' \
    'shellcheck tests/run-tests.sh 2>&1 | tee x; df -T >out' \
    'df -T > >(cat >cosign.pub)' \
    'podman images >>(tee cosign.pub)' \
    'shellcheck tests/run-tests.sh 2> >(cat >cosign.pub)' \
    'shellcheck tests/run-tests.sh >cosign.pub # a comment after the write' \
    "shellcheck tests/run-tests.sh '#' >cosign.pub" \
    'command -p shellcheck tests/run-tests.sh >cosign.pub'; do
    assert_hook_refuses_naming "the hook refuses an output redirection inside an allow-listed command: ${redirect_command}" \
      "${redirect_command}" 'allow-listed command'
  done
  # The refusal is the operator that opens a path for writing. A pipe, a
  # descriptor form and an input redirection open none.
  for redirect_command in \
    'shellcheck tests/run-tests.sh 2>&1 | tail -5' \
    'podman images | grep arch-bootc' \
    'findmnt -T / -o TARGET,SOURCE' \
    'shellcheck tests/run-tests.sh <tests/run-tests.sh' \
    'podman ps >&2' \
    'df -T 2>&-' \
    'bash -n tests/run-tests.sh </dev/null' \
    'shellcheck -x tests/run-tests.sh' \
    'bash -n tests/run-tests.sh' \
    'df -Th'; do
    assert_hook_permits "reading the output of an allow-listed command is unprompted: ${redirect_command}" \
      "${redirect_command}"
  done
  # The hook re-gates what the permission rules wave through. A command no
  # allow rule covers prompts on its own, and a redirection on another
  # command of the same string is that command's own. The last two are
  # decided by Claude Code itself: a redirection on a brace group or a
  # subshell is refused by the Bash tool before any rule or hook sees it
  # ("does not accept compound statements with redirection", 2.1.267), so
  # the hook does not restate that refusal.
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for redirect_command in \
    'echo x >cosign.pub' \
    'cat tests/run-tests.sh >cosign.pub' \
    'df -h >cosign.pub' \
    'just test >cosign.pub' \
    'echo x >out; shellcheck tests/run-tests.sh' \
    'shellcheck tests/run-tests.sh | tee out' \
    '>out echo x; podman images' \
    'bash -n tests/run-tests.sh; { bash -n missing.sh; } >cosign.pub' \
    '(shellcheck tests/run-tests.sh) >cosign.pub' \
    'echo x > >(cat >cosign.pub)' \
    'cat < <(podman images)' \
    'cat <(podman images)' \
    'command -v shellcheck' \
    'time -p ls' \
    'x=$(podman images); echo $x' \
    'echo $(podman images)' \
    'podman images --format "{{.ID}}"' \
    'findmnt -J -o TARGET,SOURCE' \
    'shellcheck tests/run-tests.sh # output > file' \
    'bash -n tests/run-tests.sh # +n' \
    'git diff HEAD # > cosign.pub'; do
    assert_hook_permits "a redirection on a command no allow rule covers is unprompted: ${redirect_command}" \
      "${redirect_command}"
  done
  # The flag that undoes `bash -n`. `+n` and `+o noexec` turn execution back
  # on for the rest of the command line, so a word beginning with `+` in a
  # `bash -n` invocation is refused, along with the spellings bash rebuilds
  # -- a brace, a `$` or a backtick -- since `{+,+}n` reaches bash as `+n`.
  # shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
  for noexec_command in \
    "bash -n +n -c 'cat ./cosign.key'" \
    'bash -n +o noexec tests/run-tests.sh' \
    'bash -n tests/run-tests.sh +n' \
    "bash -n +nv -c 'id'" \
    'bash -n "+n" -c id' \
    'git status; bash -n +n -c id' \
    'git status; command -p bash -n +n -c id' \
    'command -- bash -n +n -c id' \
    'git status; time -p bash -n +n -c id' \
    'bash -n {+,+}n -c id' \
    'bash -n $X tests/run-tests.sh' \
    'bash -n $(printf +n) -c id' \
    'bash -n `printf +n` -c id' \
    'bash -n --norc {+,+}n -c id' \
    'bash -n ?n -c id' \
    'bash -n [+]n -c id' \
    'bash -n tests/*.sh'; do
    assert_hook_refuses_naming "the hook refuses a + word or an expansion in a bash -n invocation: ${noexec_command}" \
      "${noexec_command}" '+n'
  done
  # shellcheck disable=SC2016 # the $x is a spelling handed to the hook, not expanded here
  for noexec_command in \
    'bash -n tests/run-tests.sh' \
    'bash -n scripts/quickstart.sh tests/run-tests.sh' \
    'bash -n -- tests/run-tests.sh' \
    "bash -n '?n'" \
    'bash +n -c id' \
    'echo $x; bash -n tests/run-tests.sh'; do
    assert_hook_permits "a syntax check, and a bash no allow rule covers, are unprompted: ${noexec_command}" \
      "${noexec_command}"
  done

  # A `(` behind an unquoted `<` or `>` is a process substitution, not a
  # subshell: it hands git a /dev/fd path as an operand the scan never
  # counted, and the first split reset the operand count at its `(` instead.
  # It is refused in a git invocation and left alone in any other command.
  assert_hook_refuses_naming "the hook refuses a process substitution as a git diff operand" \
    'git diff <(true) ./cosign.key' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a process substitution behind --" \
    'git diff -- ./cosign.key <(true)' 'expands braces'
  assert_hook_refuses_naming "the hook refuses a brace in a git command inside a process substitution" \
    'cat <(git diff {a,b})' 'expands braces'
  assert_hook_permits "a process substitution in a later non-git command is unprompted" \
    'git log -1; cat <(true)'
  assert_hook_permits "git inside a process substitution of another command is unprompted" \
    'cat <(git log -1)'
  assert_hook_permits "two git process substitutions handed to diff are unprompted" \
    'diff <(git log -1) <(git log -2)'

  # `$` and a backtick rebuild both refusals by another route: `$(...)` and
  # `` `...` `` supply operands the scan never counted, `$'\x74'` is the
  # letter t so `--outpu$'\x74'=FILE` reaches git as --output=FILE, and `$x`
  # is a runtime-built argument. Shown first: bash replaces the substitution
  # before git runs, and git prints the file beside it.
  subst_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${subst_dir}/fake.key"
  subst_read="$(bash --norc --noprofile -c "git diff \$(echo /dev/null) ${subst_dir}/fake.key" 2>/dev/null </dev/null)"
  if grep -q '^+SECRET-LINE-1$' <<<"${subst_read}"; then
    pass "git diff prints a plain file beside a substituted operand"
  else
    fail "git diff prints a plain file beside a substituted operand" \
      "bash no longer substitutes the operand before git runs; re-derive the \$ refusal"
  fi
  # shellcheck disable=SC2016 # the literal $(...), $x and backticks are the
  # command strings handed to the hook, not anything this script expands.
  for expand_command in \
    'git diff $(echo /dev/null) ./cosign.key' \
    "git diff \$(printf '/dev/null ./cosign.key')" \
    "git diff \`printf '/dev/null ./cosign.key'\`" \
    'git diff `echo /dev/null` ./cosign.key' \
    "git log -p --outpu\$'\\x74'=cosign.pub -1" \
    "git log --outpu\$'\\x74'=FILE" \
    'git diff $OPERANDS' \
    'git diff -- $x $y' \
    'git log -1 && git diff $(echo /dev/null) ./cosign.key' \
    "git log --grep='a|b' --outpu\$'\\x74'=cosign.pub -1" \
    "git log --grep='a|b' \`printf -- --output=cosign.pub\` -1"; do
    assert_hook_refuses_naming "the hook refuses a \$ or backtick in a git word: ${expand_command}" \
      "${expand_command}" 'before git sees the words'
  done
  # The `$` half is scoped like the brace rule, to the command that starts at
  # a `git` word: an awk or jq program in a string that never invokes git, or
  # in a command before or after it, is somebody else's argument.
  # shellcheck disable=SC2016 # literal $(date) and backticks are the point
  for expand_command in \
    "awk '{print \$1}' README.md" \
    "jq '.[\$x]' renovate.json" \
    'echo `date`' \
    'x=$(date); ls' \
    "jq '.[\$x]' f | git diff --stat" \
    "git diff HEAD | awk '{print \$1}'"; do
    assert_hook_permits "a \$ or backtick outside a git invocation is unprompted: ${expand_command}" \
      "${expand_command}"
  done

  # The word that names a command must be literal. Every scope in the hook
  # opens at a literal `git` word, and the allow rule matched the string on
  # its literal `git status` prefix: `$G` is not the word `git`, so after
  # `git status;` nothing reopened, the hook exited 0, and bash ran the
  # plain-file read. So is a brace bash would expand or a glob in that
  # position -- `{,git}`, `g?t`, `/usr/bin/g[i]t` all reach git -- and after
  # a wrapper that runs its arguments (`command`, `env`, `timeout`, ...) every
  # remaining word of the command is held to the test. `[` and `[[` are
  # commands, not globs. Shown first: `$G diff` really prints the file.
  name_dir="$(mktemp -d)"
  printf 'SECRET-LINE-1\nSECRET-LINE-2\n' >"${name_dir}/fake.key"
  name_read="$(bash --norc --noprofile -c "git status --short >/dev/null; G=git; \$G diff /dev/null ${name_dir}/fake.key" 2>/dev/null </dev/null)"
  rm -rf "${name_dir}"
  if grep -q '^+SECRET-LINE-1$' <<<"${name_read}"; then
    pass "a git invocation named through a variable really runs the plain-file read"
  else
    fail "a git invocation named through a variable really runs the plain-file read" \
      "bash no longer runs \$G as git; re-derive the literal-command-name rule"
  fi
  # shellcheck disable=SC2016 # literal $G and $(printf git) are the point
  for name_command in \
    'git status; G=git; $G diff /dev/null ./cosign.key' \
    'git status; $(printf git) diff /dev/null ./cosign.key' \
    'git status; `echo git` diff x' \
    '`echo git` diff x' \
    '$G diff /dev/null ./cosign.key' \
    'G=git $G diff /dev/null ./cosign.key' \
    'git status && "$(printf git)" diff x' \
    'git status; { $G diff x; }' \
    'git status; exec $G diff x' \
    'git status; env G=git $G diff x' \
    'git status; time $G diff x' \
    'git status | $G diff x' \
    'git status; {,git} diff /dev/null ./cosign.key' \
    'git status; g?t diff /dev/null ./cosign.key' \
    'git status; gi* diff /dev/null ./cosign.key' \
    'git status; /usr/bin/g[i]t diff /dev/null ./cosign.key' \
    'shellcheck --version; G=git; command -- $G diff /dev/null ./cosign.key' \
    'git status; env -u X $G diff /dev/null ./cosign.key' \
    'git status; timeout -s KILL 5 $G diff x'; do
    assert_hook_refuses_naming "the hook refuses a command name that is not literal: ${name_command}" \
      "${name_command}" 'Spell every command name literally'
  done
  # `env -S` is not an option but an interpreter: it splits its quoted string
  # into a command this scan never sees as words. Any -S after env, clustered
  # or long, is refused; the other env options are not.
  for name_command in \
    "git status; env -S 'git diff /dev/null ./cosign.key'" \
    "env -iS 'git diff /dev/null ./cosign.key'" \
    "git status; env --split-string='git diff x'" \
    "git status; env --split-string 'git diff x'" \
    "git status; env -u X -S 'git diff x'"; do
    assert_hook_refuses_naming "the hook refuses env -S: ${name_command}" \
      "${name_command}" 'env -S'
  done
  # shellcheck disable=SC2016 # literal $x, $HOME and backticks are the point
  for name_command in \
    'git status; git diff HEAD@{1}' \
    'FOO=bar git diff HEAD' \
    'X=$(date); git diff HEAD' \
    'echo $HOME; git diff HEAD' \
    'echo `date`; git diff HEAD' \
    'if [ -n "$x" ]; then git diff HEAD; fi' \
    '[[ -n "$x" ]] && git diff HEAD' \
    'git status; [ -f cosign.pub ]' \
    'for f in $(ls); do echo $f; done' \
    'ls > out; git status' \
    'env FOO=$x git diff HEAD' \
    'env -i PATH=$PATH git diff HEAD' \
    'env -u X git diff HEAD' \
    'timeout 60 git diff HEAD' \
    'git status; timeout -s KILL 5 git diff HEAD' \
    'xargs -I{} git diff {} < list' \
    'command -v shellcheck' \
    "find . -name '*.sh'"; do
    assert_hook_permits "a literal command name is unprompted: ${name_command}" \
      "${name_command}"
  done
  # A literal path to git is git: `/usr/bin/git diff /dev/null ./cosign.key`
  # needs no expansion and opened no scope, because every scan compared the
  # word to `git`. A literal name whose last component is git is rewritten
  # to git before any scan runs, so each refusal reaches it.
  assert_hook_refuses_naming "the hook refuses the plain-file read through /usr/bin/git after git status" \
    'git status; /usr/bin/git diff /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read through /usr/bin/git" \
    '/usr/bin/git diff /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read through ~/bin/git" \
    'git status; ~/bin/git diff /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses the plain-file read through command /usr/bin/git" \
    'git status; command /usr/bin/git diff /dev/null ./cosign.key' 'plain files'
  assert_hook_refuses_naming "the hook refuses --output through /usr/bin/git" \
    '/usr/bin/git log -1 --output=cosign.pub' '--output=FILE'
  assert_hook_refuses_naming "the hook refuses an output redirection through /usr/bin/git" \
    'git status; /usr/bin/git diff HEAD >cosign.pub' 'output redirection'
  assert_hook_refuses_naming "the hook refuses a brace through /usr/bin/git" \
    '/usr/bin/git diff {/dev/null,./cosign.key}' 'expands braces'
  assert_hook_permits "an ordinary diff through /usr/bin/git is unprompted" '/usr/bin/git diff HEAD'
  assert_hook_permits "an ordinary log through /usr/bin/git is unprompted" '/usr/bin/git log --oneline -5'
  rm -rf -- "${quoted_op_dir}" "${subst_dir}"

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

  # --- The other allow-listed command that opens a file it is pointed at ----
  #
  # `Bash(shellcheck *)` is allowed with no prompt as well, and ShellCheck
  # prints the *source line* above every diagnostic it reports. So it prints
  # back whatever it is aimed at: `shellcheck ./.env` echoes every unexported
  # `NAME=value` line of a file `Read(./.env)` refuses, values included, and a
  # PEM-shaped file gives up its `-----BEGIN/END-----` lines and its trailing
  # base64 line. It is a lossy read rather than `cat`, and for the `.env` shape
  # the deny rules name the loss is nothing that matters. The shape of the
  # problem is the same as the git case above: those rules gate the *Read*
  # tool, this is Bash, and nothing consulted them.
  #
  # No permission pattern closes it either -- patterns match by prefix, so
  # `Bash(shellcheck tests/*)` still matches
  # `shellcheck tests/run-tests.sh /home/me/.aws/credentials` -- so the hook
  # checks the operands: inside the working tree, and not one of the
  # secret-shaped names.
  #
  # Demonstrated before it is asserted, for the same reason the fixtures above
  # are. ShellCheck is a declared dependency of this repository (`just lint`
  # hard-errors without it, and the `ubuntu-26.04` runner ships 0.11.0), so its
  # absence is a failure here rather than a silent skip: the alternative is
  # this section going green on a host where the exposure was never reproduced.
  shellcheck_dir="$(mktemp -d)"
  printf '# synthetic fixture\nSYNTHETIC_SECRET=synthetic-value-1\n' \
    >"${shellcheck_dir}/fake.env"
  if ! command -v shellcheck >/dev/null 2>&1; then
    fail "shellcheck prints the contents of the file it is pointed at" \
      "shellcheck is not on PATH, so the exposure the refusals below exist for could not be reproduced"
  else
    shellcheck_output="$(shellcheck "${shellcheck_dir}/fake.env" 2>&1 || true)"
    if grep -q '^SYNTHETIC_SECRET=synthetic-value-1$' <<<"${shellcheck_output}"; then
      pass "shellcheck prints the contents of the file it is pointed at"
    else
      fail "shellcheck prints the contents of the file it is pointed at" \
        "this shellcheck no longer echoes the source line; re-derive what the refusals below are for"
    fi
  fi
  rm -rf "${shellcheck_dir}"

  # The paths the deny rules name, inside the checkout.
  assert_hook_refuses_naming "the hook refuses shellcheck pointed at ./.env" \
    'shellcheck ./.env' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses shellcheck pointed at ./cosign.key" \
    'shellcheck ./cosign.key' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses shellcheck pointed at a .pem inside the tree" \
    'shellcheck system_files/etc/pki/anything.pem' 'shellcheck prints the source line'
  # And anything outside it, which is where the interesting material usually
  # is: an agent's own credentials rather than the repository's.
  assert_hook_refuses_naming "the hook refuses shellcheck pointed outside the checkout" \
    'shellcheck /etc/shadow' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses shellcheck pointed at a home-directory key" \
    'shellcheck /home/someone/.ssh/id_ed25519' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses the climb-out-and-back-in spelling" \
    "shellcheck ../${checkout_name}/.env" 'shellcheck prints the source line'
  # A flag before the operand must not hide it, and a flag that takes a value
  # must not swallow it: `--shell bash /etc/shadow` is two words of option and
  # one operand.
  assert_hook_refuses_naming "a flag before the operand does not hide it" \
    'shellcheck -S style -o all /etc/shadow' 'shellcheck prints the source line'
  assert_hook_refuses_naming "a value-taking flag does not swallow the operand after its value" \
    'shellcheck --shell bash /etc/shadow' 'shellcheck prints the source line'
  # `-C`'s argument is optional and must be attached, so shellcheck reads
  # `-C always` as the flag plus a file named `always`. The gate reads it the
  # same way, which is why the operand after it is still checked.
  assert_hook_refuses_naming "an optional-argument flag does not swallow the operand" \
    'shellcheck -C always /etc/shadow' 'shellcheck prints the source line'
  # The word need not start the command: an operator boundary in front of
  # it changes nothing, and an environment assignment in front of it is
  # refused for itself first (see the gated-prefix scan), so the read
  # behind it never runs either way.
  assert_hook_refuses_naming "the hook refuses a shellcheck read behind another command" \
    'ls -l && shellcheck ./.env' 'shellcheck prints the source line'
  assert_hook_refuses_naming "the hook refuses a shellcheck read behind an env assignment" \
    'FOO=bar shellcheck ./.env' 'assignment before'

  # Bash rewrites some words before shellcheck sees them, and the gate reads
  # the words as typed. Two of those rewrites turned a checked operand into a
  # different file (review on aurora-zfs-simple#207, the same gate):
  #   * a leading unquoted `~` is $HOME to bash, and a literal `~` to the
  #     gate -- which `realpath -m -s` resolved to `<checkout>/~/...`, an
  #     inside path, so `shellcheck ~/.aws/credentials` passed. (The
  #     `~/.ssh/id_ed25519` case above was refused only by its basename.)
  #   * an unquoted `*`, `?` or `[` is a glob bash expands into files the
  #     gate never saw: `shellcheck .env*` is one word here, and the .env to
  #     bash.
  # Both shown first, against a throwaway HOME and a synthetic file in a
  # temporary directory of this fixture's own -- never the real $HOME.
  tilde_home="$(mktemp -d)"
  mkdir -p "${tilde_home}/.aws"
  printf 'SYNTHETIC_TILDE_SECRET=synthetic-value-2\n' >"${tilde_home}/.aws/credentials"
  tilde_output="$(HOME="${tilde_home}" bash --norc --noprofile -c 'shellcheck ~/.aws/credentials' 2>&1 </dev/null || true)"
  rm -rf "${tilde_home}"
  if grep -q '^SYNTHETIC_TILDE_SECRET=synthetic-value-2$' <<<"${tilde_output}"; then
    pass "shellcheck ~/path reads the file under \$HOME, which is not the literal ~ the gate resolves"
  else
    fail "shellcheck ~/path reads the file under \$HOME, which is not the literal ~ the gate resolves" \
      "the synthetic line did not appear; re-derive why an unquoted leading ~ is refused"
  fi
  glob_dir="$(mktemp -d)"
  printf 'SYNTHETIC_GLOB_SECRET=synthetic-value-3\n' >"${glob_dir}/.env"
  glob_output="$(cd "${glob_dir}" && bash --norc --noprofile -c 'shellcheck .env*' 2>&1 </dev/null || true)"
  rm -rf "${glob_dir}"
  if grep -q '^SYNTHETIC_GLOB_SECRET=synthetic-value-3$' <<<"${glob_output}"; then
    pass "shellcheck .env* reads the file the glob expands to, which the gate never saw as a word"
  else
    fail "shellcheck .env* reads the file the glob expands to, which the gate never saw as a word" \
      "the synthetic line did not appear; re-derive why an unquoted glob is refused"
  fi
  for rewrite_command in \
    'shellcheck ~/.aws/credentials' \
    'shellcheck ~' \
    'shellcheck ~someone/.bashrc' \
    'shellcheck .env*' \
    'shellcheck cosign.ke?' \
    'shellcheck .en[v]' \
    'shellcheck ./.*' \
    'shellcheck tests/*.sh' \
    'shellcheck -S style tests/run-tests.sh ~/.netrc' \
    'git log -1 && shellcheck ~/.aws/credentials'; do
    assert_hook_refuses_naming "the hook refuses a tilde or glob in a shellcheck operand: ${rewrite_command}" \
      "${rewrite_command}" 'bash rewrites this word'
  done
  # Brace expansion, command substitution and a process substitution are the
  # same rewrite they were for git: one word to a gate reading the typed
  # string, other files to shellcheck. The backtick closes the scope it would
  # be refused in, so it is held on the whole-string latch the git rule uses.
  # shellcheck disable=SC2016 # literal $(...), $F and backticks are the point
  for rewrite_command in \
    'shellcheck {tests/run-tests.sh,/etc/shadow}' \
    'shellcheck $(echo /etc/shadow)' \
    'shellcheck `echo /etc/shadow`' \
    'shellcheck $F' \
    'shellcheck <(cat /etc/shadow)'; do
    assert_hook_refuses_naming "the hook refuses an expansion in a shellcheck operand: ${rewrite_command}" \
      "${rewrite_command}" 'bash rewrites this word'
  done
  # ShellCheck reads file operands out of SHELLCHECK_OPTS as well, so the
  # assignment is refused wherever it stands, including in a command of its
  # own: the Bash tool's shell persists between calls.
  for rewrite_command in \
    'SHELLCHECK_OPTS=/etc/shadow shellcheck tests/run-tests.sh' \
    'export SHELLCHECK_OPTS=/etc/shadow; shellcheck tests/run-tests.sh' \
    'export SHELLCHECK_OPTS=/etc/shadow' \
    'env SHELLCHECK_OPTS=-x shellcheck tests/run-tests.sh'; do
    assert_hook_refuses_naming "the hook refuses a SHELLCHECK_OPTS assignment: ${rewrite_command}" \
      "${rewrite_command}" 'SHELLCHECK_OPTS='
  done

  # The operand scan reads the words after `shellcheck`, and an input
  # redirection puts the path somewhere it never looks. ShellCheck reads
  # standard input when its operand is `-`, so `shellcheck - < .env` prints the
  # file back exactly as `shellcheck ./.env` did, with the scan seeing only the
  # `-` (issue #323). Shown first, against a synthetic file in a temporary
  # directory of this fixture's own, for the reason the operand exposure above
  # is shown: the refusals below are worth nothing if the read they name has
  # stopped happening.
  stdin_dir="$(mktemp -d)"
  printf '# synthetic fixture\nSYNTHETIC_STDIN_SECRET=synthetic-value-4\n' \
    >"${stdin_dir}/fake.env"
  if ! command -v shellcheck >/dev/null 2>&1; then
    fail "shellcheck prints the contents of the file it is handed on standard input" \
      "shellcheck is not on PATH, so the exposure the refusals below exist for could not be reproduced"
  else
    stdin_output="$(shellcheck - <"${stdin_dir}/fake.env" 2>&1 || true)"
    if grep -q '^SYNTHETIC_STDIN_SECRET=synthetic-value-4$' <<<"${stdin_output}"; then
      pass "shellcheck prints the contents of the file it is handed on standard input"
    else
      fail "shellcheck prints the contents of the file it is handed on standard input" \
        "the synthetic line did not appear; re-derive why the target of a < is checked"
    fi
  fi
  rm -rf "${stdin_dir}"
  # The target is held to the operand test itself: inside the checkout, none of
  # the deny shapes, and spelled out. The descriptor form, the attached
  # operator and the form written before the command name are the same
  # redirection to bash, so they are the same refusal here.
  for stdin_command in \
    'shellcheck - < .env' \
    'shellcheck -s bash - <./cosign.key' \
    'shellcheck - 0< system_files/etc/pki/anything.pem' \
    'shellcheck - < /etc/shadow' \
    'shellcheck - < /home/someone/.ssh/id_ed25519' \
    "shellcheck - < ../${checkout_name}/.env" \
    'shellcheck - < ~/.aws/credentials' \
    'shellcheck - < {tests/run-tests.sh,.env}' \
    'shellcheck - < .env*' \
    '< .env shellcheck -' \
    'git log -1 && shellcheck - < .env' \
    'command -p shellcheck - < .env'; do
    assert_hook_refuses_naming "the hook refuses a shellcheck read through an input redirection: ${stdin_command}" \
      "${stdin_command}" 'shellcheck reads standard input'
  done
  # And nothing else about a `<` changes. A script inside the checkout is the
  # ordinary way to lint from stdin, `/dev/null` prints nothing back, `<<<` is
  # content and `<<` a delimiter rather than a path, and the other gated
  # commands do not read a file from stdin at all.
  for stdin_command in \
    'shellcheck - < tests/run-tests.sh' \
    'shellcheck -s bash - <scripts/quickstart.sh' \
    'shellcheck - < /dev/null' \
    'shellcheck tests/run-tests.sh </dev/null' \
    "shellcheck - <<< 'echo hi'" \
    'df -T < .env' \
    'cat < .env'; do
    assert_hook_permits "an ordinary input redirection is still unprompted: ${stdin_command}" \
      "${stdin_command}"
  done
  # A quoted or escaped glob character is the literal word bash would pass,
  # and a `~` that does not lead the word is a character in a filename.
  for rewrite_command in \
    "shellcheck 'tests/*.sh'" \
    'shellcheck "tests/*.sh"' \
    'shellcheck tests/\*.sh' \
    'shellcheck tests/run-tests.sh~' \
    "shellcheck 'tests/run-tests.sh'"; do
    assert_hook_permits "a quoted glob or a non-leading ~ in a shellcheck operand is unprompted: ${rewrite_command}" \
      "${rewrite_command}"
  done
  # An rc file is not on the skip list, so its path is checked like any other.
  assert_hook_refuses_naming "the hook refuses an rc file outside the tree" \
    'shellcheck --rcfile /home/someone/.shellcheckrc tests/run-tests.sh' \
    'shellcheck prints the source line'

  # None of that may cost the repository its own lint runs.
  assert_hook_permits "linting a tracked script is still unprompted" \
    'shellcheck tests/run-tests.sh'
  assert_hook_permits "linting several tracked scripts at once is still unprompted" \
    'shellcheck ./scripts/quickstart.sh scripts/pr-review-state.sh'
  assert_hook_permits "the attached --shell= spelling is still unprompted" \
    'shellcheck --shell=bash system_files/etc/profile.d/homebrew.sh'
  assert_hook_permits "the space --shell spelling is still unprompted" \
    'shellcheck --shell bash system_files/etc/profile.d/homebrew.sh'
  assert_hook_permits "severity and optional-check flags are still unprompted" \
    'shellcheck -S style -o all tests/check-invariants.sh'
  assert_hook_permits "source-path and external sources are still unprompted" \
    'shellcheck -x -P SCRIPTDIR scripts/quickstart.sh'
  assert_hook_permits "reading a script from stdin is still unprompted" \
    'shellcheck -'
  assert_hook_permits "a script that does not exist yet is still unprompted" \
    'shellcheck tests/test-not-written-yet.sh'
  assert_hook_permits "the word shellcheck outside a shellcheck call is not one" \
    'grep -n shellcheck Justfile'

  # The join that matters most: this repository's own lint recipe must not be
  # refused by this repository's own gate. Read the invocations out of the
  # Justfile rather than restating them, because a restated command list is a
  # second copy with the same drift problem the rest of this file avoids.
  justfile_lint_commands=0
  while IFS= read -r justfile_lint_command; do
    justfile_lint_commands=$((justfile_lint_commands + 1))
    assert_hook_permits \
      "Justfile lint invocation ${justfile_lint_commands} is still unprompted" \
      "${justfile_lint_command}"
  done < <(sed -n 's/^[[:space:]]*\(shellcheck [^#]*\)$/\1/p' "${JUSTFILE}")
  if ((justfile_lint_commands >= 2)); then
    pass "the Justfile lint recipe's shellcheck invocations were found and checked"
  else
    fail "the Justfile lint recipe's shellcheck invocations were found and checked" \
      "found ${justfile_lint_commands}; the recipe has two, so the extraction above stopped matching and those assertions checked nothing"
  fi

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
group "VM runbook (docs/vm-workflow.md is a hand copy of scripts/quickstart.sh's virt-install and of the guest-agent contract)"

# docs/vm-workflow.md is the document a reader follows once a qcow2 exists. It
# is prose around four things the tree owns: the `virt-install` invocation
# scripts/quickstart.sh runs, the teardown pair that script prints, the disk
# filename the Justfile's default size produces, and the guest-agent contract
# the Containerfile deliberately leaves to a udev rule.
#
# Every one of those is a hand copy. `just quickstart` and this document create
# the same VM by two different routes, so a flag changed in the script -- or a
# feature index swapped in the firmware string -- leaves the document telling a
# reader to build a different machine, and nothing here noticed. The document
# also hands out a base64 blob to paste: if that stops decoding to what its own
# sentence claims, the reader sets a password they cannot predict.

VM_DOC="docs/vm-workflow.md"

# Fenced blocks by info string: a `# comment` inside a ```bash block is shell,
# and a value inside a ```json block would not be a command to run.
vm_fenced() {
  local want="$1"
  awk -v want="${want}" '
    /^```/ { if (in_block) { in_block = 0 } else { in_block = (substr($0, 4) == want) } ; next }
    in_block' "${VM_DOC}"
}

# One `--flag value` per line from the first virt-install invocation on stdin.
# Comments are dropped, backslash continuations are joined, a trailing `|| ...`
# is cut off (the script's invocation captures its status that way), and quotes
# are stripped so the script's `--disk "path=..."` compares against the
# document's unquoted spelling.
virt_install_options() {
  sed -e 's/^[[:space:]]*#.*$//' -e ':a' -e '/\\$/N' -e 's/\\\n[[:space:]]*/ /' -e 'ta' |
    grep -oE 'virt-install[[:space:]]+--.*' |
    head -1 |
    sed -e 's/^virt-install[[:space:]]*//' -e 's/[[:space:]]*||.*$//' -e 's/[[:space:]]*--/\n--/g' |
    sed -e 's/[[:space:]]*$//' -e 's/"//g' |
    grep '^--'
}

if [[ ! -f "${VM_DOC}" ]]; then
  fail "the VM runbook exists" "${VM_DOC} is missing; README.md's documentation table links to it"
else

vm_headings="$(awk '/^```/ { in_block = !in_block; next } !in_block && /^#{1,6} /' "${VM_DOC}")"

# README.md's table is the only index of what this document covers, and it
# advertises both halves. Assert they are still sections here, or the
# extractions below start passing by finding nothing to check.
vm_missing_sections=""
while IFS= read -r want; do
  grep -qi -- "${want}" <<<"${vm_headings}" || vm_missing_sections+="${want}; "
done <<'SECTIONS'
Create VM
Running commands in the VM from the host
SECTIONS
if [[ -z "${vm_missing_sections}" ]]; then
  pass "docs/vm-workflow.md still has the sections README.md's table advertises"
else
  fail "docs/vm-workflow.md still has the sections README.md's table advertises" \
    "missing: ${vm_missing_sections}"
fi

assert_present "README.md's documentation table still links to the VM runbook" \
  "README.md" '\]\(docs/vm-workflow\.md\)'

assert_doc_links_resolve "${VM_DOC}" \
  "no relative links found; the hand-off to installation.md and first-boot.md is gone"

# --- The virt-install invocation --------------------------------------------

vm_doc_options="$(vm_fenced bash | virt_install_options)"
vm_quickstart_options="$(virt_install_options <"${QUICKSTART}")"

if [[ -z "${vm_doc_options}" ]]; then
  fail "docs/vm-workflow.md still shows the reader a virt-install command" \
    "no virt-install invocation in any \`\`\`bash block"
elif [[ -z "${vm_quickstart_options}" ]]; then
  fail "${QUICKSTART} still creates the VM with virt-install" \
    "no virt-install invocation found; the document is a copy of nothing"
else
  # Same options, in both directions. The document omitting one the script
  # passes is the interesting failure: `--import` or the firmware string
  # dropped from the document produces a VM that installs from nothing, or one
  # that refuses to boot an unsigned image.
  vm_doc_option_names="$(cut -d' ' -f1 <<<"${vm_doc_options}" | sort -u | tr '\n' ' ')"
  vm_quickstart_option_names="$(cut -d' ' -f1 <<<"${vm_quickstart_options}" | sort -u | tr '\n' ' ')"
  assert_equal "docs/vm-workflow.md passes virt-install exactly the options ${QUICKSTART} passes" \
    "${vm_doc_option_names}" "${vm_quickstart_option_names}"

  # And the same values, for every option whose value is not the manual
  # track's own. --name, --memory and --vcpus are prompted by the script and
  # fixed in the document; --disk is the one place the two genuinely differ,
  # because the script also attaches a cloud-init seed ISO and the document
  # bootstraps through the guest agent instead. Everything else -- the
  # connection, the CPU model, the network, the graphics stack, the firmware
  # string, the osinfo id -- must read identically or the two routes produce
  # different machines.
  vm_shared_doc="$(grep -Ev '^--(name|memory|vcpus|disk)([[:space:]]|$)' <<<"${vm_doc_options}" | sort | tr '\n' '|')"
  vm_shared_quickstart="$(grep -Ev '^--(name|memory|vcpus|disk)([[:space:]]|$)' <<<"${vm_quickstart_options}" | sort | tr '\n' '|')"
  assert_equal "every virt-install option docs/vm-workflow.md shares with ${QUICKSTART} carries the same value" \
    "${vm_shared_doc}" "${vm_shared_quickstart}"

  vm_doc_name="$(grep '^--name ' <<<"${vm_doc_options}" | sed 's/^--name[[:space:]]*//')"
  vm_doc_memory="$(grep '^--memory ' <<<"${vm_doc_options}" | sed 's/^--memory[[:space:]]*//')"
  vm_doc_vcpus="$(grep '^--vcpus ' <<<"${vm_doc_options}" | sed 's/^--vcpus[[:space:]]*//')"
  vm_doc_disk="$(grep '^--disk ' <<<"${vm_doc_options}" | sed 's/^--disk[[:space:]]*//')"

  # The script prompts for memory with a default. The document states a figure
  # instead, and it is the same one -- a reader following either route gets the
  # same guest.
  vm_quickstart_memory="$(sed -n 's/^[[:space:]]*ask VM_MEMORY "[^"]*" "\([^"]*\)".*/\1/p' "${QUICKSTART}" | head -1)"
  assert_equal "the memory docs/vm-workflow.md gives the guest is ${QUICKSTART}'s default" \
    "${vm_doc_memory}" "${vm_quickstart_memory}"

  # The section's opening sentence restates the flags in units a reader reads
  # rather than the ones virt-install takes. Both halves are hand-written.
  if [[ "${vm_doc_memory}" =~ ^[0-9]+$ ]] && ((vm_doc_memory % 1024 == 0)); then
    assert_equal "the RAM docs/vm-workflow.md's opening sentence promises is the --memory it passes" \
      "$(grep -oE '[0-9]+GB RAM' "${VM_DOC}" | head -1)" "$((vm_doc_memory / 1024))GB RAM"
  else
    fail "the RAM docs/vm-workflow.md's opening sentence promises is the --memory it passes" \
      "--memory '${vm_doc_memory}' is not a whole number of GiB"
  fi
  assert_equal "the vCPU count docs/vm-workflow.md's opening sentence promises is the --vcpus it passes" \
    "$(grep -oE '[0-9]+ vCPU' "${VM_DOC}" | head -1)" "${vm_doc_vcpus} vCPU"

  # --- The firmware string ---------------------------------------------------
  #
  # "UEFI, Secure Boot disabled" is one comma-separated `--boot` value, and the
  # feature *indices* carry the meaning: feature0 and feature1 are positional
  # slots, so swapping the two `name=` halves while leaving both `enabled=no`
  # in place still reads as disabled to a skimming eye and turns Secure Boot
  # back on. Resolve each feature by name and read that index's own flag.
  vm_boot="$(grep '^--boot ' <<<"${vm_doc_options}" | sed 's/^--boot[[:space:]]*//')"
  vm_boot_fields="$(tr ',' '\n' <<<"${vm_boot}")"
  assert_equal "docs/vm-workflow.md boots the guest with the firmware its opening sentence names" \
    "$(head -1 <<<"${vm_boot_fields}")" "uefi"
  assert_present "docs/vm-workflow.md still tells the reader Secure Boot is off" \
    "${VM_DOC}" 'Secure Boot disabled'
  for vm_feature in secure-boot enrolled-keys; do
    vm_feature_index="$(sed -n "s/^firmware\.feature\([0-9]\+\)\.name=${vm_feature}\$/\1/p" <<<"${vm_boot_fields}")"
    if [[ -z "${vm_feature_index}" ]]; then
      fail "docs/vm-workflow.md's firmware string still names the ${vm_feature} feature" \
        "--boot ${vm_boot}"
      continue
    fi
    assert_equal "docs/vm-workflow.md disables the firmware feature it labels ${vm_feature}" \
      "$(sed -n "s/^firmware\.feature${vm_feature_index}\.enabled=//p" <<<"${vm_boot_fields}")" "no"
  done

  # --- The disk ---------------------------------------------------------------
  #
  # The filename is a literal the reader types, and it encodes the Justfile's
  # default disk size. `BUILD_DISK_SIZE` changed without this document changing
  # leaves the reader importing a qcow2 that docs/installation.md never wrote.
  vm_doc_qcow="${vm_doc_disk%%,*}"
  vm_doc_qcow="${vm_doc_qcow#path=}"
  vm_disk_size="$(sed -n 's/^disk_size := env("BUILD_DISK_SIZE", "\([^"]*\)").*/\1/p' "${JUSTFILE}")"
  if [[ -z "${vm_disk_size}" ]]; then
    fail "the Justfile still has a default disk size for docs/vm-workflow.md's filename to encode" \
      "no 'disk_size := env(\"BUILD_DISK_SIZE\", ...)' in ${JUSTFILE}"
  else
    assert_equal "the qcow2 docs/vm-workflow.md imports is named for the Justfile's default disk size" \
      "${vm_doc_qcow##*/}" "arch-bootc-$(tr '[:upper:]' '[:lower:]' <<<"${vm_disk_size}").qcow2"
  fi

  # The same file, under the same directory, as the convert step the reader ran
  # one document earlier.
  vm_install_qcow="$(grep -oE 'output/[A-Za-z0-9._-]+\.qcow2' "${INSTALL_DOC}" | sort -u)"
  if [[ -z "${vm_install_qcow}" || "${vm_install_qcow}" == *$'\n'* ]]; then
    fail "docs/installation.md writes exactly one qcow2 for docs/vm-workflow.md to import" \
      "found: ${vm_install_qcow//$'\n'/ | }"
  elif [[ "${vm_doc_qcow}" == */"${vm_install_qcow}" ]]; then
    pass "docs/vm-workflow.md imports the qcow2 docs/installation.md's convert step writes"
  else
    fail "docs/vm-workflow.md imports the qcow2 docs/installation.md's convert step writes" \
      "runbook: ${vm_doc_qcow}; installation.md: ${vm_install_qcow}"
  fi

  # The bus and format matter as much as the path: a qcow2 attached without
  # `bus=virtio` boots, slowly, on an emulated controller the guest image has
  # no reason to be tuned for.
  vm_quickstart_qcow_disk="$(grep -E '^--disk .*format=qcow2' <<<"${vm_quickstart_options}" | head -1)"
  assert_equal "docs/vm-workflow.md attaches the qcow2 the way ${QUICKSTART} attaches it" \
    "${vm_doc_disk#*,}" "${vm_quickstart_qcow_disk#*,}"

  # --- Teardown ---------------------------------------------------------------
  #
  # The document's recreate step and the script's closing "Remove it again"
  # block are the same two commands. `--nvram` is the load-bearing half: undefine
  # without it leaves the per-VM UEFI variable store behind, and the next
  # virt-install inherits the old firmware state it just set up from scratch.
  vm_doc_teardown="$(vm_fenced bash |
    grep -E '^virsh .* (destroy|undefine) ' |
    sed -e 's/[[:space:]]*||[[:space:]]*true$//' -e "s/[[:space:]]${vm_doc_name}\\b//" |
    sort | tr '\n' '|')"
  vm_quickstart_teardown="$(grep -oE 'virsh -c qemu:///session (destroy|undefine) [$][{]VM_NAME[}][^"]*' "${QUICKSTART}" |
    sed -e 's/[[:space:]]*$//' -e 's/[[:space:]][$][{]VM_NAME[}]//' |
    sort | tr '\n' '|')"
  if [[ -z "${vm_doc_teardown}" ]]; then
    fail "docs/vm-workflow.md still tells the reader how to delete and recreate the VM" \
      "no virsh destroy/undefine pair in any \`\`\`bash block"
  else
    assert_equal "docs/vm-workflow.md tears the VM down with the commands ${QUICKSTART} prints" \
      "${vm_doc_teardown}" "${vm_quickstart_teardown}"
  fi

  # --- The guest agent --------------------------------------------------------
  #
  # Same command, same connection, same payload as the script's "Watch it come
  # up" line.
  vm_doc_ping="$(vm_fenced bash | grep -F 'guest-ping' | head -1 |
    sed -e "s/[[:space:]]${vm_doc_name}[[:space:]]/ VMNAME /")"
  vm_quickstart_ping="$(grep -F 'guest-ping' "${QUICKSTART}" | head -1 |
    sed -e 's/.*virsh/virsh/' -e 's/"$//' -e 's/\\//g' -e 's/[[:space:]][$][{]VM_NAME[}][[:space:]]/ VMNAME /')"
  assert_equal "docs/vm-workflow.md pings the agent with the command ${QUICKSTART} prints" \
    "${vm_doc_ping}" "${vm_quickstart_ping}"

  vm_doc_connections="$(vm_fenced bash | grep -E '^[[:space:]]*virsh' | grep -vc 'qemu:///session')"
  assert_equal "every virsh command docs/vm-workflow.md gives the reader targets the session connection it says it uses" \
    "${vm_doc_connections}" "0"
fi

# --- The payloads the reader pastes ------------------------------------------
#
# These are JSON documents typed by hand into a shell string. `jq` is what
# actually parses them on the way to the agent, so parse them here: a missing
# brace or a trailing comma is a command that fails for every reader, and a
# `capture-output` that went missing is a command that runs and returns
# nothing to read.
#
# `<PID>` is the document's own placeholder for a number the previous command
# printed. Substituting it is the only edit made before parsing.
vm_payloads="$(vm_fenced bash | grep -o "'{.*}'" | sed -e "s/^'//" -e "s/'\$//" -e 's/<PID>/0/')"
vm_payload_count="$(grep -c . <<<"${vm_payloads}")"
[[ -n "${vm_payloads}" ]] || vm_payload_count=0
if ((vm_payload_count == 0)); then
  fail "docs/vm-workflow.md still hands the reader guest-agent payloads" "no '{...}' payload in any bash block"
else
  vm_bad_payloads=""
  vm_exec_payloads=0
  while IFS= read -r payload; do
    [[ -n "${payload}" ]] || continue
    if ! jq -e . >/dev/null 2>&1 <<<"${payload}"; then
      vm_bad_payloads+="${payload} (not JSON) "
      continue
    fi
    [[ "$(jq -r '.execute // empty' <<<"${payload}")" == "guest-exec" ]] || continue
    vm_exec_payloads=$((vm_exec_payloads + 1))
    # guest-exec takes no shell and no PATH: `path` is passed to the guest's
    # exec directly, so a bare command name is a command the agent cannot find.
    [[ "$(jq -r '.arguments.path // empty' <<<"${payload}")" == /* ]] ||
      vm_bad_payloads+="${payload} (path is not absolute) "
    # The document tells the reader to "read its output" from the result.
    [[ "$(jq -r '.arguments["capture-output"] // empty' <<<"${payload}")" == "true" ]] ||
      vm_bad_payloads+="${payload} (no capture-output) "
  done <<<"${vm_payloads}"
  if [[ -n "${vm_bad_payloads}" ]]; then
    fail "every guest-agent payload docs/vm-workflow.md hands the reader parses and captures its output" \
      "${vm_bad_payloads}"
  elif ((vm_exec_payloads == 0)); then
    fail "every guest-agent payload docs/vm-workflow.md hands the reader parses and captures its output" \
      "${vm_payload_count} payload(s) found, none of them a guest-exec"
  else
    pass "every guest-agent payload docs/vm-workflow.md hands the reader parses, and each of its ${vm_exec_payloads} guest-exec calls captures output"
  fi

  # The document says the result is read back by pid. Without that second
  # command the reader has a pid and no way to learn whether the command worked,
  # which is exactly what the section's closing sentence tells them to check.
  assert_equal "docs/vm-workflow.md reads each guest-exec result back with guest-exec-status" \
    "$(jq -rs '[.[] | select(.execute == "guest-exec-status") | .arguments.pid] | length' <<<"${vm_payloads}")" "1"
  assert_present "docs/vm-workflow.md still tells the reader to confirm the exit code" \
    "${VM_DOC}" 'exitcode.:0'

  # --- The account the reader creates ---------------------------------------
  #
  # This is the same account docs/first-boot.md creates from a console and
  # scripts/quickstart.sh seeds through cloud-init. uid 1000 and `wheel` are
  # what make it the machine's first admin user; either one changed here and
  # the reader ends up with an account that cannot sudo, or one that collides
  # with the seeded user on a VM built the other way.
  vm_useradd_args="$(jq -rs '[.[] | select(.arguments.path? // "" | endswith("/useradd")) | .arguments.arg | join(" ")] | .[0] // empty' <<<"${vm_payloads}")"
  if [[ -z "${vm_useradd_args}" ]]; then
    fail "docs/vm-workflow.md still bootstraps the first admin user through the agent" \
      "no guest-exec payload runs useradd"
  else
    vm_doc_uid="$(sed -n 's/.*-u \([0-9]\+\).*/\1/p' <<<"${vm_useradd_args}")"
    vm_doc_groups="$(sed -n 's/.*-G \([A-Za-z0-9,_-]\+\).*/\1/p' <<<"${vm_useradd_args}")"
    vm_seed_uid="$(grep -oE 'uid: [0-9]+' "${QUICKSTART}" | head -1 | sed 's/uid: //')"
    assert_equal "the uid docs/vm-workflow.md gives the first admin user is the one ${QUICKSTART} seeds" \
      "${vm_doc_uid}" "${vm_seed_uid}"
    assert_equal "the groups docs/vm-workflow.md gives the first admin user are the ones ${QUICKSTART} seeds" \
      "[${vm_doc_groups}]" "$(grep -oE 'groups: \[[A-Za-z0-9, _-]+\]' "${QUICKSTART}" | head -1 | sed 's/groups: //')"
  fi

  # --- The base64 blob ------------------------------------------------------
  #
  # A reader cannot see what this decodes to; the sentence above it is the only
  # description they get. chpasswd reads `user:password` lines from stdin, so a
  # blob that decoded to something else -- or that lost its trailing newline --
  # sets a password nobody can predict, on an account that already exists.
  vm_chpasswd_b64="$(jq -rs '[.[] | select(.arguments.path? // "" | endswith("/chpasswd")) | .arguments["input-data"]] | .[0] // empty' <<<"${vm_payloads}")"
  if [[ -z "${vm_chpasswd_b64}" ]]; then
    fail "docs/vm-workflow.md still sets the new account's password through the agent" \
      "no guest-exec payload runs chpasswd with input-data"
  elif ! vm_chpasswd_plain="$(base64 -d <<<"${vm_chpasswd_b64}" 2>/dev/null)"; then
    fail "docs/vm-workflow.md's chpasswd input-data is valid base64" "${vm_chpasswd_b64}"
  else
    assert_equal "docs/vm-workflow.md's chpasswd input-data decodes to the line its own sentence describes" \
      "${vm_chpasswd_plain}" "$(sed -n 's/.*input-data is base64 of "\(.*\)\\n".*/\1/p' "${VM_DOC}" | head -1)"
    # Command substitution eats a trailing newline, so count the bytes rather
    # than compare the strings: that newline is what makes chpasswd read the
    # line at all.
    assert_equal "docs/vm-workflow.md's chpasswd input-data ends in the newline chpasswd needs to read the line" \
      "$(base64 -d <<<"${vm_chpasswd_b64}" | wc -c)" "$((${#vm_chpasswd_plain} + 1))"
    # And it is the *same* placeholder the useradd above created, not a second
    # one a reader would have to notice and reconcile.
    if [[ -n "${vm_useradd_args}" ]]; then
      assert_equal "the account docs/vm-workflow.md sets a password for is the one it just created" \
        "${vm_chpasswd_plain%%:*}" "${vm_useradd_args##* }"
    fi
  fi
fi

# --- What makes the agent reachable at all -----------------------------------
#
# "The image installs qemu-guest-agent" is a claim about every flavor, so the
# package must be in the base list rather than a desktop one.
vm_agent_package_files="$(for f in packages-*.txt; do grep -qx 'qemu-guest-agent' "${f}" && printf '%s ' "${f}"; done)"
assert_equal "qemu-guest-agent, which docs/vm-workflow.md says the image installs, is in the base package list only" \
  "${vm_agent_package_files% }" "packages-base.txt"

# The document tells the reader nothing needs enabling: the package's udev rule
# starts the service when the channel appears. The Containerfile's comment says
# the same thing and explains why force-enabling it would restart-loop on bare
# metal -- a symlink added into multi-user.target.wants would make both wrong.
assert_absent "qemu-guest-agent is left to its udev rule, as docs/vm-workflow.md's 'started automatically' promises" \
  "${CONTAINERFILE}" 'multi-user\.target\.wants/qemu-guest-agent' \
  "docs/vm-workflow.md: 'started automatically by its udev rule'; the unit has an empty [Install] section and Restart=always"

# The channel name is the udev rule's trigger, and the document names it. Both
# spellings are hand-written.
assert_equal "the agent channel docs/vm-workflow.md names is the one the Containerfile names" \
  "$(grep -oE 'org\.qemu\.guest_agent\.[0-9]+' "${VM_DOC}" | sort -u | tr '\n' ' ')" \
  "$(grep -oE 'org\.qemu\.guest_agent\.[0-9]+' "${CONTAINERFILE}" | sort -u | tr '\n' ' ')"

# --- The closing sentence ----------------------------------------------------
#
# "`sudo` already works via `wheel`" is true only because the image ships a
# sudoers drop-in granting it. Nothing else in this tree would give a wheel
# member anything: Arch ships that line commented out.
assert_present "the image grants wheel sudo, which is docs/vm-workflow.md's 'sudo already works via wheel'" \
  "${CONTAINERFILE}" '%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL' \
  "docs/vm-workflow.md ends by telling the reader sudo works; Arch's own sudoers ships that grant commented out"

assert_present "that sudoers drop-in is validated before the layer is accepted" \
  "${CONTAINERFILE}" 'visudo -cf /etc/sudoers\.d/' \
  "an unparsable drop-in locks every wheel member out of sudo, and the build would not notice"

fi

# ---------------------------------------------------------------------------
group "First-boot runbook (docs/first-boot.md is a hand copy of the root-login controls, scripts/quickstart.sh's cloud-init seed and the brew payload review)"

# docs/first-boot.md is the first document anybody follows on a machine that has
# just booted. It hands out root's password, the `useradd` line that creates the
# admin account, a cloud-init seed to write onto an offline disk, and the account
# of what the image does and does not install around Homebrew.
#
# Nothing opened it. README.md's table points at it, three other documents hand
# off to it, and tests/test-homebrew-shell-integration.sh cites it in a comment --
# but no test read the file, so every value in it is a hand copy of something in
# this tree that nothing compared. The failure that produces is specific: a
# reader is told a password that no longer works, or is told the image closes a
# door it has stopped closing, and follows the document anyway.
#
# The machine side of all of this is asserted above. What is new here is the
# join: each assertion below reads a value out of the document and compares it to
# the Containerfile step, the quickstart script, the guarded fragment or the
# manifest entry that the sentence is a copy of.
#
# One claim in it is deliberately not asserted, for the reason given at the top
# of this file: "both display managers refuse root" is behavior of the packaged
# plasmalogin and lightdm units, and there is nothing in this tree to read.

FIRSTBOOT_DOC="docs/first-boot.md"

# Spelled-out counts, for the sentences that say how many files something covers.
# The document counts in words and the tree counts in lines, which is exactly the
# pair that drifts silently: adding a manifest entry is a one-line diff and
# rewording a paragraph around it is not.
NUMBER_WORDS=(zero one two three four five six seven eight nine ten eleven
  twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty)

number_word() {
  local n="$1"
  if ((n >= 0 && n < ${#NUMBER_WORDS[@]})); then
    printf '%s' "${NUMBER_WORDS[n]}"
  fi
}

if [[ ! -f "${FIRSTBOOT_DOC}" ]]; then
  fail "the first-boot runbook exists" \
    "${FIRSTBOOT_DOC} is missing; README.md's documentation table links to it"
else

assert_present "README.md's documentation table still links to the first-boot runbook" \
  "README.md" '\]\(docs/first-boot\.md\)'

assert_doc_links_resolve "${FIRSTBOOT_DOC}" \
  "no relative links found; the hand-off to vm-workflow.md, installation.md and brew-payload.manifest is gone"

# --- The password the reader is handed ---------------------------------------
#
# The document prints it twice -- once in the warning box and once in the
# bare-metal section -- and the Containerfile sets it in one place. A password
# changed there and not here sends a reader to a console that rejects them, with
# no other way in on hardware that has no guest agent.
containerfile_root_password="$(sed -n "s/.*echo 'root:\([^']*\)'[[:space:]]*|[[:space:]]*chpasswd.*/\1/p" \
  "${CONTAINERFILE}" | head -1)"
# shellcheck disable=SC2016  # backticks and $ are literal needles in the document
firstboot_passwords="$(grep -oE '(default password \(|`root` / )`[^`]+`' "${FIRSTBOOT_DOC}" |
  grep -oE '`[^`]+`$' | tr -d '`' | sort -u | tr '\n' ' ')"
firstboot_passwords="${firstboot_passwords% }"
if [[ -z "${containerfile_root_password}" ]]; then
  fail "the root password docs/first-boot.md hands out is the one the Containerfile sets" \
    "no 'root:<password>' | chpasswd step found in ${CONTAINERFILE}"
else
  assert_equal "the root password docs/first-boot.md hands out is the one the Containerfile sets" \
    "${firstboot_passwords}" "${containerfile_root_password}"
fi

# "It is also expired, so logging in forces an immediate password change" is the
# sentence that makes printing the password in a public document defensible.
if grep -qi 'expired' "${FIRSTBOOT_DOC}"; then
  assert_present "the password docs/first-boot.md calls expired is expired by the Containerfile" \
    "${CONTAINERFILE}" 'passwd --expire root' \
    "the document still promises a forced change on first login; nothing expires the password"
else
  fail "docs/first-boot.md still says the root password is expired" \
    "the document prints a well-known password and no longer says it only survives one login"
fi

# The other half of "only works from a physical console". SSH is the half this
# tree owns.
assert_present "SSH refuses the root password docs/first-boot.md prints, as its warning box says" \
  "${CONTAINERFILE}" 'PermitRootLogin[[:space:]]+prohibit-password' \
  "docs/first-boot.md tells the reader SSH refuses root regardless of password"

# --- The admin account the reader creates ------------------------------------
#
# `sudo` working for the new user is a promise about a file this repository
# writes, and the document names that file.
firstboot_sudoers="$(grep -oE '/etc/sudoers\.d/[A-Za-z0-9_.-]+' "${FIRSTBOOT_DOC}" |
  sort -u | tr '\n' ' ')"
containerfile_sudoers="$(grep -v '^[[:space:]]*#' "${CONTAINERFILE}" |
  grep -oE '/etc/sudoers\.d/[A-Za-z0-9_.-]+' | sort -u | tr '\n' ' ')"
assert_equal "the sudoers drop-in docs/first-boot.md names is the one the Containerfile writes" \
  "${firstboot_sudoers% }" "${containerfile_sudoers% }"

# "password-prompted `sudo`" is the document's wording, and it is what makes the
# wheel grant an opt-in rather than a way around the console-only root model.
assert_absent "the wheel grant still prompts for a password, as docs/first-boot.md says" \
  "${CONTAINERFILE}" 'NOPASSWD' \
  "docs/first-boot.md promises a password prompt; a NOPASSWD rule would hand every wheel member passwordless root"

# The account the document creates is only useful if it lands in the group the
# drop-in grants, at the UID the Homebrew prefix is chowned to.
assert_present "the account docs/first-boot.md creates joins the group the sudoers drop-in grants" \
  "${FIRSTBOOT_DOC}" 'useradd .*-G wheel' \
  "the useradd line no longer puts the new user in wheel, so sudo does not work as the next sentence claims"

assert_present "that account takes the UID the Homebrew prefix is handed to" \
  "${FIRSTBOOT_DOC}" 'useradd .*-u 1000' \
  "brew-setup.service chowns the prefix to 1000:1000; a user created at another UID gets no brew"

# --- The cloud-init seed ------------------------------------------------------
#
# The document tells a reader with no console to write a seed onto an offline
# disk. That only works because the Containerfile pins cloud-init to the one
# datasource that reads a seed from the filesystem -- and the seed directory the
# document names is that datasource's, spelled in lowercase.
containerfile_datasources="$(grep -oE 'datasource_list:[[:space:]]*\[[^]]*\]' "${CONTAINERFILE}" |
  sed -E 's/.*\[//; s/\]//' | tr -d ' ' | tr ',' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ')"
firstboot_seed_dirs="$(grep -oE 'var/lib/cloud/seed/[a-z0-9]+' "${FIRSTBOOT_DOC}" |
  sed 's|.*/||' | sort -u | tr '\n' ' ')"
if [[ -z "${containerfile_datasources}" ]]; then
  fail "docs/first-boot.md seeds the datasource the Containerfile pins cloud-init to" \
    "no datasource_list: [...] in ${CONTAINERFILE}; the seed the document writes may never be read"
else
  assert_equal "docs/first-boot.md seeds the datasource the Containerfile pins cloud-init to" \
    "${firstboot_seed_dirs% }" \
    "$(tr '[:upper:]' '[:lower:]' <<<"${containerfile_datasources% }")"
fi

# The same cloud-config block is written twice: by hand here, and by
# scripts/quickstart.sh for the guided path. `just quickstart` and this document
# create the same account by two different routes, so a key changed in the script
# leaves the document seeding a user with different privileges -- or, if
# lock_passwd drifts, one that cannot log in at all.
firstboot_user_keys="$(awk '/^```/ { inb = !inb; next } inb' "${FIRSTBOOT_DOC}" |
  grep -E '^[[:space:]]{4}[a-z_]+:' | sed 's/^[[:space:]]*//' | sort -u)"
quickstart_user_keys="$(grep -oE "printf [\"'][[:space:]]*[a-z_]+:[^\"']*" "${QUICKSTART}" |
  sed -E "s/^printf [\"'][[:space:]]*//; s/\\\\n$//; s/[[:space:]]*$//" | sort -u)"
if [[ -z "${firstboot_user_keys}" ]]; then
  fail "the cloud-config user docs/first-boot.md seeds matches the one scripts/quickstart.sh seeds" \
    "no cloud-config user keys found in any fenced block of ${FIRSTBOOT_DOC}"
elif [[ -z "${quickstart_user_keys}" ]]; then
  fail "the cloud-config user docs/first-boot.md seeds matches the one scripts/quickstart.sh seeds" \
    "${QUICKSTART} no longer emits a cloud-config user block; the document is a copy of nothing"
else
  # `passwd:` is compared by key only. The document shows a placeholder and the
  # script substitutes a hash, so their values differ on purpose.
  firstboot_user_mismatch=""
  while IFS= read -r pair; do
    [[ -n "${pair}" ]] || continue
    if [[ "${pair}" == passwd:* ]]; then
      grep -q '^passwd:' <<<"${quickstart_user_keys}" ||
        firstboot_user_mismatch+="passwd: (not seeded by ${QUICKSTART}) "
      continue
    fi
    grep -qxF -- "${pair}" <<<"${quickstart_user_keys}" ||
      firstboot_user_mismatch+="${pair} "
  done <<<"${firstboot_user_keys}"
  if [[ -z "${firstboot_user_mismatch}" ]]; then
    pass "the cloud-config user docs/first-boot.md seeds matches the one scripts/quickstart.sh seeds"
  else
    fail "the cloud-config user docs/first-boot.md seeds matches the one scripts/quickstart.sh seeds" \
      "in the document, not in the script: ${firstboot_user_mismatch}"
  fi
fi

# The hash format is part of that seed: a document that tells the reader to
# generate one form while the script generates another means one of the two
# produces an account cloud-init refuses to authenticate.
assert_equal "docs/first-boot.md generates the password hash scripts/quickstart.sh generates" \
  "$(grep -oE 'openssl passwd -[0-9]' "${FIRSTBOOT_DOC}" | sort -u | tr '\n' ' ')" \
  "$(grep -oE 'openssl passwd -[0-9]' "${QUICKSTART}" | sort -u | tr '\n' ' ')"

# --- The recovery image the reader is told to run -----------------------------
#
# The manual fallback runs this repository's own published image as a rescue
# toolkit. A flavor that is not built, or a tag the publish step does not
# repoint, is a `podman run` that pulls nothing on a machine whose only other
# recovery path the reader has already been told does not apply.
firstboot_image_refs="$(grep -oE 'ghcr\.io/[a-z0-9._/-]+:[a-z0-9._-]+' "${FIRSTBOOT_DOC}" | sort -u)"
workflow_default_tag="$(sed -n 's/^[[:space:]]*DEFAULT_TAG:[[:space:]]*"\{0,1\}\([A-Za-z0-9._-]*\)"\{0,1\}[[:space:]]*$/\1/p' \
  "${BUILD_WORKFLOW}" | head -1)"
if [[ -z "${firstboot_image_refs}" ]]; then
  fail "the image docs/first-boot.md uses as a recovery toolkit is one the build publishes" \
    "no ghcr.io reference in ${FIRSTBOOT_DOC}; the offline-disk fallback names no image"
elif [[ -z "${workflow_flavors}" || -z "${workflow_default_tag}" ]]; then
  fail "the image docs/first-boot.md uses as a recovery toolkit is one the build publishes" \
    "flavors: '${workflow_flavors}', DEFAULT_TAG: '${workflow_default_tag}'"
else
  firstboot_unpublished=""
  while IFS= read -r ref; do
    [[ -n "${ref}" ]] || continue
    image="${ref##*/}"
    flavor="${image%%:*}"
    flavor="${flavor#arch-bootc-}"
    tag="${image##*:}"
    grep -qw -- "${flavor}" <<<"${workflow_flavors}" ||
      firstboot_unpublished+="${ref} (flavor '${flavor}' is not in the build matrix) "
    [[ "${tag}" == "${workflow_default_tag}" ]] ||
      firstboot_unpublished+="${ref} (tag '${tag}' is not the tag every publish repoints) "
  done <<<"${firstboot_image_refs}"
  if [[ -z "${firstboot_unpublished}" ]]; then
    pass "the image docs/first-boot.md uses as a recovery toolkit is one the build publishes"
  else
    fail "the image docs/first-boot.md uses as a recovery toolkit is one the build publishes" \
      "${firstboot_unpublished}"
  fi
fi

# --- Homebrew: the prefix and the two fragments -------------------------------
#
# "The image installs system-wide shell integration" is followed by a two-item
# list, and then by the sentence the whole ownership argument rests on: "Those
# two are the only shell integration the image installs". A third fragment added
# to system_files/ would make that false, and the ownership guard the paragraph
# goes on to describe would say nothing about it.
firstboot_guarded="$(grep -oE '/etc/(profile\.d|fish/conf\.d)/homebrew\.(sh|fish)' "${FIRSTBOOT_DOC}" |
  sort -u | tr '\n' ' ')"
shipped_fragments="$(find system_files/etc/profile.d system_files/etc/fish/conf.d -type f 2>/dev/null |
  sed 's|^system_files||' | sort | tr '\n' ' ')"
assert_equal "the two fragments docs/first-boot.md calls the only shell integration are the only ones shipped" \
  "${firstboot_guarded% }" "${shipped_fragments% }"

# The build's sweep is what keeps that true against the next payload digest, and
# its allowlist is the same two names. The document's sentence is only as strong
# as that list.
firstboot_sweep_allowlist="$(grep -oE '\-vxF( -e [^ ]+)+' "${CONTAINERFILE}" |
  tr ' ' '\n' | grep '^/' | sort -u | tr '\n' ' ')"
assert_equal "the build's unguarded-fragment sweep exempts exactly the two docs/first-boot.md names" \
  "${firstboot_sweep_allowlist% }" "${firstboot_guarded% }"

# The prefix. The document prints it as a path to read and again inside the
# `brew shellenv` line a reader pastes into an already-open shell; the guarded
# fragments eval the same path.
firstboot_prefix="$(grep -oE '/var/home/linuxbrew/\.linuxbrew' "${FIRSTBOOT_DOC}" | head -1)"
if [[ -z "${firstboot_prefix}" ]]; then
  fail "the Homebrew prefix docs/first-boot.md names is the one the guarded fragments use" \
    "${FIRSTBOOT_DOC} no longer names /var/home/linuxbrew/.linuxbrew"
else
  firstboot_prefix_missing=""
  for fragment in "${BREW_SH}" "${BREW_FISH}"; do
    grep -qF -- "${firstboot_prefix}/bin/brew" "${fragment}" || firstboot_prefix_missing+="${fragment} "
  done
  if [[ -z "${firstboot_prefix_missing}" ]]; then
    pass "the Homebrew prefix docs/first-boot.md names is the one the guarded fragments use"
  else
    fail "the Homebrew prefix docs/first-boot.md names is the one the guarded fragments use" \
      "not referenced in: ${firstboot_prefix_missing}"
  fi
fi

# The escape hatch the document offers for an already-open shell is the same eval
# the POSIX fragment runs for a new one.
firstboot_shellenv="$(grep -oE 'eval "\$\(/var/home/linuxbrew/\.linuxbrew/bin/brew shellenv\)"' \
  "${FIRSTBOOT_DOC}" | head -1)"
if [[ -z "${firstboot_shellenv}" ]]; then
  fail "the shellenv line docs/first-boot.md tells the reader to run is the one the fragment runs" \
    "${FIRSTBOOT_DOC} no longer shows the eval for an already-open shell"
elif grep -qF -- "${firstboot_shellenv}" "${BREW_SH}"; then
  pass "the shellenv line docs/first-boot.md tells the reader to run is the one the fragment runs"
else
  fail "the shellenv line docs/first-boot.md tells the reader to run is the one the fragment runs" \
    "${BREW_SH} does not contain: ${firstboot_shellenv}"
fi

# Zsh gets no fragment of its own -- the document's claim is that /etc/zsh/zprofile
# sources /etc/profile, which is a property of Arch's packaging and not of this
# tree. tests/test-homebrew-profile.sh is what exercises that path, so it is the
# only thing standing behind the sentence.
if grep -qF '/etc/zsh/zprofile' "${FIRSTBOOT_DOC}"; then
  if grep -qF '/etc/zsh/zprofile' "tests/test-homebrew-profile.sh"; then
    pass "the zsh path docs/first-boot.md promises is the one tests/test-homebrew-profile.sh exercises"
  else
    fail "the zsh path docs/first-boot.md promises is the one tests/test-homebrew-profile.sh exercises" \
      "the document says zsh login shells are covered via /etc/zsh/zprofile and no test runs that path"
  fi
fi

# --- Homebrew: what the payload brings and what the build removes -------------
#
# The document explains the review record to a reader as a count: the manifest
# covers "the other ten" of "the eleven". Both words are hand-written, and the
# thing they count is a file with one path per line.
firstboot_manifest_entries="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "${BREW_MANIFEST}" |
  grep -cv '^$')"
firstboot_count_word="$(number_word "${firstboot_manifest_entries}")"
firstboot_remainder_word="$(number_word "$((firstboot_manifest_entries - 1))")"
if [[ -z "${firstboot_count_word}" || -z "${firstboot_remainder_word}" ]]; then
  fail "docs/first-boot.md counts the payload's files the way brew-payload.manifest lists them" \
    "${firstboot_manifest_entries} entries is outside the range this check spells out"
else
  firstboot_count_missing=""
  for word in "${firstboot_count_word}" "${firstboot_remainder_word}"; do
    grep -qE "\b${word}\b" "${FIRSTBOOT_DOC}" || firstboot_count_missing+="${word} "
  done
  if [[ -z "${firstboot_count_missing}" ]]; then
    pass "docs/first-boot.md counts the payload's files the way brew-payload.manifest lists them"
  else
    fail "docs/first-boot.md counts the payload's files the way brew-payload.manifest lists them" \
      "${BREW_MANIFEST} has ${firstboot_manifest_entries} entries; the document never says: ${firstboot_count_missing}"
  fi
fi

# "one path per line" is the document's description of the file it links to, and
# the build's comparison depends on it: an entry with a second field on it
# matches no `find -printf '%P\n'` output and fails every payload.
firstboot_multi_field="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "${BREW_MANIFEST}" |
  grep -v '^$' | grep '[[:space:]]' || true)"
if [[ -z "${firstboot_multi_field}" ]]; then
  pass "brew-payload.manifest is the one-path-per-line list docs/first-boot.md describes"
else
  fail "brew-payload.manifest is the one-path-per-line list docs/first-boot.md describes" \
    "entries with more than a path: ${firstboot_multi_field//$'\n'/ | }"
fi

# The three unguarded fragments the document names are the three the Containerfile
# deletes. A fourth arriving in a later digest is the build's problem; a name that
# stops matching is this document's, and it reads as a promise that something was
# removed.
firstboot_unguarded="$(grep -oE '/(etc/profile\.d|usr/share/fish/vendor_conf\.d)/[A-Za-z0-9_.-]+' \
  "${FIRSTBOOT_DOC}" | grep -v '/homebrew\.' | sort -u | tr '\n' ' ')"
assert_equal "the fragments docs/first-boot.md says the Containerfile deletes are the ones it deletes" \
  "${firstboot_unguarded% }" \
  "$(printf '%s\n' "${VENDORED_BREW_FRAGMENTS[@]}" | sort | tr '\n' ' ' | sed 's/ $//')"

firstboot_unguarded_count="$(wc -w <<<"${firstboot_unguarded}" | tr -d ' ')"
firstboot_unguarded_word="$(number_word "${firstboot_unguarded_count}")"
if [[ -n "${firstboot_unguarded_word}" ]] &&
  grep -qE "\b${firstboot_unguarded_word}\b unguarded fragments" "${FIRSTBOOT_DOC}"; then
  pass "docs/first-boot.md counts those fragments the way it lists them"
else
  fail "docs/first-boot.md counts those fragments the way it lists them" \
    "the document names ${firstboot_unguarded_count} of them and does not say '${firstboot_unguarded_word:-?} unguarded fragments'"
fi

# The containment the last section describes, by path. The drop-in is in this
# tree, so a rename that leaves the document pointing at nothing is a plain
# comparison.
firstboot_dropin="$(grep -oE '/usr/lib/systemd/system/brew-setup\.service\.d/[A-Za-z0-9_.-]+' \
  "${FIRSTBOOT_DOC}" | sort -u | tr '\n' ' ')"
assert_equal "the PrivateTmp drop-in docs/first-boot.md names is the one this repository ships" \
  "${firstboot_dropin% }" "/${BREW_SETUP_DROPIN#system_files/}"

# The unit the document tells the reader to check when brew is missing is the one
# the Containerfile presets, and the one the manifest says arrives.
firstboot_units="$(grep -oE '[A-Za-z0-9_.-]+\.(service|timer)' "${FIRSTBOOT_DOC}" | sort -u)"
if [[ -z "${firstboot_units}" ]]; then
  fail "every unit docs/first-boot.md names is one the image enables" \
    "the document no longer names the unit whose status it tells the reader to check"
else
  firstboot_unknown_units=""
  while IFS= read -r unit; do
    [[ -n "${unit}" ]] || continue
    grep -qE "systemctl preset .*${unit//./\\.}" "${CONTAINERFILE}" ||
      firstboot_unknown_units+="${unit} "
  done <<<"${firstboot_units}"
  if [[ -z "${firstboot_unknown_units}" ]]; then
    pass "every unit docs/first-boot.md names is one the image enables"
  else
    fail "every unit docs/first-boot.md names is one the image enables" \
      "not preset by the Containerfile: ${firstboot_unknown_units}"
  fi
fi

# The tarball size the document quotes twice is the one the Containerfile and the
# manifest quote. It is the figure a reader uses to decide whether a first boot
# is hung or still extracting.
assert_equal "the payload size docs/first-boot.md quotes is the one the Containerfile quotes" \
  "$(grep -oE '[0-9]+MB' "${FIRSTBOOT_DOC}" | sort -u | tr '\n' ' ')" \
  "$(grep -oE '[0-9]+MB' "${CONTAINERFILE}" | sort -u | tr '\n' ' ')"

fi

# ---------------------------------------------------------------------------
group "Review rubric (docs/review-rubric.md is the reviewer's hand copy of the invariants asserted above)"

# The header of this file names docs/review-rubric.md as one of the documents
# whose prose these checks exist to enforce. Nothing read it. Every other
# document under docs/ is now joined to the tree, and the rubric was the one
# still unread -- which is the worst place for a stale line to sit. A reviewer
# who works down a checklist and finds a bullet naming a file, a flag or a
# carve-out that no longer exists ticks the box and moves on, and the check that
# bullet stands for simply does not happen. The document is load-bearing in
# exactly the way a test is: it is the only thing standing between a weakened
# invariant and an approval.
#
# Every assertion below runs in the same direction: take the identifier out of
# the rubric and compare it to the thing in the tree it is a hand copy of.
# Reading the needle out of the document rather than restating it here is the
# point -- the tree side of most of these is already asserted in the groups
# above, so what is new is that a reworded or deleted bullet now fails.
#
# What is deliberately not asserted, rather than left to be assumed: section 1
# (Scope) and section 6 (Evidence) are judgements about a pull request and its
# description, not properties of the checked-out tree, so there is nothing here
# to read. "Display managers still refusing root" is behavior of the packaged
# plasmalogin and lightdm units, for the reason given at the top of this file.

RUBRIC="docs/review-rubric.md"

if [[ ! -f "${RUBRIC}" ]]; then
  fail "the review rubric exists" \
    "${RUBRIC} is missing; README.md's documentation table and CONTRIBUTING.md both send a reader to it"
else

# The Containerfile with comment lines removed, for the same reason
# assert_present strips them: every control the rubric names is also described
# in a nearby rationale comment using the same words, so a plain grep is
# satisfied by the *explanation* of a control that has been deleted.
rubric_cf_active="$(grep -Ev '^[[:space:]]*#' "${CONTAINERFILE}")"

shopt -s nullglob
rubric_workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
shopt -u nullglob

# The body of one checklist item, for the bullets that need more than a grep.
# Items start at column 0 and their continuations are indented, so the next
# item -- or the next heading -- ends the one being read.
rubric_bullet() {
  awk -v needle="$1" '
    index($0, needle) && /^- \[ \]/ { grab = 1; print; next }
    grab && (/^- \[ \]/ || /^#/) { exit }
    grab { print }
  ' "${RUBRIC}"
}

# Compare an identifier the rubric hands a reviewer with the same identifier in
# the tree. An identifier that has vanished from *both* sides is a failure, not
# a match: "" == "" is exactly the silent pass this group exists to prevent.
assert_rubric_join() {
  local description="$1" from_doc="$2" from_tree="$3" note="${4:-}"
  if [[ -z "${from_doc}" ]]; then
    fail "${description}" "${RUBRIC} no longer names it${note:+: ${note}}"
  else
    assert_equal "${description}" "${from_doc}" "${from_tree}"
  fi
}

# The rubric names a literal that must appear somewhere in the tree.
assert_rubric_needle() {
  local description="$1" needle="$2" haystack="$3" where="$4"
  if [[ -z "${needle}" ]]; then
    fail "${description}" "${RUBRIC} no longer names it"
  elif grep -Fq -- "${needle}" <<<"${haystack}"; then
    pass "${description}"
  else
    fail "${description}" "${where} has no such line: ${needle}"
  fi
}

# --- The document is still reachable and still a checklist --------------------

assert_present "README.md's documentation table still links to the review rubric" \
  "README.md" '\]\(docs/review-rubric\.md\)'

assert_present "CONTRIBUTING.md still sends a contributor to the review rubric" \
  "CONTRIBUTING.md" 'docs/review-rubric\.md'

assert_doc_links_resolve "${RUBRIC}" \
  "no relative links found; the hand-off to AGENTS.md and ci-cd.md is gone"

# This file's own header claims to assert what the rubric describes in prose.
# If the header stops naming it, the pairing this group rests on is gone and
# nothing says so.
#
# Only the header is read, not the whole file: the assignment above and the
# comments in this group both spell the path, so a whole-file grep would be
# satisfied by this group's own source and could never fail.
if head -n 30 "tests/check-invariants.sh" | grep -Fq "${RUBRIC}"; then
  pass "this file still names the rubric among the documents it enforces"
else
  fail "this file still names the rubric among the documents it enforces" \
    "the header comment no longer names ${RUBRIC}"
fi

assert_equal "the rubric's numbered sections are 1 through 7, in order" \
  "$(grep -oE '^## [0-9]+\.' "${RUBRIC}" | grep -oE '[0-9]+' | tr '\n' ' ')" \
  "1 2 3 4 5 6 7 "

# A pre-ticked box is an answer somebody else supplied.
rubric_ticked="$(grep -nE '^[[:space:]]*- \[[^]] ?\]' "${RUBRIC}" | grep -vE '^[0-9]+:[[:space:]]*- \[ \]' | tr '\n' ' ')"
if [[ -z "${rubric_ticked}" ]]; then
  pass "every rubric box is unticked, so a reviewer has to answer it"
else
  fail "every rubric box is unticked, so a reviewer has to answer it" "${rubric_ticked}"
fi

# A numbered section with no checklist item left in it is a heading a reviewer
# reads past.
rubric_empty_sections=""
for rubric_n in 1 2 3 4 5 6 7; do
  rubric_items="$(awk -v n="${rubric_n}" '
    $0 ~ "^## " n "\\." { grab = 1; next }
    grab && /^## / { exit }
    grab && /^- \[ \]/ { count++ }
    END { print count + 0 }
  ' "${RUBRIC}")"
  ((rubric_items > 0)) || rubric_empty_sections+="${rubric_n} "
done
if [[ -z "${rubric_empty_sections}" ]]; then
  pass "every numbered rubric section still carries at least one checklist item"
else
  fail "every numbered rubric section still carries at least one checklist item" \
    "sections with no '- [ ]' item: ${rubric_empty_sections}"
fi

# --- 2. Security invariants ---------------------------------------------------

rubric_sshd="$(grep -oE 'PermitRootLogin [a-z-]+' "${RUBRIC}" | sort -u | tr '\n' ' ')"
assert_rubric_join "the sshd directive the rubric names is the one the Containerfile pins" \
  "${rubric_sshd}" \
  "$(grep -oE 'PermitRootLogin [a-z-]+' <<<"${rubric_cf_active}" | sort -u | tr '\n' ' ')" \
  "the rubric no longer tells a reviewer which PermitRootLogin value to look for"

# Naming one PAM service is the exact mistake the Containerfile's own comment
# warns about: util-linux's su authenticates a *login* shell against
# /etc/pam.d/su-l. A rubric that lost the second path sends a reviewer looking
# for half the control and finding it.
rubric_pam="$(grep -oE '/etc/pam\.d/[a-z-]+' "${RUBRIC}" | sort -u | tr '\n' ' ')"
assert_rubric_join "the PAM services the rubric names are the ones the Containerfile edits" \
  "${rubric_pam}" \
  "$(grep -oE '/etc/pam\.d/[a-z-]+' <<<"${rubric_cf_active}" | sort -u | tr '\n' ' ')" \
  "the rubric no longer names a PAM service file"

assert_rubric_needle "the PAM rule the rubric names is the one the build enables and verifies" \
  "$(grep -oE 'pam_wheel\.so use_uid' "${RUBRIC}" | head -1)" \
  "${rubric_cf_active}" "the Containerfile"

assert_rubric_needle "the password-expiry command the rubric names is the one the Containerfile runs" \
  "$(grep -oE 'passwd --expire' "${RUBRIC}" | head -1)" \
  "${rubric_cf_active}" "the Containerfile"

# "These four are load-bearing *together*" is a count of the closures listed in
# the same bullet, and a count in prose next to a list is the pair that drifts:
# dropping a closure from the list is a one-line diff, and the word four a few
# lines down goes on asserting that nothing was dropped.
#
# The bullet is read as one line before the count is matched out of it: the
# document wraps at 80 columns and "These four" already sits at the end of a
# line with "are load-bearing" on the next, so a line-based match finds nothing
# and reports the sentence missing when it is merely wrapped.
rubric_root_bullet="$(rubric_bullet 'The root-login model is intact' | tr '\n' ' ' | tr -s ' ')"
rubric_root_word="$(grep -oE 'These [a-z]+ are load-bearing' <<<"${rubric_root_bullet}" | awk '{print $2}')"
rubric_root_named=0
for rubric_closure in 'PermitRootLogin' 'pam_wheel' 'display manager' 'passwd --expire'; do
  if grep -Fq -- "${rubric_closure}" <<<"${rubric_root_bullet}"; then
    rubric_root_named=$((rubric_root_named + 1))
  fi
done
assert_rubric_join "the rubric's count of load-bearing root closures matches the number it lists" \
  "${rubric_root_word}" "$(number_word "${rubric_root_named}")" \
  "the bullet no longer says how many closures hold the default root password up"

rubric_policy="$(grep -oE 'system_files/etc/containers/[A-Za-z0-9._-]+' "${RUBRIC}" | sort -u | tr '\n' ' ')"
assert_rubric_join "the signature policy file the rubric names is the one this script asserts against" \
  "${rubric_policy}" "${POLICY} " \
  "the rubric no longer names the policy file a reviewer is told to check"

# "cosign.pub is not duplicated or bypassed": the Containerfile copies the one
# at the repository root into the image, and a second copy committed anywhere
# else is a second key nobody is watching.
rubric_cosign="$(grep -oE 'cosign\.pub' "${RUBRIC}" | head -1)"
if [[ -z "${rubric_cosign}" ]]; then
  fail "cosign.pub exists once, at the repository root (rubric: 'not duplicated or bypassed')" \
    "${RUBRIC} no longer names cosign.pub"
else
  assert_equal "cosign.pub exists once, at the repository root (rubric: 'not duplicated or bypassed')" \
    "$(find . -name 'cosign.pub' -not -path './.git/*' | sort | tr '\n' ' ')" \
    "./cosign.pub "
fi

rubric_bust="$(grep -oE '[A-Z][A-Z_]*CACHE_BUST' "${RUBRIC}" | sort -u | head -1)"
if [[ -z "${rubric_bust}" ]]; then
  fail "the cache-bust ARG the rubric names is declared in the Containerfile" \
    "${RUBRIC} no longer names the cache-bust ARG"
  fail "package installation has not moved above the cache-bust reference" \
    "${RUBRIC} no longer names the cache-bust ARG"
else
  assert_rubric_needle "the cache-bust ARG the rubric names is declared in the Containerfile" \
    "ARG ${rubric_bust}=" "${rubric_cf_active}" "the Containerfile"

  # The second half of that bullet -- "package installation has not moved above
  # it" -- is an ordering, and an ordering is invisible to a grep for the name.
  # The ARG only busts the layer cache for steps that come after the step
  # referencing it; a `pacman -Syu` that moves above that reference keeps
  # serving a cached package set forever, with the ARG still present and still
  # bumped by CI.
  rubric_bust_line="$(grep -nF "\${${rubric_bust}}" "${CONTAINERFILE}" |
    grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)"
  rubric_install_line="$(grep -nE '^[^#]*pacman -S' "${CONTAINERFILE}" | head -1 | cut -d: -f1)"
  if [[ -n "${rubric_bust_line}" && -n "${rubric_install_line}" ]] &&
    ((rubric_bust_line < rubric_install_line)); then
    pass "package installation has not moved above the cache-bust reference"
  else
    fail "package installation has not moved above the cache-bust reference" \
      "${rubric_bust} referenced at line ${rubric_bust_line:-none}, first pacman install at line ${rubric_install_line:-none}"
  fi
fi

# The checkout option the rubric names, counted against the checkouts that must
# carry it. The needle comes from the document so that a rubric quoting an
# option nobody sets -- or quoting `true` -- fails here.
rubric_persist="$(grep -oE 'persist-credentials: [a-z]+' "${RUBRIC}" | sort -u | head -1)"
if [[ -z "${rubric_persist}" ]] || ((${#rubric_workflows[@]} == 0)); then
  fail "every actions/checkout sets the option the rubric names" \
    "rubric option: '${rubric_persist:-none}', workflow files found: ${#rubric_workflows[@]}"
else
  assert_equal "every actions/checkout sets the option the rubric names (${rubric_persist})" \
    "$(grep -cF "${rubric_persist}" "${rubric_workflows[@]}" 2>/dev/null | awk -F: '{total += $NF} END {print total + 0}')" \
    "$(grep -c 'uses: actions/checkout@' "${rubric_workflows[@]}" 2>/dev/null | awk -F: '{total += $NF} END {print total + 0}')"
fi

# The other half of that bullet, and the only claim in section 2 that nothing in
# this tree checked before: a `${{ ... }}` expansion inside a `run:` block is
# substituted into the shell source before the shell ever sees it, so a context
# carrying text from a pull request becomes code. Passing it through `env:`
# makes it a variable the shell reads instead of source it executes.
#
# `matrix.` is carved out explicitly rather than by oversight. A matrix value is
# written in the workflow file itself, a few lines above the step that reads it,
# and cannot carry anything from a pull request; build.yml interpolates
# `matrix.flavor` in two `run:` blocks on that basis. Every other context root
# fails here, and the check below requires the matrix key to be declared in the
# same file, so the carve-out cannot be widened by naming a key that is not one.
rubric_interpolations=""
rubric_matrix_uses=""
for rubric_workflow in "${rubric_workflows[@]}"; do
  while IFS= read -r rubric_hit; do
    [[ -n "${rubric_hit}" ]] || continue
    rubric_context="${rubric_hit#*|}"
    if [[ "${rubric_context}" == matrix.* ]]; then
      rubric_matrix_uses+="${rubric_workflow}|${rubric_context#matrix.} "
    else
      rubric_interpolations+="${rubric_workflow}: ${rubric_context} "
    fi
  done < <(awk '
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>]/ {
      inrun = 1
      indent = match($0, /[^ ]/)
      next
    }
    inrun && /^[[:space:]]*$/ { next }
    inrun && match($0, /[^ ]/) <= indent { inrun = 0 }
    inrun {
      line = $0
      while (match(line, /\$\{\{[[:space:]]*[A-Za-z0-9_.-]+/)) {
        token = substr(line, RSTART, RLENGTH)
        sub(/^\$\{\{[[:space:]]*/, "", token)
        print FILENAME "|" token
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "${rubric_workflow}")
done

if [[ -z "${rubric_interpolations}" ]]; then
  pass "no run: block interpolates a context the rubric says belongs in env:"
else
  fail "no run: block interpolates a context the rubric says belongs in env:" \
    "pass these through env: instead -- ${rubric_interpolations}"
fi

rubric_undeclared_matrix=""
read -r -a rubric_matrix_pairs <<<"${rubric_matrix_uses}"
if ((${#rubric_matrix_pairs[@]} > 0)); then
  for rubric_pair in "${rubric_matrix_pairs[@]}"; do
    rubric_pair_workflow="${rubric_pair%%|*}"
    rubric_pair_key="${rubric_pair#*|}"
    grep -qE "^[[:space:]]+${rubric_pair_key}:" "${rubric_pair_workflow}" ||
      rubric_undeclared_matrix+="${rubric_pair_workflow}: matrix.${rubric_pair_key} "
  done
fi
if [[ -z "${rubric_undeclared_matrix}" ]]; then
  pass "every matrix value interpolated into a run: block is declared in that workflow"
else
  fail "every matrix value interpolated into a run: block is declared in that workflow" \
    "${rubric_undeclared_matrix}"
fi

# --- 3. Image and system correctness ------------------------------------------

# "A change to the shared base stage reaches base, kde, and xfce": the three
# names are the reviewer's list of what else to look at, and they are a hand
# copy of the Containerfile's flavor stages and of the CI build matrix. A fourth
# flavor added to the tree and not to this bullet is a flavor nobody is told to
# think about.
# shellcheck disable=SC2016  # the backticks are literal Markdown in the document
rubric_flavors="$(grep -oE '`[a-z][a-z0-9-]*`' <<<"$(rubric_bullet 'Which flavors does this touch')" |
  tr -d '`' | sort -u | tr '\n' ' ')"
assert_rubric_join "the flavors the rubric says a base-stage change reaches are the Containerfile's flavor stages" \
  "${rubric_flavors}" \
  "$(grep -oE '^FROM base-core AS [a-z][a-z0-9-]*' "${CONTAINERFILE}" | awk '{print $NF}' | sort -u | tr '\n' ' ')" \
  "the bullet no longer names the flavors"

assert_rubric_join "the flavors the rubric names are the ones the CI build matrix builds" \
  "${rubric_flavors}" \
  "$(grep -oE '^[[:space:]]*flavor:[[:space:]]*\[[^]]*\]' "${BUILD_WORKFLOW}" |
    awk -F'[][]' '{print $2}' | tr ',' '\n' | tr -d ' ' | sort -u | tr '\n' ' ')" \
  "the bullet no longer names the flavors"

# The rubric gives the directory enablement symlinks belong in. Read the prefix
# out of it and require every .wants path the Containerfile creates to sit under
# that prefix -- so a rubric rewritten to bless /etc, and a Containerfile that
# moves there, both fail.
rubric_wants_prefix="$(grep -oE '/usr/lib/systemd/system/<target>\.wants/' "${RUBRIC}" | head -1)"
rubric_wants_prefix="${rubric_wants_prefix%%<target>*}"
if [[ -z "${rubric_wants_prefix}" ]]; then
  fail "every .wants directory the Containerfile writes sits under the prefix the rubric names" \
    "${RUBRIC} no longer names the /usr/lib/systemd/system/<target>.wants/ layout"
else
  rubric_stray_wants=""
  while IFS= read -r rubric_wants_path; do
    [[ -n "${rubric_wants_path}" ]] || continue
    [[ "${rubric_wants_path}" == "${rubric_wants_prefix}"* ]] ||
      rubric_stray_wants+="${rubric_wants_path} "
  done < <(grep -oE '(/[A-Za-z0-9._-]+)+\.wants' <<<"${rubric_cf_active}" | sort -u)
  if [[ -z "${rubric_stray_wants}" ]]; then
    pass "every .wants directory the Containerfile writes sits under the prefix the rubric names"
  else
    fail "every .wants directory the Containerfile writes sits under the prefix the rubric names" \
      "outside ${rubric_wants_prefix}: ${rubric_stray_wants}"
  fi
fi

rubric_presetall="$(grep -oE 'systemctl preset-all' "${RUBRIC}" | head -1)"
if [[ -z "${rubric_presetall}" ]]; then
  fail "the command the rubric forbids is absent from the Containerfile" \
    "${RUBRIC} no longer forbids systemctl preset-all"
elif grep -Fq -- "${rubric_presetall}" <<<"${rubric_cf_active}"; then
  fail "the command the rubric forbids is absent from the Containerfile" \
    "an active Containerfile line runs ${rubric_presetall}"
else
  pass "the command the rubric forbids is absent from the Containerfile"
fi

# "except the documented mask that must live there" is singular, and it is the
# only /etc exception a reviewer is told to accept. A second mask is a second
# exception nobody agreed to.
assert_equal "the /etc exception the rubric allows is still exactly one masked unit" \
  "$(grep -cE 'systemctl[[:space:]]+mask' <<<"${rubric_cf_active}")" "1"

if grep -qE '^[[:space:]]*#.*systemctl mask' "${CONTAINERFILE}" &&
  grep -qE '^[[:space:]]*#.*/etc/systemd/system/' "${CONTAINERFILE}"; then
  pass "the mask the rubric calls documented is documented where it is written"
else
  fail "the mask the rubric calls documented is documented where it is written" \
    "no Containerfile comment explains the mask and the /etc/systemd/system/ symlink it creates"
fi

# The paths the rubric forbids a bind-mount from targeting are forbidden because
# the directory-restructuring step replaced each of them with a symlink into
# /var, and a failed bind-mount onto a dangling symlink has been observed
# deleting real files from the *host* source directory. Both halves are checked:
# that each path the rubric names is in fact one of the symlinked ones, and that
# nothing targets it.
# shellcheck disable=SC2016  # the backticks are literal Markdown in the document
rubric_dangling="$(grep -oE '`/[a-z]+`' <<<"$(rubric_bullet 'mount=type=bind')" | tr -d '`' | sort -u)"
rubric_bind_targets="$(grep -oE 'type=bind[^[:space:]]*' <<<"${rubric_cf_active}" |
  grep -oE 'target=[^ ,]+' | cut -d= -f2 | sort -u)"
if [[ -z "${rubric_dangling}" ]]; then
  fail "every path the rubric calls dangling is one the Containerfile symlinks away" \
    "${RUBRIC} no longer names the paths a bind-mount must not target"
  fail "no bind-mount targets a path the rubric calls dangling" \
    "${RUBRIC} no longer names the paths a bind-mount must not target"
else
  rubric_not_symlinked=""
  rubric_bad_targets=""
  while IFS= read -r rubric_path; do
    [[ -n "${rubric_path}" ]] || continue
    grep -qE "ln -sT? [^ ]+ ${rubric_path}([[:space:]]|$)" <<<"${rubric_cf_active}" ||
      rubric_not_symlinked+="${rubric_path} "
    while IFS= read -r rubric_target; do
      [[ -n "${rubric_target}" ]] || continue
      [[ "${rubric_target}" == "${rubric_path}" || "${rubric_target}" == "${rubric_path}/"* ]] &&
        rubric_bad_targets+="${rubric_target} "
    done <<<"${rubric_bind_targets}"
  done <<<"${rubric_dangling}"

  if [[ -z "${rubric_not_symlinked}" ]]; then
    pass "every path the rubric calls dangling is one the Containerfile symlinks away"
  else
    fail "every path the rubric calls dangling is one the Containerfile symlinks away" \
      "no restructuring symlink found for: ${rubric_not_symlinked}"
  fi

  if [[ -z "${rubric_bad_targets}" ]]; then
    pass "no bind-mount targets a path the rubric calls dangling"
  else
    fail "no bind-mount targets a path the rubric calls dangling" \
      "${rubric_bad_targets}"
  fi
fi

# --- 5. Tests and validation --------------------------------------------------

rubric_thresholds="$(grep -oE '\.coverage-thresholds\.json' "${RUBRIC}" | head -1)"
if [[ -z "${rubric_thresholds}" ]]; then
  fail "the coverage-floor file the rubric names exists" \
    "${RUBRIC} no longer names the file whose floors a reviewer is told to check"
  fail "something under tests/ actually reads the coverage-floor file the rubric names" \
    "${RUBRIC} no longer names the file"
else
  if [[ -f "${rubric_thresholds}" ]]; then
    pass "the coverage-floor file the rubric names exists"
  else
    fail "the coverage-floor file the rubric names exists" "${rubric_thresholds} is missing"
  fi

  # A floor nothing reads is not a floor. The rubric tells a reviewer to check
  # that it was raised rather than lowered, which is only a check if some test
  # enforces it.
  #
  # This file is excluded from the search deliberately: the pattern a few lines
  # up spells the filename, so including it would make the assertion satisfied
  # by its own source no matter what the rest of tests/ does.
  rubric_threshold_readers="$(grep -rlF -- "${rubric_thresholds}" tests/ 2>/dev/null |
    grep -vFx 'tests/check-invariants.sh' | tr '\n' ' ')"
  if [[ -n "${rubric_threshold_readers}" ]]; then
    pass "something under tests/ actually reads the coverage-floor file the rubric names"
  else
    fail "something under tests/ actually reads the coverage-floor file the rubric names" \
      "nothing under tests/ mentions ${rubric_thresholds}, so a lowered floor is enforced by nothing"
  fi
fi

# The rubric names the two hand-maintained ShellCheck invocations by name. Both
# names are copies: the Justfile recipe name, and the CI step name.
# shellcheck disable=SC2016  # the backticks are literal Markdown in the document
rubric_lint_recipe="$(grep -oE '`Justfile` `[a-z-]+` recipe' "${RUBRIC}" | awk '{print $2}' | tr -d '`')"
assert_rubric_needle "the Justfile recipe the rubric names still exists" \
  "${rubric_lint_recipe:+${rubric_lint_recipe}:}" \
  "$(grep -E '^[a-z][a-z-]*:' "${JUSTFILE}")" "the Justfile's recipe list"

assert_present "the CI ShellCheck step the rubric names still exists" \
  "${BUILD_WORKFLOW}" '^[[:space:]]*-[[:space:]]*name:[[:space:]]*ShellCheck'

# The glob the rubric tells a reviewer to watch for has to be the repository's
# actual naming convention, or the bullet points at a class with no members.
rubric_test_glob="$(grep -oE 'tests/test-\*\.sh' "${RUBRIC}" | head -1)"
if [[ -n "${rubric_test_glob}" ]] && compgen -G "${rubric_test_glob}" >/dev/null; then
  pass "the test-file glob the rubric names matches files in this repository"
else
  fail "the test-file glob the rubric names matches files in this repository" \
    "rubric glob: '${rubric_test_glob:-none}'"
fi

# --- 7. Checks and threads ----------------------------------------------------

# The rubric hands a reviewer a command to run. A command that is missing, or
# committed without its executable bit, fails at the moment somebody trusts the
# document.
rubric_named_tools="$(grep -oE '\./scripts/[a-z0-9-]+\.sh' "${RUBRIC}" | sort -u)"
if [[ -z "${rubric_named_tools}" ]]; then
  fail "every script the rubric tells a reviewer to run exists and is executable" \
    "${RUBRIC} no longer names the review-state script"
  fail "the ci-cd.md section the rubric hands off to still documents that script" \
    "${RUBRIC} no longer names the review-state script"
else
  rubric_tool_problems=""
  rubric_tool_undocumented=""
  while IFS= read -r rubric_tool; do
    [[ -n "${rubric_tool}" ]] || continue
    if [[ ! -f "${rubric_tool}" ]]; then
      rubric_tool_problems+="${rubric_tool} (missing) "
    elif [[ ! -x "${rubric_tool}" ]]; then
      rubric_tool_problems+="${rubric_tool} (not executable) "
    fi
    grep -Fq -- "${rubric_tool#./}" "docs/ci-cd.md" ||
      rubric_tool_undocumented+="${rubric_tool} "
  done <<<"${rubric_named_tools}"

  if [[ -z "${rubric_tool_problems}" ]]; then
    pass "every script the rubric tells a reviewer to run exists and is executable"
  else
    fail "every script the rubric tells a reviewer to run exists and is executable" \
      "${rubric_tool_problems}"
  fi

  if [[ -z "${rubric_tool_undocumented}" ]]; then
    pass "the ci-cd.md section the rubric hands off to still documents that script"
  else
    fail "the ci-cd.md section the rubric hands off to still documents that script" \
      "not mentioned in docs/ci-cd.md: ${rubric_tool_undocumented}"
  fi
fi

# --- Merging ------------------------------------------------------------------

# "Renovate automerges most dependency updates once the build is green, with
# deliberate carve-outs (notably major bootc bumps). Do not broaden that scope
# or remove a carve-out." That is the one paragraph in the rubric that describes
# a configuration file rather than a diff, so it is the one that can be
# contradicted by a merged PR without anybody editing the rubric.
rubric_merge_section="$(awk '/^## Merging/ { grab = 1; next } grab' "${RUBRIC}")"
# shellcheck disable=SC2016  # the backticks are literal Markdown in the document
rubric_carve_name="$(grep -oE 'major `[a-z][a-z0-9-]*` bumps' <<<"${rubric_merge_section}" |
  awk '{print $2}' | tr -d '`')"

if ! command -v jq >/dev/null 2>&1; then
  fail "renovate.json still automerges updates, as the rubric's merging section says" \
    "jq is not on PATH, so renovate.json could not be read"
  fail "renovate.json still carries the major carve-out the rubric names" \
    "jq is not on PATH, so renovate.json could not be read"
  fail "the carve-out names the package the rubric names" \
    "jq is not on PATH, so renovate.json could not be read"
elif ! jq -e . "renovate.json" >/dev/null 2>&1; then
  fail "renovate.json still automerges updates, as the rubric's merging section says" \
    "renovate.json is not valid JSON"
  fail "renovate.json still carries the major carve-out the rubric names" \
    "renovate.json is not valid JSON"
  fail "the carve-out names the package the rubric names" \
    "renovate.json is not valid JSON"
else
  rubric_automerging="$(jq -r '[.packageRules[]? | select(.automerge == true)] | length' "renovate.json")"
  if ((rubric_automerging > 0)); then
    pass "renovate.json still automerges updates, as the rubric's merging section says"
  else
    fail "renovate.json still automerges updates, as the rubric's merging section says" \
      "no packageRule sets automerge: true, so the paragraph describes a policy that is gone"
  fi

  # The carve-out, read as the property rather than as a rule at a fixed index:
  # a rule that refuses automerge for the major update type.
  rubric_carved_packages="$(jq -r '
    [.packageRules[]?
     | select(.automerge == false)
     | select((.matchUpdateTypes // []) | index("major"))
     | (.matchPackageNames // [])[]] | join(" ")' "renovate.json")"
  if [[ -n "${rubric_carved_packages}" ]]; then
    pass "renovate.json still carries the major carve-out the rubric names"
  else
    fail "renovate.json still carries the major carve-out the rubric names" \
      "no packageRule refuses automerge for matchUpdateTypes [major]"
  fi

  if [[ -z "${rubric_carve_name}" ]]; then
    fail "the carve-out names the package the rubric names" \
      "${RUBRIC}'s merging section no longer names which major bumps are carved out"
  elif grep -Fq -- "${rubric_carve_name}" <<<"${rubric_carved_packages}"; then
    pass "the carve-out names the package the rubric names"
  else
    fail "the carve-out names the package the rubric names" \
      "the rubric says '${rubric_carve_name}', the carve-out covers: ${rubric_carved_packages:-nothing}"
  fi
fi

fi


# ---------------------------------------------------------------------------
group "Customizations inventory (docs/customizations.md: 'This repo already includes the following opinionated changes')"

# docs/customizations.md is the answer to "what did this image change, and why
# does it behave differently from stock Arch?". Every bullet in it is a hand
# copy of one of three package lists or of a Containerfile step. Nothing read
# it: its only appearance under tests/ was the Vendored Flathub group far
# above, which borrows a single sentence about the remote being vendored.
#
# Two directions drift here, and they fail differently:
#
#   - A package the document names that nothing in the tree installs sends a
#     reader looking for something the image does not have. `xfce4-terminal`
#     was exactly that shape: it is installed, but only as a member of the
#     `xfce4` group, and no file in this tree said where it came from.
#   - A flavor tag that no longer matches the list the package lives in is
#     worse than no tag at all, because a tag reads as verified. The document
#     states its own rule in the opening paragraph -- the flavors share
#     everything except where a flavor is called out -- so an untagged package
#     belongs in packages-base.txt or in both desktop lists, and a tagged one
#     belongs in that flavor's list and not the other's.
#
# The needles are read out of the document rather than restated here. A bullet
# that renames, re-tags or deletes a package changes what these checks compare,
# which is the property that makes this a join and not a second copy.
#
# What is deliberately not asserted: whether a package is installed as an Arch
# *group* rather than as a package (`xfce4`, `plasma-meta`), and what a group
# or meta-package pulls in. That is a property of the Arch repositories, not of
# this tree, and resolving it needs a network and a pacman database. Where the
# document leans on it, it now says so with a `via \`<package>\`` clause, and
# the clause is what these checks accept in place of an install.

CUSTOM_DOC="docs/customizations.md"
PACKAGES_BASE="packages-base.txt"
PACKAGES_KDE="packages-kde.txt"
PACKAGES_XFCE="packages-xfce.txt"

if [[ ! -f "${CUSTOM_DOC}" ]]; then
  fail "${CUSTOM_DOC} exists" "the customizations document is gone"
else

# The bullets of the "Current Customizations" section, each folded onto one
# line: the document wraps, and a claim that spans two lines is still one
# claim. The Upstream Compatibility section below it is prose about the
# bootstrapping work rather than an inventory, and is asserted separately at
# the end of this group.
custom_bullets="$(awk '
  /^## Current Customizations In This Repo$/ { inside = 1; next }
  /^## / { inside = 0 }
  !inside { next }
  /^- / { if (bullet != "") print bullet; bullet = $0; next }
  /^[[:space:]]+[^[:space:]]/ { if (bullet != "") { sub(/^[[:space:]]+/, " "); bullet = bullet $0 }; next }
  { if (bullet != "") { print bullet; bullet = "" } }
  END { if (bullet != "") print bullet }
' "${CUSTOM_DOC}")"

custom_bullet_count="$(grep -c '^- ' <<<"${custom_bullets}" || true)"
if ((custom_bullet_count >= 20)); then
  pass "the customizations inventory still reads as a bulleted list (${custom_bullet_count} bullets)"
else
  fail "the customizations inventory still reads as a bulleted list" \
    "found ${custom_bullet_count} bullet(s) under 'Current Customizations In This Repo'; the checks below read their contents, so a rewrite that drops the list silently stops asserting anything"
fi

# Every backticked name in those bullets, paired with the flavor the document
# attributes it to.
#
# A backticked `kde`/`xfce` directly after an opening parenthesis is a flavor
# tag, not a package. A tag covers the clause it closes: every name back to
# the previous tag, or to a semicolon, or to the start of the bullet. So in
#
#   `distrobox`, `flatpak`, and `firefox` installed; `konsole` (`kde`) or
#   `xfce4-terminal` (`xfce`, ...)
#
# the `kde` tag reaches back only as far as the semicolon and covers `konsole`
# alone, and in "`kde-applications-meta`/`plasma-meta` (`kde`), or the
# `xfce4`/`xfce4-goodies` groups plus ... (`xfce`)" each tag covers the pair
# of names in its own clause. A name no tag covers is untagged and therefore
# shared, whatever the rest of the bullet says: the document's rule is that
# the flavors share everything except where a flavor is called out, and a tag
# on a different clause is not a call-out for this one. That is what keeps
# `firefox` checked against both desktop lists, and keeps `distrobox` from
# borrowing whichever tag happens to sit later in the same bullet. A name
# introduced by "via" is the package or group the document says provides the
# name before it, and is what the install check below accepts in place of an
# install.
#
custom_claims="$(awk '
  {
    n = 0
    rest = $0
    while (match(rest, /`[^`]+`/)) {
      n++
      befores[n] = substr(rest, 1, RSTART - 1)
      spans[n] = substr(rest, RSTART + 1, RLENGTH - 2)
      rest = substr(rest, RSTART + RLENGTH)
      if (n > 1) afters[n - 1] = befores[n]
    }
    afters[n] = rest
    for (i = 1; i <= n; i++) {
      provider_of[i] = ""
      is_marker[i] = ((spans[i] == "kde" || spans[i] == "xfce") && befores[i] ~ /\($/)
      is_provider[i] = (befores[i] ~ /via( the)? $/)
    }
    # Three things a bullet can be doing with a name, and they want opposite
    # assertions: claiming the image has it, claiming the image does not, or
    # naming it in passing to say where something else comes from. The middle
    # one is why `nano` and `base-devel` are in the document at all; the last
    # is the aside about what the upstream `base` package does not ship, which
    # is a claim about Arch rather than about this image.
    for (i = 1; i <= n; i++) {
      role[i] = "claim"
      if (afters[i] ~ /^ is \*\*not\*\* shipped/ || afters[i] ~ /^ removed from the image/) role[i] = "absent"
      else if (befores[i] ~ /not shipped by [^`]*$/) role[i] = "mention"
      else if (i > 1 && role[i - 1] == "mention" && befores[i] ~ /^[\/,[:space:]]*(and |or )?$/) role[i] = "mention"
    }
    # A "via" clause backs the name it follows, not every name in the bullet:
    # walking back from the clause to the nearest name before it is what keeps
    # `konsole` from borrowing the `xfce4` group that stands behind
    # `xfce4-terminal` two words later.
    for (j = 1; j <= n; j++) {
      if (!is_provider[j]) continue
      for (i = j - 1; i >= 1; i--) {
        if (is_marker[i] || is_provider[i]) continue
        if (spans[i] ~ /^[^A-Za-z]/ || spans[i] ~ / /) continue
        provider_of[i] = spans[j]
        break
      }
    }
    for (i = 1; i <= n; i++) {
      if (is_marker[i] || is_provider[i]) continue
      # Walk forward to the tag that closes this clause. afters[k] is the text
      # between name k and name k + 1, so a semicolon in it ends the clause
      # before any tag is reached, and the name stays shared.
      flavor = "untagged"
      for (k = i; k < n; k++) {
        if (afters[k] ~ /;/) break
        if (is_marker[k + 1]) { flavor = spans[k + 1]; break }
      }
      # A literal dash stands in for "no via clause": consecutive tabs are one
      # delimiter to `read`, so an empty field here would shift `role` into
      # `provider` and silently drop every role distinction below.
      printf "%s\t%s\t%s\t%s\n", spans[i], flavor, (provider_of[i] == "" ? "-" : provider_of[i]), role[i]
    }
    delete spans; delete befores; delete afters; delete is_marker; delete is_provider
    delete provider_of; delete role
  }
' <<<"${custom_bullets}")"

# A package name, as opposed to a unit name, a path, a size expression or a
# command line: one word, no glob, and not a systemd unit. Case is folded
# because the document writes NetworkManager the way the project spells it and
# the package list writes it the way pacman does.
package_shaped() {
  local token="$1"
  [[ "${token}" =~ ^[A-Za-z][A-Za-z0-9@._+-]*$ ]] || return 1
  [[ "${token}" =~ \.(service|socket|slice|target|timer|conf|cfg|json|txt|md|sh)$ ]] && return 1
  return 0
}

# Same shape as assert_present, for the same reason: `grep -v ... | grep -q`
# under `set -o pipefail` fails at random when the second grep exits on its
# first match and the first takes SIGPIPE. The uncommented lines are captured
# once and the match runs against the variable, so there is no pipeline.
packages_in() {
  local file="$1" token="$2"
  [[ -f "${file}" ]] || return 1
  local active
  active="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${file}")"
  grep -qxF -- "${token}" <<<"${active}"
}

# The active (non-comment) lines of the Containerfile and Justfile, read once
# for the loop below rather than re-read and re-piped per package.
custom_containerfile_active="$(grep -vE '^[[:space:]]*#' "${CONTAINERFILE}")"
custom_justfile_active="$(grep -vE '^[[:space:]]*#' "${JUSTFILE}")"

custom_uninstalled=""
custom_mistagged=""
custom_shipped_anyway=""
custom_checked=0
while IFS=$'\t' read -r token flavor provider role; do
  [[ -n "${token}" ]] || continue
  package_shaped "${token}" || continue
  [[ "${role}" == "mention" ]] && continue
  token="${token,,}"
  custom_checked=$((custom_checked + 1))

  in_base=0; in_kde=0; in_xfce=0
  packages_in "${PACKAGES_BASE}" "${token}" && in_base=1
  packages_in "${PACKAGES_KDE}" "${token}" && in_kde=1
  packages_in "${PACKAGES_XFCE}" "${token}" && in_xfce=1

  # A bullet that exists to say a package is *not* in the image inverts both
  # checks: `nano` and `base-devel` are named there precisely because they are
  # absent, so finding them installed is the failure.
  if [[ "${role}" == "absent" ]]; then
    ((in_base + in_kde + in_xfce == 0)) || custom_shipped_anyway+="${token} "
    continue
  fi

  if ((in_base + in_kde + in_xfce == 0)); then
    # Not installed by name. The tree may still account for it: the
    # Containerfile installs or removes it as part of a step (bootc's build
    # dependencies, `nano`), the Justfile names it (the build recipes), or the
    # document itself names the group or meta-package it arrives in.
    accounted=0
    grep -qwF -- "${token}" <<<"${custom_containerfile_active}" && accounted=1
    grep -qwF -- "${token}" <<<"${custom_justfile_active}" && accounted=1
    if [[ -n "${provider}" && "${provider}" != "-" ]] &&
      { packages_in "${PACKAGES_BASE}" "${provider}" ||
        packages_in "${PACKAGES_KDE}" "${provider}" ||
        packages_in "${PACKAGES_XFCE}" "${provider}"; }; then
      accounted=1
    fi
    ((accounted == 1)) || custom_uninstalled+="${token}(doc:${flavor}) "
    continue
  fi

  where=""
  ((in_base == 1)) && where+="base,"
  ((in_kde == 1)) && where+="kde,"
  ((in_xfce == 1)) && where+="xfce,"
  case "${flavor}" in
    kde)
      ((in_kde == 1 && in_xfce == 0)) ||
        custom_mistagged+="${token}(doc:kde,lists:${where%,}) "
      ;;
    xfce)
      ((in_xfce == 1 && in_kde == 0)) ||
        custom_mistagged+="${token}(doc:xfce,lists:${where%,}) "
      ;;
    untagged)
      # Untagged means every flavor gets it: from the base list, or from each
      # desktop list. Name the desktop list it is missing from, since that is
      # the list the reader has to look in.
      missing=""
      ((in_kde == 1)) || missing+="kde,"
      ((in_xfce == 1)) || missing+="xfce,"
      ((in_base == 1 || (in_kde == 1 && in_xfce == 1))) ||
        custom_mistagged+="${token}(doc:untagged,lists:${where%,},missing:${missing%,}) "
      ;;
  esac
done <<<"${custom_claims}"

if ((custom_checked >= 40)); then
  pass "the inventory still names packages for these checks to read (${custom_checked})"
else
  fail "the inventory still names packages for these checks to read" \
    "only ${custom_checked} package name(s) were found in ${CUSTOM_DOC}; the two checks below have nothing to compare"
fi

if [[ -z "${custom_uninstalled}" ]]; then
  pass "every package ${CUSTOM_DOC} names is installed by this tree, or the document names what provides it"
else
  fail "every package ${CUSTOM_DOC} names is installed by this tree, or the document names what provides it" \
    "no package list, Containerfile step or Justfile recipe names: ${custom_uninstalled}"
fi

if [[ -z "${custom_shipped_anyway}" ]]; then
  pass "every package ${CUSTOM_DOC} says is not in the image is in no package list"
else
  fail "every package ${CUSTOM_DOC} says is not in the image is in no package list" \
    "a package list installs: ${custom_shipped_anyway}"
fi

if [[ -z "${custom_mistagged}" ]]; then
  pass "every flavor tag in ${CUSTOM_DOC} matches the list the package is in"
else
  fail "every flavor tag in ${CUSTOM_DOC} matches the list the package is in" \
    "the document's opening paragraph says the flavors share everything except where a flavor is called out: ${custom_mistagged}"
fi

# The tags the document uses are the flavors this repo actually builds. A
# third desktop flavor added to the Containerfile and never mentioned here
# leaves the inventory describing an image nobody builds any more.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_flavors="$(grep -oE '\(`(kde|xfce)`' <<<"${custom_bullets}" | tr -d '(`' | sort -u | tr '\n' ' ')"
custom_tree_flavors="$(sed -n 's/^FROM base-core AS \([a-z0-9-]*\).*/\1/p' "${CONTAINERFILE}" |
  grep -vxF base | sort -u | tr '\n' ' ')"
assert_equal "the flavor tags ${CUSTOM_DOC} uses name exactly the desktop flavors the Containerfile builds" \
  "${custom_doc_flavors}" "${custom_tree_flavors}"

# "sharing everything below except where a flavor is called out", read against
# the enablement symlinks: the desktop stages must switch on the same units.
# A unit enabled in one stage and not the other is a difference the document
# does not record, whichever way round it is.
#
# The one difference it does record is the first bullet -- a graphical login
# per flavor -- so each stage's display manager is taken out of the comparison
# and checked on its own terms below. The display manager is identified by the
# alias the stage materializes rather than by name, so renaming one does not
# quietly grow the exception.
#
custom_stage_display_manager() {
  local stage="$1"
  awk -v stage="${stage}" '
    $0 ~ "^FROM base-core AS " stage "$" { inside = 1; next }
    /^FROM / { inside = 0 }
    inside && /\/display-manager\.service/ {
      if (match($0, /system\/[A-Za-z0-9@._-]+ \/usr\/lib\/systemd\/system\/display-manager\.service/)) {
        split(substr($0, RSTART, RLENGTH), parts, " ")
        sub(/.*\//, "", parts[1])
        print parts[1]
      }
    }
  ' "${CONTAINERFILE}" | sort -u | tr '\n' ' '
}

custom_stage_units() {
  local stage="$1"
  local display_manager="$2"
  awk -v stage="${stage}" '
    $0 ~ "^FROM base-core AS " stage "$" { inside = 1; next }
    /^FROM / { inside = 0 }
    inside && /\.wants\// {
      while (match($0, /\.wants\/[A-Za-z0-9@._-]+/)) {
        unit = substr($0, RSTART + 7, RLENGTH - 7)
        print unit
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
  ' "${CONTAINERFILE}" | grep -vxF "${display_manager}" | sort -u | tr '\n' ' '
}

custom_kde_dm="$(custom_stage_display_manager kde)"
custom_xfce_dm="$(custom_stage_display_manager xfce)"
custom_kde_dm="${custom_kde_dm% }"
custom_xfce_dm="${custom_xfce_dm% }"

assert_equal "the two desktop stages enable the same units apart from the graphical login, as ${CUSTOM_DOC} says they share everything untagged" \
  "$(custom_stage_units kde "${custom_kde_dm}")" "$(custom_stage_units xfce "${custom_xfce_dm}")"

# The first bullet is the exception, and it is an exception in both stages:
# each desktop flavor has exactly one display manager, and they are different
# ones. A stage that lost its display manager, or gained a second, would pass
# the comparison above by symmetry alone.
for custom_flavor in kde xfce; do
  custom_flavor_dm="${custom_kde_dm}"
  [[ "${custom_flavor}" == "xfce" ]] && custom_flavor_dm="${custom_xfce_dm}"
  if [[ "${custom_flavor_dm}" =~ ^[A-Za-z0-9@._-]+$ ]]; then
    pass "the ${custom_flavor} stage installs exactly one graphical login (${custom_flavor_dm}), as ${CUSTOM_DOC}'s first bullet says"
  else
    fail "the ${custom_flavor} stage installs exactly one graphical login, as ${CUSTOM_DOC}'s first bullet says" \
      "the stage aliases display-manager.service to: ${custom_flavor_dm:-nothing}"
  fi
done
# The carve-out above is only legitimate while the document still records the
# difference. A bullet that loses its per-flavor tags turns a documented
# difference into an undocumented one, and the comparison would go on
# excusing it.
custom_login_bullet="$(grep -i '^- Graphical login' <<<"${custom_bullets}")"
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_login_tags="$(grep -oE '\(`(kde|xfce)`\)' <<<"${custom_login_bullet}" | tr -d '()`' | sort -u | tr '\n' ' ')"
assert_equal "${CUSTOM_DOC} still calls out a graphical login for each flavor, which is the difference the comparison above excuses" \
  "${custom_login_tags}" "${custom_tree_flavors}"

if [[ -n "${custom_kde_dm}" && "${custom_kde_dm}" != "${custom_xfce_dm}" ]]; then
  pass "the flavors log in through different display managers, which is why ${CUSTOM_DOC} tags that bullet per flavor"
else
  fail "the flavors log in through different display managers, which is why ${CUSTOM_DOC} tags that bullet per flavor" \
    "both stages alias display-manager.service to '''${custom_kde_dm}'''"
fi

# "Root has a default password (`changeme`)": the word in the document is the
# word the Containerfile sets. The expiry and the sshd drop-in are asserted in
# the Root-login group above; what is new here is that this second hand copy of
# the password still matches.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_password="$(grep -oE 'default password \(`[^`]+`\)' "${CUSTOM_DOC}" |
  sed -e 's/.*(`//' -e 's/`)$//')"
custom_tree_password="$(grep -oE "echo '[a-z]+:[^']+' \| chpasswd" "${CONTAINERFILE}" |
  sed -e "s/.*://" -e "s/' | chpasswd//")"
assert_equal "the default root password ${CUSTOM_DOC} quotes is the one the Containerfile sets" \
  "${custom_doc_password}" "${custom_tree_password}"

# "reachable only from a physical console -- SSH (`PermitRootLogin ...`)": the
# setting the document quotes is the setting the drop-in writes, verbatim.
custom_doc_sshd="$(grep -oE 'PermitRootLogin [a-z-]+' "${CUSTOM_DOC}" | sort -u | tr '\n' ' ')"
custom_tree_sshd="$(grep -oE 'PermitRootLogin [a-z-]+' "${CONTAINERFILE}" | sort -u | tr '\n' ' ')"
assert_equal "the sshd setting ${CUSTOM_DOC} quotes is the one the Containerfile writes" \
  "${custom_doc_sshd}" "${custom_tree_sshd}"

# "`nano` removed from the image": removed by name, and absent from every list
# that would put it back.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_removed="$(grep -oE '`[a-z0-9-]+` removed from the image' "${CUSTOM_DOC}" | tr -d '`' | awk '{print $1}')"
if [[ -z "${custom_doc_removed}" ]]; then
  fail "${CUSTOM_DOC} still records which package is removed from the image" \
    "no '\`<package>\` removed from the image' bullet found, so the two checks below have no needle"
else
  assert_present "the package ${CUSTOM_DOC} says is removed is removed by name" \
    "${CONTAINERFILE}" "pacman -Rns[^&]*\b${custom_doc_removed}\b"
  if packages_in "${PACKAGES_BASE}" "${custom_doc_removed}" ||
    packages_in "${PACKAGES_KDE}" "${custom_doc_removed}" ||
    packages_in "${PACKAGES_XFCE}" "${custom_doc_removed}"; then
    fail "the package ${CUSTOM_DOC} says is removed is in no package list" \
      "${custom_doc_removed} is listed for installation, so the removal and the list disagree"
  else
    pass "the package ${CUSTOM_DOC} says is removed is in no package list"
  fi
fi

# "`base-devel` is **not** shipped in the final image": nothing installs it,
# in any list or in any active Containerfile line. The Containerfile carries a
# commented-out recipe for an AUR build that does install it, which is why the
# active-line form matters here.
assert_absent "no active Containerfile line installs base-devel" \
  "${CONTAINERFILE}" 'pacman -S[^|&]*base-devel'
if packages_in "${PACKAGES_BASE}" "base-devel" ||
  packages_in "${PACKAGES_KDE}" "base-devel" ||
  packages_in "${PACKAGES_XFCE}" "base-devel"; then
  fail "base-devel is in no package list, as ${CUSTOM_DOC} says" \
    "a package list installs base-devel, so the final image ships it"
else
  pass "base-devel is in no package list, as ${CUSTOM_DOC} says"
fi

# "only `rust make go-md2man elfutils` are installed for that and removed again
# by name in the same layer": both halves, read as the set the document names.
custom_active_containerfile="$(grep -vE '^[[:space:]]*#' "${CONTAINERFILE}")"
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_builddeps="$(grep -oE '`rust[^`]*`' "${CUSTOM_DOC}" | tr -d '`' | tr ' ' '\n' | sort -u | tr '\n' ' ')"
custom_installed_builddeps="$(grep -oE 'pacman -S --needed --asdeps --noconfirm [a-z0-9 -]+' <<<"${custom_active_containerfile}" |
  sed 's/pacman -S --needed --asdeps --noconfirm //' | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
custom_removed_builddeps="$(grep -oE 'pacman -Rns --noconfirm [a-z0-9 -]+' <<<"${custom_active_containerfile}" |
  sed 's/pacman -Rns --noconfirm //' | tr ' ' '\n' | grep -v '^$' | grep -vxF "${custom_doc_removed:-nano}" |
  sort -u | tr '\n' ' ')"
assert_equal "the build dependencies ${CUSTOM_DOC} names are the ones installed for the bootc build" \
  "${custom_installed_builddeps}" "${custom_doc_builddeps}"
assert_equal "the same set is removed again by name" \
  "${custom_removed_builddeps}" "${custom_doc_builddeps}"

# "zram swap enabled by default (zstd-compressed, sized `min(RAM/2, 4GiB)`)":
# the size expression the document quotes is the one the generator drop-in
# sets, compared with whitespace and unit spelling normalized -- 4GiB there,
# 4096 (MiB) in the config, which is the same number in the units each side
# uses.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_zram="$(grep -oE 'sized `min\([^`]+\)`' "${CUSTOM_DOC}" |
  sed -e 's/.*`min(//' -e 's/)`$//' -e 's/[[:space:]]//g' -e 's|RAM/2|ram/2|' -e 's/4GiB/4096/')"
custom_tree_zram="$(grep -oE 'zram-size = min\([^)]*\)' "${CONTAINERFILE}" |
  sed -e 's/.*min(//' -e 's/)$//' -e 's/[[:space:]]//g')"
assert_equal "the zram size ${CUSTOM_DOC} quotes is the one the generator drop-in sets" \
  "${custom_tree_zram}" "${custom_doc_zram}"
assert_present "zram is compressed with the algorithm ${CUSTOM_DOC} names" \
  "${CONTAINERFILE}" "compression-algorithm = $(grep -oE '[a-z0-9]+-compressed' "${CUSTOM_DOC}" | head -n 1 | sed 's/-compressed//')"

# "`systemd-oomd` tuned with drop-ins (`-.slice`, `user@.service`)": a drop-in
# for each unit the document names, under /usr/lib so a package upgrade cannot
# drop it.
while IFS= read -r custom_oomd_unit; do
  [[ -n "${custom_oomd_unit}" ]] || continue
  assert_present "the ${custom_oomd_unit} drop-in ${CUSTOM_DOC} names is written under /usr/lib" \
    "${CONTAINERFILE}" "/usr/lib/systemd/system/${custom_oomd_unit}\.d/"
done < <(grep -oE 'drop-ins \(`[^)]+\)' "${CUSTOM_DOC}" | tr -d '()`' | sed 's/drop-ins //' | tr ',' '\n' | tr -d ' ')

# "`systemd-networkd-wait-online.service` disabled to avoid startup delays".
#
# The Containerfile masks it, and says in the same breath why: the unit has no
# enablement symlink of its own, so `systemctl disable` against it exits 0 and
# changes nothing. The document's word for that is "disabled", which is what a
# reader wants to know; the check is that the tree still does the thing that
# actually works, and that nobody has since replaced the mask with the no-op
# the Containerfile's comment warns about.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_disabled="$(grep -oE '`systemd-networkd-wait-online\.service` disabled' "${CUSTOM_DOC}" |
  tr -d '`' | awk '{print $1}')"
if [[ -z "${custom_doc_disabled}" ]]; then
  fail "${CUSTOM_DOC} still records which unit is disabled for startup time" \
    "no 'systemd-networkd-wait-online.service disabled' bullet found"
else
  assert_present "the unit ${CUSTOM_DOC} says is disabled is masked, which is what stops it" \
    "${CONTAINERFILE}" "systemctl mask ${custom_doc_disabled}"
  assert_absent "it is not merely disabled, which the Containerfile records as a no-op for this unit" \
    "${CONTAINERFILE}" "systemctl disable[^&]*${custom_doc_disabled}"
fi

# "Printing stack installed and enabled, socket-activated via `cups.socket`":
# the unit the document names is what each desktop stage enables, and the
# service it is deliberately not is enabled nowhere.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_cups="$(grep -oE 'socket-activated via `[a-z.]+`' "${CUSTOM_DOC}" | tr -d '`' | awk '{print $3}')"
if [[ -z "${custom_doc_cups}" ]]; then
  fail "${CUSTOM_DOC} still records which unit socket-activates printing" \
    "no 'socket-activated via \`<unit>\`' clause found"
else
  for custom_flavor in kde xfce; do
    custom_flavor_dm="${custom_kde_dm}"
    [[ "${custom_flavor}" == "xfce" ]] && custom_flavor_dm="${custom_xfce_dm}"
    if grep -qF "${custom_doc_cups}" <<<"$(custom_stage_units "${custom_flavor}" "${custom_flavor_dm}")"; then
      pass "the ${custom_flavor} stage enables the ${custom_doc_cups} the document names"
    else
      fail "the ${custom_flavor} stage enables the ${custom_doc_cups} the document names" \
        "no .wants symlink for ${custom_doc_cups} in the ${custom_flavor} stage"
    fi
  done
  assert_absent "cups.service is never enabled, only the socket the document names" \
    "${CONTAINERFILE}" 'wants/cups\.service'
fi

# The services the document says are "installed and enabled" for every flavor.
# The package name and the unit name differ for two of these (bluez ships
# bluetooth.service, avahi ships avahi-daemon.service), so the pairing is
# spelled out rather than derived -- but each unit is checked in both desktop
# stages, so a service switched on for one desktop only still fails.
for custom_unit in power-profiles-daemon.service bluetooth.service avahi-daemon.service; do
  custom_missing=""
  for custom_flavor in kde xfce; do
    custom_flavor_dm="${custom_kde_dm}"
    [[ "${custom_flavor}" == "xfce" ]] && custom_flavor_dm="${custom_xfce_dm}"
    grep -qF "${custom_unit}" <<<"$(custom_stage_units "${custom_flavor}" "${custom_flavor_dm}")" ||
      custom_missing+="${custom_flavor} "
  done
  if [[ -z "${custom_missing}" ]]; then
    pass "${custom_unit} is enabled in both desktop stages, as ${CUSTOM_DOC} says"
  else
    fail "${custom_unit} is enabled in both desktop stages, as ${CUSTOM_DOC} says" \
      "no enablement symlink in: ${custom_missing}"
  fi
done

# "Network discovery / mDNS configured and enabled (`avahi`, `nss-mdns`)":
# nss-mdns is a resolver plugin, so installing it does nothing until
# nsswitch.conf names it. That edit is the "configured" half of the bullet.
assert_present "nsswitch.conf is edited to resolve mDNS names, which is what nss-mdns needs to do anything" \
  "${CONTAINERFILE}" 'nsswitch\.conf'

# "`NetworkManager` installed and enabled for first-boot DHCP" and "`firewalld`
# installed and enabled": both are base-stage units, so neither appears in the
# per-flavor sets above.
for custom_unit in NetworkManager.service firewalld.service; do
  assert_present "${custom_unit} is enabled, as ${CUSTOM_DOC} says" \
    "${CONTAINERFILE}" "multi-user\.target\.wants/${custom_unit}"
done

# "`cloud-init` installed and enabled, pinned to the NoCloud datasource": the
# datasource the document names is the one the pin sets, and the target is
# actually switched on.
custom_doc_datasource="$(grep -oE 'pinned to the [A-Za-z]+ datasource' "${CUSTOM_DOC}" | awk '{print $4}')"
assert_present "cloud-init is pinned to the datasource ${CUSTOM_DOC} names" \
  "${CONTAINERFILE}" "datasource_list: \[ ${custom_doc_datasource} \]"
assert_present "cloud-init.target is enabled, as ${CUSTOM_DOC} says" \
  "${CONTAINERFILE}" 'multi-user\.target\.wants/cloud-init\.target'

# "`qemu-guest-agent` installed for host-driven VM access (udev-activated only
# when run under QEMU/libvirt)": "udev-activated only" is a claim about what is
# *not* there. Force-enabling it restart-loops on bare metal, which is the
# failure the bullet exists to prevent.
assert_absent "qemu-guest-agent is enabled by no .wants symlink, as ${CUSTOM_DOC} says it is udev-activated" \
  "${CONTAINERFILE}" 'wants/qemu-guest-agent\.service'

# "`sudo` installed, with `wheel` group members granted password-prompted sudo
# via `/etc/sudoers.d/10-wheel`": the path the document names, and the
# "password-prompted" half, which is one NOPASSWD away from being false.
custom_doc_sudoers="$(grep -oE '/etc/sudoers\.d/[0-9a-z-]+' "${CUSTOM_DOC}" | sort -u | head -n 1)"
assert_present "the sudoers drop-in ${CUSTOM_DOC} names is the one the Containerfile writes" \
  "${CONTAINERFILE}" "> ${custom_doc_sudoers}"
assert_present "that drop-in is installed 0440, so visudo and sudo will read it" \
  "${CONTAINERFILE}" "chmod 0440 ${custom_doc_sudoers}"
assert_absent "wheel sudo still prompts for a password, as ${CUSTOM_DOC} says" \
  "${CONTAINERFILE}" 'NOPASSWD'

# "Container images pulled from `ghcr.io/danathar` ... require a valid cosign
# signature": the namespace the document names is the namespace policy.json
# protects. The signature chain itself is asserted in its own group above; what
# is checked here is that the document names the same namespace.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_namespace="$(grep -oE '`ghcr\.io/[a-z0-9-]+`' "${CUSTOM_DOC}" | tr -d '`' | sort -u | head -n 1)"
if command -v jq >/dev/null 2>&1 && jq -e . "${POLICY}" >/dev/null 2>&1; then
  assert_equal "the namespace ${CUSTOM_DOC} says is signature-gated is the one policy.json gates" \
    "${custom_doc_namespace}" \
    "$(jq -r '.transports.docker | keys[]' "${POLICY}" | sort -u | head -n 1)"
else
  fail "the namespace ${CUSTOM_DOC} says is signature-gated is the one policy.json gates" \
    "jq is not on PATH or ${POLICY} is not valid JSON"
fi

# "Local `just build-containerfile` / `build-base` / `build-xfce` (aliases for
# `just build-flavor kde/base/xfce`) use `--security-opt label=disable`": the
# aliases the document pairs with flavors, in the order it pairs them, and the
# flag it quotes.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_recipes="$(grep -oE 'Local `just [a-z-]+`[^(]*\(aliases for `just build-flavor [a-z/]+`\)' "${CUSTOM_DOC}")"
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_alias_names="$(grep -oE '`(just )?build-[a-z-]+`' <<<"${custom_doc_recipes}" |
  tr -d '`' | sed -e 's/^just //' | grep -vxF 'build-flavor')"
custom_alias_flavors="$(grep -oE 'build-flavor [a-z/]+' <<<"${custom_doc_recipes}" |
  sed 's/build-flavor //' | tr '/' '\n')"
if [[ -z "${custom_alias_names}" || -z "${custom_alias_flavors}" ]]; then
  fail "${CUSTOM_DOC} still pairs each local build alias with the flavor it builds" \
    "the 'aliases for \`just build-flavor ...\`' bullet no longer parses, so the checks below have no needles"
else
  custom_alias_index=0
  mapfile -t custom_alias_flavor_list <<<"${custom_alias_flavors}"
  while IFS= read -r custom_alias; do
    [[ -n "${custom_alias}" ]] || continue
    custom_alias_flavor="${custom_alias_flavor_list[${custom_alias_index}]:-}"
    custom_alias_index=$((custom_alias_index + 1))
    assert_present "\`just ${custom_alias}\` builds the ${custom_alias_flavor} flavor ${CUSTOM_DOC} pairs it with" \
      "${JUSTFILE}" "^${custom_alias} .*\(build-flavor \"${custom_alias_flavor}\""
  done <<<"${custom_alias_names}"
fi
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_build_flag="$(grep -oE '`--security-opt [a-z=]+`' "${CUSTOM_DOC}" | tr -d '`' | head -n 1)"
assert_present "the local build passes the flag ${CUSTOM_DOC} quotes" \
  "${JUSTFILE}" "${custom_doc_build_flag}"

# --- Upstream Bootcrew Compatibility Work ---
#
# The second half of the document lists the bootstrapping steps that make an
# Arch container behave like a bootc image, and ends by saying that removing
# any of them may break `bootc install/switch`. Each step below is read out of
# that section.

custom_upstream="$(awk '
  /^## Upstream Bootcrew Compatibility Work/ { inside = 1; next }
  /^## / { inside = 0 }
  inside { print }
' "${CUSTOM_DOC}")"

# "bootc is built from upstream source (`https://...`) during image build":
# the URL the document quotes is the one the build clones. The tag and commit
# pins are asserted in the bootc provenance group above and are deliberately
# not restated here -- they move on every upstream release, the document does
# not quote them, and a check that reads a version out of this file would fail
# every time Renovate does its job.
custom_doc_bootc_url="$(grep -oE 'https://github\.com/[a-z0-9./-]+\.git' <<<"${custom_upstream}" | sort -u | head -n 1)"
assert_present "bootc is cloned from the repository ${CUSTOM_DOC} names" \
  "${CONTAINERFILE}" "git clone .*${custom_doc_bootc_url//./\\.}"

# "pacman `/var` paths are relocated into `/usr/lib/sysimage`"
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_sysimage="$(grep -oE '`/usr/lib/[a-z]+`' <<<"${custom_upstream}" | tr -d '`' | sort -u | head -n 1)"
assert_present "pacman's paths are relocated into the directory ${CUSTOM_DOC} names" \
  "${CONTAINERFILE}" "= ${custom_doc_sysimage}"

# "`NoExtract` rules are disabled so language/help content can be installed"
assert_present "the NoExtract rules ${CUSTOM_DOC} names are commented out of pacman.conf" \
  "${CONTAINERFILE}" 'NoExtract'

# "`glibc` is explicitly named alongside the other base packages in the main
# install step" -- the whole point is that it is a literal target on the
# pacman line rather than a line in packages-base.txt, so this reads the
# Containerfile's install step and not the list.
assert_present "glibc is an explicit target of the base install, as ${CUSTOM_DOC} says" \
  "${CONTAINERFILE}" 'pacman -Syu --noconfirm glibc'

# "Initramfs and boot integration are prepared with `dracut` config for
# `ostree` + `bootc` modules."
assert_present "the dracut config adds the initramfs modules ${CUSTOM_DOC} names" \
  "${CONTAINERFILE}" 'add_dracutmodules\+=" ostree bootc "'

# "Bootc/ostree filesystem layout and symlink structure is enforced
# (`/sysroot`, `/ostree`, `/var/home`, etc.) with composefs enabled."
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_layout_paths="$(grep -oE 'symlink structure is enforced \([^)]*\)' <<<"${custom_upstream}" |
  grep -oE '`/[a-z/]+`' | tr -d '`')"
while IFS= read -r custom_layout_path; do
  [[ -n "${custom_layout_path}" ]] || continue
  assert_present "the layout path ${CUSTOM_DOC} names (${custom_layout_path}) is created or linked" \
    "${CONTAINERFILE}" "${custom_layout_path}"
done < <(printf '%s\n' "${custom_layout_paths}")
assert_present "composefs is enabled, as ${CUSTOM_DOC} says" \
  "${CONTAINERFILE}" '\[composefs\]'

# "Required metadata label is set for bootc-compatible images:
# `containers.bootc=1`."
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
custom_doc_label="$(grep -oE '`containers\.bootc=[0-9]+`' <<<"${custom_upstream}" | tr -d '`' | head -n 1)"
assert_present "the metadata label ${CUSTOM_DOC} names is set on the image" \
  "${CONTAINERFILE}" "LABEL ${custom_doc_label/=/ }"

fi

# ---------------------------------------------------------------------------
group "Quality signals (docs/quality.md: 'a green check here means something specific and narrower than \"it works\"')"

# docs/quality.md is the inventory of every automated signal this repository
# produces, what each one proves, and -- the part that decays fastest -- where
# the gaps are. README.md's documentation table, CONTRIBUTING.md, docs/ci-cd.md,
# docs/metrics.md and docs/risk-tiers.md all send a reader here, and two groups
# far above quote it in their own titles. Nothing read it.
#
# A stale line in this document is worse than a stale line in a runbook. A
# runbook that names a missing flag fails in the reader's hands. This document
# is consulted to decide whether something needs a test at all, so a claim that
# a path is already covered stops work, and a claim that a path is uncovered
# sends somebody to write a second copy of a test that exists. Both had already
# happened: the "Where the gaps are" section said three workflow `run:` bodies
# were executed by tests and named the `signatures` job's verification step and
# `build.yml`'s `build_push` steps as executed by nothing, months after
# tests/test-nightly-compliance.sh started executing both.
#
# Every assertion below runs in the same direction as the other document joins
# in this file: take the identifier out of the prose and compare it with the
# thing in the tree it is a hand copy of. What is new here is the direction of
# the coverage claims -- the classification of workflow bodies is computed from
# the tree and compared with the document's list, so a body that gains or loses
# a test fails this group until the sentence is rewritten.
#
# What is deliberately not asserted, rather than left to be assumed: the
# traced-line counts the document quotes for two Bash versions (117 and 116
# lines of ostree-pkg-diff) are properties of an interpreter, not of this tree,
# and reproducing them needs both interpreters installed. The percentages, the
# history of which file went ungated in CI, and every sentence about what a
# signal does *not* prove are judgements, not identifiers.

QUALITY_DOC="docs/quality.md"
TUNING_POLICY=".github/auto-qa-tuning.json"
LABELER_CONFIG=".github/labeler.yml"
ZIZMOR_WORKFLOW=".github/workflows/zizmor.yaml"
NIGHTLY_WORKFLOW=".github/workflows/nightly-compliance.yml"

if [[ ! -f "${QUALITY_DOC}" ]]; then
  fail "the quality signals document exists" \
    "${QUALITY_DOC} is missing; README.md's documentation table and CONTRIBUTING.md both send a reader to it"
else

shopt -s nullglob
quality_workflows=(.github/workflows/*.yml .github/workflows/*.yaml)
quality_test_files=(tests/*.sh tests/e2e/*.sh)
shopt -u nullglob

# The job names of one workflow, from the mapping under `jobs:` only. Trigger
# keys (`pull_request:`, `push:`) sit at the same indent under `on:`, so
# matching two-space keys anywhere in the file would accept a job name that is
# really a trigger.
quality_job_names() {
  awk '
    /^jobs:$/ { in_jobs = 1; next }
    /^[A-Za-z_]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ { print substr($0, 3, length($0) - 3) }
  ' "$1"
}

# Every step name in one workflow, and separately the names of the steps that
# carry a `run:` body. The second list is what the coverage claims are about:
# a step that runs an action has no shell of its own for a test to execute.
quality_step_names() {
  awk '/^      - name: / { print substr($0, 15) }' "$1"
}

quality_run_step_names() {
  awk '
    /^      - name: / { step = substr($0, 15); next }
    /^        run:/ { if (step != "") { print step; step = "" } }
  ' "$1"
}

# The items of a block sequence introduced by KEY at four-space indent, for the
# `paths-ignore:`/`paths:` lists under a trigger. Each occurrence is printed as
# its own record so the pull_request and push copies can be compared separately
# -- a paths filter that is right on one trigger and wrong on the other is the
# failure this document's "that touch code" paragraph is about.
quality_yaml_seq() {
  awk -v key="$1" '
    $0 == "    " key ":" { grab = 1; n = 1; next }
    grab && /^      - / {
      item = substr($0, 9)
      gsub(/^"|"$|^'"'"'|'"'"'$/, "", item)
      printf "%s ", item
      next
    }
    grab { grab = 0; printf "\n" }
    END { if (grab) printf "\n" }
  ' "$2"
}

# An identifier read out of the document, compared with the tree. An identifier
# that has vanished from *both* sides is a failure, not a match: "" == "" is
# exactly the silent pass these joins exist to prevent.
assert_quality_needle() {
  local description="$1" needle="$2" haystack="$3" where="$4"
  if [[ -z "${needle}" ]]; then
    fail "${description}" "${QUALITY_DOC} no longer names it"
  elif grep -Fq -- "${needle}" <<<"${haystack}"; then
    pass "${description}"
  else
    fail "${description}" "${where} has no such line: ${needle}"
  fi
}

# The document as one line, for the guardrail section below. Its bullets wrap
# mid-command -- `buildah rm\n  --all` -- so a phrase looked for in the file as
# written is missed for a reason that has nothing to do with what it says.
quality_doc_flat="$(tr '\n' ' ' <"${QUALITY_DOC}" | tr -s ' ')"

# A permission the guardrail section attributes to one of
# .claude/settings.json's three arrays. Both sides are checked, and they are
# spelled separately on purpose: the document describes the command in prose
# ("workflow dispatch", "secret set") while the rule carries the tool wrapper
# and the glob (`Bash(gh workflow run*)`). Requiring the document's own wording
# is what makes a deleted sentence fail here rather than pass quietly.
assert_quality_permission() {
  local description="$1" phrase="$2" token="$3" rules="$4" array="$5"
  if ! grep -Fq -- "${phrase}" <<<"${quality_doc_flat}"; then
    fail "${description}" "${QUALITY_DOC} no longer says '${phrase}'"
  elif grep -Fq -- "${token}" <<<"${rules}"; then
    pass "${description}"
  else
    fail "${description}" "no ${array} rule in ${CLAUDE_SETTINGS} carries: ${token}"
  fi
}

# --- The document is still reachable ----------------------------------------

assert_present "README.md's documentation table still links to the quality signals document" \
  "README.md" '\]\(docs/quality\.md\)'

assert_present "CONTRIBUTING.md still sends a contributor to it" \
  "CONTRIBUTING.md" 'docs/quality\.md'

assert_present "it still hands the process metrics off to docs/metrics.md" \
  "${QUALITY_DOC}" '\]\(metrics\.md\)'

assert_present "docs/metrics.md still hands the automated signals back to it" \
  "docs/metrics.md" '\]\(quality\.md\)'

assert_doc_links_resolve "${QUALITY_DOC}" \
  "no relative links found; the hand-off to ci-cd.md, renovate.md, metrics.md and the tuning policy is gone"

# --- The dashboard table names jobs, steps and workflows that exist ----------
#
# "The signals live where they are produced": every row's middle column points
# at a job, a step or a workflow by name. A renamed job leaves the row pointing
# at nothing, and the reader concludes the signal was removed. The rows are read
# out of the document rather than restated here, so a new signal is checked the
# moment somebody adds its row.

quality_table="$(awk '
  /^\| Signal \| Where to see it \| Runs on \|/ { in_table = 1; next }
  in_table && /^\| *-+ *\|/ { next }
  in_table && /^\|/ { print; next }
  in_table { exit }
' "${QUALITY_DOC}")"

quality_table_rows="$(grep -c '^|' <<<"${quality_table}" || true)"
[[ -n "${quality_table}" ]] || quality_table_rows=0
if ((quality_table_rows >= 10)); then
  pass "the dashboard table still lists the signals (${quality_table_rows} rows)"
else
  fail "the dashboard table still lists the signals" \
    "found ${quality_table_rows} rows under '| Signal | Where to see it | Runs on |'; the table has moved or been reworded"
fi

quality_pointers_checked=0
while IFS= read -r quality_row; do
  [[ -n "${quality_row}" ]] || continue
  quality_where="$(awk -F'|' '{print $3}' <<<"${quality_row}")"
  # A cell can name a step in one workflow and a job in another, separated by
  # a semicolon. Each clause carries its own workflow, so they are resolved
  # one at a time rather than against the union.
  while IFS= read -r quality_clause; do
    [[ -n "${quality_clause}" ]] || continue
    quality_files=()
    if [[ "${quality_clause}" == *"nightly workflow"* ]]; then
      quality_files=("${NIGHTLY_WORKFLOW}")
    elif [[ "${quality_clause}" == *"build workflow"* ]]; then
      quality_files=("${BUILD_WORKFLOW}")
    else
      quality_files=("${quality_workflows[@]+"${quality_workflows[@]}"}")
    fi
    # shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
    while IFS= read -r quality_pointer; do
      [[ -n "${quality_pointer}" ]] || continue
      quality_kind="${quality_pointer##* }"
      quality_name="${quality_pointer%\` *}"
      quality_name="${quality_name#\`}"
      [[ -n "${quality_name}" ]] || continue
      quality_found=""
      for quality_file in "${quality_files[@]+"${quality_files[@]}"}"; do
        case "${quality_kind}" in
          job)
            grep -qxF -- "${quality_name}" <<<"$(quality_job_names "${quality_file}")" && quality_found="${quality_file}"
            ;;
          step)
            grep -qxF -- "${quality_name}" <<<"$(quality_step_names "${quality_file}")" && quality_found="${quality_file}"
            ;;
          workflow)
            grep -qxF -- "name: ${quality_name}" "${quality_file}" && quality_found="${quality_file}"
            ;;
        esac
        [[ -n "${quality_found}" ]] && break
      done
      quality_pointers_checked=$((quality_pointers_checked + 1))
      if [[ -n "${quality_found}" ]]; then
        pass "the ${quality_kind} the dashboard sends a reader to exists: ${quality_name} (${quality_found##*/})"
      else
        fail "the ${quality_kind} the dashboard sends a reader to exists: ${quality_name}" \
          "no ${quality_kind} of that name in ${quality_files[*]}"
      fi
    done < <(grep -oE '`[^`]+` (job|step|workflow)' <<<"${quality_clause}")
  done < <(tr ';' '\n' <<<"${quality_where}")
done < <(printf '%s\n' "${quality_table}")

if ((quality_pointers_checked >= 8)); then
  pass "the dashboard's pointers were read out of the table (${quality_pointers_checked} of them)"
else
  fail "the dashboard's pointers were read out of the table" \
    "only ${quality_pointers_checked} were found; the middle column no longer names its jobs and steps in backticks, so the checks above proved nothing"
fi

# The on-demand row is the one pointer that names a script rather than a job.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
quality_review_state="$(grep -oE '`\./scripts/[a-z-]+\.sh`' <<<"${quality_table}" | tr -d '`' | head -n 1)"
if [[ -z "${quality_review_state}" ]]; then
  fail "the review-state script the dashboard names exists" "${QUALITY_DOC} no longer names it"
elif [[ -x "${quality_review_state#./}" ]]; then
  pass "the review-state script the dashboard names exists and is executable: ${quality_review_state}"
else
  fail "the review-state script the dashboard names exists and is executable" \
    "${quality_review_state} is missing or not executable"
fi

# "embedded in the `ai-fix-requested` work order" -- the label that reaches it.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
quality_ai_label="$(grep -oE '`ai-fix-requested`' <<<"${quality_table}" | tr -d '`' | head -n 1)"
assert_quality_needle "the label the dashboard says carries the review state still triggers ai-fix.yml" \
  "${quality_ai_label}" "$(cat .github/workflows/ai-fix.yml)" ".github/workflows/ai-fix.yml"

assert_present "the work order the dashboard names still runs that script" \
  ".github/workflows/ai-fix.yml" "${quality_review_state:-scripts/pr-review-state.sh}"

# --- "that touch code" is load-bearing --------------------------------------
#
# The paragraph under the table quotes build.yml's paths-ignore list and draws
# the conclusion a reader acts on: a pull request showing no checks was skipped,
# not validated. Three copies of that list exist -- the document's, the
# workflow's two triggers, and the labeler rule that puts a `documentation`
# label on exactly the pull requests the workflow skips. All three must agree,
# or the label asserts that no build ran on a pull request that built.

quality_doc_ignores="$(grep -oE 'paths-ignore: \[[^]]*\]' "${QUALITY_DOC}" | head -n 1 |
  grep -oE '"[^"]+"' | tr -d '"' | sort | tr '\n' ' ')"
if [[ -z "${quality_doc_ignores}" ]]; then
  fail "the document still quotes the build workflow's paths-ignore list" \
    "no 'paths-ignore: [...]' in ${QUALITY_DOC}; the 'that touch code' paragraph is what this group compares against"
else
  pass "the document still quotes the build workflow's paths-ignore list: ${quality_doc_ignores}"

  quality_ignore_blocks=0
  while IFS= read -r quality_ignore_block; do
    [[ -n "${quality_ignore_block}" ]] || continue
    quality_ignore_blocks=$((quality_ignore_blocks + 1))
    assert_equal "build.yml's paths-ignore filter #${quality_ignore_blocks} is the list ${QUALITY_DOC} quotes" \
      "$(tr ' ' '\n' <<<"${quality_ignore_block}" | grep -v '^$' | sort | tr '\n' ' ')" \
      "${quality_doc_ignores}"
  done < <(quality_yaml_seq paths-ignore "${BUILD_WORKFLOW}")

  # Both triggers, not one. `pull_request` alone would still skip the build on
  # a documentation PR while a push to main built it, which is the opposite of
  # what the paragraph tells a reader to expect from the daily schedule.
  assert_equal "both of build.yml's triggers carry that filter" \
    "${quality_ignore_blocks}" "2"

  # The labeler's `documentation` rule is the third copy. Its own comment says
  # it is applied under "exactly the condition under which build.yml's
  # paths-ignore skips the whole build", which is the claim the table's last
  # row repeats -- a label that "marks a PR no build ran on".
  quality_label_globs="$(awk '
    /^documentation:$/ { grab = 1; next }
    grab && /^[A-Za-z]/ { exit }
    grab && /^ *- "/ { item = $0; sub(/^ *- "/, "", item); sub(/"$/, "", item); print item }
  ' "${LABELER_CONFIG}" | sort | tr '\n' ' ')"
  assert_equal "the paths the documentation label covers are the paths the build skips" \
    "${quality_label_globs}" "${quality_doc_ignores}"
fi

# "Workflow static analysis (zizmor) | ... | Any change under `.github/workflows/**`"
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
quality_zizmor_paths="$(grep -oE '`\.github/workflows/\*\*`' <<<"${quality_table}" | tr -d '`' | head -n 1)"
if [[ -z "${quality_zizmor_paths}" ]]; then
  fail "the dashboard still says what zizmor runs on" "${QUALITY_DOC} no longer names the path filter"
else
  quality_zizmor_blocks=0
  while IFS= read -r quality_zizmor_block; do
    [[ -n "${quality_zizmor_block}" ]] || continue
    quality_zizmor_blocks=$((quality_zizmor_blocks + 1))
    assert_equal "zizmor trigger #${quality_zizmor_blocks} runs on the paths ${QUALITY_DOC} names" \
      "$(tr -d ' ' <<<"${quality_zizmor_block}")" "${quality_zizmor_paths}"
  done < <(quality_yaml_seq paths "${ZIZMOR_WORKFLOW}")
  assert_equal "both of the workflow linter's triggers carry that filter" \
    "${quality_zizmor_blocks}" "2"
fi

# "plus a daily schedule" -- a cron that is not daily makes the sentence above
# it ("only the daily schedule and the next code change will exercise those
# paths again") the wrong advice about how long an unbuilt path stays unbuilt.
quality_build_cron="$(grep -oE 'cron: "[^"]+"' "${BUILD_WORKFLOW}" | head -n 1 | sed -E 's/.*"(.*)"/\1/')"
if [[ "${quality_build_cron}" =~ ^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*$ ]]; then
  pass "the build workflow's schedule is daily, as the dashboard says (${quality_build_cron})"
else
  fail "the build workflow's schedule is daily, as the dashboard says" \
    "cron is '${quality_build_cron}'; the table's 'plus a daily schedule' no longer describes it"
fi

# "The README badge tracks the build workflow on `main`."
assert_present "the README badge tracks the build workflow on main" \
  "README.md" 'workflows/build\.yml/badge\.svg\?branch=main' \
  "the badge no longer names build.yml, or no longer pins the branch the document says it tracks"

# --- The coverage gate and its tuning policy --------------------------------

# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
quality_thresholds="$(grep -oE '`\.coverage-thresholds\.json`' "${QUALITY_DOC}" | tr -d '`' | head -n 1)"
if [[ -z "${quality_thresholds}" ]]; then
  fail "the document still names the file the floors live in" "no .coverage-thresholds.json in ${QUALITY_DOC}"
elif [[ -f "${quality_thresholds}" ]]; then
  pass "the floors file the document names exists: ${quality_thresholds}"
else
  fail "the floors file the document names exists" "no such file: ${quality_thresholds}"
fi

assert_quality_needle "the coverage gate reads the floors file the document names" \
  "${quality_thresholds}" "$(cat tests/check-coverage.sh)" "tests/check-coverage.sh"

# "The gate also fails when a new executable Bash entry point under `scripts/`
# or the shipped `usr/bin` / `usr/libexec` paths has no floor" -- the sweep is
# what makes the floors a manifest of the image rather than of whatever the
# suite happened to touch, so each root the sentence names is checked.
quality_cov_roots="$(awk '
  /^production_roots=\(/ { grab = 1; next }
  grab && /^\)/ { exit }
  grab { gsub(/[ "]/, ""); print }
' tests/check-coverage.sh)"
quality_sweep_roots=0
for quality_root in scripts/ usr/bin usr/libexec; do
  grep -Fq -- "${quality_root}" "${QUALITY_DOC}" || continue
  quality_sweep_roots=$((quality_sweep_roots + 1))
  if grep -q -- "/${quality_root%/}\$" <<<"${quality_cov_roots}"; then
    pass "the entry-point sweep covers ${quality_root}, as ${QUALITY_DOC} says"
  else
    fail "the entry-point sweep covers ${quality_root}, as ${QUALITY_DOC} says" \
      "no root in tests/check-coverage.sh's production_roots ends in ${quality_root%/}: ${quality_cov_roots//$'\n'/ | }"
  fi
done
assert_equal "all three entry-point roots the document names were checked" \
  "${quality_sweep_roots}" "3"

if [[ ! -f "${TUNING_POLICY}" ]]; then
  fail "the tuning policy the document links exists" "no such file: ${TUNING_POLICY}"
elif ! command -v jq >/dev/null 2>&1; then
  fail "jq is available to read ${TUNING_POLICY}" "jq is not on PATH"
else
  assert_present "the document still links the policy as the place the reasoning lives" \
    "${QUALITY_DOC}" '\]\(\.\./\.github/auto-qa-tuning\.json\)'

  # The policy's own comment points back here. Two documents that name each
  # other stay joined; one that stops being named is the one that goes stale.
  assert_present "the policy still names ${QUALITY_DOC} as its prose half" \
    "${TUNING_POLICY}" 'docs/quality\.md'

  assert_equal "the floors file the policy governs is the one the document names" \
    "$(jq -r '.coverage.thresholdsFile // ""' "${TUNING_POLICY}")" "${quality_thresholds}"

  # "**It raises and never lowers,** and the asymmetry is deliberate"
  assert_equal "the policy is still raise-only, as the document says" \
    "$(jq -r '.coverage.direction // ""' "${TUNING_POLICY}")" "raise-only"

  # "`--apply` is refused unless every version in the policy's `supportedBash`
  # list has been observed." Three halves: the document names the key, the
  # policy carries a non-empty list, and the tool reads that key from that file.
  # shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
  quality_supported_key="$(grep -oE '`supportedBash`' "${QUALITY_DOC}" | tr -d '`' | head -n 1)"
  if [[ -z "${quality_supported_key}" ]]; then
    fail "the document still names the list --apply is gated on" "no supportedBash in ${QUALITY_DOC}"
  else
    quality_supported="$(jq -r ".coverage.${quality_supported_key}[]? // empty" "${TUNING_POLICY}" | tr '\n' ' ')"
    if [[ -n "${quality_supported}" ]]; then
      pass "the policy lists the Bash versions --apply is gated on: ${quality_supported}"
    else
      fail "the policy lists the Bash versions --apply is gated on" \
        "${TUNING_POLICY} has no non-empty coverage.${quality_supported_key}; the gate the document describes would have nothing to require"
    fi
    assert_quality_needle "tests/tune-coverage.sh reads that list out of the policy" \
      "${quality_supported_key}" "$(cat tests/tune-coverage.sh)" "tests/tune-coverage.sh"
  fi

  assert_present "tune-coverage.sh reads the policy file the document links" \
    "tests/tune-coverage.sh" 'auto-qa-tuning\.json'

  assert_present "tune-coverage.sh refuses --apply without an observation from every supported version" \
    "tests/tune-coverage.sh" 'needs an observation from every supported Bash version' \
    "the refusal the document calls mechanical is gone, which puts the calibration rule back in prose only"
fi

# "Nothing runs it on a schedule. It is operator-run." The tool appears in the
# workflows exactly once, as an operand of the ShellCheck step -- being linted
# is not being run. Any other mention is a scheduled quality gate adjusting
# itself, which is the decision the gate exists to force.
quality_tune_mentions=0
for quality_workflow in "${quality_workflows[@]+"${quality_workflows[@]}"}"; do
  quality_tune_mentions=$((quality_tune_mentions + $(grep -c 'tune-coverage\.sh' "${quality_workflow}" || true)))
done
quality_tune_linted="$(awk '
  /^      - name: ShellCheck$/ { grab = 1; next }
  grab && /^      - name: / { exit }
  grab { print }
' "${BUILD_WORKFLOW}" | grep -c 'tune-coverage\.sh' || true)"
assert_equal "every workflow mention of tune-coverage.sh is the ShellCheck step linting it, not CI running it" \
  "${quality_tune_mentions}" "${quality_tune_linted}"

quality_tune_apply=""
for quality_workflow in "${quality_workflows[@]+"${quality_workflows[@]}"}"; do
  while IFS= read -r quality_hit; do
    quality_tune_apply+="${quality_workflow}:${quality_hit} "
  done < <(grep -n 'tune-coverage\.sh[^|;&]*--apply' "${quality_workflow}")
done
if [[ -z "${quality_tune_apply}" ]]; then
  pass "no workflow writes a coverage floor with --apply"
else
  fail "no workflow writes a coverage floor with --apply" "${quality_tune_apply}"
fi

# --- Agent guardrails -------------------------------------------------------
#
# The "Agent guardrails" section is a hand copy of .claude/settings.json's three
# permission arrays, and it is read by somebody deciding whether a mistake is
# already fenced off. A command the document says is denied and that no rule
# denies is the one shape of drift that costs something real, so every command
# spelling the section quotes is looked for in the array it is attributed to.

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is available to read ${CLAUDE_SETTINGS}" \
    "jq is not on PATH, so the guardrail section could not be joined to the settings file"
else
  quality_deny="$(jq -r '.permissions.deny[]?' "${CLAUDE_SETTINGS}")"
  quality_ask="$(jq -r '.permissions.ask[]?' "${CLAUDE_SETTINGS}")"
  quality_allow="$(jq -r '.permissions.allow[]?' "${CLAUDE_SETTINGS}")"

  # Each entry is the document's own wording, then the rule spelling it has to
  # be carried by.
  while IFS='|' read -r quality_phrase quality_token; do
    [[ -n "${quality_phrase}" ]] || continue
    assert_quality_permission "the document's denied list still matches a deny rule: ${quality_phrase}" \
      "${quality_phrase}" "${quality_token}" "${quality_deny}" "deny"
  done <<'QUALITY_DENY_CLAIMS'
cosign.key|Read(./cosign.key)
podman system prune|Bash(podman system prune
rm -a|Bash(podman rm -a
rmi -a|Bash(podman rmi -a
buildah rm --all|Bash(buildah rm --all
snapshot-delete|snapshot-delete
reset --hard|Bash(git reset --hard
clean|Bash(git clean
stash|Bash(git stash
QUALITY_DENY_CLAIMS

  # The verb families the section names by fragment rather than in full, each
  # checked against the deny rules for the shared connection only.
  for quality_denied_verb in "destroy" "undefine" "pool-" "vol-" "net-"; do
    assert_quality_permission "the irreversible verb the document names is denied on qemu:///system: ${quality_denied_verb}" \
      "${quality_denied_verb}" "${quality_denied_verb}" \
      "$(grep -F 'qemu:///system' <<<"${quality_deny}")" "deny"
  done

  while IFS='|' read -r quality_phrase quality_token; do
    [[ -n "${quality_phrase}" ]] || continue
    assert_quality_permission "the document's prompted list still matches an ask rule: ${quality_token}" \
      "${quality_phrase}" "${quality_token}" "${quality_ask}" "ask"
  done <<'QUALITY_ASK_CLAIMS'
sudo|Bash(sudo
just lint|Bash(just lint)
virt-install|Bash(virt-install
virsh|Bash(virsh
everything else on `qemu:///system`|Bash(virsh -c qemu:///system *)
branch, commit, push|Bash(git branch
branch, commit, push|Bash(git commit
branch, commit, push|Bash(git push
PR create/edit/merge|Bash(gh pr create
PR create/edit/merge|Bash(gh pr edit
PR create/edit/merge|Bash(gh pr merge
workflow dispatch|Bash(gh workflow run
secret set|Bash(gh secret set
QUALITY_ASK_CLAIMS

  # "`git restore` and `git checkout --` prompt rather than deny", because
  # AGENTS.md names restoring files a failed bind-mount deleted as *the*
  # documented correction. A rule that moved to `deny` blocks the only
  # sanctioned repair while this paragraph still says it is available.
  for quality_prompted in "git restore" "git checkout --"; do
    assert_quality_permission "the recovery the document says prompts is in ask: ${quality_prompted}" \
      "${quality_prompted}" "${quality_prompted}" "${quality_ask}" "ask"
    if grep -Fq -- "${quality_prompted}" <<<"${quality_deny}"; then
      fail "the recovery the document says prompts is not denied: ${quality_prompted}" \
        "a deny rule carries it, so the correction AGENTS.md names cannot be made"
    else
      pass "the recovery the document says prompts is not denied: ${quality_prompted}"
    fi
  done

  # "**Allowed** -- the non-privileged test suite ..." and the manifest
  # paragraph further up, which is the whole reason tests/test-manifest exists.
  for quality_allowed in "./tests/run-tests.sh" "just test" "shellcheck" "bash -n"; do
    assert_quality_permission "the document's allowed list still matches an allow rule: ${quality_allowed}" \
      "${quality_allowed}" "${quality_allowed}" "${quality_allow}" "allow"
  done

  # "the read-only VM/pool name inventories on **both** libvirt connections".
  # The point of allowing the system connection's inventory is that CLAUDE.md
  # requires inventorying both before picking a test VM name; losing one turns
  # that preflight into a prompt an agent is invited to work around.
  for quality_connection in "qemu:///session" "qemu:///system"; do
    for quality_inventory in "list --all --name" "pool-list --all --name"; do
      if grep -F "${quality_connection}" <<<"${quality_allow}" | grep -Fq -- "${quality_inventory}"; then
        pass "the read-only inventory the document allows on both connections is allowed: ${quality_connection} ${quality_inventory}"
      else
        fail "the read-only inventory the document allows on both connections is allowed: ${quality_connection} ${quality_inventory}" \
          "no allow rule carries it"
      fi
    done
  done

  # "Two knobs deliberately left unset, because they are the repository owner's
  # call": a knob that acquired a value is a decision this document says nobody
  # made.
  for quality_knob in defaultMode disableBypassPermissionsMode; do
    if ! grep -Fq -- "permissions.${quality_knob}" "${QUALITY_DOC}"; then
      fail "the document still says permissions.${quality_knob} is left unset" \
        "${QUALITY_DOC} no longer names it"
    elif [[ "$(jq -r ".permissions.${quality_knob} // \"unset\"" "${CLAUDE_SETTINGS}")" == "unset" ]]; then
      pass "permissions.${quality_knob} is still unset, as the document says"
    else
      fail "permissions.${quality_knob} is still unset, as the document says" \
        "${CLAUDE_SETTINGS} now sets it to $(jq -r ".permissions.${quality_knob}" "${CLAUDE_SETTINGS}")"
    fi
  done
fi

# --- Where the gaps are -----------------------------------------------------
#
# The gaps section is the half a reader acts on when deciding what to write
# next, and the half that goes stale silently: closing a gap does not fail
# anything, so the sentence describing it survives the work that ended it.

# "No CI job boots the image." Every other claim in this document is about
# something that exists; this one is about something that must not.
quality_boot_hits=""
for quality_workflow in "${quality_workflows[@]+"${quality_workflows[@]}"}"; do
  while IFS= read -r quality_hit; do
    quality_boot_hits+="${quality_workflow}:${quality_hit} "
  done < <(grep -nE 'virt-install|qemu-system|bootc install' "${quality_workflow}" | grep -v '^[0-9]*:[[:space:]]*#')
done
if [[ -z "${quality_boot_hits}" ]]; then
  pass "no CI job boots or installs the image, as the gaps section says"
else
  fail "no CI job boots or installs the image, as the gaps section says" \
    "the largest stated gap has been closed and the document still calls it open: ${quality_boot_hits}"
fi

# "PR builds additionally skip the rechunk, push, and sign steps, so a green PR
# check exercises less than a push to `main` does" -- and the signature row of
# the dashboard says the same thing about signing ("Pushes to `main` only").
for quality_gated_step in "Rechunk image with chunkah" "Push To GHCR" "Sign container image"; do
  quality_step_if="$(awk -v want="${quality_gated_step}" '
    /^      - name: / { step = substr($0, 15); next }
    step == want && /^        if: / { print substr($0, 13); exit }
  ' "${BUILD_WORKFLOW}")"
  if [[ "${quality_step_if}" == *"!= 'pull_request'"* && "${quality_step_if}" == *"default_branch"* ]]; then
    pass "a pull request build skips the step the document says it skips: ${quality_gated_step}"
  else
    fail "a pull request build skips the step the document says it skips: ${quality_gated_step}" \
      "its condition is '${quality_step_if}'; a green PR check would now exercise it"
  fi
done

# The workflow-body coverage claim, computed rather than restated.
#
# A step's body counts as lifted when some test file names that step, quoted,
# the way every test that executes one does: the name is what `workflow_step_run`
# is handed, so a test that stopped naming it stopped running it. The comparison
# runs in both directions -- a body that gains a test and a body that loses one
# both fail here until the sentence is rewritten, which is the failure this
# document did not have when it spent months claiming three bodies were covered
# and naming two covered ones as uncovered.

quality_bodies_bullet="$(awk '
  /^- \*\*Most workflow `run:` bodies/ { grab = 1; print; next }
  grab && (/^- \*\*/ || /^#/) { exit }
  grab { print }
' "${QUALITY_DOC}" | tr '\n' ' ')"

if [[ -z "${quality_bodies_bullet}" ]]; then
  fail "the gaps section still classifies the workflow run: bodies" \
    "no bullet starting '- **Most workflow \`run:\` bodies' in ${QUALITY_DOC}"
else
  quality_unlifted_claim="${quality_bodies_bullet#*No test lifts these bodies at all: }"
  quality_unlifted_claim="${quality_unlifted_claim%%One more*}"
  # shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
  quality_claimed_unlifted="$(grep -oE '`[^`]+`' <<<"${quality_unlifted_claim}" | tr -d '`' | sort -u)"

  # Every step name in every workflow that carries a run: body, and whether any
  # test file names it.
  quality_all_bodies=""
  for quality_workflow in "${quality_workflows[@]+"${quality_workflows[@]}"}"; do
    quality_all_bodies+="$(quality_run_step_names "${quality_workflow}")"$'\n'
  done
  quality_all_bodies="$(grep -v '^$' <<<"${quality_all_bodies}" | sort -u)"

  quality_computed_unlifted=""
  while IFS= read -r quality_body; do
    [[ -n "${quality_body}" ]] || continue
    quality_named=""
    for quality_test_file in "${quality_test_files[@]+"${quality_test_files[@]}"}"; do
      if grep -qF -- "\"${quality_body}\"" "${quality_test_file}" ||
        grep -qF -- "'${quality_body}'" "${quality_test_file}"; then
        quality_named="yes"
        break
      fi
    done
    [[ -n "${quality_named}" ]] || quality_computed_unlifted+="${quality_body}"$'\n'
  done <<<"${quality_all_bodies}"
  quality_computed_unlifted="$(grep -v '^$' <<<"${quality_computed_unlifted}" | sort -u)"

  if [[ -z "${quality_claimed_unlifted}" ]]; then
    fail "the document lists the run: bodies no test lifts" \
      "the 'No test lifts these bodies at all:' sentence names nothing in backticks"
  else
    assert_equal "the run: bodies no test lifts are the ones the document names" \
      "$(tr '\n' ' ' <<<"${quality_computed_unlifted}")" \
      "$(tr '\n' ' ' <<<"${quality_claimed_unlifted}")"
  fi

  # The other direction, per test file: the bullet credits four files by name,
  # and every workflow step it names inside a file's clause must be a step that
  # file actually names. A body moved between test files, or a clause left
  # behind by a deleted case, fails here.
  quality_covered_claim="${quality_bodies_bullet#*so the two stay next to each other: }"
  quality_covered_claim="${quality_covered_claim%%The work-order case*}"
  quality_clauses_checked=0
  while IFS= read -r quality_clause; do
    [[ -n "${quality_clause}" ]] || continue
    # shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
    quality_clause_file="$(grep -oE '`tests/[a-z0-9-]+\.sh`' <<<"${quality_clause}" | tr -d '`' | head -n 1)"
    [[ -n "${quality_clause_file}" ]] || continue
    quality_clauses_checked=$((quality_clauses_checked + 1))
    if [[ ! -f "${quality_clause_file}" ]]; then
      fail "the test file the document credits exists: ${quality_clause_file}" "no such file"
      continue
    fi
    if grep -qxF -- "${quality_clause_file#tests/}" tests/test-manifest; then
      pass "the test file the document credits is in the manifest: ${quality_clause_file}"
    else
      fail "the test file the document credits is in the manifest: ${quality_clause_file}" \
        "tests/run-tests.sh refuses to run a file the manifest does not list, so a credited file outside it never runs"
    fi
    # shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
    while IFS= read -r quality_token; do
      quality_token="${quality_token//\`/}"
      grep -qxF -- "${quality_token}" <<<"${quality_all_bodies}" || continue
      if grep -qF -- "\"${quality_token}\"" "${quality_clause_file}" ||
        grep -qF -- "'${quality_token}'" "${quality_clause_file}"; then
        pass "${quality_clause_file##*/} names the body the document credits it with: ${quality_token}"
      else
        fail "${quality_clause_file##*/} names the body the document credits it with: ${quality_token}" \
          "the document attributes that body to this file and the file does not name it"
      fi
    done < <(grep -oE '`[^`]+`' <<<"${quality_clause}")
  done < <(tr ';' '\n' <<<"${quality_covered_claim}")

  assert_equal "every test file the document credits with a workflow body was checked" \
    "${quality_clauses_checked}" "4"

  # "One more ... is read for its `env:` block but never executed" -- the suite
  # step is the one body a test names without running, so it must stay on the
  # named side of the classification above.
  quality_env_only="${quality_bodies_bullet#*One more, }"
  # shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
  quality_env_only="$(grep -oE '`[^`]+`' <<<"${quality_env_only}" | tr -d '`' | head -n 1)"
  if [[ -z "${quality_env_only}" ]]; then
    fail "the document still names the body a test reads but does not run" "the 'One more' sentence names nothing"
  elif grep -qxF -- "${quality_env_only}" <<<"${quality_all_bodies}"; then
    pass "the body the document says is read for its env: block is still a workflow step: ${quality_env_only}"
  else
    fail "the body the document says is read for its env: block is still a workflow step" \
      "no run: step is named ${quality_env_only}"
  fi
fi

fi

# ---------------------------------------------------------------------------
group "Reflections (docs/reflections/README.md: 'why a mistake was possible, how it was caught, and what would catch it next time')"

# docs/reflections/ is the third place this repository keeps knowledge, and the
# only one nothing read. README.md's documentation table, .memory/README.md and
# .claude/session-summary.md all send a writer here; the contract states a
# filename form, a five-part template and a prohibition on host inventory; and
# the one entry is a chain of claims about the Containerfile, this file and
# .github/workflows/ai-fix.yml.
#
# A stale reflection is worse than a stale runbook, for the reason the quality
# document is: a runbook that names a missing flag fails in the reader's hands,
# while a reflection is read to decide whether a class of mistake is already
# handled. Two of its claims had already gone stale by the time anything looked.
# It named the `sed` that uncomments `pam_wheel.so use_uid` by line number, and
# that line had moved from 166 to 188 -- so the transcript's `sed -i '166d'`
# now deletes a comment, which is the exact failure the section is about. And it
# said the string appears in three comments, which was true when the rationale
# block was three paragraphs and is one today. The same count was restated in
# this file's own `assert_present` comment, so both copies were wrong together.
#
# Every number and name the entry states about the tree is therefore read out of
# the prose here and resolved against the tree, rather than restated. The
# contract's own rules are enforced the same way: the filename form, the
# template's parts and the table of places are parsed from the document, so
# changing the contract fails this group until the entries follow it.
#
# What is deliberately not asserted: the pull request numbers (#161, #162, #163)
# and every sentence about why a mistake was possible. Those are history and
# judgement -- neither is a hand copy of something in the tree.

REFLECTIONS_DIR="docs/reflections"
REFLECTIONS_README="${REFLECTIONS_DIR}/README.md"
REFLECTION_PAM_ENTRY="${REFLECTIONS_DIR}/2026-09-03-checks-that-passed-for-the-wrong-reason.md"
AI_FIX_WORKFLOW=".github/workflows/ai-fix.yml"
SECURITY_AI_DOC="docs/security/SECURITY-AI.md"
CORRECTIONS_LOG=".memory/corrections.jsonl"
MEMORY_README=".memory/README.md"
SESSION_SUMMARY=".claude/session-summary.md"
INVARIANTS_SELF="tests/check-invariants.sh"

# A document flattened to one line, with any leading comment marker removed.
# Both sides of these joins wrap: the reflection's sentences wrap mid-phrase in
# Markdown, and this file's own rationale comments wrap behind a `#`. A phrase
# looked for in either as written is missed for a reason that has nothing to do
# with what it says.
reflection_flat() {
  sed -E 's/^[[:space:]]*#[[:space:]]?//' "$1" | tr '\n' ' ' | tr -s ' '
}

# Every relative link in a document resolves. This is `assert_doc_links_resolve`
# with one difference that matters here: the contract links to directories --
# `docs/` as the place a rule lands, `.memory/` as the place a one-liner does --
# and a directory is not a file. Anchors are still checked, for the targets that
# are files.
assert_reflection_links() {
  local doc="$1"
  local doc_dir="${doc%/*}"
  local link target anchor target_file slugs
  local link_problems="" links_checked=0
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
    links_checked=$((links_checked + 1))
    if [[ ! -e "${target_file}" ]]; then
      link_problems+="${link} (no such path) "
      continue
    fi
    [[ -n "${anchor}" && -f "${target_file}" ]] || continue
    slugs="$(grep -E '^#{1,6} ' "${target_file}" | sed -E 's/^#{1,6} //' |
      tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 -]//g; s/ /-/g')"
    grep -qx -- "${anchor}" <<<"${slugs}" || link_problems+="${link} (no such anchor) "
  done < <(grep -oE '\]\([^):]*\)' "${doc}" | sed 's/^](//; s/)$//' | sort -u)

  if ((links_checked == 0)); then
    fail "every relative link in ${doc} resolves" "no relative links found"
  elif [[ -z "${link_problems}" ]]; then
    pass "every relative link in ${doc} resolves (${links_checked})"
  else
    fail "every relative link in ${doc} resolves" "${link_problems}"
  fi
}

if [[ ! -f "${REFLECTIONS_README}" ]]; then
  fail "the reflections contract exists" \
    "${REFLECTIONS_README} is missing; README.md's documentation table, ${MEMORY_README} and ${SESSION_SUMMARY} all send a writer to it"
else

shopt -s nullglob
reflection_dir_files=("${REFLECTIONS_DIR}"/*.md)
shopt -u nullglob
reflection_entries=()
for reflection_file in "${reflection_dir_files[@]}"; do
  [[ "${reflection_file}" == "${REFLECTIONS_README}" ]] || reflection_entries+=("${reflection_file}")
done

# --- The contract is still reachable -----------------------------------------
#
# Three documents send a writer here, and the split between them is the whole
# reason this directory exists. A hand-off that stops pointing at it turns the
# contract into a file nobody is sent to.

assert_present "README.md's documentation table still links to the reflections" \
  "README.md" '\]\(docs/reflections/\)'

assert_present "${MEMORY_README} still hands the long-form lesson to the reflections" \
  "${MEMORY_README}" '\]\(\.\./docs/reflections/\)'

# The link in the session summary's table of places, not merely the directory
# name: both documents also discuss the split in prose a few lines further
# down, so a check that accepts any mention is satisfied by the paragraph
# *about* the row after the row is gone.
assert_present "${SESSION_SUMMARY}'s table of places still names the reflections" \
  "${SESSION_SUMMARY}" '\|[[:space:]]*\[docs/reflections/\]'

assert_reflection_links "${REFLECTIONS_README}"

# --- The table of places names paths that exist ------------------------------
#
# "This is the third place this repository keeps knowledge, so the first thing
# it owes you is a reason to exist rather than to be one of the other two." The
# reason is the table: three rows, each naming where a shape of knowledge lands.
# A row pointing at a path that no longer exists is an argument for a split that
# is no longer the split.

reflection_table="$(awk '
  /^\| Where \| Shape \| Lifetime \|/ { in_table = 1; next }
  in_table && /^\|[ -]*-/ { next }
  in_table && /^\|/ { print; next }
  in_table { exit }
' "${REFLECTIONS_README}")"

reflection_table_rows="$(grep -c '^|' <<<"${reflection_table}" || true)"
[[ -n "${reflection_table}" ]] || reflection_table_rows=0
assert_equal "the contract's table still names the three places knowledge lands" \
  "${reflection_table_rows}" "3"

while IFS= read -r reflection_row; do
  [[ -n "${reflection_row}" ]] || continue
  # shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
  reflection_place="$(grep -oE '`[^`]+`' <<<"${reflection_row}" | head -n 1 | tr -d '`')"
  if [[ -z "${reflection_place}" ]]; then
    fail "every place the contract's table names exists" "a row names no path: ${reflection_row}"
  elif [[ -e "${reflection_place}" ]]; then
    pass "the place the contract's table names exists: ${reflection_place}"
  else
    fail "the place the contract's table names exists: ${reflection_place}" \
      "no such path in the tree"
  fi
done <<<"${reflection_table}"

# "One line of JSON: an instruction was wrong, here is the correction." That is
# a shape claim about a file this table sends a writer to, and a line that does
# not parse makes the index it describes ungreppable in the one way that
# matters -- by field.
if [[ ! -f "${CORRECTIONS_LOG}" ]]; then
  fail "the corrections index the contract's table names exists" "${CORRECTIONS_LOG} is missing"
elif ! command -v jq >/dev/null 2>&1; then
  fail "every line of ${CORRECTIONS_LOG} is one JSON object, as the contract's table says" \
    "jq is not on PATH, so the shape could not be checked"
else
  reflection_bad_lines=""
  reflection_json_lines=0
  while IFS= read -r reflection_line; do
    [[ -n "${reflection_line//[[:space:]]/}" ]] || continue
    reflection_json_lines=$((reflection_json_lines + 1))
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"${reflection_line}" ||
      reflection_bad_lines+="${reflection_line:0:40}... "
  done <"${CORRECTIONS_LOG}"
  if ((reflection_json_lines == 0)); then
    fail "every line of ${CORRECTIONS_LOG} is one JSON object, as the contract's table says" \
      "the file has no entries, so the claim is unverifiable"
  elif [[ -z "${reflection_bad_lines}" ]]; then
    pass "every line of ${CORRECTIONS_LOG} is one JSON object, as the contract's table says (${reflection_json_lines})"
  else
    fail "every line of ${CORRECTIONS_LOG} is one JSON object, as the contract's table says" \
      "does not parse as an object: ${reflection_bad_lines}"
  fi
fi

# --- The entries follow the contract -----------------------------------------

if ((${#reflection_entries[@]} > 0)); then
  pass "the reflections directory still holds at least one entry (${#reflection_entries[@]})"
else
  fail "the reflections directory still holds at least one entry" \
    "${REFLECTIONS_DIR} has only a README, so every rule below is asserted against nothing"
fi

# "One file per episode, named `YYYY-MM-DD-short-topic.md`." The form is read
# out of the contract rather than restated, so renaming the convention is
# checked against the files in the same commit.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
reflection_name_form="$(grep -oE '`[A-Z]{4}-[A-Z]{2}-[A-Z]{2}-[a-z-]+\.md`' "${REFLECTIONS_README}" |
  head -n 1 | tr -d '`')"
if [[ -z "${reflection_name_form}" ]]; then
  fail "the contract still states the filename form" \
    "${REFLECTIONS_README} no longer names a YYYY-MM-DD-topic form"
else
  pass "the contract still states the filename form: ${reflection_name_form}"
  reflection_name_regex="^$(sed -E 's/YYYY/[0-9]{4}/; s/MM/[0-9]{2}/; s/DD/[0-9]{2}/; s/short-topic/[a-z0-9-]+/; s/\.md$/\\.md/' <<<"${reflection_name_form}")$"
  for reflection_entry in "${reflection_entries[@]}"; do
    reflection_base="${reflection_entry##*/}"
    if [[ "${reflection_base}" =~ ${reflection_name_regex} ]]; then
      pass "the entry filename follows the form the contract states: ${reflection_base}"
    else
      fail "the entry filename follows the form the contract states: ${reflection_base}" \
        "does not match ${reflection_name_regex}"
    fi
  done
fi

# The date in the filename is the date in the heading. A reflection is written
# after the thing is settled, and the date is how a reader places it against the
# tree it describes -- two dates disagreeing makes that placement a guess.
for reflection_entry in "${reflection_entries[@]}"; do
  reflection_base="${reflection_entry##*/}"
  reflection_file_date="$(grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' <<<"${reflection_base}")"
  reflection_heading_date="$(grep -m 1 -E '^# ' "${reflection_entry}" |
    grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n 1)"
  assert_equal "the heading date of ${reflection_base} matches its filename" \
    "${reflection_heading_date}" "${reflection_file_date}"
done

# The template's parts, read out of the fenced block in the contract. The entry
# may carry them as bold labels or as headings -- what is asserted is that the
# part is there, since the template is what makes a reflection transfer rather
# than read as a story.
reflection_template="$(awk '
  /^```markdown$/ { in_template = 1; next }
  /^```$/ { in_template = 0 }
  in_template
' "${REFLECTIONS_README}")"
reflection_parts="$(grep -oE '^\*\*[^*]+\*\*' <<<"${reflection_template}" |
  sed -E 's/^\*\*//; s/\*\*$//; s/\.$//')"

if [[ -z "${reflection_parts}" ]]; then
  fail "the contract's template still names the parts a reflection carries" \
    "no bold labels in the template block of ${REFLECTIONS_README}"
else
  pass "the contract's template still names the parts a reflection carries ($(grep -c . <<<"${reflection_parts}"))"
  for reflection_entry in "${reflection_entries[@]}"; do
    reflection_base="${reflection_entry##*/}"
    reflection_entry_flat="$(reflection_flat "${reflection_entry}")"
    while IFS= read -r reflection_part; do
      [[ -n "${reflection_part}" ]] || continue
      if grep -Fq -- "${reflection_part}" <<<"${reflection_entry_flat}"; then
        pass "${reflection_base} carries the template's '${reflection_part}' part"
      else
        fail "${reflection_base} carries the template's '${reflection_part}' part" \
          "the phrase does not appear"
      fi
    done <<<"${reflection_parts}"
    assert_reflection_links "${reflection_entry}"
  done
fi

# "Prompts, transcripts, credentials, personal data, or host inventory -- no VM
# names, pool names, disk paths, or IP addresses." Quoted command output is
# expected here, which is exactly why the prohibition needs a check: the
# evidence a reflection stands on is pasted from a real host.
reflection_host_detail="$(grep -rnE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' "${REFLECTIONS_DIR}" |
  tr '\n' ' ' || true)"
if [[ -z "${reflection_host_detail}" ]]; then
  pass "no reflection carries an IP address, which the contract lists as host inventory"
else
  fail "no reflection carries an IP address, which the contract lists as host inventory" \
    "${reflection_host_detail}"
fi

# --- The 2026-09-03 entry's claims, resolved against the tree -----------------

if [[ ! -f "${REFLECTION_PAM_ENTRY}" ]]; then
  fail "the 2026-09-03 reflection is still here" \
    "${REFLECTION_PAM_ENTRY} is missing; the contract says a reflection that turns out to be wrong is corrected in place, not deleted"
else

reflection_pam_flat="$(reflection_flat "${REFLECTION_PAM_ENTRY}")"

# The section is an argument about a line number, so the line number is the
# claim. It has moved once already, from 166 to 188, and the transcript that
# deletes 166 is left in place as the evidence it is -- which means the pointer
# a reader acts on is the sentence, and the sentence is what is resolved here.
reflection_sed_line="$(grep -oE 'line [0-9]+ of today' <<<"${reflection_pam_flat}" |
  grep -oE '[0-9]+' | head -n 1)"
if [[ -z "${reflection_sed_line}" ]]; then
  fail "the reflection still points at the sed it is about by line number" \
    "no \"line N of today's Containerfile\" sentence in ${REFLECTION_PAM_ENTRY}"
else
  reflection_sed_text="$(sed -n "${reflection_sed_line}p" "${CONTAINERFILE}")"
  if [[ "${reflection_sed_text}" =~ ^[[:space:]]*# ]]; then
    fail "the line the reflection names is the sed that uncomments pam_wheel.so use_uid" \
      "${CONTAINERFILE}:${reflection_sed_line} is a comment line -- deleting it proves nothing, which is this section's own subject"
  elif grep -Fq -- 'pam_wheel.so use_uid' <<<"${reflection_sed_text}" &&
    grep -Fq -- 'sed -i' <<<"${reflection_sed_text}"; then
    pass "the line the reflection names is the sed that uncomments pam_wheel.so use_uid (${CONTAINERFILE}:${reflection_sed_line})"
  else
    fail "the line the reflection names is the sed that uncomments pam_wheel.so use_uid" \
      "${CONTAINERFILE}:${reflection_sed_line} is: ${reflection_sed_text}"
  fi
fi

# How many comments carry the string is the other half of the same argument, and
# it is stated in two places: the reflection's correction, and this file's own
# `assert_present` comment. Both are counted against the Containerfile, so the
# pair cannot go stale together again.
reflection_pam_comments="$(grep -cE '^[[:space:]]*#.*pam_wheel\.so use_uid' "${CONTAINERFILE}")"
reflection_pam_word="$(grep -oE 'appears in [a-z]+ comment rather than' <<<"${reflection_pam_flat}" |
  awk '{print $3}')"
assert_equal "the reflection's correction counts the comments that carry pam_wheel.so use_uid" \
  "${reflection_pam_word}" "$(number_word "${reflection_pam_comments}")"

if [[ ! -f "${INVARIANTS_SELF}" ]]; then
  fail "assert_present's own comment counts them the same way" "${INVARIANTS_SELF} is missing"
else
  # Only the helper's own comment block, not the whole file: the extraction
  # pattern below spells the phrase it looks for, so searching everything would
  # let this assertion be satisfied by its own source after the comment is gone.
  reflection_helper_comment="$(sed -n '1,130p' "${INVARIANTS_SELF}" |
    sed -E 's/^[[:space:]]*#[[:space:]]?//' | tr '\n' ' ' | tr -s ' ')"
  reflection_helper_word="$(grep -oE 'uncomments it and in [a-z]+ comment' <<<"${reflection_helper_comment}" |
    awk '{print $5}')"
  assert_equal "assert_present's own comment counts them the same way" \
    "${reflection_helper_word}" "$(number_word "${reflection_pam_comments}")"
fi

# The other example the same paragraph gives.
reflection_sshd_active="$(grep -cE '^[^#]*PermitRootLogin prohibit-password' "${CONTAINERFILE}")"
assert_equal "the sshd drop-in the reflection names is still one active Containerfile line" \
  "${reflection_sshd_active}" "1"

reflection_sshd_comments="$(grep -cE '^[[:space:]]*#.*PermitRootLogin prohibit-password' "${CONTAINERFILE}")"
if ((reflection_sshd_comments > 0)); then
  pass "and is still restated in a comment, which is what makes a plain grep satisfiable by the explanation (${reflection_sshd_comments})"
else
  fail "and is still restated in a comment, which is what makes a plain grep satisfiable by the explanation" \
    "no comment line in ${CONTAINERFILE} carries PermitRootLogin prohibit-password, so the reflection's example is no longer true of this tree"
fi

# Section 2's fix: "Both affected sites use a here-string and no pipeline." A
# pipeline reintroduced at either site brings back a check that fails roughly
# one run in eight on a tree that is perfectly fine.
reflection_assert_body="$(awk '
  /^assert_present\(\) \{/ { in_body = 1 }
  in_body { print }
  in_body && /^\}/ { exit }
' "${INVARIANTS_SELF}")"
if [[ -z "${reflection_assert_body}" ]]; then
  fail "assert_present, the first site the reflection names, still exists" \
    "no assert_present definition in ${INVARIANTS_SELF}"
else
  # Comment lines are stripped for the same reason assert_present strips them,
  # and this assertion is the case that proves the point: the comment inside
  # that function spells out the pipeline it does not use, so a search over the
  # whole body finds the *explanation* of the shape and reports the shape.
  reflection_assert_code="$(grep -Ev '^[[:space:]]*#' <<<"${reflection_assert_body}")"
  if grep -Fq -- '<<<' <<<"${reflection_assert_code}"; then
    pass "assert_present still matches from a here-string, as the reflection says"
  else
    fail "assert_present still matches from a here-string, as the reflection says" \
      "no here-string in the function body"
  fi
  if grep -Eq '\|[[:space:]]*grep' <<<"${reflection_assert_code}"; then
    fail "assert_present still pipes nothing into grep, as the reflection says" \
      "a pipeline into grep is back: under pipefail, grep -q's SIGPIPE on the upstream makes a satisfied assertion report failure"
  else
    pass "assert_present still pipes nothing into grep, as the reflection says"
  fi
fi

if grep -Eq '^mismatch_branch="\$\(' "${INVARIANTS_SELF}"; then
  pass "the mismatch_branch assignment, the second site the reflection names, still exists"
else
  fail "the mismatch_branch assignment, the second site the reflection names, still exists" \
    "no mismatch_branch assignment in ${INVARIANTS_SELF}"
fi

if grep -Eq 'grep [^|]*<<<"\$\{mismatch_branch\}"' "${INVARIANTS_SELF}"; then
  pass "and still reads it through a here-string rather than a pipeline"
else
  fail "and still reads it through a here-string rather than a pipeline" \
    "mismatch_branch is no longer matched from a here-string"
fi

# The probe the intermittent failure was found with names a real Containerfile
# line. A probe against a line that no longer exists would have failed for a
# reason that has nothing to do with SIGPIPE.
reflection_probe="$(grep -oE 'ARG [A-Z_]+=' "${REFLECTION_PAM_ENTRY}" | head -n 1)"
if [[ -z "${reflection_probe}" ]]; then
  fail "the Containerfile line the reflection's race probe used is still there" \
    "${REFLECTION_PAM_ENTRY} no longer names an ARG"
else
  assert_present "the Containerfile line the reflection's race probe used is still there (${reflection_probe})" \
    "${CONTAINERFILE}" "^${reflection_probe}"
fi

# Section 3: the workflow fix. The step name, the ref it pins, the permissions
# the token carries and the script that would have been run are four hand copies
# of .github/workflows/ai-fix.yml, and the section stops being about this
# repository the moment any of them stops matching.
# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
reflection_step="$(grep -oE 'the `[^`]+` step' <<<"${reflection_pam_flat}" | head -n 1 |
  sed -E 's/^the `//; s/` step$//')"
if [[ -z "${reflection_step}" ]]; then
  fail "the checkout step the reflection names still exists in ${AI_FIX_WORKFLOW}" \
    "${REFLECTION_PAM_ENTRY} no longer names a step"
elif grep -Fq -- "- name: ${reflection_step}" "${AI_FIX_WORKFLOW}"; then
  pass "the checkout step the reflection names still exists in ${AI_FIX_WORKFLOW}: ${reflection_step}"
else
  fail "the checkout step the reflection names still exists in ${AI_FIX_WORKFLOW}" \
    "no step is named ${reflection_step}"
fi

# shellcheck disable=SC2016  # the ${{ }} expression is the document's own text, matched literally
reflection_ref="$(grep -oE '`ref: \$\{\{[^`]+`' <<<"${reflection_pam_flat}" | head -n 1 | tr -d '`')"
if [[ -z "${reflection_ref}" ]]; then
  fail "the checkout still pins the ref the reflection says it pins" \
    "${REFLECTION_PAM_ENTRY} no longer quotes a ref"
elif grep -Fq -- "${reflection_ref}" "${AI_FIX_WORKFLOW}"; then
  pass "the checkout still pins the ref the reflection says it pins: ${reflection_ref}"
else
  fail "the checkout still pins the ref the reflection says it pins" \
    "${AI_FIX_WORKFLOW} does not carry: ${reflection_ref}"
fi

# shellcheck disable=SC2016  # the backticks are the document's own markup, matched literally
reflection_perms="$(grep -oE '`[a-z-]+: write`' <<<"${reflection_pam_flat}" | tr -d '`' | sort -u)"
if [[ -z "${reflection_perms}" ]]; then
  fail "the job still carries the write permissions that made the reflection's scenario possible" \
    "${REFLECTION_PAM_ENTRY} no longer names them"
else
  while IFS= read -r reflection_perm; do
    [[ -n "${reflection_perm}" ]] || continue
    if grep -Eq "^[[:space:]]+${reflection_perm}\$" "${AI_FIX_WORKFLOW}"; then
      pass "the job still carries the permission the reflection names: ${reflection_perm}"
    else
      fail "the job still carries the permission the reflection names: ${reflection_perm}" \
        "${AI_FIX_WORKFLOW} no longer requests it, so the section describes a token this workflow does not hold"
    fi
  done <<<"${reflection_perms}"
fi

reflection_script="$(grep -oE '\./scripts/[a-z0-9-]+\.sh' <<<"${reflection_pam_flat}" | head -n 1)"
if [[ -z "${reflection_script}" ]]; then
  fail "the script the reflection's scenario runs exists and is executable" \
    "${REFLECTION_PAM_ENTRY} no longer names a script"
else
  if [[ -x "${reflection_script}" ]]; then
    pass "the script the reflection's scenario runs exists and is executable: ${reflection_script}"
  else
    fail "the script the reflection's scenario runs exists and is executable" \
      "${reflection_script} is missing or not executable"
  fi
  if grep -Fq -- "${reflection_script}" "${AI_FIX_WORKFLOW}"; then
    pass "and is still what ${AI_FIX_WORKFLOW} runs, which is what put it behind that token"
  else
    fail "and is still what ${AI_FIX_WORKFLOW} runs, which is what put it behind that token" \
      "${AI_FIX_WORKFLOW} no longer runs ${reflection_script}"
  fi
fi

# "The rule had been written down two pull requests earlier." The reflection
# credits the policy with the rule the workflow was not applying to itself; both
# sides are checked, so deleting the rule from either fails here rather than
# leaving a reflection that credits a document with a sentence it no longer has.
reflection_security_flat="$(reflection_flat "${SECURITY_AI_DOC}")"
for reflection_policy_phrase in "diff under review" "base revision"; do
  if ! grep -Fq -- "${reflection_policy_phrase}" <<<"${reflection_pam_flat}"; then
    fail "${SECURITY_AI_DOC} still states the rule the reflection credits it with: ${reflection_policy_phrase}" \
      "the reflection no longer states it either"
  elif grep -Fq -- "${reflection_policy_phrase}" <<<"${reflection_security_flat}"; then
    pass "${SECURITY_AI_DOC} still states the rule the reflection credits it with: ${reflection_policy_phrase}"
  else
    fail "${SECURITY_AI_DOC} still states the rule the reflection credits it with: ${reflection_policy_phrase}" \
      "the phrase is gone from the policy"
  fi
done

# The honest limit: a step with the right shape and the wrong effect passes a
# static check, and only the VM procedure settles it. That procedure is what
# CLAUDE.md is.
if grep -qE '^# .*VM' "CLAUDE.md"; then
  pass "CLAUDE.md is still the VM procedure the reflection's honest limit defers to"
else
  fail "CLAUDE.md is still the VM procedure the reflection's honest limit defers to" \
    "CLAUDE.md's title no longer names a VM, so the only thing that settles what a static check cannot is unclear"
fi

fi

fi

# ---------------------------------------------------------------------------
printf '\n1..%d\n' "${checks_run}"
if ((failures > 0)); then
  printf 'invariants: %d of %d check(s) failed\n' "${failures}" "${checks_run}" >&2
  exit 1
fi
printf 'invariants: all %d check(s) passed\n' "${checks_run}"
