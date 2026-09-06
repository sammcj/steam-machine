# DIY Steam Machine (SteamOS) Build

This project contains scripts, tools and notes for my DIY Steam Machine build.

See the README.md for the hardware details and list of issues I'm trying to resolve.

Note: All changes intended to be permanent must survive a reboot and Steam OS upgrade.

## Update CHANGELOG.md after changes

After making any change to this project (notes, install scripts, configs, patches): You MUST update `CHANGELOG.md`:

- Add a concise TLDR of the change(s) as bullet point(s) under today's date heading (`## YYYY-MM-DD`, newest first), creating the heading if it doesn't exist. No versioning is required.

## systemd units must not be able to hang boot

Every subsystem here installs units. Two rules, both learnt by making the machine unbootable on 2026-09-06 (`hardware/usb/` — see its README's Trap section):

- **Never call blocking `systemctl start`/`restart` from inside a unit's own `ExecStart`.** systemd will not dispatch the new job while the calling unit's job is still running, so the call waits on it forever. Use `--no-block`, keyed on `INVOCATION_ID` so interactive runs keep their exit status. A unit that is `WantedBy=` a target is started by systemd anyway — starting it by hand from a sibling unit buys nothing.
- **Do not order anything `Before=systemd-user-sessions.service`** unless a login genuinely depends on it. `graphical.target` depends on it, so blocking it means no session.

Set `TimeoutStartSec=` on any boot unit regardless: failing is fine, hanging is not. The symptom of getting either wrong is a black screen with nothing useful on the console — on a machine whose only display is a TV, indistinguishable from a display bug.
