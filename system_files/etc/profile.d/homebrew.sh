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
# so refusing links would disable Homebrew rather than protect it. Instead,
# every entry traversed while resolving the link is checked. That includes the
# link itself, its resolved target, and all directories on both sides: leaving
# out a resolved parent would let its owner replace the checked target before
# the documented path below is invoked.
__arch_bootc_brew_trusted() {
  __ab_brew="$1/linuxbrew/.linuxbrew/bin/brew"
  __ab_self=$(id -u) || return 1
  # /var/home and /home are system trust anchors supplied by this file, not by
  # the prefix owner. Start below that anchor; if a link escapes it, absolute
  # and `..` targets are still walked and checked from the point they enter.
  __ab_path=$1
  __ab_rest=linuxbrew/.linuxbrew/bin/brew
  __ab_hops=0

  # Resolve component by component rather than calling `readlink -f`, because
  # the canonical result alone has forgotten the symlinks and directories used
  # to reach it. Each `stat` deliberately does not pass `-L`: it judges the
  # current entry itself before a link is followed. Following absolute and
  # relative targets through this same loop then judges their parents too.
  while [ -n "${__ab_rest}" ]; do
    case ${__ab_rest} in
      */*)
        __ab_part=${__ab_rest%%/*}
        __ab_rest=${__ab_rest#*/}
        ;;
      *)
        __ab_part=${__ab_rest}
        __ab_rest=
        ;;
    esac

    case ${__ab_part} in
      '' | .) continue ;;
      ..)
        if [ "${__ab_path}" != / ]; then
          __ab_path=${__ab_path%/*}
          [ -n "${__ab_path}" ] || __ab_path=/
        fi
        __ab_uid=$(stat -c %u -- "${__ab_path}" 2>/dev/null) || return 1
        [ "${__ab_uid}" = 0 ] || [ "${__ab_uid}" = "${__ab_self}" ] || return 1
        continue
        ;;
    esac

    if [ "${__ab_path}" = / ]; then
      __ab_next="/${__ab_part}"
    else
      __ab_next="${__ab_path}/${__ab_part}"
    fi
    __ab_uid=$(stat -c %u -- "${__ab_next}" 2>/dev/null) || return 1
    [ "${__ab_uid}" = 0 ] || [ "${__ab_uid}" = "${__ab_self}" ] || return 1

    if [ -L "${__ab_next}" ]; then
      __ab_hops=$((__ab_hops + 1))
      [ "${__ab_hops}" -le 40 ] || return 1
      __ab_link=$(readlink -- "${__ab_next}" 2>/dev/null) || return 1
      case ${__ab_link} in
        /*)
          __ab_path=/
          __ab_link=${__ab_link#/}
          ;;
      esac
      if [ -n "${__ab_rest}" ]; then
        __ab_rest="${__ab_link}/${__ab_rest}"
      else
        __ab_rest=${__ab_link}
      fi
    else
      __ab_path=${__ab_next}
    fi
  done
  __ab_real=${__ab_path}
  [ -f "${__ab_real}" ] && [ -x "${__ab_real}" ]
}

# The command below is the documented prefix path rather than the resolved one:
# Homebrew works out its own prefix from the path it was invoked by, and
# invoking the link's target would have it answer .../Homebrew instead of
# .../.linuxbrew. That leaves the check and the use as two lookups of one path,
# which is a race in principle (CWE-367). The directory checks above are what
# make it uninteresting: swapping any path entry between the check and use
# means controlling one of the directories the walk has already refused.
if __arch_bootc_brew_trusted /var/home; then
  eval "$(/var/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif __arch_bootc_brew_trusted /home; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# This file is sourced, so anything left defined here stays in the login shell.
unset -f __arch_bootc_brew_trusted
unset __ab_brew __ab_self __ab_path __ab_rest __ab_hops __ab_part __ab_next
unset __ab_uid __ab_link __ab_real
