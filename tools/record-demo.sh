#!/usr/bin/env bash
set -euo pipefail

# Records the README demo: Spotlight opens Herdr.app, Cmd-T in Herdr, then the
# same key in Ghostty next door. Run it from Ghostty or Terminal, never from
# Herdr.app, because the recording quits Herdr to capture a real launch.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output="${1:-$repo_root/docs/demo.gif}"
herdr_bundle_id='dev.bengarcia.herdr'
ghostty_bundle_id='com.mitchellh.ghostty'
seconds=17
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { printf '%s\n' "$1" >&2; exit 1; }

settings_pane() {
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_$1"
}

[[ "$(printf '%s' "${__CFBundleIdentifier:-}" | tr 'A-Z' 'a-z')" != *herdr* ]] ||
  fail 'Run this from Ghostty or Terminal. It quits Herdr.app, which would kill this session.'

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

open -b "$ghostty_bundle_id"
osascript -e "tell application id \"$herdr_bundle_id\" to quit" >/dev/null 2>&1 || true
sleep 2

printf 'Recording %s seconds. Keep your hands off the keyboard.\n' "$seconds"
screencapture -v -V "$seconds" -k -x "$work/demo.mov" &
recorder=$!
sleep 2

osascript <<'APPLESCRIPT'
on pause(seconds)
  delay seconds
end pause

tell application "System Events"
  key code 49 using command down -- Spotlight
  pause(1)
  keystroke "Herdr"
  pause(2)
  key code 36 -- open the app
  pause(4)
  keystroke "t" using command down -- a Herdr tab
  pause(3)
end tell

tell application id "com.mitchellh.ghostty" to activate
pause(2)
tell application "System Events" to keystroke "t" using command down -- a Ghostty tab
pause(2)
APPLESCRIPT

wait "$recorder"

mkdir -p "$(dirname "$output")"
ffmpeg -hide_banner -loglevel error -i "$work/demo.mov" \
  -vf 'fps=12,scale=1280:-1:flags=lanczos,palettegen=stats_mode=diff' \
  -y "$work/palette.png"
ffmpeg -hide_banner -loglevel error -i "$work/demo.mov" -i "$work/palette.png" \
  -lavfi 'fps=12,scale=1280:-1:flags=lanczos,paletteuse=dither=bayer:bayer_scale=3' \
  -y "$output"

printf '%s (%s)\n' "$output" "$(du -h "$output" | cut -f1)"
