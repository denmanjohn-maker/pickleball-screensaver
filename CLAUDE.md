# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build commands

```sh
make                    # build PickleballScreensaver.saver
make install            # install to ~/Library/Screen Savers
make photosync          # build PickleballPhotoSync.app
make install-photosync  # install helper to ~/Applications
make clean              # remove both build artifacts
```

The project uses `swiftc` directly via Makefile — there is no Xcode build scheme or test suite.

## Architecture

The repo contains two independent products that share one Swift file.

### Screensaver — `PickleballScreensaver/`

The `.saver` bundle is a shared library loaded by the system screen-saver process. Its entry point is `PickleballScreensaverView.swift` (an `NSView` subclass), which owns the animation loop and drives everything else.

**Rendering** — all drawing is done with CoreGraphics in `drawRect`. The view renders a perspective-projected pickleball court with animated players, a scoreboard, a left-rail widget stack, and an optional photo overlay warped onto one of the back-court quadrants.

**Widget rail** — the left rail shows cards for clock, weather, tournaments, and drill of the day. Each card is toggled from the Options sheet and drawn each frame from a cached snapshot.

**Providers** — three provider classes are called from `animateOneFrame`. They self-throttle using a `nextFetch: TimeInterval` sentinel so they never block the render loop:
- `WeatherProvider` — fetches Open-Meteo every 30 min (2 min retry). No API key.
- `TournamentProvider` — fetches pickleballtournamentapi.com every hour (10 min retry). Matches the weather city to the nearest of 25 hard-coded US metros; shows an "unsupported region" message if the city is >60 miles from any of them. No API key.
- `PhotoOverlayController` — drives an idle → fadeIn → hold → fadeOut cycle, loading images off-thread from either `~/Library/Application Support/PickleballScreensaver/SyncedPhotos/` or a bookmarked folder.

**Settings** — all user preferences are stored in `ScreenSaverDefaults` under module `com.pickleball.screensaver`. Each settings struct (`PhotoSettings`, `WeatherSettings`, `TournamentSettings`, `DrillSettings`) has `load()` / `save()` that read/write those defaults. The configure sheet is `ConfigureSheetController` in `ConfigureSheet.swift`; it is a programmatic `NSPanel` (no XIB).

**Geocoding** — `GeocodingClient` in `WeatherProvider.swift` calls the Open-Meteo geocoding API to resolve city names to lat/lon; it is only used from the configure sheet's "Look Up" button.

**Drills** — `PickleballDrills.swift` decodes `Resources/drills.json` and picks a deterministic daily drill based on the day-of-year.

### Photo Sync helper — `PhotoSync/`

The `.saver` bundle cannot request or hold Apple Photos permission reliably because it runs inside the system screen-saver host. `PickleballPhotoSync.app` is a menu-bar app that holds Photos permission, exports chosen album images to the shared directory, and writes sync status to `~/Library/Application Support/PickleballScreensaver/PhotoSyncStatus.plist`.

**Shared surface** — `PickleballScreensaver/PhotoSyncShared.swift` is compiled into **both** products. It defines the shared directory URLs, `PhotoSyncStatus`, and its plist serialisation. Edits to this file affect both binaries.

## External APIs

| Service | URL | Key required |
|---|---|---|
| Weather | `https://api.open-meteo.com/v1/forecast` | No |
| Geocoding | `https://geocoding-api.open-meteo.com/v1/search` | No |
| Tournaments | `https://pickleballtournamentapi.com/api/tournaments` | No |
