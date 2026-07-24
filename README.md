# Herdr for macOS

Herdr for macOS builds a dedicated native `Herdr.app` from the official Ghostty
application. It gives Herdr its own app identity, configuration, and macOS
shortcuts without changing the Ghostty installation you already use.

- **Native application.** Spotlight, the Dock, the menu bar, notifications, and
  process inspection identify the application as Herdr.
- **Isolated configuration.** Herdr.app does not load your normal Ghostty
  configuration, so its shortcuts cannot change Ghostty in other contexts.
- **Mac shortcuts.** `Cmd-N` creates a workspace, `Cmd-T` creates a tab, and
  `Cmd-1` through `Cmd-9` select tabs.
- **Verified inputs.** The installer accepts the official Ghostty 1.3.1 app,
  verifies its Developer ID team, and verifies the pinned source archive with
  SHA-256 and minisign before rebuilding the native menu.
- **Local build.** The generated bundle contains your own Application Support
  path and receives a local ad-hoc signature instead of downloading a
  machine-specific prebuilt app.
- **Rollback.** The installer retains the previous working release and can
  reactivate it.

```text
Ghostty.app + Herdr + this repository
                 |
                 v
       ~/Applications/Herdr.app
```

## Requirements

- macOS
- [Herdr 0.7.5](https://herdr.dev/docs/install/) available as `herdr`
- The official Ghostty 1.3.1 application at `/Applications/Ghostty.app`
- Full Xcode, which supplies `ibtool`
- Homebrew packages `librsvg`, `libicns`, and `minisign`

Install the command-line dependencies:

```sh
brew install librsvg libicns minisign
```

## Install

```sh
git clone https://github.com/benngarcia/herdr-macos.git
cd herdr-macos
./install.sh
```

The installer builds, activates, and opens `~/Applications/Herdr.app`. The
original `/Applications/Ghostty.app` remains unchanged.

Verify the active installation:

```sh
./install.sh --verify
```

Restore the previous managed release:

```sh
./install.sh --rollback
```

## What the installer changes

The installer owns these paths:

```text
~/Applications/Herdr.app
~/Library/Application Support/Herdr/installer/
~/Library/Caches/herdr-macos/
```

It also adds a managed `[keys]` table to `~/.config/herdr/config.toml`. If that
file already contains a user-owned `[keys]` table, installation stops instead
of overwriting it.

Herdr.app removes an inherited `NO_COLOR` variable so Claude and other terminal
applications can emit their normal ANSI colors. Its Ghostty configuration lives
under Herdr's Application Support directory and does not read Ghostty's usual
configuration files.

## Development

[Bun](https://bun.sh/) runs the installer contract tests:

```sh
bun test
bash -n install.sh
```

The tests exercise installation, rollback, release retention, unmanaged-app
protection, and the pinned app configuration in isolated temporary directories.

## Provenance and license

This is an independent packaging project and is not an official Herdr or
Ghostty distribution. It launches a separately installed Herdr executable and
builds from an official Ghostty application on the user's Mac.

The repository is licensed under AGPL-3.0-or-later because its icon derives
from Herdr. Ghostty remains available under the MIT License. The built
application includes both complete license texts and
[`app/THIRD_PARTY.md`](app/THIRD_PARTY.md).
