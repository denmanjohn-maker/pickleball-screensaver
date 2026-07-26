import ScreenSaver
import AppKit

// MARK: - Types

// Ambient wallpaper animation: a paddle or ball drawn over the background
// pattern in the same muted style, fading in, moving/spinning, fading out.
private enum GhostKind { case paddle, ball }

private struct Ghost {
    var kind: GhostKind
    var pos: CGPoint       // screen-space center
    var vel: CGVector      // pts/sec drift (ball rolls; paddle stays put)
    var angle: CGFloat     // current rotation, rad
    var spin: CGFloat      // rad/sec
    var size: CGFloat      // half-height (paddle) / radius (ball), pts
    var t: CGFloat = 0     // elapsed seconds
    var duration: CGFloat  // total lifetime

    // Trapezoid fade: in over the first 20% of life, out over the last 25%
    var alpha: CGFloat {
        let f = t / duration
        return max(0, min(1, min(f / 0.20, (1 - f) / 0.25)))
    }
}

// 3D vector in feet: l = along court length (0 at net), w = across width, y = up
private struct F3 {
    var l: CGFloat, w: CGFloat, y: CGFloat
    static func - (a: F3, b: F3) -> F3 { F3(l: a.l - b.l, w: a.w - b.w, y: a.y - b.y) }
    func dot(_ o: F3) -> CGFloat { l * o.l + w * o.w + y * o.y }
    func cross(_ o: F3) -> F3 {
        F3(l: w * o.y - y * o.w, w: y * o.l - l * o.y, y: l * o.w - w * o.l)
    }
    var length: CGFloat { sqrt(dot(self)) }
    var normalized: F3 { let m = length; return F3(l: l / m, w: w / m, y: y / m) }
}

// MARK: - Screensaver

class PickleballScreensaverView: ScreenSaverView {

    // The rally simulation — ball, players, shots, score. The view only reads
    // its state for drawing and forwards the harness tunables.
    private let engine = RallyEngine()

    // Harness tunables forwarded to the engine (scripts/preview sets these)
    var thirdDriveFrac:  CGFloat { get { engine.thirdDriveFrac }  set { engine.thirdDriveFrac = newValue } }
    var dinkCrossFrac:   CGFloat { get { engine.dinkCrossFrac }   set { engine.dinkCrossFrac = newValue } }
    var endingErrorFrac: CGFloat { get { engine.endingErrorFrac } set { engine.endingErrorFrac = newValue } }
    var leftyProb:       CGFloat { get { engine.leftyProb }       set { engine.leftyProb = newValue } }
    var speedupProbPerDink: CGFloat { get { engine.speedupProbPerDink } set { engine.speedupProbPerDink = newValue } }
    var lobProb:         CGFloat { get { engine.lobProb }         set { engine.lobProb = newValue } }
    var simStats: ((String) -> Void)? { get { engine.statsSink } set { engine.statsSink = newValue } }
    func reseed(_ seed: UInt64) { engine.reseed(seed) }
    func setFormat(_ f: GameFormat) { engine.setFormat(f) }

    // Camera — 10 ft behind the near-left court corner (on the center-corner diagonal,
    // extended), looking down 45° at the court center
    private let ftPerX = Court.ftPerX
    private let ftPerZ = Court.ftPerZ
    private let ftPerY = Court.ftPerY
    private let camPitch:    CGFloat = .pi / 4   // downward tilt from horizontal
    private let camBehindFt: CGFloat = 10.0      // horizontal distance beyond the corner

    // Real-world equipment sizes (drawn intentionally oversized for readability)
    private let paddleLenFt: CGFloat = (16.0 / 12.0) * 2.0   // regulation ~16 in, drawn 2x
    private let ballRFt: CGFloat = 0.121 * 3.5               // regulation 1.45 in radius, drawn 3.5x
    private var minBallPx: CGFloat { max(2.0, bounds.height * 0.004) }   // keep the ball visible at the far court

    // Every drawing color comes from the active theme (Classic / Black Light)
    private var theme: Theme = .classic

    func applyTheme(_ t: Theme) {
        theme = t
        bgScaledCache = nil       // wallpaper participation differs per theme
        tintedPaddleCache = nil   // sprite tint differs per theme
        setNeedsDisplay(bounds)
    }

    // Weather (fetched by WeatherProvider from the animation loop)
    private var weatherProvider: WeatherProvider?

    // Nearby tournaments (fetched by TournamentProvider from the animation loop)
    private var tournamentProvider: TournamentProvider?

    // Drill of the day (deterministic per calendar day)
    private var drillEnabled = true
    private var drillLevel = "all"

