import ScreenSaver
import AppKit

// MARK: - 3D World State helpers

private struct Vec3 {
    var x: CGFloat
    var y: CGFloat  // height above court floor
    var z: CGFloat  // depth: 0 = near baseline, 1 = far baseline
}

private struct PaddleState {
    var x: CGFloat = 0          // side-to-side world position
    var swingAngle: CGFloat = 0
    var swingPhase = false
    var swingT: CGFloat = 0
}

class PickleballScreensaverView: ScreenSaverView {

    // MARK: - Ball state (world coordinates)
    private var ball = Vec3(x: 0, y: 0.08, z: 0.05)
    private var bVel = Vec3(x: 0.04, y: 0, z: 0)  // world units / sec
    private var trailPoints: [Vec3] = []

    // MARK: - Paddle state
    private var nearPaddle = PaddleState()   // z ≈ 0, large (foreground)
    private var farPaddle  = PaddleState()   // z ≈ 1, small (background)

    // MARK: - Physics constants
    private let gravity:     CGFloat = -3.0   // world units / sec²
    private let bounceDamp:  CGFloat = 0.60   // vy retained after floor bounce
    private let courtHalfW:  CGFloat = 0.42   // side extent in world units
    private let netHeight:   CGFloat = 0.10   // world units (net clearance target)
    private let baseSpeed:   CGFloat = 0.70   // baseline z-speed world units/sec

    // MARK: - Projection constants (tuned for 45° feel)
    private let horizonFrac: CGFloat = 0.28   // vanishing point y as fraction of screen height
    private let baselineFrac: CGFloat = 0.87  // near baseline y as fraction of screen height
    private let nearHalfPx:  CGFloat = 310    // half-width in pixels at z=0
    private let farScale:    CGFloat = 0.40   // scale factor at z=1 vs z=0
    private let heightScale: CGFloat = 260    // pixels per world Y unit at near scale

