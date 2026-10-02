# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build commands

```sh
make                    # build PickleballScreensaver.saver
make install            # install to ~/Library/Screen Savers
make clean              # remove the build artifact
make test               # deterministic engine and projection regression checks
```

The project uses `swiftc` directly via Makefile. `scripts/tests/run.sh` builds
and runs the regression executables; pass `--engine-only`, `--camera-only`,
`--art-only`, `--preview-only`, `--release-only`, or `--website-only` for a
focused check. Website checks exercise the appearance gallery in WebKit at
desktop/mobile sizes and with page JavaScript disabled.

`assets/icon/generate.sh` regenerates `AppIcon.icns`, the System Settings thumbnails, and `docs/icon.png` (the download-page favicon) from the SVG sources in `assets/icon/`. Edit the SVGs, not the PNGs/icns — the rasterized files are derived. macOS only (swiftc + iconutil).

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
- `--appearance=classic|blacklight|living-court|ink-and-paper|rally-painting` —
  override saved Appearance; `--classic` and `--blacklight` remain supported
- `--force-drop` / `--force-drive` — every third shot is a drop / drive
- `--force-speedup` / `--force-lob` / `--lefty` — force those behaviors
- `--no-runaround` — time-rich backhands are never run around for a forehand
- `--clean` — rallies end on winners only (no scripted errors)
- `--size=WxH` — override the 1280x720 render size
- `--motion=slow|standard|still` — override saved court motion
- `--yaw=N` — hold the scene at N degrees for an occlusion snapshot
- `--frame=N` — write only sampled frame N
- `--sample-every=N` — write every Nth display step (default 2 at 60 fps)
- `--fps=N` — display cadence, 4–240 fps; the simulation always runs at 120 Hz

Seeded previews disable ambient ghosts and use a fixed date, UTC time zone,
Gregorian calendar, and `en_US_POSIX` locale for the clock and daily drill,
making repeated screenshots reproducible across locale settings. Frame selection
is checked against the actual integer display-step count, including fractional
durations. Simulation tunables
are forwarded from the view to `RallyEngine`.

`scripts/preview/theme-shots.sh` regenerates the download page's five appearance
screenshots. Classic, Black Light, Living Court, and Ink-and-paper use the same
seed and frame; Rally Painting uses a later frame to show accumulated artwork.
All use no-spin framing. Defaults are seed 42, frame 210 (about 7 seconds),
and painting frame 3000 (about 100 seconds). Override with `--seed N`,
`--frame N`, `--painting-frame N`, or `--singles` / `--doubles`.
macOS only (needs `swiftc` and `sips`).

## Architecture

### Screensaver — `PickleballScreensaver/`

The `.saver` bundle is a shared library loaded by the system screen-saver process. Its entry point is `PickleballScreensaverView.swift` (an `NSView` subclass), which owns the animation loop, camera/projection, and all drawing.

**Simulation** — `RallyEngine.swift` owns the ball, players, rally lifecycle,
and side-out score. Doubles favors cross-court dinks and hands battles; singles
uses passing shots and deeper recovery. Service turns begin on the correct
court, kitchen volleys and follow-through are constrained, and contacts share
an exact ball/paddle pose. Rally scripts shape reachable shots but do not
disable defenders to force winners. Error flights are re-solved to actual
net/wide/long outcomes, and receivers leave clearly outgoing balls.
`step(dt:)` accepts 0–0.25 seconds and accumulates fixed 120 Hz substeps.
Floor crossings use analytic flight times. Read-only `lastContact`,
`contactCount`, and per-display-step `frameEvents` expose exact impacts and
live floor bounces without parsing logs.

**Rendering** — all drawing is done with CoreGraphics in `drawRect`. The view
renders a perspective-projected pickleball court with animated paddles, a
scoreboard, and a left-rail widget stack. `AppearancePreset.swift` defines the
five mutually exclusive looks and their `Theme` palettes. The Appearance and
game format are chosen in Options (`ThemeSettings` / `MatchSettings`, existing
keys `Theme` / `GameFormat`).

**Artwork** — `ArtEffects.swift` owns bounded ripple/halo lifetimes and
court-space brushstrokes. The view adapts the engine's ordered `frameEvents`
once after each step; drawing never advances artwork or gameplay. Living Court
uses exact live bounce/contact positions. Rally Painting retains strokes across
rallies, dissolves a finished game over two seconds, and caps history at 96
strokes of 128 points. Projection-keyed path caches follow resize and rotation.
`ArtTextures.swift` supplies deterministic paper grain, court-space watercolor
washes/fibers, and the ink trail. Its noise is independent of simulation
randomness. Appearance changes, reseeds, and format changes reset visual history.

Framing is cached for the whole rotation envelope; sprites and trails are
layered relative to the camera's side of the net. Team colors are stable
across rotations. `MotionSettings` persists `CourtMotion` (`slow`, `standard`,
or `still`) and the view also honors macOS Reduce motion. Animation dt uses
system uptime; wall-clock time only schedules the minute-boundary spin.
High lobs use a flight-aware, eased zoom; Reduce motion uses fixed extra headroom.

**Widget rail** — the left rail shows weather, tournaments, and drill of the day. Each card is toggled from the Options sheet and drawn each frame from a cached snapshot. The clock and stable Team A/Team B score sit below the court.

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
