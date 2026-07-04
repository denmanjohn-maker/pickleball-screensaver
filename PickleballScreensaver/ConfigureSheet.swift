import AppKit
import ScreenSaver
import Photos

// MARK: - Settings

enum PhotoSource: String {
    case off, photos, folder
}

/// Persisted configure-sheet choices, stored in the saver's ScreenSaverDefaults.
struct PhotoSettings {
    var source: PhotoSource = .off
    var intervalSeconds: Int = 60
    var albumIdentifier: String?
    var folderBookmark: Data?

    static let intervalChoices = [15, 30, 60, 300, 600]
    private static let moduleName = "com.pickleball.screensaver"

    private static var defaults: ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    static func load() -> PhotoSettings {
        var s = PhotoSettings()
        guard let d = defaults else { return s }
        if let raw = d.string(forKey: "PhotoSourceType"),
           let src = PhotoSource(rawValue: raw) { s.source = src }
        let interval = d.integer(forKey: "PhotoIntervalSeconds")
        if intervalChoices.contains(interval) { s.intervalSeconds = interval }
        s.albumIdentifier = d.string(forKey: "PhotoAlbumLocalIdentifier")
        s.folderBookmark = d.data(forKey: "PhotoFolderBookmark")
        return s
    }

    func save() {
        guard let d = Self.defaults else { return }
        d.set(source.rawValue, forKey: "PhotoSourceType")
        d.set(intervalSeconds, forKey: "PhotoIntervalSeconds")
        d.set(albumIdentifier, forKey: "PhotoAlbumLocalIdentifier")
        d.set(folderBookmark, forKey: "PhotoFolderBookmark")
        d.synchronize()
    }
}

// MARK: - Configure sheet

/// Programmatic options panel shown from System Settings ("Options…").
/// The owning view must keep this controller alive for the sheet's lifetime,
/// and dismissal must go through sheetParent.endSheet — System Settings hangs
/// on close()/stopModal.
final class ConfigureSheetController: NSObject {

    private var settings = PhotoSettings.load()

    private let intervalPopup = NSPopUpButton()
    private let offRadio    = NSButton(radioButtonWithTitle: "Off", target: nil, action: nil)
    private let photosRadio = NSButton(radioButtonWithTitle: "Photos album:", target: nil, action: nil)
    private let folderRadio = NSButton(radioButtonWithTitle: "Image folder:", target: nil, action: nil)
    private let albumPopup = NSPopUpButton()
    private let folderButton = NSButton(title: "Choose Folder…", target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: "No folder selected")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private static let intervalTitles = ["15 seconds", "30 seconds", "1 minute", "5 minutes", "10 minutes"]

    private(set) lazy var window: NSWindow = buildWindow()

    /// Sync control state from persisted settings; the view calls this each
    /// time the sheet is requested so a cancelled edit doesn't linger.
    func refresh() {
        _ = window
        settings = PhotoSettings.load()
        if let idx = PhotoSettings.intervalChoices.firstIndex(of: settings.intervalSeconds) {
            intervalPopup.selectItem(at: idx)
        }
        offRadio.state    = settings.source == .off    ? .on : .off
        photosRadio.state = settings.source == .photos ? .on : .off
        folderRadio.state = settings.source == .folder ? .on : .off
        statusLabel.stringValue = ""
        updateFolderLabel()
        albumPopup.menu?.removeAllItems()
        if settings.source == .photos { loadAlbumsIfAuthorized() }
        updateEnabledState()
    }

    // MARK: Layout

