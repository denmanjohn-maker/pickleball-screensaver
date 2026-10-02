# Pickleball for Windows 11

Independent C#/.NET **10 LTS** WPF implementation, product **1.5**
(`Version=1.5.0`), in the same repository as the unchanged macOS screensaver.
Native **win-arm64** and **win-x64** packages are self-contained; recipients
do not install .NET. Running the x64 package under ARM emulation is rejected.

The source baseline is final merged macOS **f0dc8161d77215cd4fe5dd5ed73bfe8ae541b6c3**
(evaluation PR #36 and artwork PR #37, macOS 1.5/build 2). The initial Windows
host commit was **52f84741c137a8a73cbf8f91338c3056d93f219d**. No provisional
art branch is used. Windows packages remain **validation candidates**, not
automatically published releases.

## Implemented feature inventory

* UI-independent fixed-120Hz engine: original SplitMix64 overflow and Swift
  closed-floating-range rejection mapping, serves, two-bounce rule, kitchen
  legality, all eleven shot types, human movement/handedness/stance/recovery,
  singles/doubles, opening 0–0–2, side-out scoring, games to 11 by two.
* One process-owned engine, art state, decorative RNG and provider set;
  immutable frames shared by all monitor views. Views never step the engine.
* Independently fitted perspective court/apron, service boxes/grain/lines,
  sagging net and strands/posts, yaw-aware depth/occlusion, team-tinted shared
  paddle PNG with contact-pinned swing geometry, spinning holed ball,
  shadow/trail, scoreboard/serve call/game tally/banner, clock and widget rail.
  Fit covers the full rotation envelope, not an old static rectangle.
* Mutually exclusive **classic**, **blacklight**, **living-court**,
  **ink-and-paper**, **rally-painting**; team A is positive-facing cyan,
  team B negative-facing coral/pink (deeper ink shades on paper).
  Selecting the same appearance is a strict no-op. Real appearance/format
  changes, reset and reseed clear art/ghosts/projection and brush caches.
* Living Court: ordered bounce ripples (24/1.2s), contact halos (16/.35s,
  retain height), correct behind/in-front-of-net passes. Rally Painting:
  floor-space strokes (96 × 128), contact/bounce anchors, live-only 30Hz
  samples, .01ft deduplication, bounded decimation, pre-fade beyond 80,
  smoothstep two-second old-game fade; new-game strokes remain unfaded.
  Duplicate frame numbers never replay events or age history; redraw only
  updates per-view geometry caches.
* Paper: independent seeded LCG, cached 256px tile/3000 dots, 48 washes ×
  24 vertices, 900 fibers, segmented ink trail preserving net occlusion.
  Linked original PNG/SVG/drills resources are embedded, not copied assets.
  Text uses installed Windows Segoe UI; icons are original simple vectors,
  not Apple SF Symbols or redistributed Apple fonts.
* Minute-boundary turn: standard 6s, **slow 12s default**, still.
  Windows “Animation effects” off disables rotation/ambient/zoom; fixed
  reduced-motion fit includes lob headroom. Normal lob zoom derives from
  contact velocity and eases in the per-viewport animation update.
* All final preferences/defaults: appearance, motion, match format,
  daily-drill enable/level, weather enable/city/coordinates/units,
  tournaments enable/1-or-3-month window. Versioned, validated, size-bounded,
  atomic same-directory preferences under
  `%LOCALAPPDATA%\PickleballScreensaver\settings.json`. Save/Cancel and
  explicit corrupt/unsupported recovery; editing a city cancels/invalidate
  stale geocoding and requires lookup again before saving a location.
* Optional async Open-Meteo weather/geocoding; forecast/feels-like/wind/rain/
  sunrise/sunset/tomorrow/play verdict. 30-minute refresh/two-minute retry.
  Tournament API: same city, nearest of 25 supported US metros within 60
  miles, 1/3-month window, first 20 results as in macOS, three-row visual
  pages every six seconds with edge fades; hourly refresh/10-minute retry.
  Disabled providers send no HTTP. Snapshots retain stale data explicitly.
  Requests have whole-stream timeouts/1MiB limits and lifetime cancellation.
  No telemetry, persistent network logs or extraneous location diagnostics.
* Daily filtered drills use the embedded shared JSON and Gregorian local
  calendar day-in-era (stable across DST), not seconds-since-epoch.
* Separate real CAB Classic/Black Light desktop theme packs with clean
  3840×2160 and 5120×2160 wallpaper and matching colors. No frozen widgets,
  dates, executables, cursors, sounds, icons, included msstyles or patchers.

## Screensaver host

```text
PickleballScreensaver.scr                 configuration
PickleballScreensaver.scr /c              configuration
PickleballScreensaver.scr /c:HWND          modal owned configuration
PickleballScreensaver.scr /c HWND          same
PickleballScreensaver.scr /s              synchronized fullscreen monitors
PickleballScreensaver.scr /p:HWND          real embedded child-HWND preview
PickleballScreensaver.scr /p HWND          same
```

Case-insensitive, conventional `-` forms accepted. Handles are nonzero,
unsigned decimal and pointer-sized. Bad arguments/stale handles return **2**,
other startup failures **1**; never fall back from preview to fullscreen.
Preview follows parent client size/DPI and terminates with parent death.
It **does not read saved city coordinates**, create HTTP providers or use
networking. Offline exports also strip city/coordinates and networking.
Only fullscreen hides the cursor; key/button input, deactivation or movement
outside the initial four-pixel positional noise threshold exits immediately.
There is no long startup input-ignore timer.

Mixed DPI, portrait, 4K, ultrawide, negative monitor coordinates and hotplug
are handled by independent monitor windows with a shared frame. Secure resume,
password, idle timeout, lock and sleep remain Windows policy—not application
preferences or replacements.

## Build, tests and offline images

```sh
cd windows
dotnet test tests/Pickleball.Core.Tests -c Release --nologo
python3 -B -m unittest discover -s packaging -p 'test_*.py'
dotnet build Pickleball.slnx -c Release --nologo
dotnet format Pickleball.slnx --no-restore --verify-no-changes
python3 packaging/publish.py --rid win-arm64
python3 packaging/publish.py --rid win-x64
```

SDK selection rolls forward within .NET 10. `--dotnet /path/to/dotnet`
supports a task-local SDK. `--output` must stay beneath `windows/`; use a fresh
directory when repeating publishes. Trimming and AOT are explicitly disabled.
Portable ZIPs contain **all** SDK-emitted files; separate complete folder
ZIPs provide an audited fallback. Single-file native dependencies explicitly
extract into the per-user .NET cache (`DOTNET_BUNDLE_EXTRACT_BASE_DIR` can
redirect it); “portable” does not mean zero cache writes.
PE audits reject mismatched native/R2R dependencies; only IL-only AnyCPU
assemblies may use I386 headers. SHA-256 files accompany each package.

On **native Windows**:

```powershell
dotnet run --project tools/Pickleball.Preview -c Release -- artifacts/ink.png 800 42 1280x720 '2026-01-01T12:00:00.0000000+00:00' ink-and-paper singles reduced
./packaging/test-render.ps1 -Output "$PWD/artifacts/render"
./packaging/build-themes.ps1 -Output "$PWD/artifacts/themes"
./packaging/build-msi.ps1 -Rid win-arm64 -Payload "$PWD/artifacts/PickleballScreensaver-1.5.0-win-arm64" -Themes "$PWD/artifacts/themes" -Output "$PWD/artifacts/installers"
```

Exporter arguments: output, frame (0..36000), uint seed, size, ISO epoch,
optional appearance/format/motion (`reduced` allowed), optional `wallpaper`.
`widgets` or `widgets-metric` supplies explicit synthetic cached provider
snapshots for screenshots, without HTTP or saved user location.
Wallpaper mode excludes simulation equipment, art history, ghosts and every
widget/clock/score/date. Simulation/decorative clocks/RNG are controlled.
Platform fonts and antialiasing may differ; missing geometry is not permitted.

## Current-user installation and removal

MSIs are authored using **Windows' existing Windows Installer COM API and
makecab**, not downloaded WiX binaries or a new third-party build tool.
Template Summary is `Arm64;1033` or `x64;1033`; 64-bit components, current-user
LUA package flag, native OS architecture launch condition, and no ALLUSERS.
Files go to `%LOCALAPPDATA%\Programs\PickleballScreensaver`, never System32.
Windows Installer supplies upgrade/repair/uninstall and tracks each owned
file; unrelated files and saved preferences are retained. Future public
updates must increase the product version; deterministic component IDs stay
stable per architecture/file.

Install does **not** activate/select a saver, apply a theme or alter policy.
Start-menu shortcuts expose Settings and explicitly opted-in Select/Classic/
Blacklight actions. Selection asks confirmation and changes only the user's
`SCRNSAVE.EXE` reference (not activation/timeout/secure resume). Uninstall
clears that reference only if it still names this installed saver; another
saver is untouched. Windows-imported themes remain user-owned customization.
Portable users can run `/c` and use `Maintain.ps1 -Action Select` explicitly.

WiX was evaluated, but **is not a dependency**: its current official
[OSMFEULA](https://github.com/wixtoolset/wix/blob/main/OSMFEULA.txt)
applies to project-provided binary releases used in revenue-generating
activities with annual gross revenue **≥ US$10,000**, with specified
low-revenue/separate-maintenance exemptions. Open-source status alone is not
an exemption. Source/self-compiled binaries are separately governed by
[MS-RL](https://github.com/wixtoolset/wix/blob/main/LICENSE.TXT).
No payment or acceptance of those binary terms is performed by this build.

## Signing and single release owner

No Windows Authenticode identity was supplied. Default outputs are labeled
**unsigned development candidates**; SmartScreen warnings are possible.
Optional `publish.py --sign` and `sign.ps1` require **separate Windows**
`WINDOWS_SIGNING_PFX_BASE64`, `WINDOWS_SIGNING_PASSWORD`, and HTTPS
`WINDOWS_TIMESTAMP_URL`; certificate material stays in memory and is disposed.
Signing fails if signature/trusted timestamp verification fails. Apple
credentials are never reused. Successful signing still does not promise
SmartScreen reputation or warning-free installation.

Windows validation uses only read permissions and artifact uploads. Its
manual signing option is restricted to reviewed `main`. It never creates a
release, tags or merges. Existing `.github/workflows/release.yml` remains the
**single release owner** and macOS versionless download URLs are unchanged.
Do **not** republish/overwrite already-triggered `v1.5`. Windows promotion
requires explicit maintainer approval after the gates below, then attachment
through the one release-owner path; no competing Windows publisher exists.

## Evidence and outstanding acceptance

Local macOS: 81 platform-neutral .NET tests (including exact contact and bounce frames,
types, players, received bounces/scores and ≤1e-7 vectors against unchanged
Swift seed-42 singles/doubles 180s traces), nine Python publish/CAB audits,
five-project WPF reference cross-build, format validation; final macOS engine,
camera and artwork regressions also pass. See PR/native CI for current
published `.scr`, screenshot, CAB and MSI results. Native run
[36998528519](https://github.com/denmanjohn-maker/pickleball-screensaver/actions/runs/36998528519)
passed all 81 core tests, renamed `.scr` child-preview lifecycle/architecture,
accessible configuration labels, all five appearance/two-format image fixtures,
all motion/portrait/4K/ultrawide fixtures, deterministic PNG replay and true CAB
inventory checks on both native architectures. MSI authoring succeeded;
its install exposed a missing AppSearch table, fixed in the next iteration.
These results do not substitute for the desktop/signing gates below.

`windows-2025` is an **x64 Windows Server** runner, not Windows 11 desktop
acceptance. `windows-11-arm` runs **native ARM64 Windows 11** with explicit OS,
SDK, PowerShell/test-process and published-process architecture checks.
Native tests exercise the **renamed self-contained `.scr`**, real preview
HWND/resize/parent death, settings and image export. Isolated runner MSI tests
check no auto-selection/policy changes, repair, synthetic next-version upgrade, owned-reference removal and
alternative/unowned-file preservation. Hosted users can be administrators:
passing there alone does not prove standard-user/non-admin desktop acceptance.

Before distribution, record actual **Windows 11 ARM64 and x64 desktops**:

* Control Panel preview and owned settings, independent mixed-DPI monitors/
  hotplug, fullscreen input/deactivation, idle invocation, secure resume/lock/
  sleep, reduced-motion behavior;
* clean standard-user install, upgrade, repair and uninstall, preserving an
  alternative saver; open both CAB packs and verify clean wallpaper/colors;
* sustained memory bounds and measured 60fps target on representative hardware;
* verified Windows identity/timestamp and final signed package checksums.

Cross-building on macOS, x64-on-ARM compilation, a PNG or Server runner is not
evidence for these desktop/policy/performance/signing gates.
