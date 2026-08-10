# Shell setup

The interactive-shell aliases and environment for this machine — the general-purpose ones that belong to no particular piece of hardware.

```
./install.sh              wire bashrc.d/*.sh into ~/.bashrc
./install.sh --status     report current state
./install.sh --uninstall  remove the hook lines again
```

No root needed. Nothing here needs a rootfs unlock, a keep entry or a boot self-heal.

## Why this is in the repo

The rest of the repo restores the *machine*. This restores the way it is driven: `g`, `p`, `P`, `gitwip` and the `cc*` family are the commands nearly every session on this box actually starts with, and a rebuild that brings back the subsystems but not those is only half a restore. They also document the setup — that Claude Code is used here permissively, that Homebrew and the .NET SDK are installed under `/home` rather than through pacman, that `~/.local/bin` is where hand-installed tools land.

Nothing in here is secret. No hostnames, no credentials, no private paths, no addresses — worth re-checking before adding anything, since the repo is public.

## What is where

| File | Contents |
| --- | --- |
| `bashrc.d/env.sh` | `PATH`, Homebrew `shellenv`, `DOTNET_ROOT` |
| `bashrc.d/aliases.sh` | `vi`, the `cc`/`ccd`/`cccd`/`ccrd` Claude Code aliases, `g`/`p`/`P`/`gitwip`, `trigger_detect_tv` |

The subsystem-specific shell functions are **not** here — they live with the hardware they belong to, and each subsystem's own installer wires them up:

| Function | Snippet |
| --- | --- |
| `keepawake` | [`hardware/sleep/bashrc.d/keepawake.sh`](../../hardware/sleep/bashrc.d/keepawake.sh) |
| `wayland` | [`hardware/display/bashrc.d/wayland.sh`](../../hardware/display/bashrc.d/wayland.sh) |
| `coolercontrol` | [`hardware/coolercontrol/bashrc.d/coolercontrol.sh`](../../hardware/coolercontrol/bashrc.d/coolercontrol.sh) |

## Sourced from the repo, not copied

`install.sh` appends two guarded lines to `~/.bashrc` and nothing else:

```bash
# steam-machine: shell environment
[[ -f /home/deck/git/steam-machine/system/shell/bashrc.d/env.sh ]] && . /home/deck/git/steam-machine/system/shell/bashrc.d/env.sh
```

So editing `bashrc.d/aliases.sh` takes effect in the next shell with nothing to reinstall, and the file under version control is the one actually being used — there is no copy to drift. Same pattern as the three hardware subsystems above.

`--uninstall` removes only the exact two-line block the installer wrote, after taking a backup. If the block has been hand-edited it is reported and left alone, because running `sed` blind over someone's `~/.bashrc` is a bad trade.

## Persistence

Trivial, and worth stating because it is the *exception* in this repo rather than the rule. `~/.bashrc` and the repo checkout are both on `/home`, which is its own partition. A SteamOS A/B update replaces `/usr` wholesale and carries only [an allowlisted subset of `/etc`](../../docs/steamos-platform-notes.md#steamos-persistence); it does not touch `/home`. So there is no `atomic-update.conf.d` entry and no `--boot` self-heal here — there is nothing for an update to take away.

## PATH ordering

Preserved exactly as it was before this was factored out, since it is load-bearing and easy to break by reordering:

1. `~/.local/bin` prepended,
2. Homebrew prepends itself **in front of that**,
3. `~/.dotnet` appended at the tail.

So brew's tools shadow `~/.local/bin`, and both shadow anything from dotnet. Each block is guarded on the thing existing, so the file is safe to source on a machine where brew or the .NET SDK was never installed.

## Two aliases worth knowing the teeth of

**`ccd`** is `claude --dangerously-skip-permissions`. That is a defensible trade *on this machine specifically* — a living-room console whose whole state is this repo, a Steam library and an image that can be reflashed. It is not a defensible default on anything holding credentials or someone else's data.

**`gitwip`** is `git add .; git commit -n -m "automated commit"; git push`. Deliberately blunt; the realistic alternative was not committing at all. But this repo is **public**, and it has two teeth: `git add .` stages whatever happens to be untracked, and `-n` skips the pre-commit hooks, so a gitleaks hook does not run. `.gitignore` already covers `gitleaks-report.json` and `.claude/`; keep it honest, and don't fire this in a tree you haven't looked at.

## `trigger_detect_tv`

Forces the TV to be re-detected after it was switched on later than the machine — the converter-is-the-sink problem written up in [hardware/display/](../../hardware/display/README.md).

It used to be an inline `sudo sh -c 'echo 0 > … ; sleep 2; echo 1 > …'` against a hardcoded `/sys/kernel/debug/dri/0/DP-1/trigger_hotplug`. It now calls [`display-redetect`](../../hardware/display/bin/display-redetect), which is the same idea done properly: it finds the connected connector instead of assuming card 0 / `DP-1`, takes a lock, and is the identical script the four automatic triggers (Shift+Esc, controller connect, boot, resume) run — so typing it by hand and the hotkey firing now do exactly the same thing.

`--force` skips the 60 s debounce, which is what you want when you have deliberately typed it. `--tag manual` gives it its own debounce stamp so a manual run doesn't suppress the controller-connect trigger seconds later.
