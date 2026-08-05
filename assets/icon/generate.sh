#!/bin/sh
# Regenerates AppIcon.icns, the System Settings thumbnails, and the download-page
# favicon from the SVG sources in this directory. macOS only (swiftc + iconutil;
# SVG rasterization uses NSImage, macOS 11+).
set -eu
cd "$(dirname "$0")"

swiftc -O rasterize.swift -o /tmp/pbicon-rasterize

rm -rf /tmp/pbicon.iconset
mkdir -p /tmp/pbicon.iconset
for s in 16 32 128 256 512; do
  /tmp/pbicon-rasterize icon.svg "/tmp/pbicon.iconset/icon_${s}x${s}.png" "$s"
  /tmp/pbicon-rasterize icon.svg "/tmp/pbicon.iconset/icon_${s}x${s}@2x.png" "$((s * 2))"
done
iconutil --convert icns /tmp/pbicon.iconset --output ../../PickleballScreensaver/Resources/AppIcon.icns

/tmp/pbicon-rasterize thumbnail.svg ../../PickleballScreensaver/Resources/thumbnail.png 90 58
/tmp/pbicon-rasterize thumbnail.svg ../../PickleballScreensaver/Resources/thumbnail@2x.png 180 116
/tmp/pbicon-rasterize icon.svg ../../docs/icon.png 512

echo "Regenerated AppIcon.icns, thumbnails, and docs/icon.png"
