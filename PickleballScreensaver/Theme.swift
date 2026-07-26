import AppKit
import ScreenSaver

// MARK: - Theme
// Every color the renderer uses, in one struct. `classic` reproduces the
// original look exactly; `blacklight` is pure black with neon green, pink,
// and orange under UV.

struct Theme {
    // Court
    var courtSurface: CGColor
    var serviceBox: CGColor
    var courtLine: CGColor
    var grainRow: CGColor
    var grainCol: CGColor
    // Net
    var netMesh: CGColor
    var netStrand: CGColor
    var netTape: CGColor
    var netPost: CGColor
    // Ball
    var ballOutline: CGColor
    var ballBody: CGColor
    var ballHighlight: CGColor
    var ballTrail: NSColor          // alpha is scrubbed per trail dot
    // Background
    var backgroundBase: CGColor
    var usesBackgroundImage: Bool   // blacklight skips the wallpaper for pure black
    var backgroundGlowInner: CGColor
    var backgroundGlowOuter: CGColor
    // Overlay chrome
    var glassFill: CGColor
    var glassStroke: CGColor
    var cardFill: CGColor
    var textPrimary: NSColor
    var accent: NSColor
    // Misc
    var ghostFill: CGColor
    var paddleTint: NSColor?        // sprite recolor (alpha = tint strength); nil = as authored
    var glowStrength: CGFloat       // 0 = no neon glow pass; 1 = full blacklight glow

    static let classic = Theme(
        courtSurface: CGColor(red: 0.30, green: 0.53, blue: 0.40, alpha: 1),
        serviceBox:   CGColor(red: 0.13, green: 0.32, blue: 0.62, alpha: 1),
        courtLine:    CGColor(red: 1, green: 1, blue: 1, alpha: 0.95),
        grainRow:     CGColor(red: 0, green: 0, blue: 0, alpha: 0.18),
        grainCol:     CGColor(red: 0, green: 0, blue: 0, alpha: 0.08),
        netMesh:      CGColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 0.50),
        netStrand:    CGColor(red: 0.16, green: 0.17, blue: 0.18, alpha: 0.65),
        netTape:      CGColor(red: 1, green: 1, blue: 1, alpha: 0.95),
        netPost:      CGColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 1),
        ballOutline:  CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1),
        ballBody:     CGColor(red: 0.96, green: 0.82, blue: 0.05, alpha: 1),
        ballHighlight: CGColor(red: 1, green: 0.96, blue: 0.55, alpha: 0.50),
        ballTrail:    NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1),
        backgroundBase: CGColor(red: 0.05, green: 0.09, blue: 0.10, alpha: 1),
        usesBackgroundImage: true,
        backgroundGlowInner: CGColor(red: 0.10, green: 0.22, blue: 0.20, alpha: 0.55),
        backgroundGlowOuter: CGColor(red: 0.05, green: 0.09, blue: 0.10, alpha: 0),
        glassFill:    CGColor(red: 0, green: 0, blue: 0, alpha: 0.75),
        glassStroke:  CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
        cardFill:     CGColor(red: 0.07, green: 0.13, blue: 0.15, alpha: 0.48),
        textPrimary:  .white,
        accent:       NSColor(calibratedRed: 0.96, green: 0.82, blue: 0.05, alpha: 1),
        ghostFill:    CGColor(red: 0.12, green: 0.24, blue: 0.23, alpha: 1),
        paddleTint:   nil,
        glowStrength: 0
    )

    // Black light: everything black except what fluoresces — green court
    // lines, pink net tape and trail, a yellow-green ball, orange accents.
    static let blacklight = Theme(
        courtSurface: CGColor(red: 0.02, green: 0.06, blue: 0.04, alpha: 1),
        serviceBox:   CGColor(red: 0.02, green: 0.03, blue: 0.09, alpha: 1),
        courtLine:    CGColor(red: 0.25, green: 1.0, blue: 0.40, alpha: 0.95),
        grainRow:     CGColor(red: 0.25, green: 1.0, blue: 0.40, alpha: 0.10),
        grainCol:     CGColor(red: 0.25, green: 1.0, blue: 0.40, alpha: 0.05),
        netMesh:      CGColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 0.55),
        netStrand:    CGColor(red: 0.85, green: 0.25, blue: 0.75, alpha: 0.30),
        netTape:      CGColor(red: 1.0, green: 0.30, blue: 0.78, alpha: 0.95),
        netPost:      CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1),
        ballOutline:  CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1),
        ballBody:     CGColor(red: 0.78, green: 1.0, blue: 0.15, alpha: 1),
        ballHighlight: CGColor(red: 0.95, green: 1.0, blue: 0.55, alpha: 0.50),
        ballTrail:    NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.80, alpha: 1),
        backgroundBase: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        usesBackgroundImage: false,
        backgroundGlowInner: CGColor(red: 0.10, green: 0.02, blue: 0.18, alpha: 0.40),
        backgroundGlowOuter: CGColor(red: 0, green: 0, blue: 0, alpha: 0),
        glassFill:    CGColor(red: 0, green: 0, blue: 0, alpha: 0.82),
        glassStroke:  CGColor(red: 0.25, green: 1.0, blue: 0.40, alpha: 0.35),
        cardFill:     CGColor(red: 0.02, green: 0.0, blue: 0.05, alpha: 0.55),
        textPrimary:  .white,
        accent:       NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.10, alpha: 1),
        ghostFill:    CGColor(red: 0.10, green: 0.02, blue: 0.12, alpha: 1),
        paddleTint:   NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.8, alpha: 0.35),
        glowStrength: 1
    )

    static func named(_ name: String) -> Theme {
        name == "blacklight" ? .blacklight : .classic
    }
}

// MARK: - Persisted settings
// Same ScreenSaverDefaults pattern as WeatherSettings/DrillSettings: read in
// the view's setup(), written by the configure sheet.

struct ThemeSettings {
    var theme = "classic"

    private static let moduleName = "com.pickleball.screensaver"
    private static var defaults: ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    static func load() -> ThemeSettings {
        var s = ThemeSettings()
        guard let d = defaults else { return s }
        s.theme = d.string(forKey: "Theme") ?? "classic"
        return s
    }

    func save() {
        guard let d = Self.defaults else { return }
        d.set(theme, forKey: "Theme")
        d.synchronize()
    }
}

struct MatchSettings {
    var format = "doubles"

    private static let moduleName = "com.pickleball.screensaver"
    private static var defaults: ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    static func load() -> MatchSettings {
        var s = MatchSettings()
        guard let d = defaults else { return s }
        s.format = d.string(forKey: "GameFormat") ?? "doubles"
        return s
    }

    func save() {
        guard let d = Self.defaults else { return }
        d.set(format, forKey: "GameFormat")
        d.synchronize()
    }
}
