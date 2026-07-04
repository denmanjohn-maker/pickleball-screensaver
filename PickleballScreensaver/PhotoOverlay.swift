import AppKit
import ImageIO

/// Drives the photo-dissolve overlay: sources images from the synced Photos
/// folder or a bookmarked folder and runs the idle → fadeIn → hold → fadeOut
/// cycle. All loading happens off the main thread; `update(dt:)` and
/// `alpha`/`image` are main-thread only and never block.
final class PhotoOverlayController {

    private enum Phase { case idle, fadeIn, hold, fadeOut }

    private let fadeDuration: CGFloat = 1.0
    private let holdDuration: CGFloat = 5.0
    private let retryDelay: CGFloat = 10.0

    private var phase: Phase = .idle
    private var phaseTime: CGFloat = 0
    private let idleDuration: CGFloat
    private var pendingImage: CGImage?
    private var loading = false
    private var loadCooldown: CGFloat = 0
    private(set) var image: CGImage?

    /// Cap for decoded image size in pixels; the view sets it from its bounds.
    var maxPixelSize: CGFloat = 2048

    private let settings: PhotoSettings

    init(settings: PhotoSettings) {
        self.settings = settings
        idleDuration = CGFloat(settings.intervalSeconds)
    }

    var alpha: CGFloat {
        switch phase {
        case .idle:    return 0
        case .fadeIn:  return smoothstep(min(1, phaseTime / fadeDuration))
        case .hold:    return 1
        case .fadeOut: return 1 - smoothstep(min(1, phaseTime / fadeDuration))
        }
    }

    private func smoothstep(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    /// Advance the cycle. Returns true when a new photo just started fading in,
    /// so the caller can pick its placement.
    func update(dt: CGFloat) -> Bool {
        phaseTime += dt
        switch phase {
        case .idle:
            loadCooldown = max(0, loadCooldown - dt)
            if phaseTime >= idleDuration - 2, pendingImage == nil, !loading, loadCooldown <= 0 {
                startLoad()
            }
            if phaseTime >= idleDuration {
                if let img = pendingImage {
                    pendingImage = nil
                    image = img
                    phase = .fadeIn
                    phaseTime = 0
                    return true
                }
                phaseTime = idleDuration   // wait at the boundary until a load succeeds
            }
        case .fadeIn:
            if phaseTime >= fadeDuration { phase = .hold; phaseTime = 0 }
        case .hold:
            if phaseTime >= holdDuration { phase = .fadeOut; phaseTime = 0 }
        case .fadeOut:
            if phaseTime >= fadeDuration {
                phase = .idle
                phaseTime = 0
                image = nil
            }
        }
        return false
    }

    /// Test hook for the offscreen preview harness: dissolve this image in on
    /// the next update, bypassing Photos/folder loading entirely.
    func _debugInject(_ image: CGImage) {
        pendingImage = image
        phase = .idle
        phaseTime = idleDuration
    }

    // MARK: - Loading

    private func startLoad() {
        loading = true
        let maxSize = maxPixelSize
        let settings = self.settings
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let img = Self.loadRandomImage(settings: settings, maxPixelSize: maxSize)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                if let img {
                    self.pendingImage = img
                } else {
                    self.loadCooldown = self.retryDelay
                }
            }
        }
    }

    private static func loadRandomImage(settings: PhotoSettings, maxPixelSize: CGFloat) -> CGImage? {
        switch settings.source {
        case .off:
            return nil
        case .photoSync:
            return loadFromDirectory(url: PhotoSyncShared.syncedPhotosDirectoryURL, maxPixelSize: maxPixelSize)
        case .folder:
            return loadFromFolder(bookmark: settings.folderBookmark, maxPixelSize: maxPixelSize)
        }
    }

    private static func loadFromFolder(bookmark: Data?, maxPixelSize: CGFloat) -> CGImage? {
        guard let bookmark else { return nil }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return loadFromDirectory(url: url, maxPixelSize: maxPixelSize)
    }

    private static func loadFromDirectory(url: URL, maxPixelSize: CGFloat) -> CGImage? {
        let exts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "gif", "webp"]
        guard let files = try? FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter({ exts.contains($0.pathExtension.lowercased()) }),
            let pick = files.randomElement() else { return nil }

        guard let src = CGImageSourceCreateWithURL(pick as CFURL, nil) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // applies EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
    }
}
