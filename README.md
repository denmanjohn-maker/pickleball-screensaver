# pickleball-screensaver

[![Latest release](https://img.shields.io/github/v/release/denmanjohn-maker/pickleball-screensaver)](https://github.com/denmanjohn-maker/pickleball-screensaver/releases/latest)

A macOS and Windows 11 screensaver that renders a stylized pickleball court with animated singles or doubles rallies and a scoreboard.

**Just want to install it?** Choose your platform on the
**[download page](https://denmanjohn-maker.github.io/pickleball-screensaver/)** —
no build tools needed. macOS downloads are signed and notarized.

**Windows 11:** the same repository now contains a native ARM64/x64 .NET 10
implementation. New shared version releases include **x64 and ARM64 MSI
installers and portable ZIPs**, SHA-256 checksums, and optional Classic/Black
Light desktop theme packs. Windows packages are **unsigned** and may trigger
unknown-publisher or SmartScreen warnings; hosted checks do not certify final
desktop, standard-user or performance acceptance. Select the architecture in
**Settings → System → About → System type**; .NET is included.
The first Windows downloads will appear with a new shared release, not as a
replacement of the existing macOS-only `v1.6`.
See the [Windows downloads](https://denmanjohn-maker.github.io/pickleball-screensaver/#windows-downloads)
and [Windows guide](windows/README.md) for installation and acceptance details.

The left rail of widget-style cards shows current weather with a "good day to play?" badge, nearby tournaments, and drill of the day. A separate clock and team-colored scoreboard sit below the court.

## Court and game options

Choose one of five **Appearance** presets, and **Singles** or **Doubles**, in
**Options…**. Existing Classic and Black Light selections are preserved.

| Appearance | Look |
|---|---|
| Classic | The original green/blue court and muted wallpaper. |
| Black Light | Neon court lines and fluorescent equipment on black. |
| Living Court | Classic colors with gentle ripples at live ball bounces and brief halos at paddle contact. |
| Ink-and-paper | Warm textured paper, watercolor court washes, charcoal lines, and an ink-like ball trail. |
| Rally Painting | Team-colored brushstrokes build up on a dark court across rallies, then gently dissolve when a game ends. Older strokes fade out during long games to keep the artwork bounded. |

These are mutually exclusive presets, not stacked effects. All use the same
game mechanics and physics. Team A uses cyan paddles; Team B uses coral, or pink
in Black Light, with deeper ink shades on paper. Those identities stay fixed
on the scoreboard as the camera rotates.

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

## Build on macOS

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
forced shot behaviors, camera framing throughout a full rotation, fractional
preview-frame bounds, seeded screenshots across locale/calendar/time-zone settings,
appearance persistence, artwork lifecycles and storage limits, and identical
seeded gameplay across appearances.

To install it for the current user:

```sh
make install
```

To build a zip you can share with other Macs, run `make dist` — see
[DISTRIBUTING.md](DISTRIBUTING.md) for signing/notarization details and what
recipients need to do.

## Releases

Pushing a new `vX.Y` (or `vX.Y.Z`) tag builds both platforms and publishes one
GitHub Release only after macOS and native Windows x64/ARM64 checks succeed.
macOS packages are signed and notarized; Windows packages are unsigned.
Manual **Release** action runs build either or both platforms and upload
artifacts only, never a release. Windows-only dry runs need no Apple secrets.
See [DISTRIBUTING.md](DISTRIBUTING.md#cutting-a-release) for synchronized version
bumps, release assets and the one-time secrets setup. The
[download page](https://denmanjohn-maker.github.io/pickleball-screensaver/) is
served by GitHub Pages from [docs/](docs/) and always points at the latest
release. Until Windows assets are published, its Windows links safely open
the Releases listing. Existing macOS download URLs are unchanged.
