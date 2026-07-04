import AppKit
import ScreenSaver

// MARK: - Settings

enum PhotoSource: String {
    case off, photoSync, folder
}

/// Persisted configure-sheet choices, stored in the saver's ScreenSaverDefaults.
struct PhotoSettings {
    var source: PhotoSource = .off
    var intervalSeconds: Int = 60
    var folderBookmark: Data?

    static let intervalChoices = [15, 30, 60, 300, 600]
    private static let moduleName = "com.pickleball.screensaver"

    private static var defaults: ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    static func load() -> PhotoSettings {
        var s = PhotoSettings()
        guard let d = defaults else { return s }
        if let raw = d.string(forKey: "PhotoSourceType") {
            if raw == "photos" {
                s.source = .photoSync
            } else if let src = PhotoSource(rawValue: raw) {
                s.source = src
            }
        }
        let interval = d.integer(forKey: "PhotoIntervalSeconds")
        if intervalChoices.contains(interval) { s.intervalSeconds = interval }
        s.folderBookmark = d.data(forKey: "PhotoFolderBookmark")
        return s
    }

    func save() {
        guard let d = Self.defaults else { return }
        d.set(source.rawValue, forKey: "PhotoSourceType")
        d.set(intervalSeconds, forKey: "PhotoIntervalSeconds")
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
    private let syncRadio   = NSButton(radioButtonWithTitle: "Synced Photos:", target: nil, action: nil)
    private let folderRadio = NSButton(radioButtonWithTitle: "Image folder:", target: nil, action: nil)
    private let syncButton = NSButton(title: "Open Photo Sync…", target: nil, action: nil)
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
        offRadio.state = settings.source == .off ? .on : .off
        syncRadio.state = settings.source == .photoSync ? .on : .off
        folderRadio.state = settings.source == .folder ? .on : .off
        updateFolderLabel()
        refreshPhotoSyncStatus()
        updateEnabledState()
    }

    // MARK: Layout

    private func buildWindow() -> NSWindow {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Pickleball Screensaver Options"

        for b in [offRadio, syncRadio, folderRadio] {
            b.target = self
            b.action = #selector(sourceChanged(_:))
        }
        intervalPopup.addItems(withTitles: Self.intervalTitles)
        syncButton.target = self
        syncButton.action = #selector(openPhotoSync(_:))
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
            syncRadio,
            indent(syncButton),
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
        for b in [offRadio, syncRadio, folderRadio] { b.state = b == sender ? .on : .off }
        if sender == syncRadio { refreshPhotoSyncStatus() }
        updateEnabledState()
    }

    private func updateEnabledState() {
        syncButton.isEnabled = syncRadio.state == .on
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
        settings.source = offRadio.state == .on ? .off : (syncRadio.state == .on ? .photoSync : .folder)
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

    // MARK: Photo Sync

    @objc private func openPhotoSync(_ sender: Any?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PhotoSyncShared.appBundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
                DispatchQueue.main.async {
                    if let error {
                        self?.statusLabel.stringValue = error.localizedDescription
                    } else {
                        self?.refreshPhotoSyncStatus()
                    }
                }
            }
            return
        }
        if let bundlePath = PhotoSyncShared.readStatus()?.appBundlePath {
            let url = URL(fileURLWithPath: bundlePath)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
                    DispatchQueue.main.async {
                        self?.statusLabel.stringValue = error?.localizedDescription ?? self?.statusLabel.stringValue ?? ""
                    }
                }
                return
            }
        }
        statusLabel.stringValue = "Pickleball Photo Sync is not installed yet. Build it with `make photosync install-photosync`."
    }

    private func refreshPhotoSyncStatus() {
        if let status = PhotoSyncShared.readStatus() {
            statusLabel.stringValue = status.summaryText
        } else {
            statusLabel.stringValue = "Open Photo Sync to choose a Photos album and sync it for the screensaver."
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
