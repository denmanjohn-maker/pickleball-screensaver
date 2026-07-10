# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build commands

```sh
make                    # build PickleballScreensaver.saver
make install            # install to ~/Library/Screen Savers
make clean              # remove the build artifact
```

The project uses `swiftc` directly via Makefile — there is no Xcode build scheme or test suite.

## Preview harness

`scripts/preview/main.swift` renders the screensaver offscreen to numbered PNGs so animation changes can be reviewed without installing the saver. Build and run from the repo root (asset loading falls back to CWD-relative paths):

```sh
swiftc -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" \
  -framework Cocoa -framework ScreenSaver \
  PickleballScreensaver/*.swift scripts/preview/main.swift -o /tmp/pbpreview
/tmp/pbpreview <outDir> [seconds] [startClock] [--rush|--no-rush] [--cross] [--clean]
```

`startClock` is the synthetic wall clock in seconds — the turntable spin fires at each minute boundary (55 shows a spin 5 s in; 90 keeps short runs flat). Flags force rally behaviors via the `var` tunables on the view (`rushProb`, `crossCourtProb`, `netFaultProb`, `passingShotProb`).

## Architecture

### Screensaver — `PickleballScreensaver/`

The `.saver` bundle is a shared library loaded by the system screen-saver process. Its entry point is `PickleballScreensaverView.swift` (an `NSView` subclass), which owns the animation loop and drives everything else.

**Rendering** — all drawing is done with CoreGraphics in `drawRect`. The view renders a perspective-projected pickleball court with animated players, a scoreboard, and a left-rail widget stack.

**Widget rail** — the left rail shows cards for clock, weather, tournaments, and drill of the day. Each card is toggled from the Options sheet and drawn each frame from a cached snapshot.

**Providers** — two provider classes are called from `animateOneFrame`. They self-throttle using a `nextFetch: TimeInterval` sentinel so they never block the render loop:
- `WeatherProvider` — fetches Open-Meteo every 30 min (2 min retry). No API key.
- `TournamentProvider` — fetches pickleballtournamentapi.com every hour (10 min retry). Matches the weather city to the nearest of 25 hard-coded US metros; shows an "unsupported region" message if the city is >60 miles from any of them. No API key.

**Settings** — all user preferences are stored in `ScreenSaverDefaults` under module `com.pickleball.screensaver`. Each settings struct (`WeatherSettings`, `TournamentSettings`, `DrillSettings`) has `load()` / `save()` that read/write those defaults. The configure sheet is `ConfigureSheetController` in `ConfigureSheet.swift`; it is a programmatic `NSPanel` (no XIB).

**Geocoding** — `GeocodingClient` in `WeatherProvider.swift` calls the Open-Meteo geocoding API to resolve city names to lat/lon; it is only used from the configure sheet's "Look Up" button.

**Drills** — `PickleballDrills.swift` decodes `Resources/drills.json` and picks a deterministic daily drill based on the day-of-year.

## External APIs

| Service | URL | Key required |
|---|---|---|
| Weather | `https://api.open-meteo.com/v1/forecast` | No |
| Geocoding | `https://geocoding-api.open-meteo.com/v1/search` | No |
| Tournaments | `https://pickleballtournamentapi.com/api/tournaments` | No |
