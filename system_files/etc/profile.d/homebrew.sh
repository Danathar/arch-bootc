# Make ublue-os/brew available to all users once brew-setup.service has extracted it.
# The bootc image maps /home -> /var/home, but support both paths for portability.
if [ -x /var/home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/var/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