    // Shared formatters and accent — the overlays redraw every frame
    private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    private let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f }()
    private var accentYellow: NSColor { theme.accent }

    // Turntable spin — a full 360° yaw of the scene every minute on the minute
    private var courtYaw: CGFloat = 0     // current angle, rad
    private var spinT: CGFloat = -1       // -1 = idle, else 0..1 progress
    private let spinDuration: CGFloat = 6.0
    private var lastMinuteMark = -1       // -1 = unseeded (minute 0 is a real value in the harness)

    // Ambient wallpaper ghosts (paddle spins, ball rolls by at random times)
    private var ghosts: [Ghost] = []
    private var ghostSpawnTimer: CGFloat = .random(in: 3...8)
    private let maxGhosts = 2

    // Tournament card auto-scroll — cycles through pages of fetched entries,
    // fading out/in at each page boundary
    private var tournamentPageIndex = 0
    private var tournamentCycleTimer: CGFloat = 0
    private let tournamentPageInterval: CGFloat = 6.0   // seconds a page is shown
    private let tournamentFadeDuration: CGFloat = 0.6   // seconds faded in/out at each edge

    // Frame timing
    private var lastFrameTime: TimeInterval = 0

    // MARK: - Init

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        theme = Theme.named(ThemeSettings.load().theme)
        engine.setFormat(GameFormat(rawValue: MatchSettings.load().format) ?? .doubles)
        let drillSettings = DrillSettings.load()
        drillEnabled = drillSettings.drillEnabled
        drillLevel = drillSettings.drillLevel
        // Networking stays out of the tiny System Settings preview
        if !isPreview {
            let weatherSettings = WeatherSettings.load()
            if weatherSettings.enabled && weatherSettings.hasLocation {
                weatherProvider = WeatherProvider(settings: weatherSettings)
            }
            let tournamentSettings = TournamentSettings.load()
            if tournamentSettings.enabled && weatherSettings.hasLocation {
                tournamentProvider = TournamentProvider(settings: tournamentSettings, weatherSettings: weatherSettings)
            }
        }
    }

    // MARK: - Projection (look-at pinhole camera behind the near-left corner, AppKit Y-up)

    // Camera position and orthonormal basis (right, up, forward), all in feet
    private lazy var camPos: F3 = {
        let corner = F3(l: -ftPerZ / 2, w: -ftPerX, y: 0)
        let horiz = corner.length + camBehindFt          // horizontal distance to court center
        let dir = corner.normalized                      // center -> corner, on the ground
        return F3(l: dir.l * horiz, w: dir.w * horiz, y: horiz * tan(camPitch))
    }()
    private lazy var camF: F3 = (F3(l: 0, w: 0, y: 0) - camPos).normalized  // at court center
    private lazy var camR: F3 = camF.cross(F3(l: 0, w: 0, y: 1)).normalized
    private lazy var camU: F3 = camR.cross(camF)

    private func toFeet(_ wx: CGFloat, _ wz: CGFloat, _ wy: CGFloat) -> F3 {
        let l = (wz - 0.5) * ftPerZ, w = wx * ftPerX
        guard courtYaw != 0 else { return F3(l: l, w: w, y: wy * ftPerY) }
        // Turntable yaw about the court center spins the whole scene coherently
        let c = cos(courtYaw), s = sin(courtYaw)
        return F3(l: l * c - w * s, w: l * s + w * c, y: wy * ftPerY)
    }

    // Normalized image-plane coords (x, y) and camera depth for a world point
    private func unitProj(_ wx: CGFloat, _ wz: CGFloat, _ wy: CGFloat) -> (x: CGFloat, y: CGFloat, depth: CGFloat) {
        let p = toFeet(wx, wz, wy) - camPos
        let d = p.dot(camF)
        return (p.dot(camR) / d, p.dot(camU) / d, d)
    }

    // Focal length and principal point fitted so the court apron fills the frame,
    // leaving the bottom of the screen clear for the clock/calendar overlays.
    private var fitCache: (size: CGSize, focal: CGFloat, xOff: CGFloat, yOff: CGFloat)?
    private var fit: (focal: CGFloat, xOff: CGFloat, yOff: CGFloat) {
        if let c = fitCache, c.size == bounds.size { return (c.focal, c.xOff, c.yOff) }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        // Framing is always the unrotated view so a mid-spin resize can't bake
        // a rotated fit (the court would zoom/jitter for the rest of the spin)
        let yaw = courtYaw; courtYaw = 0
        defer { courtYaw = yaw }
        for (wx, wz) in [(-1.15, -0.05), (1.15, -0.05), (1.15, 1.05), (-1.15, 1.05)] {
            let u = unitProj(CGFloat(wx), CGFloat(wz), 0)
            minX = min(minX, u.x); maxX = max(maxX, u.x)
            minY = min(minY, u.y); maxY = max(maxY, u.y)
        }
        let W = bounds.width, H = bounds.height
        let focal = min(W * 0.58 / (maxX - minX), H * 0.92 / (maxY - minY))
        let xOff = W * 0.66 - focal * (minX + maxX) / 2   // court on the right; overlays own the left column
        let yOff = H * 0.51 - focal * (minY + maxY) / 2
        fitCache = (bounds.size, focal, xOff, yOff)
        return (focal, xOff, yOff)
    }

    // Pixels per foot for sprite sizing at a given court position (at floor level)
    private func ppf(atWx wx: CGFloat, atWz wz: CGFloat) -> CGFloat {
        fit.focal / unitProj(wx, wz, 0).depth
    }

    private func proj(_ wx: CGFloat, _ wz: CGFloat, _ wy: CGFloat) -> CGPoint {
        let u = unitProj(wx, wz, wy)
        let f = fit
        return CGPoint(x: f.xOff + f.focal * u.x, y: f.yOff + f.focal * u.y)
    }

    private func proj(_ v: Vec3) -> CGPoint { proj(v.x, v.z, v.y) }

    // MARK: - Animation loop

    override func animateOneFrame() {
        let now = Date().timeIntervalSinceReferenceDate
        let dt: CGFloat = lastFrameTime == 0 ? 1/60.0 : min(CGFloat(now - lastFrameTime), 0.05)
        lastFrameTime = now
        step(now: now, dt: dt)
    }

    // One frame of simulation, split from animateOneFrame so the offscreen
    // preview harness (scripts/preview) can drive a synthetic clock
    func step(now: TimeInterval, dt: CGFloat) {
        updateGhosts(dt: dt)

        // Turntable spin: kick off at every wall-clock minute boundary
        let minuteMark = Int(now / 60)
        if lastMinuteMark == -1 { lastMinuteMark = minuteMark }   // no spin at launch
        if minuteMark != lastMinuteMark { lastMinuteMark = minuteMark; spinT = 0 }
        if spinT >= 0 {
            spinT += dt / spinDuration
            if spinT >= 1 { spinT = -1; courtYaw = 0 }
            else { courtYaw = 2 * .pi * smoothstep(spinT) }
        }

        // Overlay content keeps updating even during the fault pause
        weatherProvider?.updateIfNeeded()
        tournamentProvider?.updateIfNeeded()

        tournamentCycleTimer += dt
        if tournamentCycleTimer >= tournamentPageInterval {
            tournamentCycleTimer = 0
            tournamentPageIndex += 1
        }

        engine.step(dt: dt)
        setNeedsDisplay(bounds)
    }

    // MARK: - Ambient wallpaper ghosts

    private func updateGhosts(dt: CGFloat) {
        for i in ghosts.indices {
            ghosts[i].t += dt
            ghosts[i].angle += ghosts[i].spin * dt
            ghosts[i].pos.x += ghosts[i].vel.dx * dt
            ghosts[i].pos.y += ghosts[i].vel.dy * dt
        }
        ghosts.removeAll { $0.t >= $0.duration }

        ghostSpawnTimer -= dt
        if ghostSpawnTimer <= 0 {
            ghostSpawnTimer = .random(in: 6...15)
            if ghosts.count < maxGhosts, let g = makeGhost() { ghosts.append(g) }
        }
    }

    // Pick a spot for a new ghost that stays clear of the overlay rail and the
    // court apron for its whole drift; a few misses just skips this cycle.
    private func makeGhost() -> Ghost? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let kind: GhostKind = Bool.random() ? .paddle : .ball
        let size = bounds.height * (kind == .paddle ? CGFloat.random(in: 0.05...0.09)
                                                    : CGFloat.random(in: 0.02...0.035))
        let duration = CGFloat.random(in: 5...9)
        var vel = CGVector.zero
        var spin = CGFloat.random(in: 0.3...0.7) * (Bool.random() ? 1 : -1)
        if kind == .ball {
            let dx = bounds.width * CGFloat.random(in: 0.008...0.016) * (Bool.random() ? 1 : -1)
            vel = CGVector(dx: dx, dy: 0)
            spin = -dx / size   // rotation matches translation so the ball reads as rolling
        }

        let railRect = CGRect(x: 0, y: 0, width: bounds.width * 0.30, height: bounds.height)
        // Court apron trapezoid (convex). The wallpaper triangles beside it
        // are fair game, so test the quad itself, not its bounding rect.
        let quad = [(-1.15, -0.05), (1.15, -0.05), (1.15, 1.05), (-1.15, 1.05)]
            .map { proj(CGFloat($0.0), CGFloat($0.1), 0) }
        func insideApron(_ p: CGPoint) -> Bool {
            var sign: CGFloat = 0
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                if cross == 0 { continue }
                if sign == 0 { sign = cross } else if sign * cross < 0 { return false }
            }
            return true
        }
        // A candidate is good if the ghost's footprint (start and end of its
        // drift, expanded by its size) misses the rail, the apron, and the edges
        func clear(_ c: CGPoint) -> Bool {
            for pt in [c, CGPoint(x: c.x - size, y: c.y - size), CGPoint(x: c.x - size, y: c.y + size),
                       CGPoint(x: c.x + size, y: c.y - size), CGPoint(x: c.x + size, y: c.y + size)] {
                if insideApron(pt) || railRect.contains(pt) { return false }
            }
            return c.x > size && c.x < bounds.width - size
                && c.y > size && c.y < bounds.height - size
        }
        // Sample the drift path at size-sized steps so the swept band can't
        // clip an apron corner between a clear start and a clear end
        let drift = hypot(vel.dx, vel.dy) * duration
        let steps = max(1, Int(ceil(drift / size)))
        for _ in 0..<16 {
            let p = CGPoint(x: .random(in: 0...bounds.width), y: .random(in: 0...bounds.height))
            let path = (0...steps).map { i -> CGPoint in
                let t = duration * CGFloat(i) / CGFloat(steps)
                return CGPoint(x: p.x + vel.dx * t, y: p.y + vel.dy * t)
            }
            if path.allSatisfy(clear) {
                return Ghost(kind: kind, pos: p, vel: vel, angle: .random(in: 0...(2 * .pi)),
                             spin: spin, size: size, duration: duration)
            }
        }
        return nil
    }

    // MARK: - Draw

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(ctx: ctx, rect: rect)
        drawGhosts(ctx: ctx)
        drawCourt(ctx: ctx)
        drawBallShadow(ctx: ctx)
        drawTrail(ctx: ctx)

        // Painter's algorithm: sprites beyond the net plane (wz > 0.5) render first,
        // then the net, then near-side sprites; each group sorted farthest-first
        // (index breaks depth ties so partners never flicker in sort order).
        let ball = engine.ball
        var sprites: [(wz: CGFloat, depth: CGFloat, order: Int, draw: () -> Void)] = [
            (ball.z, unitProj(ball.x, ball.z, ball.y).depth, -1,
             { self.drawBall(ctx: ctx) }),
        ]
        for p in engine.players {
            sprites.append((p.z, unitProj(engine.paddleWx(p), p.z, 0.1).depth, sprites.count,
                            { self.drawPaddle(ctx: ctx, state: p, wz: p.z, side: p.facing) }))
        }
        let byDepth: ((wz: CGFloat, depth: CGFloat, order: Int, draw: () -> Void),
                      (wz: CGFloat, depth: CGFloat, order: Int, draw: () -> Void)) -> Bool = {
            $0.depth != $1.depth ? $0.depth > $1.depth : $0.order < $1.order
        }
        for s in sprites.filter({ $0.wz > 0.5 }).sorted(by: byDepth) { s.draw() }
        drawNet(ctx: ctx)
        for s in sprites.filter({ $0.wz <= 0.5 }).sorted(by: byDepth) { s.draw() }

        // Widget-style left rail: weather / tournaments cards flowing down from
        // the top margin, with drill-of-the-day pinned to the bottom margin.
        let rail = railMetrics(rect)
        var railY = rect.height * 0.95
        let afterWeather = drawWeather(ctx: ctx, rect: rect, rail: rail, top: railY)
        // Weather can no-op (disabled, or no snapshot yet) — only spend a gap if it actually drew a card
        if afterWeather != railY { railY = afterWeather - rail.gap }
        _ = drawTournaments(ctx: ctx, rect: rect, rail: rail, top: railY)
        drawDrill(ctx: ctx, rect: rect, rail: rail, bottom: rect.height * 0.05)
        drawScoreboard(ctx: ctx, rect: rect)
        drawCourtClock(ctx: ctx, rect: rect)
    }

    // MARK: - Background

    // Patterned wallpaper, loaded like the paddle sprite so the offscreen
    // preview harness finds it too
    private static let backgroundImage: CGImage? = {
        let candidates: [URL?] = [
            Bundle(for: PickleballScreensaverView.self).url(forResource: "background", withExtension: "png"),
            Bundle.main.url(forResource: "background", withExtension: "png"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("background.png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("PickleballScreensaver/Resources/background.png"),
        ]
        for c in candidates {
            if let c, let img = NSImage(contentsOf: c),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        }
        return nil
    }()

    // The wallpaper is aspect-fill rescaled once per view size, then blitted
    // every frame (rescaling the full-resolution source at 60 fps would be slow)
    private var bgScaledCache: (size: CGSize, image: CGImage)?

    private func drawBackground(ctx: CGContext, rect: NSRect) {
        ctx.setFillColor(theme.backgroundBase)
        ctx.fill(rect)
        if theme.usesBackgroundImage, let img = scaledBackground() {
            ctx.draw(img, in: bounds)
            return
        }
        // Radial wash: the fallback when the wallpaper asset is missing, and
        // the intended look for themes that skip the wallpaper entirely
        let colors = [theme.backgroundGlowInner, theme.backgroundGlowOuter] as CFArray
        let locs: [CGFloat] = [0, 1]
        if let sp = CGColorSpace(name: CGColorSpace.sRGB),
           let gr = CGGradient(colorsSpace: sp, colors: colors, locations: locs) {
            ctx.drawRadialGradient(gr,
                startCenter: CGPoint(x: rect.midX, y: rect.height * 0.60), startRadius: 0,
                endCenter:   CGPoint(x: rect.midX, y: rect.height * 0.60),
                endRadius: max(rect.width, rect.height) * 0.7, options: [])
        }
    }

    private func scaledBackground() -> CGImage? {
        if let c = bgScaledCache, c.size == bounds.size { return c.image }
        guard let src = Self.backgroundImage, bounds.width > 0, bounds.height > 0 else { return nil }
        let pxScale = window?.backingScaleFactor ?? 2
        let pxW = Int(bounds.width * pxScale), pxH = Int(bounds.height * pxScale)
        guard let bctx = CGContext(data: nil, width: pxW, height: pxH,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Aspect-fill: cover the view, cropping the overflowing dimension
        let iw = CGFloat(src.width), ih = CGFloat(src.height)
        let scale = max(CGFloat(pxW) / iw, CGFloat(pxH) / ih)
        let w = iw * scale, h = ih * scale
        bctx.interpolationQuality = .high
        bctx.draw(src, in: CGRect(x: (CGFloat(pxW) - w) / 2, y: (CGFloat(pxH) - h) / 2,
                                  width: w, height: h))
        guard let img = bctx.makeImage() else { return nil }
        bgScaledCache = (bounds.size, img)
        return img
    }

    // MARK: - Ghost drawing (over the wallpaper, under everything else)

    private var ghostFill: CGColor { theme.ghostFill }

    private func drawGhosts(ctx: CGContext) {
        for g in ghosts where g.alpha > 0 {
            ctx.saveGState()
            ctx.setAlpha(g.alpha * 0.5)
            // The transparency layer isolates the .clear hole punches so they
            // erase within the ghost only, not through the wallpaper below
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.translateBy(x: g.pos.x, y: g.pos.y)
            ctx.rotate(by: g.angle)
            switch g.kind {
            case .paddle: drawGhostPaddle(ctx: ctx, halfH: g.size)
            case .ball:   drawGhostBall(ctx: ctx, r: g.size)
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    // Silhouette matching the real paddle's proportions, centered on the origin
    private func drawGhostPaddle(ctx: CGContext, halfH: CGFloat) {
        let hPx = halfH * 2
        let wPx = hPx * Self.paddleAspect
        let handleW = 0.27 * wPx
        ctx.setFillColor(ghostFill)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -handleW / 2, y: -halfH,
                                               width: handleW, height: Self.paddlePivotFrac * hPx),
                           cornerWidth: handleW * 0.3, cornerHeight: handleW * 0.3, transform: nil))
        ctx.addPath(CGPath(roundedRect: CGRect(x: -wPx / 2, y: -halfH + Self.paddlePivotFrac * hPx,
                                               width: wPx, height: (1 - Self.paddlePivotFrac) * hPx),
                           cornerWidth: wPx * 0.15, cornerHeight: wPx * 0.15, transform: nil))
        ctx.fillPath()
    }

    // Muted disc with the pickleball hole pattern punched through to the wallpaper
    private func drawGhostBall(ctx: CGContext, r: CGFloat) {
        ctx.setFillColor(ghostFill)
        ctx.fillEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        ctx.setBlendMode(.clear)
        let hr = max(0.6, r * 0.15)
        for i in 0..<5 {
            let a = CGFloat(i) / 5 * .pi * 2
            ctx.fillEllipse(in: CGRect(x: cos(a) * r * 0.40 - hr, y: sin(a) * r * 0.40 - hr,
                                       width: hr * 2, height: hr * 2))
        }
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * .pi * 2 + .pi / 6
            ctx.fillEllipse(in: CGRect(x: cos(a) * r * 0.72 - hr, y: sin(a) * r * 0.72 - hr,
                                       width: hr * 2, height: hr * 2))
        }
        ctx.setBlendMode(.normal)
    }

    // MARK: - Court

    private func drawCourt(ctx: CGContext) {
        // Court surface floats on the wallpaper; a soft drop shadow lifts it
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: bounds.height * 0.008, height: -bounds.height * 0.022),
                      blur: bounds.height * 0.05,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.85))
        fillQuad(ctx,
                 proj(-1, 0, 0), proj(1, 0, 0),
                 proj(1, 1, 0),  proj(-1, 1, 0),
                 color: theme.courtSurface)
        ctx.restoreGState()

        // Service boxes (kitchen between kitchenNearZ..kitchenFarZ keeps the surface color)
        let kitchenNearZ = Court.kitchenNearZ, kitchenFarZ = Court.kitchenFarZ
        let box = theme.serviceBox
        // Near half: baseline (0) → near kitchen line
        fillQuad(ctx, proj(-1, 0, 0), proj(0, 0, 0), proj(0, kitchenNearZ, 0), proj(-1, kitchenNearZ, 0), color: box)
        fillQuad(ctx, proj(0, 0, 0),  proj(1, 0, 0), proj(1, kitchenNearZ, 0), proj(0, kitchenNearZ, 0),  color: box)
        // Far half: far kitchen line → far baseline (1)
        fillQuad(ctx, proj(-1, kitchenFarZ, 0), proj(0, kitchenFarZ, 0), proj(0, 1, 0), proj(-1, 1, 0), color: box)
        fillQuad(ctx, proj(0, kitchenFarZ, 0),  proj(1, kitchenFarZ, 0), proj(1, 1, 0), proj(0, 1, 0),  color: box)

        // Court surface texture — perspective-correct horizontal + vertical grain lines
        ctx.saveGState()
        let courtPath = CGMutablePath()
        courtPath.move(to: proj(-1, 0, 0)); courtPath.addLine(to: proj(1, 0, 0))
        courtPath.addLine(to: proj(1, 1, 0)); courtPath.addLine(to: proj(-1, 1, 0))
        courtPath.closeSubpath()
        ctx.addPath(courtPath); ctx.clip()

        // Horizontal rows (follow court depth perspective)
        ctx.setStrokeColor(theme.grainRow)
        ctx.setLineWidth(0.7)
        var tz: CGFloat = -0.02
        while tz <= 1.1 {
            line(ctx, from: proj(-1.3, tz, 0), to: proj(1.3, tz, 0))
            tz += 0.028
        }

        // Vertical columns (fixed-width in world-x, narrow toward the far end)
        ctx.setStrokeColor(theme.grainCol)
        ctx.setLineWidth(0.5)
        var tx: CGFloat = -1.15
        while tx <= 1.15 {
            line(ctx, from: proj(tx, -0.05, 0), to: proj(tx, 1.05, 0))
            tx += 0.07
        }

        ctx.restoreGState()

        // Court lines — under black light they glow, one blur pass for the
        // whole group so the cost stays flat
        if theme.glowStrength > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: bounds.height * 0.012 * theme.glowStrength,
                          color: theme.courtLine)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        ctx.setStrokeColor(theme.courtLine)
        ctx.setLineWidth(2.5)
        strokeQuad(ctx, proj(-1, 0, 0), proj(1, 0, 0), proj(1, 1, 0), proj(-1, 1, 0))   // outer boundary

        // Kitchen lines (across width)
        line(ctx, from: proj(-1, kitchenNearZ, 0), to: proj(1, kitchenNearZ, 0))
        line(ctx, from: proj(-1, kitchenFarZ, 0),  to: proj(1, kitchenFarZ, 0))

        // Center service lines (service zones only)
        ctx.setLineWidth(2.0)
        line(ctx, from: proj(0, 0, 0),            to: proj(0, kitchenNearZ, 0))
        line(ctx, from: proj(0, kitchenFarZ, 0),  to: proj(0, 1, 0))
        if theme.glowStrength > 0 {
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    // MARK: - Net (vertical band at z = 0.5, seen at an angle from the corner camera)

    private func netTopY(_ wx: CGFloat) -> CGFloat { Court.netTopY(wx) }

    private func drawNet(ctx: CGContext) {
        let sagSteps = 16
        let topPts: [CGPoint] = (0...sagSteps).map { i in
            let wx = -1 + 2 * CGFloat(i) / CGFloat(sagSteps)
            return proj(wx, 0.5, netTopY(wx))
        }
        let bl = proj(-1, 0.5, 0); let br = proj(1, 0.5, 0)

        // Mesh body (top edge follows the sag)
        ctx.setFillColor(theme.netMesh)
        ctx.beginPath()
        ctx.move(to: bl)
        ctx.addLine(to: br)
        for p in topPts.reversed() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.fillPath()

        // Vertical strands
        ctx.setStrokeColor(theme.netStrand)
        ctx.setLineWidth(0.8)
        let vSteps = 55
        for i in 0...vSteps {
            let wx = -1 + 2 * CGFloat(i) / CGFloat(vSteps)
            line(ctx, from: proj(wx, 0.5, 0), to: proj(wx, 0.5, netTopY(wx)))
        }
        // Horizontal strands (each follows the sag at its height fraction)
        let hSteps = 10
        for i in 1..<hSteps {
            let f = CGFloat(i) / CGFloat(hSteps)
            ctx.beginPath()
            for j in 0...sagSteps {
                let wx = -1 + 2 * CGFloat(j) / CGFloat(sagSteps)
                let p = proj(wx, 0.5, f * netTopY(wx))
                j == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
            }
            ctx.strokePath()
        }

        // Top tape (glows under black light)
        if theme.glowStrength > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: bounds.height * 0.012 * theme.glowStrength,
                          color: theme.netTape)
        }
        ctx.setStrokeColor(theme.netTape)
        ctx.setLineWidth(5.0)
        ctx.beginPath()
        for (i, p) in topPts.enumerated() {
            i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
        }
        ctx.strokePath()
        if theme.glowStrength > 0 { ctx.restoreGState() }

        // Posts: center + sides
        drawPost(ctx, atX: 0)
        drawPost(ctx, atX: -1)
        drawPost(ctx, atX: 1)
    }

    private func drawPost(_ ctx: CGContext, atX wx: CGFloat) {
        let base = proj(wx, 0.5, 0)
        let top  = proj(wx, 0.5, netTopY(wx))
        let w: CGFloat = 0.25 * ppf(atWx: wx, atWz: 0.5)
        ctx.setStrokeColor(theme.netPost)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        line(ctx, from: base, to: top)
        ctx.setLineCap(.butt)
    }

    // MARK: - Ball shadow

    private func drawBallShadow(ctx: CGContext) {
        let ball = engine.ball
        let sp = proj(ball.x, ball.z, 0)
        let fade = max(0, 1 - ball.y / 0.6)
        let s = ppf(atWx: ball.x, atWz: ball.z)
        let rw: CGFloat = max(minBallPx, ballRFt * s) * 1.1 * fade
        let rh: CGFloat = rw * 0.30
        // Soft penumbra
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.12 * fade))
        ctx.fillEllipse(in: CGRect(x: sp.x - rw * 1.5, y: sp.y - rh * 1.5, width: rw * 3, height: rh * 3))
        // Hard core shadow
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.45 * fade))
        ctx.fillEllipse(in: CGRect(x: sp.x - rw, y: sp.y - rh, width: rw * 2, height: rh * 2))
    }

    // MARK: - Trail

    private func drawTrail(ctx: CGContext) {
        let trailPoints = engine.trailPoints
        let count = trailPoints.count
        for (i, t) in trailPoints.enumerated() {
            let frac = CGFloat(i) / CGFloat(count)
            let r = max(minBallPx, ballRFt * ppf(atWx: t.x, atWz: t.z)) * frac
            let p = proj(t)
            ctx.setFillColor(theme.ballTrail.withAlphaComponent(frac * 0.28).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Ball (yellow holed pickleball)

    private func drawBall(ctx: CGContext) {
        let ball = engine.ball
        let p = proj(ball)
        let s = ppf(atWx: ball.x, atWz: ball.z)
        let r: CGFloat = max(minBallPx, ballRFt * s)
        let rim: CGFloat = max(0.6, r * 0.09)

        // Under black light the ball itself glows
        if theme.glowStrength > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: r * 1.4 * theme.glowStrength,
                          color: theme.ballBody)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        // Dark outline ring
        ctx.setFillColor(theme.ballOutline)
        ctx.fillEllipse(in: CGRect(x: p.x - r - rim, y: p.y - r - rim,
                                   width: (r + rim) * 2, height: (r + rim) * 2))

        // Ball body
        ctx.setFillColor(theme.ballBody)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))

        // Transparent holes — punch through with .clear so the court shows through
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: engine.ballSpin)
        ctx.setBlendMode(.clear)
        let hr: CGFloat = max(0.6, r * 0.15)
        // Inner ring: 5 holes evenly spaced
        for i in 0..<5 {
            let a = CGFloat(i) / 5 * .pi * 2
            let hx = cos(a) * r * 0.40
            let hy = sin(a) * r * 0.40
            ctx.fillEllipse(in: CGRect(x: hx - hr, y: hy - hr, width: hr * 2, height: hr * 2))
        }
        // Outer ring: 6 holes offset by π/6 for asymmetry (makes spin obvious)
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * .pi * 2 + .pi / 6
            let hx = cos(a) * r * 0.72
            let hy = sin(a) * r * 0.72
            ctx.fillEllipse(in: CGRect(x: hx - hr, y: hy - hr, width: hr * 2, height: hr * 2))
        }
        ctx.restoreGState()

        // Fixed highlight (light direction doesn't rotate with ball)
        ctx.setFillColor(theme.ballHighlight)
        ctx.fillEllipse(in: CGRect(x: p.x - r * 0.38, y: p.y + r * 0.15,
                                   width: r * 0.76, height: r * 0.50))

        if theme.glowStrength > 0 {
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    // MARK: - Paddle (PNG sprite at regulation size)

    // Sprite geometry measured from the asset's alpha profile: fractions of the
    // image height, from the bottom, for the grip junction (rotation pivot) and
    // the face center (ball contact point).
    private static let paddleAspect:         CGFloat = 0.514   // width / height
    private static let paddlePivotFrac:      CGFloat = 0.38
    private static let paddleFaceCenterFrac: CGFloat = 0.695

    // Loaded once; the extra paths let the offscreen preview harness (which
    // compiles this view outside the saver bundle) find the asset too.
    private static let paddleImage: CGImage? = {
        let candidates: [URL?] = [
            Bundle(for: PickleballScreensaverView.self).url(forResource: "paddle", withExtension: "png"),
            Bundle.main.url(forResource: "paddle", withExtension: "png"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("paddle.png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("PickleballScreensaver/Resources/paddle.png"),
        ]
        for c in candidates {
            if let c, let img = NSImage(contentsOf: c),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        }
        return nil
    }()

    // Theme-tinted paddle sprite, recolored once per theme change (never per
    // frame — four paddles draw at 60 fps)
    private var tintedPaddleCache: CGImage?

    private func paddleSprite() -> CGImage? {
        guard let base = Self.paddleImage else { return nil }
        guard let tint = theme.paddleTint else { return base }
        if let cached = tintedPaddleCache { return cached }
        guard let bctx = CGContext(data: nil, width: base.width, height: base.height,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }
        let rect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        bctx.draw(base, in: rect)
        bctx.setBlendMode(.sourceAtop)   // keep the sprite's texture, wash with neon
        bctx.setFillColor(tint.cgColor)
        bctx.fill(rect)
        guard let img = bctx.makeImage() else { return base }
        tintedPaddleCache = img
        return img
    }

    private func drawPaddle(ctx: CGContext, state: PlayerState, wz: CGFloat, side: CGFloat) {
        let wx = engine.paddleWx(state)
        let hPx = paddleLenFt * ppf(atWx: wx, atWz: wz)
        let wPx = hPx * Self.paddleAspect

        // The face center rides the stroke path (back-and-down, low-to-high,
        // finish, recover); the grip pivot hangs off it along the paddle axis.
        // At contact the face is horizontal and the face center lands exactly
        // on the ball; at every other pose the same offset keeps the paddle
        // rotating rigidly about the grip.
        let face = proj(wx, wz + state.faceDZ, state.faceY)
        let faceCenterPx = (Self.paddleFaceCenterFrac - Self.paddlePivotFrac) * hPx
        // The on-screen rotation comes from a screen-space basis at the face
        // center's true court position: N = this player's projected toward-net
        // axis, U = projected world-up; the paddle axis is N tilted toward U by
        // the swing angle (0 = face at the net, readyAngle = held upright).
        // The corner camera projects the far player's N down-screen, which
        // would put the head under the ball at contact (a slice/dig pose), so
        // N is lifted to the local screen horizontal by removing its downward
        // component: the head then always RISES into the ball — hanging low in
        // the windup, blade just above horizontal at the strike, high finish.
        // Subtracting the component once is a projection; the earlier 2x
        // (reflect-N-upright) was orientation-reversing and made the far
        // handle appear to strike, and 0x (raw basis) made the head scoop
        // under the ball. min(0, ·) is the identity for the near player and
        // at the crossover, so the pose stays continuous while yaw-spinning.
        let kFt: CGFloat = 0.5   // probe length in feet
        let wzF = wz + state.faceDZ
        let upTip  = proj(wx, wzF, state.faceY + kFt / ftPerY)
        let netTip = proj(wx, wzF + side * kFt / ftPerZ, state.faceY)
        let uLen = max(1e-9, hypot(upTip.x - face.x, upTip.y - face.y))
        let ux = (upTip.x - face.x) / uLen, uy = (upTip.y - face.y) / uLen
        var nx = netTip.x - face.x, ny = netTip.y - face.y
        let nLen = hypot(nx, ny)
        let downAmt = min(0, nx * ux + ny * uy)
        nx -= downAmt * ux
        ny -= downAmt * uy
        let ax = cos(state.swingAngle) * nx + sin(state.swingAngle) * (upTip.x - face.x)
        let ay = cos(state.swingAngle) * ny + sin(state.swingAngle) * (upTip.y - face.y)
        let phi = atan2(ay, ax) - .pi / 2
        // Face-pinned pivot: the face center rides the stroke path and the grip
        // hangs off it. Reads correctly up close, where the path's toward-net
        // sweep carries the whole paddle up-screen through contact.
        let facePivot = CGPoint(x: face.x + faceCenterPx * sin(phi),
                                y: face.y - faceCenterPx * cos(phi))
        // Grip-pinned pivot: the hand is anchored near the strike point (riding
        // the height sweep plus a fraction of the depth lunge) and the HEAD
        // whips around it — hanging low in the windup, through the ball, up to
        // the finish. Needed on the far side, where the toward-net sweep runs
        // down-screen: face-pinning there leaves the head static and the handle
        // doing the visible swinging.
        let nClLen = max(1e-9, hypot(nx, ny))
        let anchor = proj(wx, wz, state.faceY)
        let gripFollow: CGFloat = 0.35   // how much of the depth lunge the hand follows
        let gripPivot = CGPoint(
            x: anchor.x + gripFollow * (face.x - anchor.x) - faceCenterPx * nx / nClLen,
            y: anchor.y + gripFollow * (face.y - anchor.y) - faceCenterPx * ny / nClLen)
        // Blend by how far the raw N dips below the local horizontal: 0 for the
        // near player (bit-identical face-pinning), ~0.9 for the far player.
        // Both pivots coincide exactly at the contact pose (faceDZ = 0, axis =
        // clamped N), so the ball always lands on the face center, and the
        // blend stays continuous through the turntable spin.
        let w = nLen > 1e-9 ? min(1, -downAmt / nLen) : 0
        let pivot = CGPoint(x: facePivot.x + w * (gripPivot.x - facePivot.x),
                            y: facePivot.y + w * (gripPivot.y - facePivot.y))

        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: phi)
        // The far paddle is seen from its other side, and a backhand shows the
        // paddle's other face; either flips the sprite artwork about its long
        // axis. A backhand is contact away from the forehand side, which for a
        // lefty is the mirror of a righty's.
        let backhand = state.swingPhase && state.stance != side * state.hand
        if (side < 0) != backhand {
            ctx.scaleBy(x: -1, y: 1)
        }

        // Sprite is authored upright: handle hangs DOWN from the grip pivot,
        // face extends UP; the image rect places the pivot at the grip junction
        let spriteRect = CGRect(x: -wPx / 2, y: -Self.paddlePivotFrac * hPx,
                                width: wPx, height: hPx)
        ctx.setShadow(offset: CGSize(width: 0.05 * hPx, height: -0.06 * hPx),
                      blur: 0.10 * hPx,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        if let img = paddleSprite() {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: spriteRect)
        } else {
            // Fallback silhouette so a packaging mistake never hides the paddles
            let handleW = 0.27 * wPx
            ctx.setFillColor(CGColor(red: 0.17, green: 0.20, blue: 0.21, alpha: 1))
            ctx.addPath(CGPath(roundedRect: CGRect(x: -handleW / 2, y: spriteRect.minY,
                                                   width: handleW, height: Self.paddlePivotFrac * hPx),
                               cornerWidth: handleW * 0.3, cornerHeight: handleW * 0.3, transform: nil))
            ctx.addPath(CGPath(roundedRect: CGRect(x: -wPx / 2, y: 0,
                                                   width: wPx, height: (1 - Self.paddlePivotFrac) * hPx),
                               cornerWidth: wPx * 0.15, cornerHeight: wPx * 0.15, transform: nil))
            ctx.fillPath()
        }

        ctx.restoreGState()
    }

    // MARK: - Overlay style (widget-style left rail)

    private struct Rail { var x, width, pad, corner, gap: CGFloat }

    private func railMetrics(_ rect: NSRect) -> Rail {
        Rail(x: rect.height * 0.05,
             width: min(rect.width * 0.35, rect.height * 0.82),
             pad: rect.height * 0.018,
             corner: rect.height * 0.022,
             gap: rect.height * 0.02)
    }

    // SF Rounded variant of the system font; falls back to plain SF
    private func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight, monoDigits: Bool = false) -> NSFont {
        let base = monoDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
        guard let desc = base.fontDescriptor.withDesign(.rounded),
              let f = NSFont(descriptor: desc, size: size) else { return base }
        return f
    }

    // Alpha tiers: 0.95 primary, 0.60 secondary, 0.40 tertiary
    private func textAttrs(_ size: CGFloat, _ weight: NSFont.Weight, alpha: CGFloat,
                           color: NSColor? = nil, monoDigits: Bool = false,
                           kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(size, weight, monoDigits: monoDigits),
            .foregroundColor: (color ?? theme.textPrimary).withAlphaComponent(alpha),
        ]
        if kern != 0 { attrs[.kern] = kern }
        return attrs
    }

    // Small ALL-CAPS section header with wide tracking
    private func kickerAttrs(_ size: CGFloat, color: NSColor? = nil,
                             alpha: CGFloat = 0.40) -> [NSAttributedString.Key: Any] {
        textAttrs(size, .semibold, alpha: alpha, color: color, kern: size * 0.14)
    }

    // Translucent rounded "glass" panel background, shared by the rail cards,
    // the scoreboard pill, and the floating court clock
    private func drawGlassPanel(_ ctx: CGContext, rect: CGRect, corner: CGFloat, shadowBlur: CGFloat,
                                fillColor: CGColor? = nil) {
        let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -shadowBlur * 0.3), blur: shadowBlur,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
        ctx.setFillColor(fillColor ?? theme.glassFill)
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(theme.glassStroke)
        ctx.setLineWidth(1)
        ctx.addPath(path); ctx.strokePath()
    }

    // Translucent rounded "glass" panel; returns the padded content rect
    @discardableResult
    private func drawCard(_ ctx: CGContext, _ rail: Rail, top: CGFloat, height: CGFloat) -> CGRect {
        let rect = CGRect(x: rail.x, y: top - height, width: rail.width, height: height)
        drawGlassPanel(ctx, rect: rect, corner: rail.corner, shadowBlur: rail.pad, fillColor: theme.cardFill)
        return rect.insetBy(dx: rail.pad, dy: rail.pad)
    }

    // Tinted SF Symbol anchored at its bottom-left corner; returns the drawn rect
    @discardableResult
    private func drawSymbol(_ name: String, at origin: CGPoint, size: CGFloat,
                            alpha: CGFloat, color: NSColor? = nil) -> CGRect {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return CGRect(origin: origin, size: .zero)
        }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [(color ?? theme.textPrimary).withAlphaComponent(alpha)]))
        let img = base.withSymbolConfiguration(config) ?? base
        let scale = img.size.height > 0 ? size / img.size.height : 1
        let rect = CGRect(x: origin.x, y: origin.y, width: img.size.width * scale, height: size)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        return rect
    }

    // MARK: - Clock (bottom-right corner, no card)

    private func drawCourtClock(ctx: CGContext, rect: NSRect) {
        let now = Date()
        let tSize = rect.height * 0.09
        let dSize = rect.height * 0.030
        let margin = rect.height * 0.05

        let timeAS = NSAttributedString(string: timeFmt.string(from: now),
                                        attributes: textAttrs(tSize, .bold, alpha: 0.95, monoDigits: true))
        let dateAS = NSAttributedString(string: dayFmt.string(from: now),
                                        attributes: textAttrs(dSize, .semibold, alpha: 0.60))
        let timeSz = timeAS.size(), dateSz = dateAS.size()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -tSize * 0.03), blur: tSize * 0.12,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.60))
        let dateY = margin
        dateAS.draw(at: NSPoint(x: rect.width - margin - dateSz.width, y: dateY))
        let timeY = dateY + dSize * 1.5
        timeAS.draw(at: NSPoint(x: rect.width - margin - timeSz.width, y: timeY))
        ctx.restoreGState()
    }

    // MARK: - Weather card

    private func drawWeather(ctx: CGContext, rect: NSRect, rail: Rail, top: CGFloat) -> CGFloat {
        guard let snap = weatherProvider?.snapshot else { return top }
        let kSize = rect.height * 0.016
        let kickerH = kSize * 1.6
        let bigSize = rect.height * 0.052
        let rowSize = rect.height * 0.020
        let rowH = rowSize * 1.6
        let badgeH = rect.height * 0.032

        let rowCount: CGFloat = snap.tomorrowMax != nil ? 4 : 3
        let contentH = kickerH + bigSize * 1.35 + rowH * rowCount + rail.pad * 0.8 + badgeH
        let content = drawCard(ctx, rail, top: top, height: contentH + rail.pad * 2)
        let secondary = textAttrs(rowSize, .regular, alpha: 0.60)

        var y = content.maxY - kickerH
        let place = weatherProvider?.settings.locationName.uppercased() ?? ""
        NSAttributedString(string: place.isEmpty ? "WEATHER" : "WEATHER · \(place)",
                           attributes: kickerAttrs(kSize))
            .draw(at: NSPoint(x: content.minX, y: y))

        // Current temperature + condition
        y -= bigSize * 1.35
        let sym = drawSymbol(WMOCode.symbol(snap.weatherCode),
                             at: CGPoint(x: content.minX, y: y + bigSize * 0.12),
                             size: bigSize * 0.9, alpha: 0.90)
        let tempAS = NSAttributedString(string: snap.tempText(snap.temperature),
                                        attributes: textAttrs(bigSize, .semibold, alpha: 0.95,
                                                              monoDigits: true))
        let tempX = sym.maxX + bigSize * 0.25
        tempAS.draw(at: NSPoint(x: tempX, y: y))
        NSAttributedString(string: WMOCode.label(snap.weatherCode), attributes: secondary)
            .draw(at: NSPoint(x: tempX + tempAS.size().width + bigSize * 0.3, y: y + bigSize * 0.12))

        // Feels-like + wind
        y -= rowH
        NSAttributedString(string: "Feels \(snap.tempText(snap.apparentTemperature))  ·  Wind \(snap.windText)",
                           attributes: secondary)
            .draw(at: NSPoint(x: content.minX, y: y))

        // Today's range + rain chance
        y -= rowH
        NSAttributedString(string: "H \(snap.tempText(snap.todayMax))  L \(snap.tempText(snap.todayMin))"
                                 + "  ·  Rain \(snap.todayPrecipProb)%",
                           attributes: secondary)
            .draw(at: NSPoint(x: content.minX, y: y))

        // Sunrise / sunset
        y -= rowH
        var sx = content.minX
        sx = drawSymbol("sunrise.fill", at: CGPoint(x: sx, y: y + rowSize * 0.05),
                        size: rowSize * 1.05, alpha: 0.60).maxX + rowSize * 0.35
        let riseAS = NSAttributedString(string: snap.sunrise,
                                        attributes: textAttrs(rowSize, .regular, alpha: 0.60,
                                                              monoDigits: true))
        riseAS.draw(at: NSPoint(x: sx, y: y))
        sx += riseAS.size().width + rowSize * 1.1
        sx = drawSymbol("sunset.fill", at: CGPoint(x: sx, y: y + rowSize * 0.05),
                        size: rowSize * 1.05, alpha: 0.60).maxX + rowSize * 0.35
        NSAttributedString(string: snap.sunset,
                           attributes: textAttrs(rowSize, .regular, alpha: 0.60, monoDigits: true))
            .draw(at: NSPoint(x: sx, y: y))

        // Compact tomorrow line
        if let tMax = snap.tomorrowMax, let tMin = snap.tomorrowMin {
            y -= rowH
            var s = "Tomorrow \(snap.tempText(tMax)) / \(snap.tempText(tMin))"
            if let p = snap.tomorrowPrecipProb { s += "  ·  Rain \(p)%" }
            NSAttributedString(string: s, attributes: textAttrs(rowSize, .regular, alpha: 0.40))
                .draw(at: NSPoint(x: content.minX, y: y))
        }

        // Play badge pill
        y -= rail.pad * 0.8 + badgeH
        drawPlayBadge(ctx, verdict: snap.playVerdict, at: CGPoint(x: content.minX, y: y),
                      height: badgeH, textSize: kSize)

        return content.minY - rail.pad   // card bottom
    }

    private func drawPlayBadge(_ ctx: CGContext, verdict: WeatherSnapshot.PlayVerdict,
                               at origin: CGPoint, height: CGFloat, textSize: CGFloat) {
        let good = verdict != .indoor
        let color = good ? accentYellow : NSColor.white
        let label = NSAttributedString(string: verdict.label,
                                       attributes: textAttrs(textSize, .bold, alpha: 0.95,
                                                             color: color, kern: textSize * 0.10))
        let sz = label.size()
        let padX = height * 0.55
        let pill = CGRect(x: origin.x, y: origin.y, width: sz.width + padX * 2, height: height)
        let path = CGPath(roundedRect: pill, cornerWidth: height / 2, cornerHeight: height / 2,
                          transform: nil)
        ctx.setFillColor(color.withAlphaComponent(good ? 0.16 : 0.08).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(color.withAlphaComponent(0.40).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path); ctx.strokePath()
        label.draw(at: NSPoint(x: pill.minX + padX, y: pill.minY + (height - sz.height) / 2))
    }

    // MARK: - Tournaments card

    // Tournament dates are calendar days with no time-of-day; format in UTC to
    // match how TournamentProvider parses them, so the day never shifts under
    // a non-UTC system time zone.
    private static let tournamentDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func drawTournaments(ctx: CGContext, rect: NSRect, rail: Rail, top: CGFloat) -> CGFloat {
        guard let provider = tournamentProvider else { return top }
        guard rail.width > rect.height * 0.12 else { return top }
        let kSize = rect.height * 0.016
        let kickerH = kSize * 1.6
        let rowSize = rect.height * 0.020
        let lineH = rowSize * 1.6
        let maxW = rail.width - rail.pad * 2

        if let unsupported = provider.unsupportedRegion {
            let msg = "No tracked pickleball metro near your weather city — nearest is "
                + "\(unsupported.metroName), \(unsupported.metroState) "
                + "(~\(Int(unsupported.distanceMiles.rounded())) mi away)."
            let bodyAttrs = textAttrs(rowSize, .regular, alpha: 0.60)
            let bodyAS = NSAttributedString(string: msg, attributes: bodyAttrs)
            let bodyH = ceil(bodyAS.boundingRect(with: NSSize(width: maxW, height: 1000),
                                                 options: .usesLineFragmentOrigin).height)
            let contentH = kickerH + kSize * 0.5 + bodyH
            let content = drawCard(ctx, rail, top: top, height: contentH + rail.pad * 2)
            var y = content.maxY - kickerH
            let glyph = drawSymbol("trophy.fill", at: CGPoint(x: content.minX, y: y + kSize * 0.05),
                                   size: kSize * 1.15, alpha: 0.40)
            NSAttributedString(string: "TOURNAMENTS", attributes: kickerAttrs(kSize))
                .draw(at: NSPoint(x: glyph.maxX + kSize * 0.6, y: y))
            y -= kSize * 0.5 + bodyH
            bodyAS.draw(with: CGRect(x: content.minX, y: y, width: maxW, height: bodyH),
                        options: .usesLineFragmentOrigin)
            return content.minY - rail.pad
        }

        guard let snap = provider.snapshot else { return top }

        let windowLabel = snap.windowMonths == 1 ? "1 MONTH" : "3 MONTHS"
        let fetched = snap.entries
        let rowGap = rail.pad * 0.5
        let perPage = 3

        if fetched.isEmpty {
            let contentH = kickerH + lineH
            let content = drawCard(ctx, rail, top: top, height: contentH + rail.pad * 2)
            var y = content.maxY - kickerH
            let glyph = drawSymbol("trophy.fill", at: CGPoint(x: content.minX, y: y + kSize * 0.05),
                                   size: kSize * 1.15, alpha: 0.40)
            NSAttributedString(string: "TOURNAMENTS · \(snap.metroName.uppercased()) · \(windowLabel)",
                               attributes: kickerAttrs(kSize))
                .draw(at: NSPoint(x: glyph.maxX + kSize * 0.6, y: y))
            y -= lineH
            NSAttributedString(string: "No tournaments scheduled nearby",
                               attributes: textAttrs(rowSize, .regular, alpha: 0.40))
                .draw(at: NSPoint(x: content.minX, y: y))
            return content.minY - rail.pad
        }

        // Auto-scroll: cycle a fixed-height page of `perPage` entries at a time so
        // the card never has to resize as it rotates through everything fetched.
        let numPages = Int(ceil(Double(fetched.count) / Double(perPage)))
        let pageIdx = tournamentPageIndex % numPages
        let pageStart = pageIdx * perPage
        let shown = Array(fetched[pageStart..<min(fetched.count, pageStart + perPage)])
        let moreCount = snap.totalCount - fetched.count   // beyond what we ever fetched
        let showTrailer = moreCount > 0 && pageIdx == numPages - 1

        let maxRowH = tournamentMaxRowHeight(rowSize: rowSize, width: maxW)
        var contentH = kickerH + maxRowH * CGFloat(perPage) + rowGap * CGFloat(perPage - 1)
        if moreCount > 0 { contentH += lineH * 0.7 }
        let content = drawCard(ctx, rail, top: top, height: contentH + rail.pad * 2)

        var y = content.maxY - kickerH
        let glyph = drawSymbol("trophy.fill", at: CGPoint(x: content.minX, y: y + kSize * 0.05),
                               size: kSize * 1.15, alpha: 0.40)
        NSAttributedString(string: "TOURNAMENTS · \(snap.metroName.uppercased()) · \(windowLabel)",
                           attributes: kickerAttrs(kSize))
            .draw(at: NSPoint(x: glyph.maxX + kSize * 0.6, y: y))

        // Rows fade out/in at each page boundary; the header stays put so only
        // the rotating content dims — the same alpha-scrub technique used for
        // the ambient wallpaper ghosts.
        let fadeAlpha: CGFloat = numPages <= 1 ? 1 : tournamentFadeAlpha()
        ctx.saveGState()
        ctx.setAlpha(fadeAlpha)
        for (i, entry) in shown.enumerated() {
            if i > 0 { y -= rowGap }
            y -= maxRowH
            drawTournamentRow(entry, top: y + maxRowH, in: content, rowSize: rowSize)
        }
        if showTrailer {
            y -= lineH * 0.7
            NSAttributedString(string: "+\(moreCount) more",
                               attributes: textAttrs(rowSize * 0.85, .regular, alpha: 0.40))
                .draw(at: NSPoint(x: content.minX, y: y))
        }
        ctx.restoreGState()
        return content.minY - rail.pad   // card bottom
    }

    // Ramps 0→1 over the first `tournamentFadeDuration` seconds of a page, holds,
    // then ramps back to 0 over the last `tournamentFadeDuration` before the swap.
    private func tournamentFadeAlpha() -> CGFloat {
        let t = tournamentCycleTimer
        if t < tournamentFadeDuration { return t / tournamentFadeDuration }
        let remaining = tournamentPageInterval - t
        if remaining < tournamentFadeDuration { return max(0, remaining / tournamentFadeDuration) }
        return 1
    }

    private func tournamentNameHeight(_ entry: TournamentSnapshot.Entry, rowSize: CGFloat, width: CGFloat) -> CGFloat {
        let name = entry.isCanceled ? "\(entry.name) (canceled)" : entry.name
        let nameAttrs = textAttrs(rowSize, .regular, alpha: 0.85)
        let lineH = ceil(NSAttributedString(string: "Ag", attributes: nameAttrs)
            .boundingRect(with: NSSize(width: width, height: 1000), options: .usesLineFragmentOrigin).height)
        let naturalH = ceil(NSAttributedString(string: name, attributes: nameAttrs)
            .boundingRect(with: NSSize(width: width, height: 1000), options: .usesLineFragmentOrigin).height)
        return min(naturalH, lineH * 2)   // cap at 2 lines; the rest truncates
    }

    // Worst-case row height (a full 2-line name) so a page's card height never
    // changes as auto-scroll rotates through entries of differing name length.
    private func tournamentMaxRowHeight(rowSize: CGFloat, width: CGFloat) -> CGFloat {
        let nameAttrs = textAttrs(rowSize, .regular, alpha: 0.85)
        let lineH = ceil(NSAttributedString(string: "Ag", attributes: nameAttrs)
            .boundingRect(with: NSSize(width: width, height: 1000), options: .usesLineFragmentOrigin).height)
        return rowSize * 0.78 * 1.3 + lineH * 2
    }

    private func drawTournamentRow(_ entry: TournamentSnapshot.Entry, top y: CGFloat, in content: CGRect,
                                   rowSize: CGFloat) {
        var dateStr = Self.tournamentDateFmt.string(from: entry.startDate)
        if let end = entry.endDate, end > entry.startDate {
            dateStr += "–\(Self.tournamentDateFmt.string(from: end))"
        }
        let dateSize = rowSize * 0.78
        NSAttributedString(string: dateStr,
                           attributes: textAttrs(dateSize, .medium, alpha: entry.isCanceled ? 0.30 : 0.55,
                                                 monoDigits: true))
            .draw(at: NSPoint(x: content.minX, y: y - dateSize * 1.05))

        let name = entry.isCanceled ? "\(entry.name) (canceled)" : entry.name
        let nameH = tournamentNameHeight(entry, rowSize: rowSize, width: content.width)
        let nameY = y - dateSize * 1.3 - nameH
        NSAttributedString(string: name,
                           attributes: textAttrs(rowSize, .regular, alpha: entry.isCanceled ? 0.35 : 0.85))
            .draw(with: CGRect(x: content.minX, y: nameY, width: content.width, height: nameH),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: - Drill of the day card (pinned to the bottom margin)

    private func drawDrill(ctx: CGContext, rect: NSRect, rail: Rail, bottom: CGFloat) {
        guard drillEnabled, let drill = PickleballDrills.drillOfTheDay(level: drillLevel) else { return }

        let kSize = rect.height * 0.016
        let kickerH = kSize * 1.6
        let titleSize = rect.height * 0.022
        let metaSize = rect.height * 0.016
        let bodySize = rect.height * 0.019
        let maxW = rail.width - rail.pad * 2

        let titleAS = NSAttributedString(string: drill.name,
                                         attributes: textAttrs(titleSize, .semibold, alpha: 0.95))
        let titleH = ceil(titleAS.boundingRect(with: NSSize(width: maxW, height: 1000),
                                               options: .usesLineFragmentOrigin).height)
        let metaAS = NSAttributedString(string: "DUPR \(drill.level) · \(drill.category.uppercased()) · \(drill.minutes) MIN",
                                        attributes: textAttrs(metaSize, .semibold, alpha: 0.40,
                                                              kern: metaSize * 0.06))
        let metaH = ceil(metaAS.size().height)

        // Body capped at 5 lines so a wordy drill can't crowd the weather card;
        // wrapping stays on and .truncatesLastVisibleLine ellipsizes the cutoff.
        let bodyAttrs = textAttrs(bodySize, .regular, alpha: 0.85)
        let bodyAS = NSAttributedString(string: drill.description, attributes: bodyAttrs)
        let lineH = ceil(NSAttributedString(string: "Ag", attributes: bodyAttrs)
            .boundingRect(with: NSSize(width: maxW, height: 1000),
                          options: .usesLineFragmentOrigin).height)
        let naturalH = ceil(bodyAS.boundingRect(with: NSSize(width: maxW, height: 1000),
                                                options: .usesLineFragmentOrigin).height)
        let bodyH = min(naturalH, lineH * 5)

        let contentH = kickerH + kSize * 0.5 + titleH + metaH + kSize * 0.5 + bodyH
        let content = drawCard(ctx, rail, top: bottom + contentH + rail.pad * 2,
                               height: contentH + rail.pad * 2)

        var y = content.maxY - kickerH
        let symbol = NSImage(systemSymbolName: "figure.pickleball", accessibilityDescription: nil) != nil
            ? "figure.pickleball" : "figure.tennis"
        let glyph = drawSymbol(symbol, at: CGPoint(x: content.minX, y: y + kSize * 0.05),
                               size: kSize * 1.15, alpha: 0.85, color: accentYellow)
        NSAttributedString(string: "DRILL OF THE DAY", attributes: kickerAttrs(kSize))
            .draw(at: NSPoint(x: glyph.maxX + kSize * 0.6, y: y))

        y -= kSize * 0.5 + titleH
        titleAS.draw(with: CGRect(x: content.minX, y: y, width: maxW, height: titleH),
                     options: .usesLineFragmentOrigin)
        y -= metaH
        metaAS.draw(at: NSPoint(x: content.minX, y: y))
        y -= kSize * 0.5 + bodyH
        bodyAS.draw(with: CGRect(x: content.minX, y: y, width: maxW, height: bodyH),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: - Scoreboard (bottom-center glass pill; singles side-out scoring)

    private func drawScoreboard(ctx: CGContext, rect: NSRect) {
        let size = rect.height * 0.030
        let y = rect.height * 0.035

        let scoreAttrs = textAttrs(size, .semibold, alpha: 0.90, monoDigits: true)
        let labelAttrs = textAttrs(size * 0.52, .semibold, alpha: 0.45, kern: size * 0.05)

        let score = NSMutableAttributedString()
        score.append(NSAttributedString(string: "NEAR  ", attributes: labelAttrs))
        score.append(NSAttributedString(string: "\(engine.nearScore)  –  \(engine.farScore)", attributes: scoreAttrs))
        score.append(NSAttributedString(string: "  FAR", attributes: labelAttrs))
        let sz = score.size()
        let x0 = rect.midX - sz.width / 2

        // Glass pill behind the score line, matching the rail cards
        let padX = size * 0.9, padY = size * 0.42
        let pill = CGRect(x: x0 - padX, y: y - padY, width: sz.width + padX * 2, height: sz.height + padY * 2)
        drawGlassPanel(ctx, rect: pill, corner: pill.height / 2, shadowBlur: 0)

        score.draw(at: NSPoint(x: x0, y: y))

        // Serve dot (ball-yellow) beside the serving side; doubles adds the
        // server number (the third number of the real 0-0-2 call)
        let r = size * 0.16
        let nearServing = engine.nearServing
        let dotX = nearServing ? x0 - r * 3 : x0 + sz.width + r
        ctx.setFillColor(accentYellow.withAlphaComponent(0.85).cgColor)
        ctx.fillEllipse(in: CGRect(x: dotX, y: y + sz.height * 0.38 - r, width: r * 2, height: r * 2))
        if engine.format == .doubles {
            let sn = NSAttributedString(string: "\(engine.serverNumber)",
                                        attributes: textAttrs(size * 0.52, .bold, alpha: 0.70,
                                                              color: accentYellow, monoDigits: true))
            let snSz = sn.size()
            let snX = nearServing ? dotX - snSz.width - r : dotX + r * 2 + r
            sn.draw(at: NSPoint(x: snX, y: y + sz.height * 0.38 - snSz.height / 2))
        }

        // Games tally above the pill once a game has been won
        if engine.nearGames + engine.farGames > 0 {
            let games = NSAttributedString(string: "GAMES \(engine.nearGames) – \(engine.farGames)",
                                           attributes: textAttrs(size * 0.45, .semibold, alpha: 0.40,
                                                                 kern: size * 0.04))
            let gsz = games.size()
            games.draw(at: NSPoint(x: rect.midX - gsz.width / 2, y: pill.maxY + gsz.height * 0.35))
        }

        // Brief GAME banner when a game is won
        if engine.gameBannerTimer > 0 {
            let pulse = 0.35 + 0.45 * abs(sin(engine.gameBannerTimer * .pi * 1.5))
            let banner = NSAttributedString(string: "GAME",
                                            attributes: textAttrs(size * 1.8, .bold, alpha: pulse,
                                                                  color: accentYellow))
            let bsz = banner.size()
            banner.draw(at: NSPoint(x: rect.midX - bsz.width / 2, y: pill.maxY + sz.height * 0.9))
        }
    }

    // MARK: - Helpers

    private func line(_ ctx: CGContext, from a: CGPoint, to b: CGPoint) {
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    }

    private func fillQuad(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, color: CGColor) {
        let p = CGMutablePath()
        p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.addLine(to: d); p.closeSubpath()
        ctx.setFillColor(color)
        ctx.addPath(p)
        ctx.fillPath()
    }

    private func strokeQuad(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) {
        let p = CGMutablePath()
        p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.addLine(to: d); p.closeSubpath()
        ctx.addPath(p)
        ctx.strokePath()
    }

    // MARK: - ScreenSaverView

    private lazy var configureController = ConfigureSheetController()

    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? {
        configureController.refresh()
        return configureController.window
    }
}
