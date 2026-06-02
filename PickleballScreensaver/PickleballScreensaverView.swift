import ScreenSaver
import AppKit

// MARK: - Types

private struct Vec3 {
    var x: CGFloat   // court length: 0 = left baseline, 1 = right baseline
    var y: CGFloat   // height above floor
    var z: CGFloat   // court width: 0 = near sideline (camera side), 1 = far sideline
}

private struct PaddleState {
    var z: CGFloat = 0.5        // position across court width (depth)
    var swingAngle: CGFloat = 0
    var swingPhase = false
    var swingT: CGFloat = 0
}

// MARK: - Screensaver

class PickleballScreensaverView: ScreenSaverView {

    // Ball state
    private var ball = Vec3(x: 0.05, y: 0.0, z: 0.5)
    private var bVel = Vec3(x: 0.72, y: 0, z: 0)
    private var trailPoints: [Vec3] = []

    // Paddle state — left (x≈0) and right (x≈1)
    private var leftPaddle  = PaddleState()
    private var rightPaddle = PaddleState()

    // Physics
    private let gravity:     CGFloat = -3.0
    private let bounceDamp:  CGFloat = 0.58
    private let netHeight:   CGFloat = 0.10
    private let baseSpeed:   CGFloat = 0.72

    // Projection — camera at near sideline (z=0), elevated, centered at x=0.5
    // x=0..1 maps left-right on screen; z=0..1 recedes into screen (depth)
    private let horizonFrac:   CGFloat = 0.30   // vanishing-point y / screen height
    private let baselineFrac:  CGFloat = 0.86   // near-sideline y / screen height
    private let courtHalfFrac: CGFloat = 0.38   // half court length as fraction of screen width (at z=0)
    private let farScale:      CGFloat = 0.44   // perspective scale at far sideline vs near
    private let heightScale:   CGFloat = 265    // screen pixels per world Y unit (at z=0)

    // Court geometry (normalised 0..1 along court length)
    private let kitchenNearX: CGFloat = 15.0 / 44.0   // ≈ 0.341
    private let kitchenFarX:  CGFloat = 29.0 / 44.0   // ≈ 0.659

