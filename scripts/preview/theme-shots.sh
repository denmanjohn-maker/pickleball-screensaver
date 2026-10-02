#!/bin/bash
# Regenerate the download page's five appearance screenshots (macOS only).
#
# The first four appearances share a seed, frame, clock, and format. Painting
# uses a later frame so its accumulated strokes are visible. No-spin framing
# makes the court larger while keeping every shot at the same camera angle.
#
# The harness reseeds after applyAppearance(); artwork consumes no game RNG.
#
#   ./scripts/preview/theme-shots.sh [--seed N] [--frame N] [--painting-frame N] [--singles]
#
# Run from the repo root. Writes five 1280x720 JPEGs in docs/.
set -euo pipefail

SEED=42
FRAME=210          # 30 sampled frames/s: just after a live impact
PAINTING_FRAME=3000
FORMAT=--doubles
CLOCK=90           # keeps the turntable spin off a short run
QUALITY=82

while [ $# -gt 0 ]; do
  case "$1" in
    --seed)    SEED=$2; shift 2 ;;
    --frame)   FRAME=$2; shift 2 ;;
    --painting-frame) PAINTING_FRAME=$2; shift 2 ;;
    --singles) FORMAT=--singles; shift ;;
    --doubles) FORMAT=--doubles; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$SEED" =~ ^[0-9]+$ && "$FRAME" =~ ^[0-9]+$ && "$PAINTING_FRAME" =~ ^[0-9]+$ ]] || {
  echo "seed and frame values must be nonnegative integers" >&2; exit 2;
}

[ "$(uname)" = "Darwin" ] || { echo "macOS only: needs swiftc, Cocoa/ScreenSaver and sips" >&2; exit 1; }
[ -d PickleballScreensaver ] || { echo "run from the repo root" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "building the preview harness..."
swiftc -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" \
  -framework Cocoa -framework ScreenSaver \
  PickleballScreensaver/*.swift scripts/preview/main.swift -o "$work/pbpreview"

shoot() {   # shoot <appearance> <out-jpg> <sampled-frame>
  local appearance=$1 out=$2 frame=$3 dir="$work/$1"
  local seconds_run=$((frame / 30 + 1))
  echo "rendering $appearance (seed=$SEED $FORMAT frame=$frame)..."
  "$work/pbpreview" "$dir" "$seconds_run" "$CLOCK" "--seed=$SEED" "$FORMAT" "--appearance=$appearance" \
    --motion=still "--frame=$frame" >/dev/null
  local src
  src=$(printf '%s/frame_%05d.png' "$dir" "$frame")
  [ -f "$src" ] || { echo "frame $frame not rendered" >&2; exit 1; }
  sips -s format jpeg -s formatOptions "$QUALITY" "$src" --out "$out" >/dev/null
  echo "  wrote $out"
}

shoot classic         docs/screenshot-classic.jpg "$FRAME"
shoot blacklight      docs/screenshot.jpg "$FRAME"
shoot living-court    docs/screenshot-living-court.jpg "$FRAME"
shoot ink-and-paper   docs/screenshot-ink-and-paper.jpg "$FRAME"
shoot rally-painting  docs/screenshot-rally-painting.jpg "$PAINTING_FRAME"

echo
echo "done — four matched rally views and an accumulated painting, all from seed $SEED."
echo "preview with:  open docs/index.html"
echo "not the moment you want? re-run with a different --frame (or --seed)."
