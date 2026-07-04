# pickleball-screensaver

A macOS screensaver that renders a stylized pickleball court, scoreboard, calendar overlays, and photo callouts on the blue back-court quadrants.

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