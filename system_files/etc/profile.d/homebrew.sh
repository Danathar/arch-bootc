# Make ublue-os/brew available to all users once brew-setup.service has extracted it.
# The bootc image maps /home -> /var/home, but support both paths for portability.
#
# Only a prefix owned by root, or by the user whose shell this is, is trusted.
# This file is /etc/profile.d, so it runs in every login shell on the machine
# -- root's included, via `su -`, `sudo -i` or a console login, and zsh's too
# because /etc/zsh/zprofile sources /etc/profile. The path it runs is not a
# system location: brew-setup.service extracts it for UID 1000, and Homebrew
# requires its prefix to be writable by the user running it (brew refuses to
# run as root at all). Without this check, whoever can write that prefix gets
# code execution in every other account's login shell -- both from the binary
# itself and from `eval` of what it prints -- which turns a compromised user
# session into root without ever needing the sudo password.
#
# A second user therefore no longer inherits the first user's brew on PATH.
# That is intended: upstream Homebrew does not support a shared multi-user
# prefix either. A root-owned prefix, being a genuine system-wide install, is
# still used by everyone.
#
# Every ownership test below describes the path itself and never what a symlink
# points at. That distinction is the whole of this guard. The first version of
# it asked `[ -O ... ]`, and `-O`, like `-x`, dereferences: it answered "is the
# *target* owned by the logging-in user", which is a question whoever owns the
# prefix gets to answer by choosing the target. UID 1000 owns this prefix, so
# it could replace bin/brew with a link to any root-owned executable on the
# system; `-O` then came out true for root, and root's login shell ran that
# executable and eval'd its output. `stat` without `-L` reports a link's own
# owner, so a link planted by an untrusted user is refused however it points.
#
# Links are not rejected outright, which is the obvious fix and the wrong one:
# a stock Homebrew prefix ships bin/brew as a link into ../Homebrew/bin/brew,
# so refusing links would disable Homebrew rather than protect it. A link owned
# by root or by you is a link only root or you could have aimed, which is
# exactly the question being asked -- and what it resolves to is checked too,
# because a trusted link into an untrusted file is not a trusted brew.
__arch_bootc_brew_trusted() {
  __ab_brew="$1/linuxbrew/.linuxbrew/bin/brew"
  # Resolve once. `readlink -f` leaves no link behind, so the owner check below
  # and the `-f`/`-x` tests after it all describe the same real file.
  __ab_real=$(readlink -f -- "${__ab_brew}" 2>/dev/null) || return 1
  [ -n "${__ab_real}" ] || return 1
  # One `stat` for every component of the prefix plus the resolved target. It
  # exits non-zero when any of them is missing, which is also how a machine
  # that never ran brew-setup.service arrives here. The directories are
  # included because a directory an untrusted user owns is a directory whose
  # contents they choose, whoever owns the file sitting in it right now.
  __ab_uids=$(
    stat -c %u -- \
      "$1/linuxbrew" \
      "$1/linuxbrew/.linuxbrew" \
      "$1/linuxbrew/.linuxbrew/bin" \
      "${__ab_brew}" \
      "${__ab_real}" 2>/dev/null
  ) || return 1
  __ab_self=$(id -u)
  # shellcheck disable=SC2086 # one uid per line; splitting is the point
  for __ab_uid in ${__ab_uids}; do
    [ "${__ab_uid}" = 0 ] || [ "${__ab_uid}" = "${__ab_self}" ] || return 1
  done
  [ -f "${__ab_real}" ] && [ -x "${__ab_real}" ]
}

# The command below is the documented prefix path rather than the resolved one:
# Homebrew works out its own prefix from the path it was invoked by, and
# invoking the link's target would have it answer .../Homebrew instead of
# .../.linuxbrew. That leaves the check and the use as two lookups of one path,
# which is a race in principle (CWE-367). The directory checks above are what
# make it uninteresting: swapping the file between the two lookups means being
# able to write `bin`, and a `bin` an untrusted user can write is one this
# guard has already refused.
if __arch_bootc_brew_trusted /var/home; then
  eval "$(/var/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif __arch_bootc_brew_trusted /home; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# This file is sourced, so anything left defined here stays in the login shell.
unset -f __arch_bootc_brew_trusted
unset __ab_brew __ab_real __ab_uids __ab_self __ab_uid
