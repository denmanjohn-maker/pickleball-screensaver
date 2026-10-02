# Distributing the screensaver

## Cutting a release

Releases are built, signed, notarized, and published automatically by
[.github/workflows/release.yml](.github/workflows/release.yml) whenever a
`vX.Y` tag is pushed:

1. Bump `CFBundleShortVersionString` in `PickleballScreensaver/Info.plist`
   (the workflow fails if the tag and plist version disagree).
2. Commit to `main`, then:

   ```sh
   git tag v1.1
   git push origin v1.1
   ```

3. In ~10 minutes (notarization included) the release appears at
   https://github.com/denmanjohn-maker/pickleball-screensaver/releases with
   four assets: versioned zip/dmg plus version-less
   `PickleballScreensaver.zip` / `PickleballScreensaver.dmg` copies. The
   version-less names keep the download page's
   `releases/latest/download/...` links stable across versions.

You can also run the workflow manually from the Actions tab as a build-only
dry run — it uploads the artifacts without creating a release.

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

## Windows candidates and coordinated promotion

Windows 11 ARM64/x64 code, current-user MSI, complete self-contained portable
ZIPs and architecture-independent Classic/Black Light CAB theme packs live
under [`windows/`](windows/README.md). Product version 1.5 uses the .NET/MSI
numeric version 1.5.0. Windows architecture is explicit in every saver/installer
filename, with individual SHA-256 files. No .NET installation is required.

`.github/workflows/windows-foundation.yml` now validates the real engine,
artwork, settings/providers, native renamed `.scr`, screenshots, CAB packs
and MSI lifecycle on native x64 Server and native ARM64 Windows 11 runners.
Default artifacts are **unsigned development candidates**. Actual Windows 11
desktop/standard-user/performance/secure-resume acceptance and a Windows
Authenticode identity remain release gates; neither successful compilation
nor Apple signing/notarization satisfies those gates.

The existing **Release** workflow is the only release owner. Windows validation
uploads CI artifacts only—even its explicitly requested, main-only signing
path never creates a release. Keep macOS versionless asset URLs unchanged.
Do not rerun/publish over the existing `v1.5` automatically. After documented
desktop acceptance and explicit maintainer approval, the single release owner
can attach reviewed architecture-labeled Windows packages and checksums.
Windows signing secrets are independent of all Apple secrets; signing does
not guarantee SmartScreen reputation.

MSI authoring uses Windows Installer COM/makecab already present on Windows,
not WiX downloads. See the Windows guide for the verified WiX binary OSMF
threshold/exemptions and source-license distinction; this build incurs no
third-party installer fee or agreement acceptance.
