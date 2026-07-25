# Herdr for macOS

Makes [Herdr](https://herdr.dev) a Mac app you can launch from Spotlight. Press
Cmd-Space, type Herdr, hit Enter, and Herdr opens in its own window with its own
Dock icon and Mac keyboard shortcuts. The Ghostty you already use, and the config
you have tuned for it, are untouched.

![Spotlight opens Herdr.app, Cmd-T opens a tab, and the Ghostty window beside it answers the same key on its own](docs/demo.gif)

- **A real app.** Spotlight, the Dock, the menu bar, notifications, and Activity
  Monitor all say Herdr, because `~/Applications/Herdr.app` is its own bundle
  with its own identifier and icon.
- **Its own Herdr.** The app runs a Herdr server whose config, sessions, and logs
  live under its own directory, so what you do in the app never mixes with
  `herdr` typed in another terminal.
- **Mac shortcuts.** Cmd-T, Cmd-N, Cmd-1 to Cmd-9, splits, pane focus, and zoom,
  all typed as whatever prefix your Herdr config uses. They live in the app's own
  terminal config and cannot leak into Ghostty.
- **Built from your Ghostty.** Nothing prebuilt is downloaded. The installer
  copies the Ghostty app already on your Mac, checks it against Ghostty's
  Developer ID team, verifies the matching source archive with the official
  minisign key, and signs the result locally.
- **Rollback.** Every install keeps the previous release. One flag puts it back.

## Requirements

- macOS, with the official [Ghostty](https://ghostty.org) app in
  `/Applications`. Any version works; the menu bar is rebuilt from the source of
  the release you have.
- [Herdr](https://herdr.dev/docs/install/) on the `PATH` of a zsh login shell,
  since that is how the app starts it.
- Full Xcode, for `ibtool`. Command Line Tools alone are not enough.
- `brew install librsvg libicns minisign`

## Install

```sh
git clone https://github.com/benngarcia/herdr-macos.git
cd herdr-macos
./install.sh
```

That builds the bundle, activates `~/Applications/Herdr.app`, and opens it. Rerun
it any time to rebuild, and use `./install.sh --verify` to check the active app
or `./install.sh --rollback` to go back one release. Only the active release and
the rollback release are kept, at about 62 MB each.

## What it changes

```text
~/Applications/Herdr.app                        the app you launch
~/Library/Application Support/Herdr/installer/  releases, rollback links, config
~/Library/Caches/herdr-macos/                   verified Ghostty source archive
```

Nothing outside those paths is written. The Cmd shortcuts need to know which
prefix to type, so the installer seeds `prefix`, `cycle_pane_previous`, and
`cycle_pane_next` into the app's own Herdr config, and only where you have not
set them yourself. Set your own prefix and the shortcuts are rebuilt to match it.

## Known limits

- **Permissions reset on rebuild.** The bundle is re-signed ad-hoc, which drops
  Ghostty's Developer ID signature, hardened runtime, and entitlements. Each
  rebuild is a new code identity, so macOS asks again for anything you had
  granted, and the app is not notarized.
- **No auto-update.** Sparkle is stripped and Ghostty's updater is off. Rerun
  `./install.sh`.
- **Shortcuts assume Herdr 0.7.5.** They send prefix sequences taken from
  [this shortcut reference](https://venabl.es/herdr-macos-shortcuts). If Herdr
  reassigns a key, the matching Cmd shortcut quietly does the new thing.
- **One Herdr per app.** Sessions in Herdr.app and sessions from `herdr` in
  another terminal are separate servers, on purpose. If you want one shared
  server everywhere, do not use this.

## Development

```sh
bun test
bash -n install.sh
```

The tests cover installation, rollback, release retention, migration from the old
symlink layout, refusal to replace an app the installer does not own, and the
configuration contracts. To exercise the real build without touching your live
install, point it somewhere scratch:

```sh
./install.sh --applications-dir /tmp/apps --state-dir /tmp/state --no-launch
```

`tools/record-demo.sh` regenerates `docs/demo.gif`. Run it from Ghostty or
Terminal, not from Herdr.app, and grant that terminal Screen Recording and
Accessibility first.

## Provenance and license

This is an independent packaging project, not an official Herdr or Ghostty
distribution. It launches a separately installed Herdr executable and builds from
an official Ghostty app already on your Mac.

The repository is licensed under AGPL-3.0-or-later because its icon derives from
Herdr. Ghostty remains available under the MIT License. The built app includes
both complete license texts and [`app/THIRD_PARTY.md`](app/THIRD_PARTY.md).
