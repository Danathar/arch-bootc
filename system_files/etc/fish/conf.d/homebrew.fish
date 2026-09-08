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
    set --local self (id -u)
    or return 1
    # The two literal base paths are system trust anchors. Begin below the
    # anchor; an absolute or `..` link target is still walked from its new path.
    set --local path "$base"
    set --local rest linuxbrew/.linuxbrew/bin/brew
    set --local hops 0

    # Resolve one component at a time so symlinks and directories traversed on
    # the way to the canonical target are not lost. `stat` has no `-L` because
    # the current entry must be judged before a symlink is followed.
    while test -n "$rest"
        set --local pieces (string split -m 1 / -- "$rest")
        set --local part "$pieces[1]"
        if test (count $pieces) -gt 1
            set rest "$pieces[2]"
        else
            set rest ""
        end

        switch "$part"
            case '' .
                continue
            case ..
                if test "$path" != /
                    set path (string replace -r '/[^/]*$' '' -- "$path")
                    test -n "$path"; or set path /
                end
                set --local parent_uid (stat -c %u -- "$path" 2>/dev/null)
                or return 1
                if test "$parent_uid" != 0; and test "$parent_uid" != "$self"
                    return 1
                end
                continue
        end

        set --local next
        if test "$path" = /
            set next "/$part"
        else
            set next "$path/$part"
        end
        set --local uid (stat -c %u -- "$next" 2>/dev/null)
        or return 1
        if test "$uid" != 0; and test "$uid" != "$self"
            return 1
        end

        if test -L "$next"
            set hops (math "$hops + 1")
            test "$hops" -le 40; or return 1
            set --local link (readlink -- "$next" 2>/dev/null)
            or return 1
            if string match -q '/*' -- "$link"
                set path /
                set link (string replace -r '^/' '' -- "$link")
            end
            if test -n "$rest"
                set rest "$link/$rest"
            else
                set rest "$link"
            end
        else
            set path "$next"
        end
    end
    test -f "$path"; and test -x "$path"
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
