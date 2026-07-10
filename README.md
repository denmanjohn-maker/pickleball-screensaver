# pickleball-screensaver

A macOS screensaver that renders a stylized pickleball court with an animated singles rally and scoreboard.

The left rail of widget-style cards shows the clock, current weather with a "good day to play?" badge, nearby tournaments, and drill of the day.

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

To install it for the current user:

```sh
make install
```
