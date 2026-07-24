#!/usr/bin/env bash
set -euo pipefail

ghostty_version='1.3.1'
ghostty_sha256='3349d25600ffbda281197a18314f7d18791969cffe9474f0ff16a45a9ebfccdb'
ghostty_minisign_key='RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV'
ghostty_bundle_id='com.mitchellh.ghostty'
ghostty_team_id='24VZTF6M5V'
herdr_bundle_id='dev.bengarcia.herdr'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
definition_dir="$repo_root/app"
app_name='Herdr.app'
applications_dir="${HOME}/Applications"
state_dir="${HOME}/Library/Application Support/Herdr/installer"
source_app=''
release_id=''
rollback_id=''
mode='build'
launch_after=true

usage() {
  printf '%s\n' \
    'Usage:' \
    '  ./install.sh [options]' \
    '  ./install.sh --app PATH --release-id ID [options]' \
    '  ./install.sh --rollback [RELEASE_ID] [options]' \
    '  ./install.sh --verify [options]' \
    '' \
    'Builds Herdr.app from the pinned, signed Ghostty application already' \
    'installed at /Applications/Ghostty.app, signs it locally, and activates' \
    "$HOME/Applications/Herdr.app. The prior release remains available for rollback." \
    '' \
    'Options:' \
    '  --app PATH              Install an already built Herdr.app' \
    '  --release-id ID         Release ID for --app' \
    '  --rollback [ID]         Activate the prior or named release' \
    '  --verify                Verify the active application' \
    '  --applications-dir DIR  Canonical app directory' \
    '  --state-dir DIR         Versioned release state directory' \
    '  --no-launch             Activate without launching' \
    '  -h, --help              Show this help'
}

while (($#)); do
  case "$1" in
    --app) mode='install'; shift; source_app="${1:?--app requires a path}" ;;
    --release-id) shift; release_id="${1:?--release-id requires an ID}" ;;
    --rollback)
      mode='rollback'
      if (($# > 1)) && [[ "${2}" != --* ]]; then shift; rollback_id="$1"; fi
      ;;
    --verify) mode='verify' ;;
    --applications-dir) shift; applications_dir="${1:?--applications-dir requires a path}" ;;
    --state-dir) shift; state_dir="${1:?--state-dir requires a path}" ;;
    --no-launch) launch_after=false ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "${HERDR_MACOS_INSTALLER_TESTING:-0}" != 1 && "$(uname -s)" != Darwin ]]; then
  printf 'Herdr.app can only be built and installed on macOS.\n' >&2
  exit 1
fi
command -v codesign >/dev/null || { printf 'codesign is required.\n' >&2; exit 1; }
command -v ditto >/dev/null || { printf 'ditto is required.\n' >&2; exit 1; }

release_root="$state_dir/releases"
current_link="$state_dir/current"
previous_link="$state_dir/previous"
activation_log="$state_dir/activations.tsv"
ghostty_xdg_root="$state_dir/xdg"
ghostty_config="$ghostty_xdg_root/ghostty/config"
canonical_app="$applications_dir/$app_name"
lock_dir="$state_dir/.install-lock"
mkdir -p "$applications_dir" "$release_root"
if ! mkdir "$lock_dir" 2>/dev/null; then
  printf 'Another Herdr install or rollback is already running.\n' >&2
  exit 1
fi

