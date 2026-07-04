import AppKit

final class PhotoSyncAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PhotoSyncMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = PhotoSyncMenuController()
        controller?.start()
    }
}
