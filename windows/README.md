# Windows 11 foundation (not the finished screensaver)

This directory is a separate C# / **.NET 10 LTS** implementation in the same
repository. macOS source, packaging, workflows and download names are unchanged.
The current scene is deliberately labeled **foundation only**: its moving
geometric marker is a deterministic host test, not pickleball simulation or
provisional artwork. Appearance choices are persisted, but only classic and
blacklight change the foundation background/accent. The other appearances are
reserved for the final merged artwork port.

## Source gate

Foundation began on **`73b2f867b686d8a14318f572cca69bc2c7f6748f`**
(merged evaluation PR #36, verified against `origin/main` on October 2, 2026).
During implementation, artwork PR #37 merged and main advanced to
**`f0dc8161d77215cd4fe5dd5ed73bfe8ae541b6c3`** (version 1.5 bump).
Only this new isolated Windows branch was rebased onto that merged-main
baseline; no other checkout or agent branch was changed.
The earlier `5114909` baseline is obsolete. Artwork was still in progress at
the start of this stage; no unfinished artwork branch was fetched into this
implementation. **The parent's re-evaluation of the final merged code remains
required before porting final features.** Do not treat this foundation commit
or its independent `0.1.0` development version as a coordinated product release.

## Projects

| Path | Responsibility |
| --- | --- |
| `src/Pickleball.Core` | UI-independent host arguments, versioned atomic preferences, injected monotonic/wall/replay clocks, immutable frame/event boundary, viewport/input helpers, embedded shared resources |
| `src/Pickleball.Windows` | WPF `.scr` entry point, per-monitor fullscreen windows, true child-HWND preview, modal configuration, one process render session |
| `tests/Pickleball.Core.Tests` | Platform-neutral xUnit regressions |
| `tests/Pickleball.Windows.Tests` | Bounded native STA/WPF integration executable; requires an explicit isolated output directory and published `.scr` |
| `tools/Pickleball.Preview` | Offline deterministic one-frame PNG exporter; does not register the saver |
| `packaging/publish.py` | Explicit RID, self-contained portable ZIPs, PE architecture audit and SHA-256 checksums |

Original PNG, SVG and `drills.json` files are **linked as embedded resources
from their existing repository locations**, not copied source assets.
`SharedResources.Open` reads manifest streams, so resources do not depend on
the current directory, executable name, `Assembly.Location` or the extraction
directory. No SF Symbols or Apple fonts are redistributed. The foundation uses
the installed Windows Segoe UI font.

## Build and portable tests

Install a stable .NET 10 SDK (the SDK selection rolls forward within .NET 10).
Run all commands here, not in the macOS project directory:

```sh
cd windows
dotnet test tests/Pickleball.Core.Tests -c Release --nologo
python3 -B -m unittest discover -s packaging -p 'test_*.py'
dotnet build Pickleball.slnx -c Release --nologo
python3 packaging/publish.py --rid win-arm64
python3 packaging/publish.py --rid win-x64
```

`EnableWindowsTargeting` allows reference-assembly compilation on macOS/Linux;
it does **not** make WPF executable there. On Windows `python` may be used
instead of `python3`. `--dotnet /absolute/path/to/dotnet` supports a local SDK.
Publish output must be under `windows/`. To repeat publishing use a fresh
`--output artifacts/run-2`; the script refuses existing publish folders to
prevent stale dependencies leaking into packages.

For each RID, the script emits:

* `PickleballScreensaver-foundation-0.1.0-win-{arm64|x64}.zip`: renamed bundled
  apphost, all SDK-emitted sidecars if any, foundation warning and architecture
  report.
* A separate `...-folder.zip` retaining **all** unbundled self-contained
  dependencies. This is the explicit fallback if native single-file runtime
  acceptance fails, and permits auditing the native dependencies before
  bundling.
* Per-ZIP SHA-256 files. No installer, registration, signing or release upload.

The publish command explicitly disables trimming and AOT; neither is assumed
supported by WPF. Single-file publishing explicitly enables
`IncludeNativeLibrariesForSelfExtract`. The runtime extracts native libraries
to its per-user .NET bundle cache by default; portable means **no .NET install**,
not zero cache writes. Tests redirect extraction into their isolated artifact
directory. PE checks require AMD64 (`0x8664`) or ARM64 (`0xaa64`) apphosts and
native/R2R dependencies for the requested RID; I386 headers are allowed only
on IL-only AnyCPU assemblies. Native dependencies are .NET/WPF runtime files
and Windows OS libraries; no third-party native dependency is introduced.

## `.scr` protocol and lifetimes

```text
PickleballScreensaver.scr             configuration
PickleballScreensaver.scr /c          configuration
PickleballScreensaver.scr /c:HWND     modal configuration owned by that live window
PickleballScreensaver.scr /c HWND     same
PickleballScreensaver.scr /s          fullscreen foundation on every monitor
PickleballScreensaver.scr /p:HWND     embedded preview
PickleballScreensaver.scr /p HWND     same
```

Options are case-insensitive; the conventional `-c`/`-p`/`-s` forms are also
accepted. HWND text is unsigned decimal, pointer-sized and nonzero. Invalid
options, duplicates, extra arguments, malformed/zero/stale HWNDs fail with
exit code **2**, never a fullscreen fallback. Other startup failures return
**1**. Diagnostics are capped at eight category/type-only entries to Trace
and stderr; no persistent logs, location, settings content or telemetry.

Configuration assigns the native owner and runs a WPF modal dialog. For
foreign-process owners (such as Windows settings), an explicit owner scope
disables that live window for the dialog and restores its previous enabled
state afterward, including exceptional exits; an already-disabled owner is
not spuriously enabled.

Preview uses `HwndSource` with `WS_CHILD`, not a top-level imitation or
`SetParent` reparenting. It fits the parent's physical client rectangle and
checks every 100 ms for resize, disappearance, reparenting or changed parent
process/thread identity. Disposal removes subscriptions, stops timers and
notifies application shutdown. PerMonitorV2 is declared for Windows 11; the
preview's WPF root inherits its child HWND DPI context. Zero-sized parents
produce a zero-sized child, not fullscreen. Preview never hides the cursor or
installs fullscreen input/deactivation handlers.

Fullscreen windows use physical monitor bounds including negative desktop
coordinates. Each WPF renderer independently fits the 1280×720 foundation
scene using its current DIP dimensions. Display/DPI messages and a one-second
display check reconcile connected monitors without resetting shared time.
One timer advances **one** `RenderTimeline`, then broadcasts the exact same
immutable frame to every view; no engine/provider is created per monitor.
The timeline bounds elapsed steps to 250 ms and uses monotonic time; wall
clock adjustments do not step it. Views only render snapshots.

Fullscreen exits on key, mouse button/wheel, movement beyond four physical
pixels from the initial cursor position, application deactivation to another
process or window close. Initial/small cursor noise is ignored by position,
not by a long input-suppression interval. Only fullscreen sets `Cursors.None`.
No code changes idle, timeout, sign-in, lock, password or secure-resume policy.
Windows remains responsible for secure resume; physical acceptance is pending.

`RenderSession.Providers` owns the process cancellation token and the
provider-permission boundary. `ProcessProviders.RegisterNetwork` deduplicates
factories by name before startup and rejects them without invoking the factory
in offline mode. Start/dispose happen once per process, including cleanup of
all providers when one fails. No weather, geocoding, tournament or other network provider exists
in this stage. Preview/export set `NetworkAllowed=false` and inject a fixed
or replay wall clock: there are no clock/widget API calls. Future providers
must be created **once** by the process session, obey that gate and cancellation,
and publish cached snapshots rather than block rendering.

`RenderFrame.Events` reserves an ordered per-step **contact/bounce** delivery
boundary. It is empty in the foundation because no engine has been ported.
Final event payloads must be reconciled with the merged artwork implementation;
do not alter `RallyEngine` to support the renderer or infer impacts from logs.

## Preferences and configuration

Normal application configuration uses
`%LOCALAPPDATA%\PickleballScreensaver\settings.json`. No file/directory is
created merely by loading or cancelling configuration. Schema version 1
currently stores **only** `theme`, using the persisted contract
`classic`, `blacklight`, `living-court`, `ink-and-paper`, `rally-painting`.
There is one Appearance menu and no effect toggles. Match, motion and provider
fields will be added after their merged defaults/contracts are verified.

Save validates values, writes/flushes a unique same-directory staging file,
then atomically renames it over the owned preferences file. Readers permit
delete-sharing for atomic replacement on Windows. Corrupt, oversized
(>16 KiB) or unsupported-version files are not silently overwritten; the
configuration requires an explicit replacement checkbox before Save.
Unavailable files report an error and are not overwritten. Cancel never saves.
Version migration, multi-process editing conflicts and additional provider
preferences are future work, not implied by schema versioning.

## Deterministic native preview and CI

On Windows, export the same seed, frame, size and ISO-8601 epoch twice:

```powershell
dotnet run --project tools/Pickleball.Preview -c Release -- artifacts/frame.png 120 42 1280x720 '2026-01-01T12:00:00.0000000+00:00'
```

The output directory must already exist. Frames are advanced at a fixed
60 Hz and bounded to 36,000 steps. Export never loads/saves user preferences
or starts providers. Repeatability is checked **on the same native runner**;
cross-architecture/font-version bit-for-bit PNG identity is not promised.

`.github/workflows/windows-foundation.yml` uses `windows-2025` (native x64)
and `windows-11-arm` (native ARM64), with explicit OS/SDK/process architecture
checks to reject emulation. These labels are listed in the official
[GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
(checked October 2, 2026); this repository is public. x64 hosted runners are
Windows Server, so the x64 job does not constitute Windows 11 desktop acceptance.
The ARM job uses the Windows 11 image. CI publishes/audits both RIDs, exercises
small isolated child HWNDs, Save/Cancel against an explicit test directory,
provider cancellation, offscreen rendering, invalid `.scr` options/handles,
valid renamed bundled `.scr` preview/resize/parent-death and
same-seed PNG repeatability. It never installs or registers a saver, alters
user preferences or policies, or requires signing secrets. CI uploads unsigned
foundation artifacts only; it is not a second release publisher.

Local macOS validation can prove portable tests, reference compilation and
PE/publish architecture. It **cannot** prove Windows runtime operation.
Native CI must run after pushing this branch; no native CI pass is claimed
by the local implementation.

### Foundation-stage validation recorded October 2, 2026

Executed only in the isolated `denmanjohn-maker-miniature-journey` worktree
on macOS ARM64, using an official Microsoft **10.0.401** SDK installed locally
for this task (not a global SDK installation):

| Check | Result |
| --- | --- |
| `dotnet test tests/Pickleball.Core.Tests -c Release --nologo` | 59 passed, 0 failed, 0 skipped |
| `python3 -B -m unittest discover -s packaging -p 'test_*.py'` | 7 passed (PE architecture/AnyCPU/native-apphost checks) |
| `dotnet build Pickleball.slnx -c Release --nologo` | All five projects compiled; 0 warnings/errors |
| `dotnet format Pickleball.slnx --verify-no-changes --no-restore` | Passed |
| `python3 packaging/publish.py --rid win-arm64 --output artifacts/handoff` | Bundled + complete-folder self-contained publishes succeeded; ARM64 `0xaa64` apphosts; 397 dependency PEs audited, including 157 native/R2R |
| `python3 packaging/publish.py --rid win-x64 --output artifacts/handoff` | Bundled + complete-folder self-contained publishes succeeded; AMD64 `0x8664` apphosts; 398 dependency PEs audited, including 158 native/R2R |
| Independent `file` inspection, ZIP CRC and SHA-256 verification | Both renamed GUI `.scr` architectures verified; all four ZIPs verified |
| Workflow YAML parsing and `git diff --check` | Passed |
| WPF execution, native integration/export, Windows 11 user acceptance | **Not run on macOS; pending Windows** |

The two bundled ZIPs, two fallback-folder ZIPs, checksum sidecars and unpacked
architecture reports are retained as ignored build outputs under
`windows/artifacts/handoff/`. The `--dotnet` override was used for the local
SDK during publication. Task-only SDK/download/cache files were removed after
validation; no installer or release was produced.

## Remaining stages / acceptance gate

1. Receive the final merged evaluation + artwork SHA; re-evaluate engine,
   renderer and defaults and then port rules/physics/movement/scoring/shot
   lifecycles and ordered per-step impacts.
2. Port projected court/net/paddles/ball/trails/shadows, scoreboard, all five
   appearances, framing/motion/team-color options and local clock/drills.
3. Port cached weather/geocoding/tournament providers with shared lifetime,
   cancellation and no-network preview/export enforcement; expand validated
   settings and Save/Cancel tests.
4. Native Windows 11 ARM64 **and** x64 desktop acceptance: real Control Panel
   preview, parent resize/death, owned modal configuration, keyboard/buttons/
   movement/deactivation exit, secure resume, multi-monitor negative origins,
   portrait/ultrawide/4K, mixed scaling and hot-plug. CI does not cover all of
   these scenarios.
5. Prove current-user ARM64/x64 installer tooling (WiX/MSI is a candidate, not
   yet selected/proven), install under LOCALAPPDATA, opt-in registration/theme
   selection, owned-artifact upgrade/repair/uninstall; never System32 or policy
   changes. Build final portable ZIPs and original Classic/BlackLight CAB
   `.deskthemepack` assets only after artwork is final.
6. Coordinate product version, single release owner, arch labels/checksums
   and Windows signing separately from macOS secrets. Signing identity is
   not supplied; no signing or SmartScreen guarantee is claimed. Preserve
   existing macOS release/download asset names. Do not tag/release foundation.
