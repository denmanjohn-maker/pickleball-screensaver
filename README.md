# pickleball-screensaver

A macOS screensaver that renders a stylized pickleball court, scoreboard, and photo callouts on the blue back-court quadrants.

The left rail of widget-style cards shows the clock, current weather with a "good day to play?" badge, nearby tournaments, and drill of the day.

## Weather

Weather comes from the free [Open-Meteo](https://open-meteo.com) API — no API key needed. In the screensaver's **Options…** sheet, check **Show weather**, type a city, click **Look Up**, and pick °F or °C. The forecast refreshes every 30 minutes while the screensaver runs.

## Nearby tournaments

Check **Show nearby tournaments** in the same sheet to add a card listing upcoming tournaments near your weather city, sourced from the [Pickleball Tournament API](https://pickleballtournamentapi.com), which tracks each metro's tournaments within 100 miles of that metro's center. Choose whether to show the next 1 or 3 months. The API only tracks ~25 major US metro areas, so this works best when your weather city is close to one of those; if it's too far from any tracked metro, the card explains that instead of showing stale or misleading data. Tournament listings refresh about once an hour.

## Build

```sh
make
```

That builds `PickleballScreensaver.saver`.

To install it for the current user:

```sh
make install
```

## Photos support

The screensaver itself no longer talks to Apple Photos directly. macOS hosts `.saver` bundles inside the system screen-saver process, which cannot request or hold Photos permission reliably, so album access is handled by a separate helper app instead.

### Build the Photo Sync helper

```sh
make photosync
make install-photosync
```

That builds and installs `PickleballPhotoSync.app` into `~/Applications`.

### Use synced Photos albums

1. Launch **Pickleball Photo Sync**.
2. Grant Photos access when prompted.
3. Choose an album from the menu bar app.
4. Click **Sync Now**.
5. In the screensaver's **Options…** sheet, choose **Synced Photos**.

The helper exports synced images to:

```text
~/Library/Application Support/PickleballScreensaver/SyncedPhotos
```

The screensaver reads random images from that folder and perspective-warps each one to fit a randomly chosen blue back-court quadrant.

## Manual folder source

If you do not want to use Apple Photos, the screensaver still supports choosing any local image folder directly from the **Options…** sheet.