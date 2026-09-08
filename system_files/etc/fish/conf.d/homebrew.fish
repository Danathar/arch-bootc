# Make ublue-os/brew available to fish users once brew-setup.service has extracted it.
#
# Ownership guard, matching /etc/profile.d/homebrew.sh: only a prefix owned by
# root, or by the user whose shell this is, is trusted. brew-setup.service
# extracts the prefix for UID 1000 and Homebrew requires it to be writable by
# the user running it, so without this check whoever can write it gets code
# execution in every other account's shell -- both from running the binary and
# from `source`ing what it prints. See that file for the full reasoning.
if test -x /var/home/linuxbrew/.linuxbrew/bin/brew
    if test -O /var/home/linuxbrew/.linuxbrew/bin/brew; or test (stat -c %u /var/home/linuxbrew/.linuxbrew/bin/brew) = 0
        /var/home/linuxbrew/.linuxbrew/bin/brew shellenv | source
    end
else if test -x /home/linuxbrew/.linuxbrew/bin/brew
    if test -O /home/linuxbrew/.linuxbrew/bin/brew; or test (stat -c %u /home/linuxbrew/.linuxbrew/bin/brew) = 0
        /home/linuxbrew/.linuxbrew/bin/brew shellenv | source
    end
end
