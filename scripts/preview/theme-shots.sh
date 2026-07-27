#!/bin/bash
# Regenerate the download page's matched hero screenshots (macOS only).
#
# docs/index.html cross-fades the classic and black-light themes in one slot.
# For the fade to read as "the same court changing color" rather than a cut
# between two unrelated moments, both frames must be the same instant of the
# same rally — same seed, same clock, same format, differing only in theme.
#
# The harness reseeds after applyTheme() and the theme choice consumes no RNG,
# so two runs with an identical --seed simulate identically: frame N of the
# classic run and frame N of the black-light run are the same moment.
#
#   ./scripts/preview/theme-shots.sh [--seed N] [--frame N] [--singles]
#
# Run from the repo root. Writes docs/screenshot-classic.jpg (classic) and
# docs/screenshot.jpg (black-light), both 1280x720 — the harness's native size,
# which is already the 16:9 the page reserves.
set -euo pipefail

SEED=7
FRAME=150          # 30 png/s, so 150 ~= 5 s in — mid-rally, past the serve
FORMAT=--doubles
CLOCK=90           # keeps the turntable spin off a short run
SECONDS_RUN=8
QUALITY=82

while [ $# -gt 0 ]; do
  case "$1" in
    --seed)    SEED=$2; shift 2 ;;
    --frame)   FRAME=$2; shift 2 ;;
    --singles) FORMAT=--singles; shift ;;
    --doubles) FORMAT=--doubles; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ "$(uname)" = "Darwin" ] || { echo "macOS only: needs swiftc, Cocoa/ScreenSaver and sips" >&2; exit 1; }
[ -d PickleballScreensaver ] || { echo "run from the repo root" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "building the preview harness..."
swiftc -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" \
  -framework Cocoa -framework ScreenSaver \
  PickleballScreensaver/*.swift scripts/preview/main.swift -o "$work/pbpreview"

shoot() {   # shoot <theme-flag> <out-jpg>
  local theme=$1 out=$2 dir="$work/${1#--}"
  echo "rendering $theme (seed=$SEED $FORMAT)..."
  "$work/pbpreview" "$dir" "$SECONDS_RUN" "$CLOCK" "--seed=$SEED" "$FORMAT" "$theme" >/dev/null
  local src
  src=$(printf '%s/frame_%05d.png' "$dir" "$FRAME")
  [ -f "$src" ] || { echo "frame $FRAME not rendered; lower --frame or raise SECONDS_RUN" >&2; exit 1; }
  sips -s format jpeg -s formatOptions "$QUALITY" "$src" --out "$out" >/dev/null
  echo "  wrote $out"
}

shoot --classic    docs/screenshot-classic.jpg
shoot --blacklight docs/screenshot.jpg

echo
echo "done — both frames are moment $FRAME of seed $SEED, so they align under the cross-fade."
echo "preview with:  open docs/index.html"
echo "not the moment you want? re-run with a different --frame (or --seed)."