    private func buildWindow() -> NSWindow {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Pickleball Screensaver Options"

        for b in [offRadio, photosRadio, folderRadio] {
            b.target = self
            b.action = #selector(sourceChanged(_:))
        }
        intervalPopup.addItems(withTitles: Self.intervalTitles)
        folderButton.target = self
        folderButton.action = #selector(chooseFolder(_:))
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let okButton = NSButton(title: "OK", target: self, action: #selector(ok(_:)))
        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"

        let sourceHeader = NSTextField(labelWithString: "Photo source:")
        sourceHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let stack = NSStackView(views: [
            hstack([NSTextField(labelWithString: "Show a photo every:"), intervalPopup]),
            sourceHeader,
            offRadio,
            photosRadio,
            indent(albumPopup),
            folderRadio,
            indent(hstack([folderButton, folderLabel])),
            statusLabel,
            hstack([spacer(), cancelButton, okButton]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            albumPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        // The button row and status label stretch to the sheet's full width
        for v in [stack.views.last!, statusLabel] {
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        panel.setContentSize(NSSize(width: 460, height: content.fittingSize.height))
        return panel
    }

    private func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func indent(_ view: NSView) -> NSStackView {
        let pad = NSView()
        pad.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return hstack([pad, view])
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    // MARK: Actions

    @objc private func sourceChanged(_ sender: NSButton) {
        // Manual radio behaviour — the three buttons live in different stack rows,
        // so AppKit won't group them automatically.
        for b in [offRadio, photosRadio, folderRadio] { b.state = b == sender ? .on : .off }
        statusLabel.stringValue = ""
        if sender == photosRadio { requestPhotosAndLoadAlbums() }
        updateEnabledState()
    }

    private func updateEnabledState() {
        albumPopup.isEnabled = photosRadio.state == .on
        folderButton.isEnabled = folderRadio.state == .on
    }

    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // Security-scoped bookmarks can fail without the entitlement in some
            // hosts; a plain bookmark still works for folders the saver can read.
            self.settings.folderBookmark =
                (try? url.bookmarkData(options: [.withSecurityScope],
                                       includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? (try? url.bookmarkData())
            self.updateFolderLabel()
        }
    }

    @objc private func ok(_ sender: Any?) {
        settings.intervalSeconds = PhotoSettings.intervalChoices[max(0, intervalPopup.indexOfSelectedItem)]
        settings.source = offRadio.state == .on ? .off : (photosRadio.state == .on ? .photos : .folder)
        settings.albumIdentifier = albumPopup.selectedItem?.representedObject as? String ?? settings.albumIdentifier
        settings.save()
        dismiss(.OK)
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(.cancel)
    }

    private func dismiss(_ code: NSApplication.ModalResponse) {
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: code)
        } else {
            window.orderOut(nil)   // standalone test host
        }
    }

    // MARK: Photos albums

    private func requestPhotosAndLoadAlbums() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            loadAlbums()
        case .notDetermined:
            statusLabel.stringValue = "Requesting Photos access…"
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if status == .authorized || status == .limited {
                        self.statusLabel.stringValue = ""
                        self.loadAlbums()
                    } else {
                        self.statusLabel.stringValue = "Photos access was denied — choose an image folder instead."
                    }
                }
            }
        default:
            statusLabel.stringValue = "Photos access is denied. Allow it in System Settings › Privacy & Security › Photos, or choose an image folder."
        }
    }

    private func loadAlbumsIfAuthorized() {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if s == .authorized || s == .limited { loadAlbums() }
    }

    private func loadAlbums() {
        albumPopup.menu?.removeAllItems()
        var albums: [(title: String, id: String)] = []
        let favorites = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil)
        favorites.enumerateObjects { c, _, _ in
            albums.append((c.localizedTitle ?? "Favorites", c.localIdentifier))
        }
        let user = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil)
        user.enumerateObjects { c, _, _ in
            albums.append((c.localizedTitle ?? "Untitled", c.localIdentifier))
        }
        for a in albums {
            // Not addItem(withTitle:) — it silently drops duplicate titles
            let item = NSMenuItem(title: a.title, action: nil, keyEquivalent: "")
            item.representedObject = a.id
            albumPopup.menu?.addItem(item)
        }
        if albums.isEmpty {
            statusLabel.stringValue = "No albums found in your Photos library."
        }
        if let id = settings.albumIdentifier,
           let idx = albums.firstIndex(where: { $0.id == id }) {
            albumPopup.selectItem(at: idx)
        }
    }

    private func updateFolderLabel() {
        if let data = settings.folderBookmark {
            var stale = false
            let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &stale))
            if let url {
                folderLabel.stringValue = url.path
                return
            }
        }
        folderLabel.stringValue = "No folder selected"
    }
}
