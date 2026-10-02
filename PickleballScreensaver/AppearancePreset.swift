import AppKit

enum AppearancePreset: String, CaseIterable {
    case classic, blacklight
    case livingCourt = "living-court"
    case inkPaper = "ink-and-paper"
    case rallyPainting = "rally-painting"

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .blacklight: return "Black Light"
        case .livingCourt: return "Living Court"
        case .inkPaper: return "Ink-and-paper"
        case .rallyPainting: return "Rally Painting"
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
        }
    }

    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }
}
