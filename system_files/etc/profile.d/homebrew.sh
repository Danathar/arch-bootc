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
if [ -x /var/home/linuxbrew/.linuxbrew/bin/brew ]; then
  if [ -O /var/home/linuxbrew/.linuxbrew/bin/brew ] \
    || [ "$(stat -c %u /var/home/linuxbrew/.linuxbrew/bin/brew)" = 0 ]; then
    eval "$(/var/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  if [ -O /home/linuxbrew/.linuxbrew/bin/brew ] \
    || [ "$(stat -c %u /home/linuxbrew/.linuxbrew/bin/brew)" = 0 ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  fi
fi
