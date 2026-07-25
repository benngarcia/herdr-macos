# Herdr for macOS

[Herdr](https://herdr.dev) is a terminal multiplexer for running coding agents,
and it ships as a command you type into some other terminal. This installer turns
it into a real Mac app: one command builds `~/Applications/Herdr.app` from the
Ghostty you already have installed, so Herdr gets its own Dock icon, Spotlight
entry, menu bar, and Mac keyboard shortcuts. Your existing Ghostty install and
its configuration are never touched.

- **Launch it like an app.** Spotlight, the Dock, the menu bar, notifications,
  and Activity Monitor all say Herdr, because the bundle is a real
  `Herdr.app` with its own identifier and icon.
- **Mac shortcuts that stay put.** Cmd-T for a tab, Cmd-N for a workspace,
  Cmd-1 to Cmd-9 to select tabs, plus splits, pane focus, and zoom. They live in
  Herdr.app's own Ghostty config, so they cannot leak into the Ghostty you use
  for everything else.
- **Nothing downloaded to run.** The app is built on your Mac from the official
  Ghostty 1.3.1 app already in `/Applications` and signed locally. No prebuilt
  binary from a stranger.
- **Verified inputs.** The installer checks Ghostty's Developer ID team
  (`24VZTF6M5V`), then verifies the 38 MB pinned source archive against a
  SHA-256 digest and a minisign signature before it reuses anything from it.
- **Rollback.** Every install keeps the previous working release. One flag puts
  it back.

```sh
git clone https://github.com/benngarcia/herdr-macos.git
cd herdr-macos
./install.sh
# Herdr active release: ghostty-1.3.1-8b9d0854c9f5
# Herdr.app opens, running herdr, ready for Cmd-T
```

---

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [What the installer changes](#what-the-installer-changes)
- [Known limits](#known-limits)
- [Development](#development)
- [Provenance and license](#provenance-and-license)

## Requirements

- macOS
- [Herdr 0.7.5](https://herdr.dev/docs/install/) installed as `herdr`, on the
  `PATH` that a zsh login shell sees. The app starts Herdr with
  `/bin/zsh -l -c 'unset NO_COLOR; exec herdr'`, so if `herdr` is only on the
  `PATH` of a different shell, the window opens and closes immediately.
- The official Ghostty 1.3.1 app at `/Applications/Ghostty.app`. The version
  must match exactly.
- Full Xcode, which supplies `ibtool` for rebuilding the app's menu bar. The
  Command Line Tools alone are not enough.
- Homebrew packages `librsvg` (icon rendering), `libicns` (icon packing), and
  `minisign` (source verification):

```sh
brew install librsvg libicns minisign
```

## Install

```sh
git clone https://github.com/benngarcia/herdr-macos.git
cd herdr-macos
./install.sh
```

The installer builds the bundle, activates it at `~/Applications/Herdr.app`, and
opens it. `/Applications/Ghostty.app` is left exactly as it was.

Check that the active app is still intact and correctly signed:

```sh
./install.sh --verify
# Herdr verification passed: /Users/you/Applications/Herdr.app
```

Go back to the release you were running before:

```sh
./install.sh --rollback
```

Rebuild after pulling a change to this repository by running `./install.sh`
again. Each build gets a release ID derived from the pinned Ghostty version and
a digest of the app definition, and only the active release and the rollback
release are kept, so the store stays at two copies of about 62 MB each.

## What the installer changes

These paths belong to the installer:

```text
~/Applications/Herdr.app                        the app you launch
~/Library/Application Support/Herdr/installer/  releases, rollback links, config
~/Library/Caches/herdr-macos/                   verified Ghostty source archive
```

Two changes reach outside those paths, and both are worth knowing about:

**Herdr's key bindings become managed.** The Cmd shortcuts work by typing
Herdr's prefix sequences, so the installer appends a `[keys]` table under a
`# Managed by herdr-macos` marker to your Herdr config, pinning
`prefix = "ctrl+b"` and the pane-cycling keys. That config is shared with Herdr
everywhere else, not just inside Herdr.app. If the file already has a `[keys]`
table you wrote yourself, the installer stops and changes nothing rather than
overwrite it.

**Herdr.app keeps its own Herdr state.** The bundle sets `XDG_CONFIG_HOME` to
its private directory so it cannot read your normal Ghostty config. Herdr reads
the same variable, so the Herdr inside Herdr.app runs its own server with its own
config, sessions, and logs under
`~/Library/Application Support/Herdr/installer/xdg/herdr/`. Sessions you start by
typing `herdr` in another terminal live in `~/.config/herdr/` and will not show
up in Herdr.app.

## Known limits

- **The Ghostty version is pinned.** Upgrade `/Applications/Ghostty.app` past
  1.3.1 and the installer refuses to build until the pin in `install.sh` is
  updated. An already-installed Herdr.app keeps working, because it is a copy.
- **The signature is ad-hoc.** The rebuilt bundle is signed with `codesign
  --sign -`, which drops Ghostty's Developer ID signature, its hardened runtime,
  and its entitlements. The app is not notarized, and because each rebuild
  produces a new code identity, macOS treats it as a new app and asks again for
  permissions you had already granted.
- **No auto-update.** Sparkle is removed from the bundle and Ghostty's own
  updater is switched off. Rerun `./install.sh` to pick up changes.
- **Shortcuts assume Herdr 0.7.5.** They are sent as literal prefix key
  sequences adapted from
  [this shortcut reference](https://venabl.es/herdr-macos-shortcuts). If Herdr
  reassigns a key, the matching Cmd shortcut does the new thing silently.

## Development

[Bun](https://bun.sh/) runs the installer contract tests:

```sh
bun test
bash -n install.sh
```

The tests exercise installation, rollback, release retention, migration from the
old symlink layout, refusal to replace an app the installer does not own, and the
pinned app configuration, all in temporary directories. To exercise the real
build without touching your live install, point it at scratch directories:

```sh
./install.sh --applications-dir /tmp/apps --state-dir /tmp/state --no-launch
```

## Provenance and license

This is an independent packaging project, not an official Herdr or Ghostty
distribution. It launches a separately installed Herdr executable and builds
from an official Ghostty app already on your Mac.

The repository is licensed under AGPL-3.0-or-later because its icon derives from
Herdr. Ghostty remains available under the MIT License. The built app includes
both complete license texts and [`app/THIRD_PARTY.md`](app/THIRD_PARTY.md).
