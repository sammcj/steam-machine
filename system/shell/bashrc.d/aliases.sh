# Interactive shell aliases for this machine.
#
# Sourced from ~/.bashrc by system/shell/install.sh. Edits here take effect in
# the next shell; nothing needs reinstalling.
#
# These are in the repo because they are part of how this machine is set up,
# not because any of them are clever -- a rebuild that restores the subsystems
# but not the muscle memory is only half a restore. Nothing here is secret: no
# hosts, no credentials, no private paths.

alias vi=vim

# --- Claude Code --------------------------------------------------------------
# `ccd` skips every permission prompt. That is a reasonable trade *on this
# machine specifically*: it is a living-room console whose entire state is this
# repo, a Steam library and a SteamOS image that can be reflashed. It is not a
# reasonable default anywhere with credentials or someone else's data on it.
alias cc='claude'
alias ccd='claude --dangerously-skip-permissions'
alias cccd='ccd --continue'
alias ccrd='ccd --resume'

# --- this repo ----------------------------------------------------------------
alias g='cd /home/deck/git/steam-machine'
alias p='git pull'
alias P='git push'

# Stage everything, commit unsigned with a canned message, push. Deliberately
# blunt -- this repo is notes and scripts, and the realistic alternative was
# not committing at all.
#
# Two teeth to be aware of, because the repo is public: `git add .` stages
# whatever happens to be untracked, and `-n` skips the pre-commit hooks, so a
# gitleaks hook does not run. Keep .gitignore honest (it already covers
# gitleaks-report.json and .claude/), and don't fire this in a tree you have
# not looked at.
alias gitwip='git add .; git commit -n -m "automated commit" ; git push'

# --- display ------------------------------------------------------------------
# Force the TV to be re-detected after it was switched on later than the
# machine. See hardware/display/README.md for why this is needed at all -- the
# DP->HDMI converter is the sink, so nothing on this side ever learns the TV
# woke up.
#
# This used to write 0/1 to a hardcoded /sys/kernel/debug/dri/0/DP-1/trigger_hotplug.
# display-redetect is the same idea done properly: it auto-detects the
# connected connector rather than assuming card 0 / DP-1, takes a lock, and is
# the identical script the four automatic triggers (Shift+Esc, controller
# connect, boot, resume) run. --force skips the 60 s debounce, which is what
# you want when you have typed it by hand; --tag manual keeps that from
# stealing the automatic triggers' debounce stamp.
alias trigger_detect_tv='sudo /home/deck/git/steam-machine/hardware/display/bin/display-redetect --force --tag manual'
