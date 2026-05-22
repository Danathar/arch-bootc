# Make ublue-os/brew available to zsh login shells once brew-setup.service has extracted it.
if [ -r /etc/profile.d/homebrew.sh ]; then
  . /etc/profile.d/homebrew.sh
fi