    // MARK: - Rally state
    private var rallyCount = 0
    private var lastFrameTime: TimeInterval = 0
    private var faultTimer: CGFloat = 0       // countdown after a fault before reset

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
        resetRally(nearServes: true)
    }

    // MARK: - Projection

    private func proj(_ v: Vec3) -> CGPoint { proj(v.x, v.z, v.y) }

    private func proj(_ wx: CGFloat, _ wz: CGFloat, _ wy: CGFloat) -> CGPoint {
        let W = bounds.width
        let H = bounds.height
        let horizonY = H * horizonFrac
        let baseY    = H * baselineFrac
        let s = 1.0 + (farScale - 1.0) * wz          // perspective scale
        let sx = W / 2 + wx * s * nearHalfPx
        let sy = baseY - wz * (baseY - horizonY) - wy * heightScale * s
        return CGPoint(x: sx, y: sy)
    }

    private func perspScale(_ wz: CGFloat) -> CGFloat {
        1.0 + (farScale - 1.0) * wz
    }

    // MARK: - Rally / reset

    private func resetRally(nearServes: Bool) {
        let startZ: CGFloat = nearServes ? 0.04 : 0.96
        let targetZ: CGFloat = nearServes ? 1.0 : 0.0
        ball = Vec3(x: CGFloat.random(in: -0.15...0.15), y: 0.0, z: startZ)
        let vz = (targetZ > startZ ? 1 : -1) * baseSpeed
        // Compute vy so ball peaks above net height
        // Peak at z=0.5: vy0*t - 0.5*g*t² = netHeight+0.05, t = 0.5/|vz|
        let t = 0.5 / abs(vz)
        let targetPeak = netHeight + 0.07
        // vy0 so ball peaks at targetPeak: peak = vy0²/(2·|g|)
        let vy0 = sqrt(2.0 * abs(gravity) * targetPeak)
        bVel = Vec3(x: CGFloat.random(in: -0.08...0.08), y: vy0, z: vz)
        nearPaddle = PaddleState()
        farPaddle  = PaddleState()
        trailPoints.removeAll()
        faultTimer = 0
    }

    // MARK: - Animation loop

    override func animateOneFrame() {
        let now = Date().timeIntervalSinceReferenceDate
        let dt: CGFloat = lastFrameTime == 0 ? 1/60.0 : min(CGFloat(now - lastFrameTime), 0.05)
        lastFrameTime = now

        if faultTimer > 0 {
            faultTimer -= dt
            if faultTimer <= 0 { resetRally(nearServes: Bool.random()) }
            setNeedsDisplay(bounds)
            return
        }

        // Integrate physics
        ball.y += bVel.y * dt
        bVel.y += gravity * dt
        ball.z += bVel.z * dt
        ball.x += bVel.x * dt

        // Floor bounce
        if ball.y < 0 {
            ball.y = 0
            bVel.y = abs(bVel.y) * bounceDamp
        }

        // Side-wall bounce
        if ball.x < -courtHalfW { ball.x = -courtHalfW; bVel.x = abs(bVel.x) }
        if ball.x >  courtHalfW { ball.x =  courtHalfW; bVel.x = -abs(bVel.x) }

        // AI paddles track ball's X
        let paddleSpeed: CGFloat = 0.55
        nearPaddle.x = moveVal(nearPaddle.x, toward: ball.x, speed: paddleSpeed * dt, lo: -courtHalfW + 0.05, hi: courtHalfW - 0.05)
        farPaddle.x  = moveVal(farPaddle.x,  toward: ball.x, speed: paddleSpeed * dt, lo: -courtHalfW + 0.05, hi: courtHalfW - 0.05)

        // Paddle swing animation
        updateSwing(&nearPaddle, dt: dt)
        updateSwing(&farPaddle,  dt: dt)

        // Hit detection — near paddle (z ≈ 0, ball coming toward viewer)
        if bVel.z < 0 && ball.z < 0.06 && ball.z > 0 && abs(ball.x - nearPaddle.x) < 0.18 && ball.y < 0.30 {
            hitBall(goingFar: true, paddle: &nearPaddle)
            rallyCount += 1
        }

        // Hit detection — far paddle (z ≈ 1, ball going away)
        if bVel.z > 0 && ball.z > 0.94 && ball.z < 1.0 && abs(ball.x - farPaddle.x) < 0.18 && ball.y < 0.30 {
            hitBall(goingFar: false, paddle: &farPaddle)
            rallyCount += 1
        }

        // Out of bounds
        if ball.z < -0.15 || ball.z > 1.15 {
            faultTimer = 1.2
        }

        // Trail
        trailPoints.append(ball)
        if trailPoints.count > 18 { trailPoints.removeFirst() }

        setNeedsDisplay(bounds)
    }

    private func updateSwing(_ p: inout PaddleState, dt: CGFloat) {
        guard p.swingPhase else { return }
        p.swingT += dt * 2.8
        p.swingAngle = sin(p.swingT * .pi) * 1.0
        if p.swingT >= 1 { p.swingPhase = false; p.swingAngle = 0; p.swingT = 0 }
    }

    private func hitBall(goingFar: Bool, paddle: inout PaddleState) {
        let vz = (goingFar ? 1 : -1) * (baseSpeed + CGFloat.random(in: 0...0.15))
        let vy0 = sqrt(2.0 * abs(gravity) * (netHeight + CGFloat.random(in: 0.04...0.12)))
        bVel.z = vz
        bVel.y = vy0
        bVel.x = CGFloat.random(in: -0.12...0.12)
        ball.z = goingFar ? 0.07 : 0.93
        paddle.swingPhase = true
        paddle.swingT = 0
    }

    private func moveVal(_ v: CGFloat, toward t: CGFloat, speed: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        let d = t - v
        let step = min(abs(d), speed) * (d >= 0 ? 1 : -1)
        return max(lo, min(hi, v + step))
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(ctx: ctx, rect: rect)
        drawCourt(ctx: ctx)
        drawFarPaddle(ctx: ctx)
        drawNet(ctx: ctx)
        drawBallShadow(ctx: ctx)
        drawTrail(ctx: ctx)
        drawBall(ctx: ctx)
        drawNearPaddle(ctx: ctx)
        drawRallyCounter(ctx: ctx, rect: rect)
    }

    // MARK: - Background

    private func drawBackground(ctx: CGContext, rect: NSRect) {
        ctx.setFillColor(CGColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 1))
        ctx.fill(rect)

        let colors = [CGColor(red: 0.08, green: 0.18, blue: 0.38, alpha: 0.5),
                      CGColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 0)] as CFArray
        let locs: [CGFloat] = [0, 1]
        if let sp = CGColorSpace(name: CGColorSpace.sRGB),
           let gr = CGGradient(colorsSpace: sp, colors: colors, locations: locs) {
            let cx = rect.midX, cy = rect.midY
            ctx.drawRadialGradient(gr,
                startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                endCenter:   CGPoint(x: cx, y: cy), endRadius: max(rect.width, rect.height) * 0.65,
                options: [])
        }
    }

    // MARK: - Court

    private func drawCourt(ctx: CGContext) {
        let nl = proj(-courtHalfW, 0, 0)
        let nr = proj( courtHalfW, 0, 0)
        let fl = proj(-courtHalfW, 1, 0)
        let fr = proj( courtHalfW, 1, 0)

        // Court surface
        let courtPath = CGMutablePath()
        courtPath.move(to: nl)
        courtPath.addLine(to: nr)
        courtPath.addLine(to: fr)
        courtPath.addLine(to: fl)
        courtPath.closeSubpath()
        ctx.setFillColor(CGColor(red: 0.13, green: 0.42, blue: 0.72, alpha: 1))
        ctx.addPath(courtPath)
        ctx.fillPath()

        // Kitchen zones (non-volley zone) — 7ft from net each side ≈ 23% of half-court
        let kFrac: CGFloat = 0.27
        let kNearZ = 0.5 - kFrac   // near kitchen line z
        let kFarZ  = 0.5 + kFrac   // far kitchen line z

        let knl = proj(-courtHalfW, kNearZ, 0)
        let knr = proj( courtHalfW, kNearZ, 0)
        let kfl = proj(-courtHalfW, kFarZ,  0)
        let kfr = proj( courtHalfW, kFarZ,  0)
        let netL = proj(-courtHalfW, 0.5, 0)
        let netR = proj( courtHalfW, 0.5, 0)

        // Near kitchen (between near baseline and near kitchen line)
        let nearKitchen = CGMutablePath()
        nearKitchen.move(to: nl)
        nearKitchen.addLine(to: nr)
        nearKitchen.addLine(to: knr)
        nearKitchen.addLine(to: knl)
        nearKitchen.closeSubpath()
        ctx.setFillColor(CGColor(red: 0.09, green: 0.32, blue: 0.60, alpha: 1))
        ctx.addPath(nearKitchen)
        ctx.fillPath()

        // Far kitchen (between far kitchen line and far baseline)
        let farKitchen = CGMutablePath()
        farKitchen.move(to: kfl)
        farKitchen.addLine(to: kfr)
        farKitchen.addLine(to: fr)
        farKitchen.addLine(to: fl)
        farKitchen.closeSubpath()
        ctx.addPath(farKitchen)
        ctx.fillPath()

        // White court lines
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.90))
        ctx.setLineWidth(2.0)

        // Outer boundary
        ctx.addPath(courtPath)
        ctx.strokePath()

        // Kitchen lines
        line(ctx, from: knl, to: knr)
        line(ctx, from: kfl, to: kfr)

        // Center service lines (only in service zones, not kitchen)
        // Near service zone: from near baseline to near kitchen line
        line(ctx, from: proj(0, 0, 0),    to: proj(0, kNearZ, 0))
        // Far service zone: from far kitchen line to far baseline
        line(ctx, from: proj(0, kFarZ, 0), to: proj(0, 1, 0))

        // Net center line stub on court floor (thin)
        ctx.setLineWidth(1.0)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
        line(ctx, from: netL, to: netR)
    }

    // MARK: - Net

    private func drawNet(ctx: CGContext) {
        let nh = netHeight + 0.02  // net top height in world units
        let nl0 = proj(-courtHalfW, 0.5, 0)
        let nr0 = proj( courtHalfW, 0.5, 0)
        let nlT = proj(-courtHalfW, 0.5, nh)
        let nrT = proj( courtHalfW, 0.5, nh)

        // Net body quad
        let netPath = CGMutablePath()
        netPath.move(to: nl0)
        netPath.addLine(to: nr0)
        netPath.addLine(to: nrT)
        netPath.addLine(to: nlT)
        netPath.closeSubpath()
        ctx.setFillColor(CGColor(red: 0.75, green: 0.78, blue: 0.85, alpha: 0.30))
        ctx.addPath(netPath)
        ctx.fillPath()

        // Horizontal mesh strands
        ctx.setStrokeColor(CGColor(red: 0.80, green: 0.83, blue: 0.90, alpha: 0.45))
        ctx.setLineWidth(0.7)
        let steps = 8
        for i in 1..<steps {
            let frac = CGFloat(i) / CGFloat(steps)
            let wy = frac * nh
            line(ctx, from: proj(-courtHalfW, 0.5, wy), to: proj(courtHalfW, 0.5, wy))
        }

        // Vertical strands
        ctx.setStrokeColor(CGColor(red: 0.80, green: 0.83, blue: 0.90, alpha: 0.25))
        let vSteps = 12
        for i in 0...vSteps {
            let wx = -courtHalfW + courtHalfW * 2 * CGFloat(i) / CGFloat(vSteps)
            line(ctx, from: proj(wx, 0.5, 0), to: proj(wx, 0.5, nh))
        }

        // White top tape
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.setLineWidth(3.5)
        line(ctx, from: nlT, to: nrT)

        // Bottom edge
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.6))
        ctx.setLineWidth(2)
        line(ctx, from: nl0, to: nr0)

        // Net posts
        let postR: CGFloat = 5
        ctx.setFillColor(CGColor(red: 0.70, green: 0.73, blue: 0.78, alpha: 1))
        fillCircle(ctx, at: nlT, r: postR)
        fillCircle(ctx, at: nrT, r: postR)
        fillCircle(ctx, at: nl0, r: postR * 0.7)
        fillCircle(ctx, at: nr0, r: postR * 0.7)
    }

    // MARK: - Ball shadow

    private func drawBallShadow(ctx: CGContext) {
        let sp = proj(ball.x, ball.z, 0)
        let heightFade = max(0, 1 - ball.y / 0.5)
        let s = perspScale(ball.z)
        let rw: CGFloat = 14 * s * heightFade
        let rh: CGFloat = 5  * s * heightFade
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35 * heightFade))
        ctx.fillEllipse(in: CGRect(x: sp.x - rw, y: sp.y - rh, width: rw * 2, height: rh * 2))
    }

    // MARK: - Ball trail

    private func drawTrail(ctx: CGContext) {
        let count = trailPoints.count
        for (i, t) in trailPoints.enumerated() {
            let frac = CGFloat(i) / CGFloat(count)
            let s = perspScale(t.z)
            let r = 10.0 * s * frac * 0.65
            let a = frac * 0.30
            let p = proj(t)
            ctx.setFillColor(CGColor(red: 1, green: 0.92, blue: 0.2, alpha: a))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Ball

    private func drawBall(ctx: CGContext) {
        let p = proj(ball)
        let s = perspScale(ball.z)
        let r: CGFloat = 11 * s

        // Body
        ctx.setFillColor(CGColor(red: 0.94, green: 0.91, blue: 0.14, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))

        // Highlight
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.72, alpha: 0.65))
        ctx.fillEllipse(in: CGRect(x: p.x - r * 0.4, y: p.y + r * 0.15, width: r * 0.75, height: r * 0.5))

        // Holes
        ctx.setFillColor(CGColor(red: 0.74, green: 0.70, blue: 0.04, alpha: 0.85))
        let offsets: [(CGFloat, CGFloat)] = [
            (-0.42, 0), (0.42, 0), (0, 0.42), (0, -0.42),
            (-0.27, 0.30), (0.27, 0.30), (-0.27, -0.30), (0.27, -0.30)
        ]
        for (dx, dy) in offsets {
            let hr: CGFloat = max(1.2, 1.9 * s)
            ctx.fillEllipse(in: CGRect(x: p.x + dx * r - hr, y: p.y + dy * r - hr,
                                       width: hr * 2, height: hr * 2))
        }
    }

    // MARK: - Near paddle (foreground, large)

    private func drawNearPaddle(ctx: CGContext) {
        let baseP = proj(nearPaddle.x, 0.02, 0)
        drawPaddle3D(ctx: ctx, screenPos: baseP, worldZ: 0.02,
                     swingAngle: nearPaddle.swingAngle, facingFar: true)
    }

    // MARK: - Far paddle (background, small)

    private func drawFarPaddle(ctx: CGContext) {
        let baseP = proj(farPaddle.x, 0.98, 0)
        drawPaddle3D(ctx: ctx, screenPos: baseP, worldZ: 0.98,
                     swingAngle: farPaddle.swingAngle, facingFar: false)
    }

    private func drawPaddle3D(ctx: CGContext, screenPos: CGPoint, worldZ: CGFloat,
                               swingAngle: CGFloat, facingFar: Bool) {
        let s = perspScale(worldZ)

        // Paddle dimensions scaled by perspective
        let faceW: CGFloat = 52 * s
        let faceH: CGFloat = 70 * s
        let handleLen: CGFloat = 38 * s
        let handleW: CGFloat   = 12 * s

        ctx.saveGState()
        // Pivot around handle base (bottom of paddle)
        let pivotY = screenPos.y
        let pivotX = screenPos.x
        ctx.translateBy(x: pivotX, y: pivotY)
        ctx.rotate(by: swingAngle)
        ctx.translateBy(x: -pivotX, y: -pivotY)

        let cx = screenPos.x
        // Handle goes down from screenPos
        let handleRect = CGRect(x: cx - handleW / 2, y: pivotY - handleLen,
                                width: handleW, height: handleLen)
        let faceRect   = CGRect(x: cx - faceW / 2,  y: pivotY - handleLen - faceH,
                                width: faceW, height: faceH)

        // Shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 4 * s, height: -5 * s), blur: 10 * s,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        // Handle
        ctx.setFillColor(CGColor(red: 0.30, green: 0.14, blue: 0.05, alpha: 1))
        ctx.addPath(CGPath(roundedRect: handleRect, cornerWidth: 4 * s, cornerHeight: 4 * s, transform: nil))
        ctx.fillPath()

        // Paddle edge (dark border)
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        ctx.addPath(CGPath(roundedRect: faceRect, cornerWidth: 9 * s, cornerHeight: 9 * s, transform: nil))
        ctx.fillPath()

        ctx.restoreGState()

        // Paddle face (vivid blue)
        let innerFace = faceRect.insetBy(dx: 2 * s, dy: 2 * s)
        ctx.setFillColor(CGColor(red: 0.14, green: 0.36, blue: 0.82, alpha: 1))
        ctx.addPath(CGPath(roundedRect: innerFace, cornerWidth: 7 * s, cornerHeight: 7 * s, transform: nil))
        ctx.fillPath()

        // Face highlight
        let hlRect = CGRect(x: innerFace.minX + 3 * s, y: innerFace.midY,
                            width: innerFace.width - 6 * s, height: innerFace.height / 2 - 2 * s)
        ctx.setFillColor(CGColor(red: 0.30, green: 0.52, blue: 0.95, alpha: 0.40))
        ctx.addPath(CGPath(roundedRect: hlRect, cornerWidth: 5 * s, cornerHeight: 5 * s, transform: nil))
        ctx.fillPath()

        // Grip wraps
        ctx.setStrokeColor(CGColor(red: 0.18, green: 0.09, blue: 0.02, alpha: 0.65))
        ctx.setLineWidth(1.0 * s)
        let step = 5 * s
        var wy = handleRect.minY + 4 * s
        while wy < handleRect.maxY - 2 * s {
            line(ctx, from: CGPoint(x: handleRect.minX + s, y: wy),
                      to:   CGPoint(x: handleRect.maxX - s, y: wy))
            wy += step
        }

        ctx.restoreGState()
    }

    // MARK: - Rally counter

    private func drawRallyCounter(ctx: CGContext, rect: NSRect) {
        let label = "Rally  \(rallyCount)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.40)
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.height * 0.93))
    }

    // MARK: - Helpers

    private func line(_ ctx: CGContext, from a: CGPoint, to b: CGPoint) {
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    }

    private func fillCircle(_ ctx: CGContext, at p: CGPoint, r: CGFloat) {
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // MARK: - ScreenSaverView

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
