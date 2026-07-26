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
/tmp/pbpreview <outDir> [seconds] [startClock] [flags]
```

`startClock` is the synthetic wall clock in seconds — the turntable spin fires at each minute boundary (55 shows a spin 5 s in; 90 keeps short runs flat). Flags:

- `--seed=N` — deterministic simulation (replays identical rallies each run)
- `--stats` — per-shot log lines plus end-of-run aggregates (rally-length histogram, backhand %, cross-court dink %, ending mix)
- `--sim-only` — run the simulation without rendering; use long durations (600+) with `--stats` for distribution checks
- `--singles` / `--doubles` — force the game format
- `--blacklight` — force the neon-on-black theme
- `--force-drop` / `--force-drive` — every third shot is a drop / drive
- `--force-speedup` / `--force-lob` / `--lefty` — force those behaviors
- `--clean` — rallies end on winners only (no scripted errors)

All flags map to `var` tunables on the view, forwarded to `RallyEngine`.

## Architecture

### Screensaver — `PickleballScreensaver/`

The `.saver` bundle is a shared library loaded by the system screen-saver process. Its entry point is `PickleballScreensaverView.swift` (an `NSView` subclass), which owns the animation loop, camera/projection, and all drawing.

**Simulation** — `RallyEngine.swift` owns the ball, the players (2 in singles, 4 in doubles), and the full rally lifecycle: diagonal serve into the correct box, two-bounce rule, third-shot drop/drive, kitchen dinking (~80% cross-court), speed-ups into hands battles, lobs, and side-out scoring (doubles uses the three-number call with both partners serving). Players move at human speeds with reaction delays and noisy ball reads, so forehands and backhands both occur (stance follows the paddle-hip rule; ~1 in 6 players is left-handed). Each rally's length and ending are sampled at serve time from pro-match distributions; non-terminal shots are aimed reachable by construction. Ball flight uses a landing-constrained solver (arc → speed), so dinks float at ~8 mph while drives fly at ~30+. The view calls `engine.step(dt:)` once per frame and only reads state.

**Rendering** — all drawing is done with CoreGraphics in `drawRect`. The view renders a perspective-projected pickleball court with animated paddles, a scoreboard, and a left-rail widget stack. All colors route through `Theme.swift` (`classic` or `blacklight` — pure black with neon green/pink/orange and a group-glow pass); the theme and game format are chosen in the Options sheet (`ThemeSettings` / `MatchSettings`, keys `Theme` / `GameFormat`).

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