stage_dir=''
next_app=''
prior_app=''
config_next=''
cleanup() {
  [[ -z "$stage_dir" ]] || rm -rf "$stage_dir"
  [[ -z "$next_app" ]] || rm -rf "$next_app"
  [[ -z "$prior_app" ]] || rm -rf "$prior_app"
  [[ -z "$config_next" ]] || rm -f "$config_next"
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

verify_app() {
  local app="$1"
  [[ -d "$app" ]] || { printf 'Herdr app bundle is missing: %s\n' "$app" >&2; return 1; }
  [[ -x "$app/Contents/MacOS/ghostty" ]] || {
    printf 'Herdr terminal executable is missing: %s\n' "$app/Contents/MacOS/ghostty" >&2
    return 1
  }
  [[ -f "$app/Contents/Resources/herdr.ghostty" ]] || {
    printf 'Herdr terminal configuration is missing.\n' >&2
    return 1
  }
  if grep -Eq '^[[:space:]]*config-default-files[[:space:]]*=' "$app/Contents/Resources/herdr.ghostty"; then
    printf 'Herdr terminal configuration must rely on its isolated XDG root.\n' >&2
    return 1
  fi
  grep -Fxq "command = /bin/zsh -l -c 'exec herdr'" "$app/Contents/Resources/herdr.ghostty" || {
    printf 'Herdr terminal configuration does not start Herdr.\n' >&2
    return 1
  }
  if [[ "${HERDR_MACOS_INSTALLER_TESTING:-0}" != 1 ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$herdr_bundle_id" ]] || {
      printf 'Unexpected Herdr bundle identifier.\n' >&2
      return 1
    }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" == ghostty ]] || {
      printf 'Herdr must preserve Ghostty as its native bundle executable.\n' >&2
      return 1
    }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:XDG_CONFIG_HOME' "$app/Contents/Info.plist")" == "$ghostty_xdg_root" ]] || {
      printf 'Herdr does not point at its isolated terminal configuration root.\n' >&2
      return 1
    }
  fi
  codesign --verify --deep --strict "$app"
}