    // Rally state
    private var rallyCount = 0
    private var lastFrameTime: TimeInterval = 0
    private var faultTimer: CGFloat = 0

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
        resetRally(leftServes: true)
    }

    // MARK: - Projection
    // wx: 0=left baseline … 1=right baseline  (maps to screen X)
    // wz: 0=near sideline  … 1=far sideline   (maps to depth / screen Y rise)
    // wy: height above floor                   (maps upward on screen)

    private func proj(_ wx: CGFloat, _ wz: CGFloat, _ wy: CGFloat) -> CGPoint {
        let W = bounds.width, H = bounds.height
        let baseY    = H * baselineFrac
        let horizonY = H * horizonFrac
        let s = 1.0 + (farScale - 1.0) * wz   // 1.0 at near, farScale at far
        let halfW = W * courtHalfFrac
        let sx = W / 2 + (wx - 0.5) * halfW * 2 * s
        let sy = baseY - wz * (baseY - horizonY) - wy * heightScale * s
        return CGPoint(x: sx, y: sy)
    }

    private func proj(_ v: Vec3) -> CGPoint { proj(v.x, v.z, v.y) }

    private func scaleAt(_ wz: CGFloat) -> CGFloat { 1.0 + (farScale - 1.0) * wz }

    // MARK: - Reset

    private func resetRally(leftServes: Bool) {
        let startX: CGFloat = leftServes ? 0.05 : 0.95
        let vx = leftServes ? baseSpeed : -baseSpeed
        ball = Vec3(x: startX, y: 0.0, z: CGFloat.random(in: 0.3...0.7))
        let vy0 = sqrt(2.0 * abs(gravity) * (netHeight + 0.07))
        bVel = Vec3(x: vx, y: vy0, z: CGFloat.random(in: -0.04...0.04))
        leftPaddle  = PaddleState(z: 0.5, swingAngle: 0, swingPhase: false, swingT: 0)
        rightPaddle = PaddleState(z: 0.5, swingAngle: 0, swingPhase: false, swingT: 0)
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
            if faultTimer <= 0 { resetRally(leftServes: Bool.random()) }
            setNeedsDisplay(bounds)
            return
        }

        // Physics
        ball.y += bVel.y * dt
        bVel.y += gravity * dt
        ball.x += bVel.x * dt
        ball.z += bVel.z * dt

        // Floor bounce
        if ball.y < 0 {
            ball.y = 0
            bVel.y = abs(bVel.y) * bounceDamp
        }

        // Sideline bounces (near/far)
        if ball.z < 0.02 { ball.z = 0.02; bVel.z =  abs(bVel.z) }
        if ball.z > 0.98 { ball.z = 0.98; bVel.z = -abs(bVel.z) }

        // AI paddles track ball depth (z)
        let spd: CGFloat = 0.55
        leftPaddle.z  = moveVal(leftPaddle.z,  toward: ball.z, speed: spd * dt, lo: 0.1, hi: 0.9)
        rightPaddle.z = moveVal(rightPaddle.z, toward: ball.z, speed: spd * dt, lo: 0.1, hi: 0.9)

        // Swing animation
        updateSwing(&leftPaddle,  dt: dt)
        updateSwing(&rightPaddle, dt: dt)

        // Net clearance: interpolate ball height at x=0.5 crossing.
        // Use the pre-gravity velocity (before bVel.y += gravity*dt was applied)
        // so that the reconstructed prevY and yAtNet are accurate.
        let prevVelY = bVel.y - gravity * dt
        let prevX = ball.x - bVel.x * dt
        if (prevX < 0.5) != (ball.x < 0.5) {
            let t = (0.5 - prevX) / (ball.x - prevX)
            let prevY = ball.y - prevVelY * dt
            let yAtNet = prevY + prevVelY * dt * t + 0.5 * gravity * (dt * t) * (dt * t)
            if yAtNet < netHeight { faultTimer = 1.2 }
        }

        // Hit detection — left paddle
        if bVel.x < 0 && ball.x < 0.07 && ball.x > 0
           && abs(ball.z - leftPaddle.z) < 0.18 && ball.y < 0.35 {
            hitBall(goingRight: true, paddle: &leftPaddle)
            rallyCount += 1
        }

        // Hit detection — right paddle
        if bVel.x > 0 && ball.x > 0.93 && ball.x < 1.0
           && abs(ball.z - rightPaddle.z) < 0.18 && ball.y < 0.35 {
            hitBall(goingRight: false, paddle: &rightPaddle)
            rallyCount += 1
        }

        // Out of bounds
        if ball.x < -0.15 || ball.x > 1.15 { faultTimer = 1.2 }

        // Trail
        trailPoints.append(ball)
        if trailPoints.count > 18 { trailPoints.removeFirst() }

        setNeedsDisplay(bounds)
    }

    private func updateSwing(_ p: inout PaddleState, dt: CGFloat) {
        guard p.swingPhase else { return }
        p.swingT += dt * 2.8
        p.swingAngle = sin(p.swingT * .pi) * 1.05
        if p.swingT >= 1 { p.swingPhase = false; p.swingAngle = 0; p.swingT = 0 }
    }

    private func hitBall(goingRight: Bool, paddle: inout PaddleState) {
        let vx = (goingRight ? 1 : -1) * (baseSpeed + CGFloat.random(in: 0...0.15))
        let vy0 = sqrt(2.0 * abs(gravity) * (netHeight + CGFloat.random(in: 0.04...0.12)))
        bVel.x = vx
        bVel.y = vy0
        bVel.z = CGFloat.random(in: -0.08...0.08)
        ball.x = goingRight ? 0.07 : 0.93
        paddle.swingPhase = true
        paddle.swingT = 0
    }

    private func moveVal(_ v: CGFloat, toward t: CGFloat, speed: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        let d = t - v
        let step = min(abs(d), speed) * (d >= 0 ? 1 : -1)
        return max(lo, min(hi, v + step))
    }

    // MARK: - Draw

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(ctx: ctx, rect: rect)
        drawCourt(ctx: ctx)
        // Draw each paddle in depth order (farther = drawn first)
        let lpFirst = leftPaddle.z > rightPaddle.z
        if lpFirst {
            drawPaddle(ctx: ctx, state: leftPaddle,  atX: 0.04, facingRight: true)
            drawNet(ctx: ctx)
            drawPaddle(ctx: ctx, state: rightPaddle, atX: 0.96, facingRight: false)
        } else {
            drawPaddle(ctx: ctx, state: rightPaddle, atX: 0.96, facingRight: false)
            drawNet(ctx: ctx)
            drawPaddle(ctx: ctx, state: leftPaddle,  atX: 0.04, facingRight: true)
        }
        drawBallShadow(ctx: ctx)
        drawTrail(ctx: ctx)
        drawBall(ctx: ctx)
        drawRallyCounter(ctx: ctx, rect: rect)
    }

    // MARK: - Background

    private func drawBackground(ctx: CGContext, rect: NSRect) {
        ctx.setFillColor(CGColor(red: 0.04, green: 0.06, blue: 0.13, alpha: 1))
        ctx.fill(rect)
        let colors = [CGColor(red: 0.08, green: 0.18, blue: 0.38, alpha: 0.45),
                      CGColor(red: 0.04, green: 0.06, blue: 0.13, alpha: 0)] as CFArray
        let locs: [CGFloat] = [0, 1]
        if let sp = CGColorSpace(name: CGColorSpace.sRGB),
           let gr = CGGradient(colorsSpace: sp, colors: colors, locations: locs) {
            ctx.drawRadialGradient(gr,
                startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                endCenter:   CGPoint(x: rect.midX, y: rect.midY),
                endRadius: max(rect.width, rect.height) * 0.65, options: [])
        }
    }

    // MARK: - Court

    private func drawCourt(ctx: CGContext) {
        // Four corners of the court floor
        let nl = proj(0, 0, 0);  let nr = proj(1, 0, 0)   // near sideline (camera side)
        let fl = proj(0, 1, 0);  let fr = proj(1, 1, 0)   // far sideline

        // Full court surface
        fillQuad(ctx, nl, nr, fr, fl, color: CGColor(red: 0.13, green: 0.42, blue: 0.72, alpha: 1))

        // Kitchen zones — darker blue adjacent to net on each side
        let knl = proj(kitchenNearX, 0, 0); let knr = proj(kitchenNearX, 1, 0)
        let kfl = proj(kitchenFarX,  0, 0); let kfr = proj(kitchenFarX,  1, 0)
        let kitchenColor = CGColor(red: 0.09, green: 0.32, blue: 0.60, alpha: 1)
        // Near-side kitchen: from kitchenNearX to net (x=0.5)
        fillQuad(ctx, knl, proj(0.5, 0, 0), proj(0.5, 1, 0), knr, color: kitchenColor)
        // Far-side kitchen: from net (x=0.5) to kitchenFarX
        fillQuad(ctx, proj(0.5, 0, 0), kfl, kfr, proj(0.5, 1, 0), color: kitchenColor)

        // White court lines
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.90))
        ctx.setLineWidth(2.0)

        // Outer boundary
        strokeQuad(ctx, nl, nr, fr, fl)

        // Kitchen lines (across court width)
        line(ctx, from: knl, to: knr)
        line(ctx, from: kfl, to: kfr)

        // Center service line (along court length, in service zones only, at z midpoint)
        ctx.setLineWidth(1.5)
        line(ctx, from: proj(0,           0.5, 0), to: proj(kitchenNearX, 0.5, 0))
        line(ctx, from: proj(kitchenFarX, 0.5, 0), to: proj(1,           0.5, 0))
    }

    // MARK: - Net
    // From the sideline at center court the net is nearly edge-on.
    // Draw it as a narrow vertical band at x=0.5 with mesh strands.

    private func drawNet(ctx: CGContext) {
        let nh = netHeight
        let netBandHalfW: CGFloat = 6   // screen-space half-width of net band

        // Net body — a narrow quad centered on x=0.5 for near and far edges
        let bNear = proj(0.5, 0, 0); let bFar  = proj(0.5, 1, 0)
        let tNear = proj(0.5, 0, nh); let tFar  = proj(0.5, 1, nh)

        let netPath = CGMutablePath()
        netPath.move(to:    CGPoint(x: bNear.x - netBandHalfW, y: bNear.y))
        netPath.addLine(to: CGPoint(x: bFar.x  + netBandHalfW, y: bFar.y))
        netPath.addLine(to: CGPoint(x: tFar.x  + netBandHalfW, y: tFar.y))
        netPath.addLine(to: CGPoint(x: tNear.x - netBandHalfW, y: tNear.y))
        netPath.closeSubpath()
        ctx.setFillColor(CGColor(red: 0.75, green: 0.78, blue: 0.85, alpha: 0.28))
        ctx.addPath(netPath)
        ctx.fillPath()

        // Mesh strands — project horizontal lines across court width, visible as
        // short diagonal lines from near to far
        ctx.setStrokeColor(CGColor(red: 0.80, green: 0.83, blue: 0.90, alpha: 0.50))
        ctx.setLineWidth(0.7)
        let hSteps = 9
        for i in 1..<hSteps {
            let wy = CGFloat(i) / CGFloat(hSteps) * nh
            line(ctx, from: proj(0.5, 0, wy), to: proj(0.5, 1, wy))
        }

        // Vertical strands on near face
        ctx.setStrokeColor(CGColor(red: 0.80, green: 0.83, blue: 0.90, alpha: 0.30))
        let vSteps = 14
        for i in 0...vSteps {
            let wz = CGFloat(i) / CGFloat(vSteps)
            line(ctx, from: proj(0.5, wz, 0), to: proj(0.5, wz, nh))
        }

        // Top cable (white)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
        ctx.setLineWidth(3.0)
        line(ctx, from: tNear, to: tFar)

        // Bottom edge
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
        ctx.setLineWidth(1.8)
        line(ctx, from: bNear, to: bFar)

        // Net posts (circles at near and far top)
        ctx.setFillColor(CGColor(red: 0.70, green: 0.73, blue: 0.78, alpha: 1))
        fillCircle(ctx, at: tNear, r: 5)
        fillCircle(ctx, at: tFar,  r: CGFloat(5) * CGFloat(farScale))
        fillCircle(ctx, at: bNear, r: 4)
        fillCircle(ctx, at: bFar,  r: CGFloat(4) * CGFloat(farScale))
    }

    // MARK: - Ball shadow

    private func drawBallShadow(ctx: CGContext) {
        let sp = proj(ball.x, ball.z, 0)
        let fade = max(0, 1 - ball.y / 0.5)
        let s = scaleAt(ball.z)
        let rw: CGFloat = 13 * s * fade
        let rh: CGFloat = 4.5 * s * fade
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35 * fade))
        ctx.fillEllipse(in: CGRect(x: sp.x - rw, y: sp.y - rh, width: rw * 2, height: rh * 2))
    }

    // MARK: - Trail

    private func drawTrail(ctx: CGContext) {
        let count = trailPoints.count
        for (i, t) in trailPoints.enumerated() {
            let frac = CGFloat(i) / CGFloat(count)
            let s = scaleAt(t.z)
            let r = 10.0 * s * frac * 0.60
            let p = proj(t)
            ctx.setFillColor(CGColor(red: 1, green: 0.92, blue: 0.2, alpha: frac * 0.28))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Ball

    private func drawBall(ctx: CGContext) {
        let p = proj(ball)
        let s = scaleAt(ball.z)
        let r: CGFloat = 11 * s

        ctx.setFillColor(CGColor(red: 0.94, green: 0.91, blue: 0.14, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.72, alpha: 0.65))
        ctx.fillEllipse(in: CGRect(x: p.x - r * 0.4, y: p.y + r * 0.15, width: r * 0.75, height: r * 0.5))

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

    // MARK: - Paddle
    // From the sideline the paddle face points left/right (toward opponent).
    // We draw handle + face as a projected shape and rotate for the swing.

    private func drawPaddle(ctx: CGContext, state: PaddleState, atX wx: CGFloat, facingRight: Bool) {
        let s = scaleAt(state.z)
        let pivot = proj(wx, state.z, 0.18)   // handle base projected

        let faceH: CGFloat = 66 * s
        let faceW: CGFloat = 48 * s
        let handleLen: CGFloat = 36 * s
        let handleW:   CGFloat = 11 * s

        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: state.swingAngle * (facingRight ? 1 : -1))

        // Handle extends downward from pivot
        let handleRect = CGRect(x: -handleW / 2, y: -handleLen, width: handleW, height: handleLen)
        // Face sits on top of pivot
        let faceRect   = CGRect(x: -faceW / 2,   y: 0,          width: faceW,   height: faceH)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 4 * s, height: -5 * s), blur: 9 * s,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        // Handle
        ctx.setFillColor(CGColor(red: 0.30, green: 0.14, blue: 0.05, alpha: 1))
        ctx.addPath(CGPath(roundedRect: handleRect, cornerWidth: 4 * s, cornerHeight: 4 * s, transform: nil))
        ctx.fillPath()

        // Paddle edge
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        ctx.addPath(CGPath(roundedRect: faceRect, cornerWidth: 9 * s, cornerHeight: 9 * s, transform: nil))
        ctx.fillPath()

        ctx.restoreGState()

        // Paddle face (vivid blue)
        let inner = faceRect.insetBy(dx: 2 * s, dy: 2 * s)
        ctx.setFillColor(CGColor(red: 0.14, green: 0.36, blue: 0.82, alpha: 1))
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 7 * s, cornerHeight: 7 * s, transform: nil))
        ctx.fillPath()

        // Highlight
        let hl = CGRect(x: inner.minX + 3 * s, y: inner.midY,
                        width: inner.width - 6 * s, height: inner.height / 2 - 2 * s)
        ctx.setFillColor(CGColor(red: 0.30, green: 0.52, blue: 0.95, alpha: 0.38))
        ctx.addPath(CGPath(roundedRect: hl, cornerWidth: 5 * s, cornerHeight: 5 * s, transform: nil))
        ctx.fillPath()

        // Grip wraps
        ctx.setStrokeColor(CGColor(red: 0.18, green: 0.09, blue: 0.02, alpha: 0.60))
        ctx.setLineWidth(s)
        var wy = handleRect.minY + 4 * s
        while wy < handleRect.maxY - 2 * s {
            line(ctx, from: CGPoint(x: handleRect.minX + s, y: wy),
                      to:   CGPoint(x: handleRect.maxX - s, y: wy))
            wy += 5 * s
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

    private func fillQuad(_ ctx: CGContext,
                           _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint,
                           color: CGColor) {
        let p = CGMutablePath()
        p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.addLine(to: d)
        p.closeSubpath()
        ctx.setFillColor(color)
        ctx.addPath(p)
        ctx.fillPath()
    }

    private func strokeQuad(_ ctx: CGContext,
                             _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) {
        let p = CGMutablePath()
        p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.addLine(to: d)
        p.closeSubpath()
        ctx.addPath(p)
        ctx.strokePath()
    }

    // MARK: - ScreenSaverView

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
