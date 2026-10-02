#!/bin/bash
set -euo pipefail
preview=$1
work=$2

expect_invalid() {
  local expected=$1 status=0
  shift
  "$preview" "$work/invalid" "$@" --sim-only >"$work/invalid.log" 2>&1 || status=$?
  if [[ "$status" != 2 ]] || ! grep -Fq -- "$expected" "$work/invalid.log"; then
    cat "$work/invalid.log" >&2
    echo "FAIL: preview must reject invalid arguments with a usage error" >&2
    exit 1
  fi
}

expect_invalid "--frame must identify" 0.375 90 --fps=4 --sample-every=1 --frame=1
expect_invalid "--frame must identify" 0.625 90 --fps=4 --sample-every=2 --frame=1
expect_invalid "--frame must identify" 0.625 90 --fps=4 --sample-every=2 --frame=9223372036854775807
expect_invalid "duration must contain" 0.1 90 --fps=4 --frame=0
expect_invalid "duration must contain" 1e308 90 --fps=4 --frame=0

flags=(--fps=4 --sample-every=1 --seed=42 --classic --doubles --motion=still --size=320x180)
"$preview" "$work/first" 0.375 0 "${flags[@]}" --frame=0
"$preview" "$work/last" 0.625 0 "${flags[@]}" --frame=1
if [[ ! -f "$work/first/frame_00000.png" || ! -f "$work/last/frame_00001.png" ||
      -e "$work/last/frame_00000.png" ]]; then
  echo "FAIL: valid fractional-duration previews did not write exactly the selected frames" >&2
  exit 1
fi

TZ=UTC "$preview" "$work/utc" 0.25 0 "${flags[@]}" --frame=0 \
  -AppleLocale en_US -AppleLanguages '(en)'
TZ=Pacific/Honolulu "$preview" "$work/buddhist" 0.25 0 "${flags[@]}" --frame=0 \
  -AppleLocale 'th_TH@calendar=buddhist' -AppleLanguages '(th)'
TZ=Asia/Tokyo "$preview" "$work/japanese" 0.25 0 "${flags[@]}" --frame=0 \
  -AppleLocale 'fr_FR@calendar=japanese' -AppleLanguages '(fr)' -AppleICUForce24HourTime YES
for profile in buddhist japanese; do
  if ! cmp "$work/utc/frame_00000.png" "$work/$profile/frame_00000.png"; then
    echo "FAIL: seeded preview changed across locale, calendar, or time zone" >&2
    exit 1
  fi
done
echo "All preview regression checks passed"
