#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
compile() {
  swiftc -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" \
    -framework Cocoa -framework ScreenSaver \
    PickleballScreensaver/*.swift "$1" -o "$2"
}
if [[ "${1:-}" == --art-only ]]; then
  compile scripts/tests/art/main.swift "$work/art"
  "$work/art"
  exit
fi
if [[ "${1:-}" != --preview-only ]]; then
  compile scripts/tests/main.swift "$work/regressions"
  "$work/regressions" "$@"
fi
if [[ $# == 0 ]]; then
  compile scripts/tests/art/main.swift "$work/art"
  "$work/art"
fi
if [[ "${1:-}" != --engine-only && "${1:-}" != --camera-only ]]; then
  compile scripts/preview/main.swift "$work/preview"
  bash scripts/tests/preview.sh "$work/preview" "$work"
fi
