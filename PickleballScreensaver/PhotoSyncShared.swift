import Foundation

struct PhotoSyncStatus {
    var albumIdentifier: String?
    var albumName: String?
    var imageCount: Int
    var lastSyncDate: Date?
    var lastError: String?
    var isAuthorized: Bool
    var appBundlePath: String?

    init(
        albumIdentifier: String? = nil,
        albumName: String? = nil,
        imageCount: Int = 0,
        lastSyncDate: Date? = nil,
        lastError: String? = nil,
        isAuthorized: Bool = false,
        appBundlePath: String? = nil
    ) {
        self.albumIdentifier = albumIdentifier
        self.albumName = albumName
        self.imageCount = imageCount
        self.lastSyncDate = lastSyncDate
        self.lastError = lastError
        self.isAuthorized = isAuthorized
        self.appBundlePath = appBundlePath
    }

    init?(dictionary: [String: Any]) {
        albumIdentifier = dictionary["albumIdentifier"] as? String
        albumName = dictionary["albumName"] as? String
        imageCount = dictionary["imageCount"] as? Int ?? 0
        lastSyncDate = dictionary["lastSyncDate"] as? Date
        lastError = dictionary["lastError"] as? String
        isAuthorized = dictionary["isAuthorized"] as? Bool ?? false
        appBundlePath = dictionary["appBundlePath"] as? String
    }

    var dictionaryRepresentation: [String: Any] {
        var dictionary: [String: Any] = [
            "imageCount": imageCount,
            "isAuthorized": isAuthorized,
        ]
        if let albumIdentifier { dictionary["albumIdentifier"] = albumIdentifier }
        if let albumName { dictionary["albumName"] = albumName }
        if let lastSyncDate { dictionary["lastSyncDate"] = lastSyncDate }
        if let lastError { dictionary["lastError"] = lastError }
        if let appBundlePath { dictionary["appBundlePath"] = appBundlePath }
        return dictionary
    }

    var summaryText: String {
        if !isAuthorized {
            return "Photo Sync needs Photos access. Open the helper app to grant it."
        }
        guard let albumName else {
            return "Open Photo Sync to choose a Photos album."
        }
        if let lastError, !lastError.isEmpty {
            return "Album: \(albumName) · \(lastError)"
        }
        var pieces = ["Album: \(albumName)", "\(imageCount) synced"]
        if let lastSyncDate {
            let formatter = RelativeDateTimeFormatter()
            pieces.append("synced \(formatter.localizedString(for: lastSyncDate, relativeTo: Date()))")
        } else {
            pieces.append("not synced yet")
        }
        return pieces.joined(separator: " · ")
    }
}

enum PhotoSyncShared {
    static let appBundleIdentifier = "com.pickleball.photosync"

    static var appSupportDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PickleballScreensaver", isDirectory: true)
    }

    static var syncedPhotosDirectoryURL: URL {
        appSupportDirectoryURL.appendingPathComponent("SyncedPhotos", isDirectory: true)
    }

    static var statusFileURL: URL {
        appSupportDirectoryURL.appendingPathComponent("PhotoSyncStatus.plist", isDirectory: false)
    }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: syncedPhotosDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    static func readStatus() -> PhotoSyncStatus? {
        guard
            let dictionary = NSDictionary(contentsOf: statusFileURL) as? [String: Any]
        else {
            return nil
        }
        return PhotoSyncStatus(dictionary: dictionary)
    }

    static func writeStatus(_ status: PhotoSyncStatus) throws {
        try ensureDirectories()
        let dictionary = status.dictionaryRepresentation as NSDictionary
        if !dictionary.write(to: statusFileURL, atomically: true) {
            throw NSError(
                domain: "PhotoSyncShared",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write Photo Sync status."]
            )
        }
    }
}
