import AppKit
import Photos
import ServiceManagement

private struct AlbumChoice {
    let title: String
    let identifier: String
}

final class PhotoSyncMenuController: NSObject, NSMenuDelegate {
    private let selectedAlbumKey = "SelectedAlbumIdentifier"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let defaults = UserDefaults.standard

    private var albums: [AlbumChoice] = []
    private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private var isSyncing = false
    private var imageCount = 0
    private var lastSyncDate: Date?
    private var lastError: String?
    private var selectedAlbumName: String?
    private var refreshTimer: Timer?

    func start() {
        configureStatusItem()
        loadPersistedStatus()
        refreshAuthorizationAndAlbums()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 30 * 60,
            target: self,
            selector: #selector(syncTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        rebuildMenu()
    }

    private var selectedAlbumIdentifier: String? {
        get { defaults.string(forKey: selectedAlbumKey) }
        set { defaults.set(newValue, forKey: selectedAlbumKey) }
    }

    private var selectedAlbum: AlbumChoice? {
        guard let selectedAlbumIdentifier else { return nil }
        return albums.first { $0.identifier == selectedAlbumIdentifier }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.toolTip = "Pickleball Photo Sync"
            button.image = NSImage(
                systemSymbolName: "photo.on.rectangle.angled",
                accessibilityDescription: "Pickleball Photo Sync"
            )
            button.image?.isTemplate = true
            if button.image == nil {
                button.title = "PB"
            }
        }
    }

    private func loadPersistedStatus() {
        guard let status = PhotoSyncShared.readStatus() else { return }
        imageCount = status.imageCount
        lastSyncDate = status.lastSyncDate
        lastError = status.lastError
        selectedAlbumName = status.albumName
        if selectedAlbumIdentifier == nil {
            selectedAlbumIdentifier = status.albumIdentifier
        }
    }

    private func refreshAuthorizationAndAlbums() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            albums = loadAlbums()
            if let selected = selectedAlbum {
                selectedAlbumName = selected.title
            } else if let firstAlbum = albums.first, selectedAlbumIdentifier == nil {
                selectedAlbumIdentifier = firstAlbum.identifier
                selectedAlbumName = firstAlbum.title
            }
        } else {
            albums = []
        }
        persistStatus()
        rebuildMenu()
    }

    private func loadAlbums() -> [AlbumChoice] {
        var choices: [AlbumChoice] = []
        var seen = Set<String>()

        let favorites = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumFavorites,
            options: nil
        )
        favorites.enumerateObjects { collection, _, _ in
            guard seen.insert(collection.localIdentifier).inserted else { return }
            choices.append(AlbumChoice(
                title: collection.localizedTitle ?? "Favorites",
                identifier: collection.localIdentifier
            ))
        }

        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var regularAlbums: [AlbumChoice] = []
        userAlbums.enumerateObjects { collection, _, _ in
            guard seen.insert(collection.localIdentifier).inserted else { return }
            regularAlbums.append(AlbumChoice(
                title: collection.localizedTitle ?? "Untitled Album",
                identifier: collection.localIdentifier
            ))
        }
        regularAlbums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        choices.append(contentsOf: regularAlbums)
        return choices
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let titleItem = NSMenuItem(title: "Pickleball Photo Sync", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let detailItem = NSMenuItem(title: statusSummary(), action: nil, keyEquivalent: "")
        detailItem.isEnabled = false
        menu.addItem(detailItem)

        menu.addItem(.separator())

        if authorizationStatus == .notDetermined {
            menu.addItem(makeItem("Grant Photos Access…", #selector(requestPhotosAccess(_:))))
        } else if authorizationStatus != .authorized && authorizationStatus != .limited {
            menu.addItem(makeItem("Open Photos Privacy Settings", #selector(openPhotosPrivacySettings(_:))))
        }

        let albumMenuItem = NSMenuItem(title: "Choose Album", action: nil, keyEquivalent: "")
        let albumSubmenu = NSMenu(title: "Choose Album")
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            if albums.isEmpty {
                let emptyItem = NSMenuItem(title: "No albums found", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                albumSubmenu.addItem(emptyItem)
            } else {
                for album in albums {
                    let item = NSMenuItem(title: album.title, action: #selector(selectAlbum(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = album.identifier
                    item.state = album.identifier == selectedAlbumIdentifier ? .on : .off
                    albumSubmenu.addItem(item)
                }
            }
        } else {
            let lockedItem = NSMenuItem(title: "Photos access required", action: nil, keyEquivalent: "")
            lockedItem.isEnabled = false
            albumSubmenu.addItem(lockedItem)
        }
        albumMenuItem.submenu = albumSubmenu
        menu.addItem(albumMenuItem)

        let syncNowItem = makeItem("Sync Now", #selector(syncNow(_:)))
        syncNowItem.isEnabled = !isSyncing && selectedAlbum != nil && (authorizationStatus == .authorized || authorizationStatus == .limited)
        menu.addItem(syncNowItem)

        let openFolderItem = makeItem("Open Synced Photos Folder", #selector(openSyncedFolder(_:)))
        menu.addItem(openFolderItem)

        let launchItem = makeItem("Launch at Login", #selector(toggleLaunchAtLogin(_:)))
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("Quit", #selector(quit(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func makeItem(_ title: String, _ action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func statusSummary() -> String {
        if isSyncing {
            return "Syncing photos…"
        }
        return PhotoSyncStatus(
            albumIdentifier: selectedAlbumIdentifier,
            albumName: selectedAlbumName,
            imageCount: imageCount,
            lastSyncDate: lastSyncDate,
            lastError: lastError,
            isAuthorized: authorizationStatus == .authorized || authorizationStatus == .limited,
            appBundlePath: Bundle.main.bundlePath
        ).summaryText
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func persistStatus() {
        do {
            try PhotoSyncShared.writeStatus(
                PhotoSyncStatus(
                    albumIdentifier: selectedAlbumIdentifier,
                    albumName: selectedAlbumName,
                    imageCount: imageCount,
                    lastSyncDate: lastSyncDate,
                    lastError: lastError,
                    isAuthorized: authorizationStatus == .authorized || authorizationStatus == .limited,
                    appBundlePath: Bundle.main.bundlePath
                )
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    @objc private func requestPhotosAccess(_ sender: Any?) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshAuthorizationAndAlbums()
            }
        }
    }

    @objc private func openPhotosPrivacySettings(_ sender: Any?) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func selectAlbum(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        selectedAlbumIdentifier = identifier
        selectedAlbumName = albums.first(where: { $0.identifier == identifier })?.title
        lastError = nil
        persistStatus()
        performSync()
    }

    @objc private func syncNow(_ sender: Any?) {
        performSync()
    }

    @objc private func openSyncedFolder(_ sender: Any?) {
        do {
            try PhotoSyncShared.ensureDirectories()
            NSWorkspace.shared.open(PhotoSyncShared.syncedPhotosDirectoryURL)
        } catch {
            lastError = error.localizedDescription
            persistStatus()
            rebuildMenu()
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            lastError = nil
        } catch {
            lastError = "Launch at Login failed: \(error.localizedDescription)"
        }
        persistStatus()
        rebuildMenu()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func syncTimerFired(_ sender: Any?) {
        performSync()
    }

    private func performSync() {
        guard !isSyncing else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            lastError = "Photos access is required before syncing."
            persistStatus()
            rebuildMenu()
            return
        }
        guard let selectedAlbum else {
            lastError = "Choose an album first."
            persistStatus()
            rebuildMenu()
            return
        }

        isSyncing = true
        lastError = nil
        rebuildMenu()

        let selectedIdentifier = selectedAlbum.identifier
        let selectedTitle = selectedAlbum.title

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let syncedCount = try Self.syncAlbum(identifier: selectedIdentifier)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSyncing = false
                    self.imageCount = syncedCount
                    self.lastSyncDate = Date()
                    self.lastError = nil
                    self.selectedAlbumName = selectedTitle
                    self.persistStatus()
                    self.rebuildMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSyncing = false
                    self.lastError = "Sync failed: \(error.localizedDescription)"
                    self.selectedAlbumName = selectedTitle
                    self.persistStatus()
                    self.rebuildMenu()
                }
            }
        }
    }

    private static func syncAlbum(identifier: String, maxPixelSize: CGFloat = 2560) throws -> Int {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw NSError(domain: "PhotoSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected album no longer exists."])
        }

        try PhotoSyncShared.ensureDirectories()

        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let assets = PHAsset.fetchAssets(in: album, options: fetchOptions)
        guard assets.count > 0 else {
            throw NSError(domain: "PhotoSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected album has no images."])
        }

        let imageManager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.isNetworkAccessAllowed = false
        requestOptions.resizeMode = .exact

        let fileManager = FileManager.default
        var expectedNames = Set<String>()
        var syncedCount = 0

        for index in 0..<assets.count {
            autoreleasepool {
                let asset = assets.object(at: index)
                let filename = sanitizedFilename(for: asset.localIdentifier) + ".jpg"
                expectedNames.insert(filename)
                let destinationURL = PhotoSyncShared.syncedPhotosDirectoryURL.appendingPathComponent(filename)
                do {
                    guard let imageData = renderJPEGData(for: asset, imageManager: imageManager, requestOptions: requestOptions, maxPixelSize: maxPixelSize) else {
                        return
                    }
                    try imageData.write(to: destinationURL, options: .atomic)
                    syncedCount += 1
                } catch {
                    // Fail the whole sync only if writing breaks; missing local
                    // iCloud originals are simply skipped.
                }
            }
        }

        let existingFiles = try fileManager.contentsOfDirectory(
            at: PhotoSyncShared.syncedPhotosDirectoryURL,
            includingPropertiesForKeys: nil
        )
        for fileURL in existingFiles where !expectedNames.contains(fileURL.lastPathComponent) {
            try? fileManager.removeItem(at: fileURL)
        }

        return syncedCount
    }

    private static func renderJPEGData(
        for asset: PHAsset,
        imageManager: PHImageManager,
        requestOptions: PHImageRequestOptions,
        maxPixelSize: CGFloat
    ) -> Data? {
        let originalWidth = CGFloat(max(asset.pixelWidth, 1))
        let originalHeight = CGFloat(max(asset.pixelHeight, 1))
        let longEdge = max(originalWidth, originalHeight)
        let scale = min(1, maxPixelSize / longEdge)
        let targetSize = CGSize(
            width: max(1, originalWidth * scale),
            height: max(1, originalHeight * scale)
        )

        var renderedImage: NSImage?
        imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: requestOptions
        ) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if !degraded && !cancelled {
                renderedImage = image
            }
        }

        guard
            let renderedImage,
            let cgImage = renderedImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    private static func sanitizedFilename(for identifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = identifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars)
    }
}