resolve_link() {
  local link="$1" target
  [[ -L "$link" ]] || return 1
  target="$(readlink "$link")"
  if [[ "$target" == /* ]]; then
    printf '%s\n' "$target"
  else
    printf '%s/%s\n' "$(cd "$(dirname "$link")" && pwd -P)" "$target"
  fi
}

replace_link() {
  local source="$1" destination="$2"
  if [[ "$(uname -s)" == Darwin ]]; then
    mv -fh "$source" "$destination"
  else
    mv -Tf "$source" "$destination"
  fi
}

managed_release_app() {
  local app="$1"
  [[ "$app" == "$release_root"/*"/$app_name" ]]
}

active_release() {
  local active=''
  if [[ -L "$canonical_app" ]]; then
    active="$(resolve_link "$canonical_app")"
  elif [[ -d "$canonical_app" && -L "$current_link" ]]; then
    active="$(resolve_link "$current_link")"
  else
    return 1
  fi
  managed_release_app "$active" || return 1
  printf '%s\n' "$active"
}

prune_releases() {
  local current_release="$1" retained_release=''
  if [[ -L "$previous_link" ]]; then
    retained_release="$(dirname "$(resolve_link "$previous_link")")"
  fi
  local candidate
  for candidate in "$release_root"/*; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    [[ "$candidate" == "$current_release" || "$candidate" == "$retained_release" ]] &&
      continue
    rm -rf "$candidate"
  done
}

activate() {
  local target="$1" prior='' current_next='' previous_next=''
  verify_app "$target"
  managed_release_app "$target" || {
    printf 'Refusing to activate an app outside the managed release store.\n' >&2
    return 1
  }
  if [[ -e "$canonical_app" || -L "$canonical_app" ]]; then
    prior="$(active_release)" || {
      printf 'Refusing to replace a non-managed app at %s.\n' "$canonical_app" >&2
      return 1
    }
  fi

  next_app="$applications_dir/.Herdr-next.$$.app"
  ditto --rsrc --extattr "$target" "$next_app"
  verify_app "$next_app"

  if [[ "$launch_after" == true ]]; then
    osascript -e "tell application id \"$herdr_bundle_id\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -f '/Herdr\.app/Contents/(MacOS/ghostty|Helpers/Herdr)' >/dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -f '/Herdr\.app/Contents/(MacOS/ghostty|Helpers/Herdr)' >/dev/null 2>&1; then
      printf 'Herdr did not quit; the release was not switched.\n' >&2
      return 1
    fi
  fi

  if [[ -n "$prior" && "$prior" != "$target" ]]; then
    previous_next="$state_dir/.previous.$$"
    ln -s "$prior" "$previous_next"
  fi
  current_next="$state_dir/.current.$$"
  ln -s "$target" "$current_next"

  if [[ -e "$canonical_app" || -L "$canonical_app" ]]; then
    prior_app="$applications_dir/.Herdr-prior.$$.app"
    mv "$canonical_app" "$prior_app"
  fi
  if ! mv "$next_app" "$canonical_app"; then
    [[ -z "$prior_app" ]] || mv "$prior_app" "$canonical_app"
    return 1
  fi
  next_app=''
  rm -rf "$prior_app"
  prior_app=''

  mkdir -p "$(dirname "$ghostty_config")"
  config_next="$ghostty_config.next.$$"
  cp "$canonical_app/Contents/Resources/herdr.ghostty" "$config_next"
  mv -f "$config_next" "$ghostty_config"
  config_next=''

  if [[ -n "$previous_next" ]]; then
    replace_link "$previous_next" "$previous_link"
  fi
  replace_link "$current_next" "$current_link"
  printf '%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(basename "$(dirname "$target")")" \
    "$target" >> "$activation_log"
  prune_releases "$(dirname "$target")"
  if [[ "$launch_after" == true ]]; then
    open "$canonical_app"
  fi
  printf 'Herdr active release: %s\n' "$(basename "$(dirname "$target")")"
}

install_app() {
  [[ -n "$source_app" ]] || { printf '--app is required.\n' >&2; exit 2; }
  [[ -n "$release_id" ]] || { printf '--release-id is required.\n' >&2; exit 2; }
  [[ "$release_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    printf 'Release ID contains invalid characters.\n' >&2
    exit 2
  }
  source_app="$(cd "$(dirname "$source_app")" && pwd -P)/$(basename "$source_app")"
  verify_app "$source_app"
  local release_dir="$release_root/$release_id"
  if [[ ! -e "$release_dir" ]]; then
    stage_dir="$(mktemp -d "$release_root/.install.XXXXXX")"
    ditto --rsrc --extattr "$source_app" "$stage_dir/$app_name"
    verify_app "$stage_dir/$app_name"
    mv "$stage_dir" "$release_dir"
    stage_dir=''
  fi
  activate "$release_dir/$app_name"
}

build_icon() {
  local resources="$1" generated="$2" size png
  local pngs=()
  mkdir -p "$generated"
  for size in 16 32 128 256 512 1024; do
    png="$generated/Herdr-${size}.png"
    rsvg-convert -w "$size" -h "$size" "$definition_dir/Herdr.svg" -o "$png"
    pngs+=("$png")
  done
  png2icns "$resources/Herdr.icns" "${pngs[@]}" >/dev/null 2>&1
}

verified_ghostty_source() {
  local cache_root="${HOME}/Library/Caches/herdr-macos/ghostty-${ghostty_version}"
  local archive="$cache_root/ghostty-${ghostty_version}.tar.gz"
  local signature="$archive.minisig"
  local source="$cache_root/source"
  mkdir -p "$cache_root"
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --output "$archive" \
      "https://release.files.ghostty.org/${ghostty_version}/ghostty-${ghostty_version}.tar.gz"
  fi
  if [[ ! -f "$signature" ]]; then
    curl --fail --location --output "$signature" \
      "https://release.files.ghostty.org/${ghostty_version}/ghostty-${ghostty_version}.tar.gz.minisig"
  fi
  [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" == "$ghostty_sha256" ]] || {
    printf 'Ghostty source archive digest does not match the pin.\n' >&2
    return 1
  }
  command -v minisign >/dev/null || { printf 'Homebrew minisign is required.\n' >&2; return 1; }
  minisign -Vm "$archive" -x "$signature" -P "$ghostty_minisign_key" >/dev/null
  if [[ ! -f "$source/macos/Sources/App/macOS/MainMenu.xib" ]]; then
    [[ ! -e "$source" ]] || {
      printf 'Ghostty source cache is incomplete: %s\n' "$source" >&2
      return 1
    }
    local extract
    extract="$(mktemp -d "$cache_root/.extract.XXXXXX")"
    tar -xzf "$archive" -C "$extract" --strip-components=1
    mv "$extract" "$source"
  fi
  printf '%s\n' "$source"
}

compile_main_menu() {
  local app="$1" source="$2" xib="$stage_dir/MainMenu.xib"
  cp "$source/macos/Sources/App/macOS/MainMenu.xib" "$xib"
  sed -i '' \
    -e 's/title="Ghostty"/title="Herdr"/g' \
    -e 's/title="About Ghostty"/title="About Herdr"/g' \
    -e 's/title="Make Ghostty the Default Terminal"/title="Make Herdr the Default Terminal"/g' \
    -e 's/title="Hide Ghostty"/title="Hide Herdr"/g' \
    -e 's/title="Quit Ghostty"/title="Quit Herdr"/g' \
    -e 's/title="Ghostty Help"/title="Herdr Help"/g' \
    -e 's/selector="showAbout:"/selector="orderFrontStandardAboutPanel:"/' \
    "$xib"
  sed -i '' '/<menuItem title="Check for Updates\.\.\."/,/<\/menuItem>/d' "$xib"
  ibtool --compile "$app/Contents/Resources/MainMenu.nib" "$xib"
}

install_herdr_keys() {
  [[ "${HERDR_MACOS_INSTALLER_TESTING:-0}" != 1 ]] || return 0
  local config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/herdr"
  local config="$config_dir/config.toml"
  mkdir -p "$config_dir"
  touch "$config"
  if grep -Eq '^[[:space:]]*\[keys\][[:space:]]*$' "$config"; then
    grep -Fq 'Managed by herdr-macos' "$config" || {
      printf 'Herdr already has an unmanaged [keys] table at %s; refusing to overwrite it.\n' "$config" >&2
      return 1
    }
    herdr config reset-keys >/dev/null
    config_next="$config.next.$$"
    sed '/^# Managed by herdr-macos$/d' "$config" > "$config_next"
    mv -f "$config_next" "$config"
    config_next=''
  fi
  {
    printf '\n# Managed by herdr-macos\n'
    sed '1{/^# Managed Herdr key overrides/d;}' "$definition_dir/herdr-keys.toml"
  } >> "$config"
  herdr config check
  herdr server reload-config >/dev/null 2>&1 || true
}

set_plist() {
  local plist="$1" key="$2" value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
}

brand_bundle_metadata() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local permission_keys=(
    NSAppleEventsUsageDescription
    NSBluetoothAlwaysUsageDescription
    NSCalendarsUsageDescription
    NSCameraUsageDescription
    NSContactsUsageDescription
    NSLocalNetworkUsageDescription
    NSLocationUsageDescription
    NSMicrophoneUsageDescription
    NSMotionUsageDescription
    NSPhotoLibraryUsageDescription
    NSRemindersUsageDescription
    NSSpeechRecognitionUsageDescription
    NSSystemAdministrationUsageDescription
  )
  local key value
  for key in "${permission_keys[@]}"; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
    set_plist "$plist" "$key" "${value//Ghostty/Herdr}"
  done
  set_plist "$plist" NSServices:0:NSMenuItem:default "New Herdr Tab Here"
  set_plist "$plist" NSServices:1:NSMenuItem:default "New Herdr Window Here"
  set_plist "$plist" UTExportedTypeDeclarations:0:UTTypeDescription "Herdr Surface Identifier"
  set_plist "$plist" UTExportedTypeDeclarations:0:UTTypeIdentifier \
    "${herdr_bundle_id}.surface-id"

  local plugin_plist="$app/Contents/PlugIns/DockTilePlugin.plugin/Contents/Info.plist"
  set_plist "$plugin_plist" CFBundleDisplayName "Herdr Dock Tile Plugin"
  set_plist "$plugin_plist" CFBundleIdentifier "${herdr_bundle_id}.dock-tile"

  local scripting_definition="$app/Contents/Resources/Ghostty.sdef"
  sed -i '' -e 's/Ghostty/Herdr/g' -e 's/HerdrScript/GhosttyScript/g' \
    "$scripting_definition"
}

build_app() {
  local ghostty_app='/Applications/Ghostty.app'
  [[ -d "$ghostty_app" ]] || { printf 'Install Ghostty.app 1.3.1 first.\n' >&2; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ghostty_app/Contents/Info.plist")" == "$ghostty_bundle_id" ]] || {
    printf 'The source application is not official Ghostty.\n' >&2
    exit 1
  }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ghostty_app/Contents/Info.plist")" == "$ghostty_version" ]] || {
    printf 'Ghostty.app must be version %s.\n' "$ghostty_version" >&2
    exit 1
  }
  codesign --verify --deep --strict "$ghostty_app"
  local signature
  signature="$(codesign -dv --verbose=4 "$ghostty_app" 2>&1 || true)"
  grep -Fq "TeamIdentifier=$ghostty_team_id" <<<"$signature" || {
    printf 'Ghostty.app is not signed by the expected upstream team.\n' >&2
    exit 1
  }
  command -v rsvg-convert >/dev/null || { printf 'Homebrew librsvg is required.\n' >&2; exit 1; }
  command -v png2icns >/dev/null || { printf 'Homebrew libicns is required.\n' >&2; exit 1; }
  command -v ibtool >/dev/null || { printf 'Xcode ibtool is required.\n' >&2; exit 1; }
  local ghostty_source
  ghostty_source="$(verified_ghostty_source)"

  stage_dir="$(mktemp -d "$release_root/.build.XXXXXX")"
  local app="$stage_dir/$app_name"
  ditto --rsrc --extattr "$ghostty_app" "$app"
  cp "$definition_dir/herdr.ghostty" "$app/Contents/Resources/herdr.ghostty"
  cp "$definition_dir/THIRD_PARTY.md" "$app/Contents/Resources/THIRD_PARTY.md"
  cp "$repo_root/LICENSE" "$app/Contents/Resources/LICENSE-HERDR-AGPL-3.0.txt"
  cp "$ghostty_source/LICENSE" "$app/Contents/Resources/LICENSE-GHOSTTY-MIT.txt"
  build_icon "$app/Contents/Resources" "$stage_dir/Herdr-icons"
  compile_main_menu "$app" "$ghostty_source"

  local plist="$app/Contents/Info.plist"
  set_plist "$plist" CFBundleDisplayName Herdr
  set_plist "$plist" CFBundleName Herdr
  set_plist "$plist" CFBundleIdentifier "$herdr_bundle_id"
  set_plist "$plist" CFBundleExecutable ghostty
  set_plist "$plist" CFBundleIconFile Herdr.icns
  set_plist "$plist" LSEnvironment:XDG_CONFIG_HOME "$ghostty_xdg_root"
  set_plist "$plist" NSHumanReadableCopyright "Terminal implementation: Ghostty ${ghostty_version}"
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Delete :SUPublicEDKey' "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Delete :SUEnableAutomaticChecks' "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$plist" 2>/dev/null || true
  brand_bundle_metadata "$app"

  codesign --force --deep --sign - "$app"
  verify_app "$app"

  local definition_digest
  definition_digest="$(
    shasum -a 256 \
      "$definition_dir/herdr.ghostty" \
      "$definition_dir/herdr-keys.toml" \
      "$definition_dir/Herdr.svg" \
      "$0" |
      shasum -a 256 |
      cut -c1-12
  )"
  release_id="ghostty-${ghostty_version}-${definition_digest}"
  source_app="$app"
  install_herdr_keys
  install_app
}

case "$mode" in
  build) build_app ;;
  install) install_app ;;
  verify)
    verify_app "$canonical_app"
    printf 'Herdr verification passed: %s\n' "$canonical_app"
    ;;
  rollback)
    target=''
    if [[ -n "$rollback_id" ]]; then
      target="$release_root/$rollback_id/$app_name"
    elif [[ -L "$previous_link" ]]; then
      target="$(resolve_link "$previous_link")"
    else
      printf 'No Herdr rollback release is available.\n' >&2
      exit 1
    fi
    activate "$target"
    ;;
esac
