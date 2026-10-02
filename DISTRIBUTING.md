# Distributing the screensaver

## Cutting a release

Shared macOS and Windows releases are built and published automatically by
[.github/workflows/release.yml](.github/workflows/release.yml) whenever a
new `vX.Y` or `vX.Y.Z` tag is pushed. macOS is signed and notarized; Windows
is explicitly **unsigned**. The single publishing job waits for both platforms'
build/check jobs, uploads a draft, and makes it public only after all uploads
succeed.

1. Bump `CFBundleShortVersionString` in `PickleballScreensaver/Info.plist`
   and `Version` in `windows/Directory.Build.props` together.
   For example, macOS `1.7` corresponds to Windows `1.7.0`; macOS `1.7.1`
   corresponds to Windows `1.7.1`. Use a fresh version higher than the previous
   release; Windows Installer supports numeric major/minor/patch values up to
   255/255/65535. The workflow fails if the product versions or tag disagree.
2. Commit to `main`, then:

   ```sh
   git tag v1.7
   git push origin v1.7
   ```

3. After builds, native Windows checks, notarization and uploads succeed, the
   release appears at
   https://github.com/denmanjohn-maker/pickleball-screensaver/releases.
   It retains the four macOS assets: versioned ZIP/DMG plus versionless
   `PickleballScreensaver.zip` / `PickleballScreensaver.dmg`.
   Windows assets are listed below. Versionless names keep the download
   page's `releases/latest/download/...` URLs stable across versions.

You can also run **Release** manually from the Actions tab as a build-only
dry run, choosing `all`, `windows` or `macos`. It uploads artifacts without
creating a release, **even if you select a tag**. Windows-only dry runs do
not need Apple secrets. Windows packages and themes are separate artifacts;
diagnostic screenshots/logs are separate again and are never release assets.

Do not reuse existing tags or rerun publication over `v1.5`/`v1.6`. An existing
release or draft for the tag stops publication without replacing any assets.
If an upload fails after creating a draft, inspect and explicitly remove that
failed draft before retrying the failed job; nothing is silently overwritten.
No Windows assets are retroactively added to the existing macOS-only `v1.6`.

### One-time GitHub setup

The workflow needs these repository secrets
(**Settings → Secrets and variables → Actions**):

| Secret | Value |
|---|---|
| `APPLE_CERT_APPLICATION_P12` | base64 of your Developer ID **Application** certificate exported as `.p12` |
| `APPLE_CERT_INSTALLER_P12` | base64 of your Developer ID **Installer** certificate exported as `.p12` |
| `APPLE_CERT_PASSWORD` | the password you set when exporting the `.p12` files |
| `APPLE_SIGN_ID` | `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_INSTALLER_SIGN_ID` | `Developer ID Installer: Your Name (TEAMID)` |
| `APPLE_ID` | the Apple ID email for notarization |
| `APPLE_TEAM_ID` | your 10-character team ID |
| `APPLE_APP_PASSWORD` | an [app-specific password](https://account.apple.com) for that Apple ID |

To produce the cert values: in **Keychain Access**, select the certificate
(with its private key), File → Export Items… as `.p12` with a password, then
`base64 -i cert.p12 | pbcopy`. Find your identity strings with
`security find-identity -v -p codesigning` (Application) and
`security find-identity -v` (Installer). Export both certificates with the
same password, or store them separately and adjust the workflow.

The workflow checks notarization credentials before importing certificates or
building. If Apple returns HTTP 401 ("Invalid credentials"), verify that
`APPLE_ID` and `APPLE_TEAM_ID` match your developer account, generate a new
app-specific password at https://account.apple.com, and update the repository's
`APPLE_APP_PASSWORD` secret. Use an app-specific password, not your Apple ID
login password. Apple revokes app-specific passwords when the account password
is changed or reset. Retry the failed release after correcting the secrets;
rebuilding or changing the signing certificates does not fix this error.

The download page at
https://denmanjohn-maker.github.io/pickleball-screensaver/ is GitHub Pages
serving the `docs/` folder — enable it once under **Settings → Pages →
Deploy from a branch → `main` / `docs`**.

## Build a release zip

```sh
make dist
```

This builds a universal (Apple Silicon + Intel) `PickleballScreensaver.saver`,
ad-hoc signs it, and produces `PickleballScreensaver-<version>.zip`. Bump
`CFBundleShortVersionString` in `PickleballScreensaver/Info.plist` for each
release.

Share the zip however you like (GitHub Releases is the usual choice).

## What recipients do (zip)

1. Unzip and double-click `PickleballScreensaver.saver`. macOS asks whether to
   install for the current user or all users.
2. Open **System Settings → Screen Saver** and select it.

## Build a pkg-in-dmg instead

If you'd rather ship a standard macOS installer experience (double-click,
Installer.app walks them through it, no manual drag-and-drop) instead of a
raw `.saver` file:

