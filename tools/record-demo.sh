#!/usr/bin/env bash
set -euo pipefail

# Records the README demo: Spotlight opens Herdr.app, Cmd-T in Herdr, then the
# same key in Ghostty next door. Run it from Ghostty or Terminal, never from
# Herdr.app, because the recording quits Herdr to capture a real launch.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output="${1:-$repo_root/docs/demo.gif}"
installed_app="${HOME}/Applications/Herdr.app"
ghostty_bundle_id='com.mitchellh.ghostty'
seconds=17
recorder=''
work="$(mktemp -d)"

cleanup() {
  [[ -z "$recorder" ]] || kill "$recorder" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() { printf '%s\n' "$1" >&2; exit 1; }

settings_pane() {
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_$1"
}

[[ "$(printf '%s' "${__CFBundleIdentifier:-}" | tr 'A-Z' 'a-z')" != *herdr* ]] ||
  fail 'Run this from Ghostty or Terminal. It quits Herdr.app, which would kill this session.'
[[ -d "$installed_app" ]] || fail "No app to record: $installed_app is missing."

# screencapture reports a blocked display on stdout and still exits 0, so the
# only reliable probe is whether a frame came out.
screencapture -x -t png "$work/probe.png" >/dev/null 2>&1 || true
[[ -s "$work/probe.png" ]] || {
  settings_pane ScreenCapture
  fail 'Grant Screen & System Audio Recording to this terminal, then run again.'
}
osascript -e 'tell application "System Events" to key code 63' >/dev/null 2>&1 || {
  settings_pane Accessibility
  fail 'Grant Accessibility to this terminal, then run again.'
}

# Quit whatever identifier the installed bundle actually carries, so a Herdr
# built before an identifier change still gets closed.
quit_herdr() {
  local id
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$installed_app/Contents/Info.plist" 2>/dev/null || true)"
  [[ -z "$id" ]] || osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
  local _
  for _ in 1 2 3 4 5; do
    pgrep -f "$installed_app/Contents/MacOS/ghostty" >/dev/null 2>&1 || return 0
    sleep 1
  done
  pkill -f "$installed_app/Contents/MacOS/ghostty" 2>/dev/null || true
  sleep 1
}

open -b "$ghostty_bundle_id"
quit_herdr

printf 'Recording the main display for %s seconds. Hands off the keyboard.\n' "$seconds"
screencapture -v -V "$seconds" -k -x "$work/demo.mov" &
recorder=$!
sleep 2

osascript <<'APPLESCRIPT'
tell application "System Events"
  key code 49 using command down -- Spotlight
  delay 1
  keystroke "Herdr"
  delay 2
  key code 36 -- open the app
  delay 5
  keystroke "t" using command down -- a Herdr tab
  delay 3
end tell

tell application id "com.mitchellh.ghostty" to activate
delay 2
tell application "System Events"
  keystroke "t" using command down -- a Ghostty tab
  delay 2
end tell
APPLESCRIPT

wait "$recorder"
recorder=''
[[ -s "$work/demo.mov" ]] || fail 'The recording produced no video.'

mkdir -p "$(dirname "$output")"
ffmpeg -hide_banner -loglevel error -i "$work/demo.mov" \
  -vf 'fps=12,scale=1280:-1:flags=lanczos,palettegen=stats_mode=diff' \
  -y "$work/palette.png"
ffmpeg -hide_banner -loglevel error -i "$work/demo.mov" -i "$work/palette.png" \
  -lavfi 'fps=12,scale=1280:-1:flags=lanczos,paletteuse=dither=bayer:bayer_scale=3' \
  -y "$output"

printf '%s (%s)\n' "$output" "$(du -h "$output" | cut -f1)"
