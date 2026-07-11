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

## What recipients do

1. Unzip and double-click `PickleballScreensaver.saver`. macOS asks whether to
   install for the current user or all users.
2. Open **System Settings → Screen Saver** and select it.

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
