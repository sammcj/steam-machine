# Interactive shell environment for this machine.
#
# Sourced from ~/.bashrc by system/shell/install.sh. Edits here take effect in
# the next shell; nothing needs reinstalling.
#
# Ordering matters and is preserved from the original ~/.bashrc: .local/bin is
# prepended first, then Homebrew prepends itself in front of it, then .dotnet
# is appended at the tail. So brew's tools win over ~/.local/bin, and both win
# over anything from dotnet.
#
# Everything here is guarded on the thing actually existing, so the file is
# safe to source on a machine where brew or dotnet was never installed.

# Where locally-installed user tools land. This is the one that matters on
# SteamOS: the rootfs is read-only and replaced wholesale by every A/B update,
# so anything installed by hand goes under /home and needs to be on PATH.
export PATH="$HOME/.local/bin:$PATH"

# Homebrew on Linux. Installs to /home/linuxbrew, which is on the home
# partition, so it survives OS updates -- the reason it is here rather than
# reaching for pacman, which would write to the read-only rootfs.
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
fi

# .NET SDK, installed via dotnet-install.sh into $HOME rather than packaged.
if [[ -d "$HOME/.dotnet" ]]; then
    export DOTNET_ROOT="$HOME/.dotnet"
    export PATH="$PATH:$HOME/.dotnet"
fi
