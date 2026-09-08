# Make ublue-os/brew available to fish users once brew-setup.service has extracted it.
#
# Ownership guard, matching /etc/profile.d/homebrew.sh: only a prefix owned by
# root, or by the user whose shell this is, is trusted. brew-setup.service
# extracts the prefix for UID 1000 and Homebrew requires it to be writable by
# the user running it, so without this check whoever can write it gets code
# execution in every other account's shell -- both from running the binary and
# from `source`ing what it prints. See that file for the full reasoning,
# including why every test here reads the path itself rather than what a
# symlink points at: `-O` and `-x` dereference, so the first version of this
# guard could be satisfied by a link the untrusted owner of the prefix aimed at
# any root-owned executable on the system.
function __arch_bootc_brew_trusted --argument-names base
    set --local brew "$base/linuxbrew/.linuxbrew/bin/brew"
    # Resolve once, so the owner check and the -f/-x tests describe one file.
    set --local real (readlink -f -- "$brew" 2>/dev/null)
    or return 1
    test -n "$real"
    or return 1
    # `stat` without `-L` reports a link's own owner. The directories are
    # checked too: a directory an untrusted user owns is a directory whose
    # contents they choose, whoever owns the file sitting in it right now.
    set --local uids (stat -c %u -- \
        "$base/linuxbrew" \
        "$base/linuxbrew/.linuxbrew" \
        "$base/linuxbrew/.linuxbrew/bin" \
        "$brew" \
        "$real" 2>/dev/null)
    or return 1
    set --local self (id -u)
    for uid in $uids
        if test "$uid" != 0; and test "$uid" != "$self"
            return 1
        end
    end
    test -f "$real"; and test -x "$real"
end

# The documented prefix path is what runs, not the resolved one -- Homebrew
# works out its own prefix from the path it was invoked by. See homebrew.sh.
if __arch_bootc_brew_trusted /var/home
    /var/home/linuxbrew/.linuxbrew/bin/brew shellenv | source
else if __arch_bootc_brew_trusted /home
    /home/linuxbrew/.linuxbrew/bin/brew shellenv | source
end

# conf.d files run in the shell itself, so the helper would otherwise stay
# defined in every fish session.
functions --erase __arch_bootc_brew_trusted
