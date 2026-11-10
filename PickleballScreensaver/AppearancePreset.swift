import AppKit

enum AppearancePreset: String, CaseIterable {
    case classic, blacklight
    case livingCourt = "living-court"
    case inkPaper = "ink-and-paper"
    case rallyPainting = "rally-painting"
    case sunFadedRecLeague = "sun-faded-rec-league"
    case saturdayBroadcast = "saturday-broadcast"

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .blacklight: return "Black Light"
        case .livingCourt: return "Living Court"
        case .inkPaper: return "Ink-and-paper"
        case .rallyPainting: return "Rally Painting"
        case .sunFadedRecLeague: return "Sun-Faded Rec League"
        case .saturdayBroadcast: return "Saturday Broadcast"
        }
    }

    var theme: Theme {
        switch self {
        case .classic, .livingCourt: return .classic
        case .blacklight: return .blacklight
        case .inkPaper:
            var t = Theme.classic
            t.courtSurface = color(0.90, 0.87, 0.78)
            t.serviceBox = color(0.69, 0.78, 0.79, 0.62)
            t.courtLine = color(0.22, 0.23, 0.22, 0.85)
            t.grainRow = color(0, 0, 0, 0)
            t.grainCol = color(0, 0, 0, 0)
            t.netMesh = color(0.29, 0.28, 0.25, 0.18)
            t.netStrand = color(0.23, 0.24, 0.23, 0.38)
            t.netTape = color(0.27, 0.28, 0.26, 0.90)
            t.netPost = color(0.22, 0.24, 0.23)
            t.ballOutline = color(0.20, 0.23, 0.21)
            t.ballBody = color(0.75, 0.54, 0.16)
            t.ballHighlight = color(1, 0.95, 0.76, 0.55)
            t.ballTrail = NSColor(calibratedRed: 0.24, green: 0.30, blue: 0.28, alpha: 1)
            t.backgroundBase = color(0.96, 0.94, 0.88)
            t.usesBackgroundImage = false
            t.backgroundGlowInner = color(0, 0, 0, 0)
            t.backgroundGlowOuter = color(0, 0, 0, 0)
            t.glassFill = color(0.99, 0.98, 0.94, 0.94)
            t.glassStroke = color(0.24, 0.27, 0.25, 0.18)
            t.cardFill = color(0.99, 0.98, 0.94, 0.94)
            t.textPrimary = NSColor(calibratedRed: 0.15, green: 0.19, blue: 0.18, alpha: 1)
            t.accent = NSColor(calibratedRed: 0.44, green: 0.30, blue: 0.09, alpha: 1)
            t.teamA = NSColor(calibratedRed: 0.06, green: 0.40, blue: 0.49, alpha: 1)
            t.teamB = NSColor(calibratedRed: 0.65, green: 0.25, blue: 0.17, alpha: 1)
            return t
        case .rallyPainting:
            var t = Theme.classic
            t.courtSurface = color(0.09, 0.13, 0.15)
            t.serviceBox = color(0.08, 0.11, 0.14)
            t.courtLine = color(0.66, 0.74, 0.76, 0.70)
            t.grainRow = color(0.75, 0.80, 0.82, 0.035)
            t.grainCol = color(0.75, 0.80, 0.82, 0.025)
            t.backgroundBase = color(0.025, 0.035, 0.05)
            t.usesBackgroundImage = false
            t.backgroundGlowInner = color(0.09, 0.14, 0.18, 0.28)
            t.backgroundGlowOuter = color(0.025, 0.035, 0.05, 0)
            return t
        case .sunFadedRecLeague:
            var t = Theme.classic
            t.courtSurface = color(0.55, 0.53, 0.32)
            t.serviceBox = color(0.34, 0.50, 0.52)
            t.courtLine = color(0.96, 0.88, 0.69, 0.94)
            t.grainRow = color(0.18, 0.15, 0.08, 0.09)
            t.grainCol = color(0.18, 0.15, 0.08, 0.035)
            t.netMesh = color(0.15, 0.15, 0.12, 0.34)
            t.netStrand = color(0.20, 0.20, 0.17, 0.55)
            t.netTape = color(0.93, 0.83, 0.61, 0.92)
            t.netPost = color(0.20, 0.19, 0.15)
            t.ballOutline = color(0.20, 0.18, 0.11)
            t.ballBody = color(0.95, 0.70, 0.20)
            t.ballHighlight = color(1, 0.90, 0.58, 0.48)
            t.ballTrail = NSColor(calibratedRed: 0.87, green: 0.48, blue: 0.19, alpha: 1)
            t.backgroundBase = color(0.22, 0.17, 0.12)
            t.usesBackgroundImage = false
            t.backgroundGlowInner = color(0.43, 0.27, 0.14, 0.34)
            t.backgroundGlowOuter = color(0.22, 0.17, 0.12, 0)
            t.glassFill = color(0.94, 0.87, 0.70, 0.94)
            t.glassStroke = color(0.24, 0.20, 0.13, 0.24)
            t.cardFill = color(0.91, 0.82, 0.62, 0.96)
            t.textPrimary = NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.18, alpha: 1)
            t.accent = NSColor(calibratedRed: 0.73, green: 0.34, blue: 0.14, alpha: 1)
            t.teamA = NSColor(calibratedRed: 0.08, green: 0.39, blue: 0.43, alpha: 1)
            t.teamB = NSColor(calibratedRed: 0.72, green: 0.28, blue: 0.16, alpha: 1)
            return t
        case .saturdayBroadcast:
            var t = Theme.classic
            t.courtSurface = color(0.10, 0.39, 0.45)
            t.serviceBox = color(0.16, 0.28, 0.39)
            t.courtLine = color(0.98, 0.88, 0.64, 0.96)
            t.grainRow = color(0.96, 0.88, 0.64, 0.07)
            t.grainCol = color(0.96, 0.88, 0.64, 0.035)
            t.netMesh = color(0.02, 0.08, 0.12, 0.48)
            t.netStrand = color(0.80, 0.84, 0.78, 0.38)
            t.netTape = color(0.96, 0.56, 0.21, 0.96)
            t.netPost = color(0.04, 0.09, 0.13)
            t.ballOutline = color(0.05, 0.08, 0.10)
            t.ballBody = color(1, 0.72, 0.12)
            t.ballHighlight = color(1, 0.95, 0.66, 0.55)
            t.ballTrail = NSColor(calibratedRed: 1, green: 0.45, blue: 0.16, alpha: 1)
            t.backgroundBase = color(0.06, 0.12, 0.18)
            t.usesBackgroundImage = false
            t.backgroundGlowInner = color(0.13, 0.26, 0.34, 0.40)
            t.backgroundGlowOuter = color(0.06, 0.12, 0.18, 0)
            t.glassFill = color(0.03, 0.09, 0.14, 0.92)
            t.glassStroke = color(0.96, 0.62, 0.28, 0.42)
            t.cardFill = color(0.05, 0.15, 0.20, 0.94)
            t.textPrimary = NSColor(calibratedRed: 0.97, green: 0.91, blue: 0.75, alpha: 1)
            t.accent = NSColor(calibratedRed: 1, green: 0.57, blue: 0.22, alpha: 1)
            t.teamA = NSColor(calibratedRed: 0.23, green: 0.83, blue: 0.84, alpha: 1)
            t.teamB = NSColor(calibratedRed: 0.98, green: 0.38, blue: 0.30, alpha: 1)
            return t
        }
    }

    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }
}
