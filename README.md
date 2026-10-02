# pickleball-screensaver

[![Latest release](https://img.shields.io/github/v/release/denmanjohn-maker/pickleball-screensaver)](https://github.com/denmanjohn-maker/pickleball-screensaver/releases/latest)

A macOS screensaver that renders a stylized pickleball court with animated singles or doubles rallies and a scoreboard.

**Just want to install it?** Grab the signed, notarized installer from the
**[download page](https://denmanjohn-maker.github.io/pickleball-screensaver/)** —
no build tools needed.

The left rail of widget-style cards shows current weather with a "good day to play?" badge, nearby tournaments, and drill of the day. A separate clock and team-colored scoreboard sit below the court.

## Court and game options

Choose **Classic** or **Black Light**, and **Singles** or **Doubles**, in
**Options…**. Team A uses cyan paddles; Team B uses coral in Classic and pink
in Black Light. Those identities stay fixed on the scoreboard as the camera rotates.

**Court motion** offers a slow 12-second turn each minute (the default), the
original 6-second turn, or no spin. macOS **Reduce motion** disables court
spins and ambient wallpaper effects regardless of this choice.
High lobs gently ease the camera back when necessary to keep the ball visible;
Reduce motion uses fixed framing with extra headroom instead.

Doubles favors kitchen exchanges and hands battles; singles favors passing
shots, deeper recovery, and selective approaches. Serving follows service-court
rules and side-out scoring, and players must let the serve and return bounce.
Kitchen balls can be played off the bounce, but players must reestablish
position outside the kitchen before volleying.

## Weather

Weather comes from the free [Open-Meteo](https://open-meteo.com) API — no API key needed. In the screensaver's **Options…** sheet, check **Show weather**, type a city, click **Look Up**, and pick °F or °C. The forecast refreshes every 30 minutes while the screensaver runs.

## Nearby tournaments

Check **Show nearby tournaments** in the same sheet to add a card listing upcoming tournaments near your weather city, sourced from the [Pickleball Tournament API](https://pickleballtournamentapi.com), which tracks each metro's tournaments within 100 miles of that metro's center. Choose whether to show the next 1 or 3 months. The API only tracks ~25 major US metro areas, so this works best when your weather city is close to one of those; if it's too far from any tracked metro, the card explains that instead of showing stale or misleading data. Tournament listings refresh about once an hour.

## Drill of the day

Check **Show drill of the day** in the same sheet to add a card with one drill, picked deterministically so it stays the same all day and changes the next. Pick **All levels** or a DUPR tier (3.0–5.0) to filter which drills come up.

## Build

```sh
make
```

That builds `PickleballScreensaver.saver`.

Run the deterministic simulation and projection regression checks with:

```sh
make test
```

These cover service rotations, kitchen legality, paddle contact, exact bounce
locations, shot-speed and ending distributions, frame-rate independence,
forced shot behaviors, and camera framing throughout a full rotation.

To install it for the current user:

```sh
make install
```

To build a zip you can share with other Macs, run `make dist` — see
[DISTRIBUTING.md](DISTRIBUTING.md) for signing/notarization details and what
recipients need to do.

## Releases

Pushing a `vX.Y` tag builds, signs, notarizes, and publishes a GitHub Release
automatically — see [DISTRIBUTING.md](DISTRIBUTING.md#cutting-a-release) for
the release process and the one-time secrets setup. The
[download page](https://denmanjohn-maker.github.io/pickleball-screensaver/) is
served by GitHub Pages from [docs/](docs/) and always points at the latest
release.