```sh
make dmg
```

This builds the signed `.saver`, wraps it in an installer package
(`PickleballScreensaver-<version>.pkg`) that places it in
`/Library/Screen Savers` for all users on the Mac, then wraps that package in
`PickleballScreensaver-<version>.dmg`. `make pkg` alone stops after the pkg if
you don't need the disk image.

### What recipients do (pkg/dmg)

1. Double-click the `.dmg` to mount it, then double-click the `.pkg` inside.
2. Follow the Installer.app prompts (admin password required, since it
   installs to `/Library/Screen Savers` for every user on the machine).
3. Open **System Settings → Screen Saver** and select it.

### Signing the pkg itself

`SIGN_ID` (see below) signs the `.saver` bundle, but the outer `.pkg`
installer needs its own signature from a **Developer ID Installer**
certificate — a different certificate type than Developer ID Application,
requested the same way from the [Certificates
page](https://developer.apple.com/account/resources/certificates/list) once
you're enrolled in the Developer Program. Without it, `make pkg`/`make dmg`
produce an *unsigned* pkg — installable, but Gatekeeper will warn (see
below), and it can't be notarized as a pkg.

```sh
make dmg SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
         INSTALLER_SIGN_ID="Developer ID Installer: Your Name (TEAMID)"
```

## Gatekeeper: the ad-hoc-signed zip will be blocked at first

Anything downloaded from the internet is quarantined, and an ad-hoc signature
doesn't satisfy Gatekeeper on someone else's Mac. Recipients will see
*"PickleballScreensaver.saver" can't be opened because Apple cannot verify it*.
They have two ways past it:

- After the blocked attempt, open **System Settings → Privacy & Security**,
  scroll to the Security section, and click **Open Anyway** (macOS 15 asks
  for an admin password).
- Or clear quarantine in Terminal before double-clicking:
  `xattr -dr com.apple.quarantine ~/Downloads/PickleballScreensaver.saver`

Include one of these in your release notes — on macOS 15+ the old
right-click → Open shortcut no longer works.

## Removing the friction: Developer ID + notarization

To make installs "just work" (no warnings), you need a **Developer ID
Application** certificate, which requires the Apple Developer Program
($99/year, https://developer.apple.com/programs/):

1. In Xcode → Settings → Accounts (or the developer portal), create a
   **Developer ID Application** certificate and install it in your keychain.
2. Sign the bundle with it:

   ```sh
   make dist SIGN_ID="Developer ID Application: Your Name (TEAMID)"
   ```

   This signs with the hardened runtime and a secure timestamp, both required
   for notarization.
3. Store your notarization credentials once
   (app-specific password from https://account.apple.com):

   ```sh
   xcrun notarytool store-credentials pickleball \
     --apple-id you@example.com --team-id TEAMID
   ```

4. Notarize the zip and wait for approval (usually a couple of minutes):

   ```sh
   xcrun notarytool submit PickleballScreensaver-<version>.zip \
     --keychain-profile pickleball --wait
   ```

5. Staple the ticket to the bundle and re-zip, so it verifies even offline:

   ```sh
   xcrun stapler staple PickleballScreensaver.saver
   ditto -c -k --keepParent PickleballScreensaver.saver \
     PickleballScreensaver-<version>.zip
   ```

Ship that final zip. Recipients just double-click — no warnings.

## Windows releases and downloads

Windows 11 ARM64/x64 code, current-user MSI, complete self-contained portable
ZIPs and architecture-independent Classic/Black Light CAB theme packs live
under [`windows/`](windows/README.md). Product version 1.6 uses the .NET/MSI
numeric version 1.6.0. Windows architecture is explicit in every saver/installer
filename, with individual SHA-256 files. No .NET installation is required.
For a Windows version `<version>` and `<rid>` of `win-x64` or `win-arm64`,
each release includes:

| Package | Versioned filename | Stable download filename |
|---|---|---|
| Current-user installer | `PickleballScreensaver-<version>-<rid>.msi` | `PickleballScreensaver-<rid>.msi` |
| Complete portable ZIP | `PickleballScreensaver-<version>-<rid>.zip` | `PickleballScreensaver-<rid>.zip` |
| Unbundled folder ZIP fallback | `PickleballScreensaver-<version>-<rid>-folder.zip` | `PickleballScreensaver-<rid>-folder.zip` |
| Optional Classic wallpaper/colors | `Pickleball-Classic.deskthemepack` | Same |
| Optional Black Light wallpaper/colors | `Pickleball-BlackLight.deskthemepack` | Same |

Every Windows asset, including each stable alias, has a `.sha256` sidecar
containing that exact filename. Verify a downloaded package on Windows with
`Get-FileHash .\PickleballScreensaver-win-x64.msi -Algorithm SHA256`, comparing
the result with the matching checksum. Checksums detect damaged downloads;
they do not replace publisher signing or establish publisher trust.

`.github/workflows/windows-build.yml` validates the real engine,
artwork, settings/providers, native renamed `.scr`, screenshots, CAB packs
and MSI lifecycle on native x64 Server and native ARM64 Windows 11 runners.
Both **Release** and **Windows validation** reuse those checks. Product/MSI
and synthetic upgrade-test versions are derived from the product metadata,
not hard-coded. Release staging requires the exact inventory, correct native
package metadata and valid checksums; test fixtures cannot be promoted.

Public Windows builds are **unsigned** by design in this workflow.
Unknown-publisher or SmartScreen warnings are possible; no Windows signing
secret is needed for releases. Actual Windows 11 desktop, standard-user,
performance and secure-resume acceptance remain outstanding, not certified
by hosted checks. See [the acceptance details](windows/README.md#evidence-and-outstanding-acceptance).
Do not describe these releases as signed, warning-free or desktop-certified.

The existing **Release** workflow is the only release owner. **Windows
validation** uploads candidates only—even its explicitly requested, main-only
signing option never creates a release. Optional candidate signing uses
independent `WINDOWS_SIGNING_PFX_BASE64` / `WINDOWS_SIGNING_PASSWORD` secrets and
the HTTPS `WINDOWS_TIMESTAMP_URL` repository variable. These are not Apple
credentials. Signing a validation candidate does not change the public
unsigned-release policy or guarantee SmartScreen reputation.

### Installing on Windows 11

Choose the native architecture in **Settings → System → About → System type**:
x64 for Intel/AMD, ARM64 for ARM. The MSI installs for the current user under
`%LOCALAPPDATA%\Programs\PickleballScreensaver`; it does not place files in
System32, activate a saver, apply a theme or change security/idle policy.
Use the Start menu's **Pickleball Select (opt in)** shortcut to explicitly
select the saver and **Pickleball settings** to configure it.

For a portable ZIP, extract it and keep all files together. Double-click
`PickleballScreensaver.scr` for settings, and use `Maintain.ps1 -Action Select`
for explicit selection. Use `Maintain.ps1 -Action Uninstall` before deleting
a selected portable copy. MSI users uninstall through Windows Installed apps.
Theme packs are optional, user-owned desktop wallpaper/color customizations.

GitHub Pages continues to serve `main` / `docs`. Windows download links fall
back to the Releases listing before the first Windows release, when JavaScript
is disabled or when availability cannot be checked. Once matching assets
exist in the latest release, the page resolves them to direct stable downloads.

MSI authoring uses Windows Installer COM/makecab already present on Windows,
not WiX downloads. See the Windows guide for the verified WiX binary OSMF
threshold/exemptions and source-license distinction; this build incurs no
third-party installer fee or agreement acceptance.
