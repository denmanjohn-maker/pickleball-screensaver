# Distributing the screensaver

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
