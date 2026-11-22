A personal fork of [Boring Notch](https://github.com/TheBoredTeam/boring.notch). (GPL-3.0)

**Download `travisNotch.zip`** below (not "Source code").

## Install
1. Unzip `travisNotch.zip` and move `travisNotch.app` to `/Applications`.
2. The app is not notarized, so macOS blocks it on first launch. Allow it with either:
   - System Settings → Privacy & Security → "Open Anyway"
   - or in Terminal: `xattr -dr com.apple.quarantine /Applications/travisNotch.app`

## Updates
From v1.0.1 on, the app checks this repository for updates automatically (it never installs official Boring Notch updates).
If you have v1.0.0, install v1.0.1 manually once.

## Notes
- Fan control and lid-closed awake ask for your admin password on first use, and again after each update, to install a root helper at `/usr/local/libexec/boringnotch-helper`.
- The Claude usage card only works if Claude Code is signed in on that Mac.
