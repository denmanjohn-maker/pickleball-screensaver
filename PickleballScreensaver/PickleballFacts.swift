import Foundation
import ScreenSaver

/// Persisted toggles for the drill-of-the-day card.
struct TipSettings {
    var drillEnabled = true
    var drillLevel = "all"   // "all" or a DUPR tier: "3.0", "3.5", "4.0", "5.0"

    private static let moduleName = "com.pickleball.screensaver"
    private static var defaults: ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    static func load() -> TipSettings {
        var s = TipSettings()
        if let d = defaults {
            if d.object(forKey: "ShowDrillOfTheDay") != nil {
                s.drillEnabled = d.bool(forKey: "ShowDrillOfTheDay")
            }
            if let level = d.string(forKey: "DrillLevel") {
                s.drillLevel = level
            }
        }
        return s
    }

    func save() {
        guard let d = Self.defaults else { return }
        d.set(drillEnabled, forKey: "ShowDrillOfTheDay")
        d.set(drillLevel, forKey: "DrillLevel")
        d.synchronize()
    }
}
