# Make ublue-os/brew available to fish users once brew-setup.service has extracted it.
if test -x /var/home/linuxbrew/.linuxbrew/bin/brew
    /var/home/linuxbrew/.linuxbrew/bin/brew shellenv | source
else if test -x /home/linuxbrew/.linuxbrew/bin/brew
    /home/linuxbrew/.linuxbrew/bin/brew shellenv | source
end
