import ScreenSaver
import AppKit

// MARK: - Types

private struct Vec3 {
    var x: CGFloat   // court width: -1 = left sideline, +1 = right sideline (0 = center line)
    var y: CGFloat   // height above floor
    var z: CGFloat   // depth: 0 = near baseline (bottom of screen), 1 = far baseline (top)
}

private struct PaddleState {
    var x: CGFloat = 0          // position across court width
    var swingAngle: CGFloat = 0
    var swingPhase = false
    var swingT: CGFloat = 0
}

// MARK: - Screensaver

class PickleballScreensaverView: ScreenSaverView {

    // Ball state
    private var ball = Vec3(x: 0, y: 0.0, z: 0.04)
    private var bVel = Vec3(x: 0, y: 0, z: 0.55)
    private var trailPoints: [Vec3] = []

    // Paddles — near (z≈0, bottom, large) and far (z≈1, top, small)
    private var nearPaddle = PaddleState()
    private var farPaddle  = PaddleState()

    // Physics
    private let gravity:    CGFloat = -2.6
    private let bounceDamp: CGFloat = 0.55
    private let netHeight:  CGFloat = 0.32
    private let zSpeed:     CGFloat = 0.52   // depth speed of the ball (units / sec)
    private let paddleSpeed: CGFloat = 1.30  // lateral tracking speed (units / sec)

    // Court depth landmarks (normalised over 44 ft court length)
    private let kitchenNearZ: CGFloat = 15.0 / 44.0   // ≈ 0.341
    private let kitchenFarZ:  CGFloat = 29.0 / 44.0   // ≈ 0.659
    private let nearPaddleZ:  CGFloat = 0.04
    private let farPaddleZ:   CGFloat = 0.96

    // Projection
    private let farScale:    CGFloat = 0.40   // perspective scale at far baseline
    private let nearFrac:    CGFloat = 0.14   // near baseline y / H (bottom)
    private let farFrac:     CGFloat = 0.80   // far baseline y / H (top)
    private let halfFrac:    CGFloat = 0.46   // half court width / W (at near baseline)
    private let heightScale: CGFloat = 360    // px per world Y unit (at near scale)

    // Colors (matched to reference photo)
    private let greenCourt = CGColor(red: 0.30, green: 0.53, blue: 0.40, alpha: 1)
    private let blueBox    = CGColor(red: 0.13, green: 0.32, blue: 0.62, alpha: 1)
    private let whiteLine  = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)

    // Ball spin
    private var ballSpin: CGFloat = 0

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
        wantsLayer = true
        resetRally(nearServes: true)
    }

    // MARK: - Projection (behind-baseline perspective, AppKit Y-up)

    private func scale(_ wz: CGFloat) -> CGFloat { 1.0 / (1.0 + (1.0 / farScale - 1.0) * wz) }

    private func proj(_ wx: CGFloat, _ wz: CGFloat, _ wy: CGFloat) -> CGPoint {
        let W = bounds.width, H = bounds.height
        let nearY = H * nearFrac
        let farY  = H * farFrac
        let s = scale(wz)
        let halfW = W * halfFrac
        let sx = W / 2 + wx * halfW * s
        let sy = nearY + (farY - nearY) * (1 - s) / (1 - farScale) + wy * heightScale * s
        return CGPoint(x: sx, y: sy)
    }

    private func proj(_ v: Vec3) -> CGPoint { proj(v.x, v.z, v.y) }

    // MARK: - Launch math
    // Solve vy0 so the ball is at height (netHeight+margin) when it reaches the net (z=0.5).
    // y(t) = vy0*t + 0.5*g*t² ; t = |0.5 - fromZ| / zSpd
    private func launchVy(fromZ: CGFloat, zSpd: CGFloat, margin: CGFloat) -> CGFloat {
        let tNet = max(0.0001, abs(0.5 - fromZ) / zSpd)
        return (netHeight + margin - 0.5 * gravity * tNet * tNet) / tNet
    }

    // MARK: - Reset

    private func resetRally(nearServes: Bool) {
        let startZ = nearServes ? nearPaddleZ : farPaddleZ
        let dir: CGFloat = nearServes ? 1 : -1
        ball = Vec3(x: CGFloat.random(in: -0.4...0.4), y: 0.02, z: startZ)
        let vy0 = launchVy(fromZ: startZ, zSpd: zSpeed, margin: netHeight * 0.7)
        bVel = Vec3(x: CGFloat.random(in: -0.1...0.1), y: vy0, z: dir * zSpeed)
        nearPaddle = PaddleState(x: 0, swingAngle: 0, swingPhase: false, swingT: 0)
        farPaddle  = PaddleState(x: 0, swingAngle: 0, swingPhase: false, swingT: 0)
        trailPoints.removeAll()
        faultTimer = 0
        ballSpin = 0
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

        let prevZ = ball.z

        // Integrate
        ball.y += bVel.y * dt
        bVel.y += gravity * dt
        ball.x += bVel.x * dt
        ball.z += bVel.z * dt

        // Floor bounce
        if ball.y < 0 {
            ball.y = 0
            bVel.y = abs(bVel.y) * bounceDamp
        }

        // Sideline bounce
        if ball.x < -1 { ball.x = -1; bVel.x =  abs(bVel.x) }
        if ball.x >  1 { ball.x =  1; bVel.x = -abs(bVel.x) }

        // Predictive paddle positioning: aim for ball's x when it reaches each baseline
        let predNear = predictX(toZ: nearPaddleZ)
        let predFar  = predictX(toZ: farPaddleZ)
        nearPaddle.x = moveVal(nearPaddle.x, toward: predNear, speed: paddleSpeed * dt, lo: -1, hi: 1)
        farPaddle.x  = moveVal(farPaddle.x,  toward: predFar,  speed: paddleSpeed * dt, lo: -1, hi: 1)

        updateSwing(&nearPaddle, dt: dt)
        updateSwing(&farPaddle,  dt: dt)

        // Net clearance safety check
        if (prevZ - 0.5) * (ball.z - 0.5) < 0 {
            let t = (0.5 - prevZ) / (ball.z - prevZ)
            let yAtNet = (ball.y - bVel.y * dt) + bVel.y * dt * t
            if yAtNet < netHeight { faultTimer = 1.0 }
        }

        // Hit detection — near paddle (ball arriving at bottom)
        if bVel.z < 0 && ball.z <= nearPaddleZ {
            if abs(ball.x - nearPaddle.x) < 0.5 {
                returnBall(fromZ: nearPaddleZ, goingFar: true, paddle: &nearPaddle)
                rallyCount += 1
            } else {
                faultTimer = 1.0
            }
        }

        // Hit detection — far paddle (ball arriving at top)
        if bVel.z > 0 && ball.z >= farPaddleZ {
            if abs(ball.x - farPaddle.x) < 0.5 {
                returnBall(fromZ: farPaddleZ, goingFar: false, paddle: &farPaddle)
                rallyCount += 1
            } else {
                faultTimer = 1.0
            }
        }

        // Spin
        let linearSpd = sqrt(bVel.x * bVel.x + bVel.z * bVel.z)
        ballSpin += linearSpd * 18.0 * dt

        // Trail
        trailPoints.append(ball)
        if trailPoints.count > 18 { trailPoints.removeFirst() }

        setNeedsDisplay(bounds)
    }

    // Extrapolate the ball's x to when it reaches depth targetZ (clamped to court)
    private func predictX(toZ targetZ: CGFloat) -> CGFloat {
        guard abs(bVel.z) > 0.0001 else { return ball.x }
        let t = (targetZ - ball.z) / bVel.z
        if t < 0 { return ball.x }
        var px = ball.x + bVel.x * t
        // account for one sideline reflection
        if px < -1 { px = -2 - px }
        if px >  1 { px =  2 - px }
        return max(-1, min(1, px))
    }

    private func returnBall(fromZ: CGFloat, goingFar: Bool, paddle: inout PaddleState) {
        ball.z = fromZ
        ball.y = max(ball.y, 0.02)
        let dir: CGFloat = goingFar ? 1 : -1
        let vy0 = launchVy(fromZ: fromZ, zSpd: zSpeed, margin: netHeight * CGFloat.random(in: 0.6...1.0))
        bVel.y = vy0
        bVel.z = dir * zSpeed
        bVel.x = CGFloat.random(in: -0.18...0.18)
        paddle.swingPhase = true
        paddle.swingT = 0
    }

    private func updateSwing(_ p: inout PaddleState, dt: CGFloat) {
        guard p.swingPhase else { return }
        p.swingT += dt * 3.0
        p.swingAngle = sin(p.swingT * .pi) * 1.0
        if p.swingT >= 1 { p.swingPhase = false; p.swingAngle = 0; p.swingT = 0 }
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
        drawPaddle(ctx: ctx, state: farPaddle, wz: farPaddleZ)    // far paddle behind net
        drawNet(ctx: ctx)
        drawBallShadow(ctx: ctx)
        drawTrail(ctx: ctx)
        drawBall(ctx: ctx)
        drawPaddle(ctx: ctx, state: nearPaddle, wz: nearPaddleZ)  // near paddle in front
        drawRallyCounter(ctx: ctx, rect: rect)
    }

    // MARK: - Background

    private func drawBackground(ctx: CGContext, rect: NSRect) {
        ctx.setFillColor(CGColor(red: 0.05, green: 0.09, blue: 0.10, alpha: 1))
        ctx.fill(rect)
        let colors = [CGColor(red: 0.10, green: 0.22, blue: 0.20, alpha: 0.55),
                      CGColor(red: 0.05, green: 0.09, blue: 0.10, alpha: 0)] as CFArray
        let locs: [CGFloat] = [0, 1]
        if let sp = CGColorSpace(name: CGColorSpace.sRGB),
           let gr = CGGradient(colorsSpace: sp, colors: colors, locations: locs) {
            ctx.drawRadialGradient(gr,
                startCenter: CGPoint(x: rect.midX, y: rect.height * 0.5), startRadius: 0,
                endCenter:   CGPoint(x: rect.midX, y: rect.height * 0.5),
                endRadius: max(rect.width, rect.height) * 0.7, options: [])
        }
    }

    // MARK: - Court

    private func drawCourt(ctx: CGContext) {
        // Green apron + court surface (one region)
        fillQuad(ctx,
                 proj(-1.15, -0.05, 0), proj(1.15, -0.05, 0),
                 proj(1.15, 1.05, 0),   proj(-1.15, 1.05, 0),
                 color: greenCourt)

        // Blue service boxes (kitchen between kitchenNearZ..kitchenFarZ stays green)
        // Near half: baseline (0) → near kitchen line
        fillQuad(ctx, proj(-1, 0, 0), proj(0, 0, 0), proj(0, kitchenNearZ, 0), proj(-1, kitchenNearZ, 0), color: blueBox)
        fillQuad(ctx, proj(0, 0, 0),  proj(1, 0, 0), proj(1, kitchenNearZ, 0), proj(0, kitchenNearZ, 0),  color: blueBox)
        // Far half: far kitchen line → far baseline (1)
        fillQuad(ctx, proj(-1, kitchenFarZ, 0), proj(0, kitchenFarZ, 0), proj(0, 1, 0), proj(-1, 1, 0), color: blueBox)
        fillQuad(ctx, proj(0, kitchenFarZ, 0),  proj(1, kitchenFarZ, 0), proj(1, 1, 0), proj(0, 1, 0),  color: blueBox)

        // White lines
        ctx.setStrokeColor(whiteLine)
        ctx.setLineWidth(2.5)
        strokeQuad(ctx, proj(-1, 0, 0), proj(1, 0, 0), proj(1, 1, 0), proj(-1, 1, 0))   // outer boundary

        // Kitchen lines (across width)
        line(ctx, from: proj(-1, kitchenNearZ, 0), to: proj(1, kitchenNearZ, 0))
        line(ctx, from: proj(-1, kitchenFarZ, 0),  to: proj(1, kitchenFarZ, 0))

        // Center service lines (service zones only)
        ctx.setLineWidth(2.0)
        line(ctx, from: proj(0, 0, 0),            to: proj(0, kitchenNearZ, 0))
        line(ctx, from: proj(0, kitchenFarZ, 0),  to: proj(0, 1, 0))
    }

    // MARK: - Net (horizontal band at z = 0.5)

    private func drawNet(ctx: CGContext) {
        let nh = netHeight
        let bl = proj(-1, 0.5, 0); let br = proj(1, 0.5, 0)
        let tl = proj(-1, 0.5, nh); let tr = proj(1, 0.5, nh)

        // Mesh body
        fillQuad(ctx, bl, br, tr, tl, color: CGColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 0.50))

        // Vertical strands
        ctx.setStrokeColor(CGColor(red: 0.16, green: 0.17, blue: 0.18, alpha: 0.65))
        ctx.setLineWidth(0.8)
        let vSteps = 55
        for i in 0...vSteps {
            let wx = -1 + 2 * CGFloat(i) / CGFloat(vSteps)
            line(ctx, from: proj(wx, 0.5, 0), to: proj(wx, 0.5, nh))
        }
        // Horizontal strands
        let hSteps = 10
        for i in 1..<hSteps {
            let wy = nh * CGFloat(i) / CGFloat(hSteps)
            line(ctx, from: proj(-1, 0.5, wy), to: proj(1, 0.5, wy))
        }

        // White top tape
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.setLineWidth(6.0)
        line(ctx, from: tl, to: tr)

        // Posts: center + sides
        drawPost(ctx, atX: 0)
        drawPost(ctx, atX: -1)
        drawPost(ctx, atX: 1)
    }

    private func drawPost(_ ctx: CGContext, atX wx: CGFloat) {
        let base = proj(wx, 0.5, 0)
        let top  = proj(wx, 0.5, netHeight)
        let w: CGFloat = 7 * scale(0.5)
        ctx.setStrokeColor(CGColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 1))
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        line(ctx, from: base, to: top)
        ctx.setLineCap(.butt)
    }

    // MARK: - Ball shadow

    private func drawBallShadow(ctx: CGContext) {
        let sp = proj(ball.x, ball.z, 0)
        let fade = max(0, 1 - ball.y / 0.6)
        let s = scale(ball.z)
        let rw: CGFloat = 26 * s * fade
        let rh: CGFloat = 10 * s * fade
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.32 * fade))
        ctx.fillEllipse(in: CGRect(x: sp.x - rw, y: sp.y - rh, width: rw * 2, height: rh * 2))
    }

    // MARK: - Trail

    private func drawTrail(ctx: CGContext) {
        let count = trailPoints.count
        for (i, t) in trailPoints.enumerated() {
            let frac = CGFloat(i) / CGFloat(count)
            let s = scale(t.z)
            let r = 20.0 * s * frac * 0.6
            let p = proj(t)
            ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: frac * 0.28))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Ball (yellow holed pickleball)

    private func drawBall(ctx: CGContext) {
        let p = proj(ball)
        let s = scale(ball.z)
        let r: CGFloat = 26 * s
        let rim: CGFloat = 1.8 * s

        // Dark outline ring
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: p.x - r - rim, y: p.y - r - rim,
                                   width: (r + rim) * 2, height: (r + rim) * 2))

        // Yellow body
        ctx.setFillColor(CGColor(red: 0.96, green: 0.82, blue: 0.05, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))

        // Transparent holes — punch through with .clear so the court shows through
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: ballSpin)
        ctx.setBlendMode(.clear)
        let hr: CGFloat = max(2.5, 4.0 * s)
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
        ctx.setFillColor(CGColor(red: 1, green: 0.96, blue: 0.55, alpha: 0.50))
        ctx.fillEllipse(in: CGRect(x: p.x - r * 0.38, y: p.y + r * 0.15,
                                   width: r * 0.76, height: r * 0.50))
    }

    // MARK: - Paddle (charcoal with skull & crossbones)

    private func drawPaddle(ctx: CGContext, state: PaddleState, wz: CGFloat) {
        let s = scale(wz)
        let pivot = proj(state.x, wz, 0.0)

        let faceW: CGFloat = 82 * s
        let faceH: CGFloat = 108 * s
        let handleLen: CGFloat = 58 * s
        let handleW:   CGFloat = 14 * s

        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: state.swingAngle)

        // Stack above the floor pivot: handle first, then face
        let handleRect = CGRect(x: -handleW / 2, y: 0,          width: handleW, height: handleLen)
        let faceRect   = CGRect(x: -faceW / 2,   y: handleLen,  width: faceW,   height: faceH)
        let faceCenter = CGPoint(x: 0, y: handleLen + faceH * 0.52)

        // Shadow pass
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 4 * s, height: -5 * s), blur: 9 * s,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        // Handle (charcoal)
        ctx.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.19, alpha: 1))
        ctx.addPath(CGPath(roundedRect: handleRect, cornerWidth: 4 * s, cornerHeight: 4 * s, transform: nil))
        ctx.fillPath()
        // Face (charcoal)
        ctx.setFillColor(CGColor(red: 0.17, green: 0.20, blue: 0.21, alpha: 1))
        ctx.addPath(CGPath(roundedRect: faceRect, cornerWidth: 12 * s, cornerHeight: 12 * s, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        // Inner panel (slightly lighter)
        let inner = faceRect.insetBy(dx: 3 * s, dy: 3 * s)
        ctx.setFillColor(CGColor(red: 0.21, green: 0.24, blue: 0.25, alpha: 1))
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 10 * s, cornerHeight: 10 * s, transform: nil))
        ctx.fillPath()

        // Skull & crossbones
        drawSkull(ctx, center: faceCenter, scale: s)

        // Grip stripes (diagonal)
        ctx.setStrokeColor(CGColor(red: 0.30, green: 0.32, blue: 0.33, alpha: 0.8))
        ctx.setLineWidth(2.0 * s)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: handleRect, cornerWidth: 4 * s, cornerHeight: 4 * s, transform: nil))
        ctx.clip()
        var gy = handleRect.minY - handleW
        while gy < handleRect.maxY + handleW {
            line(ctx, from: CGPoint(x: handleRect.minX - 2, y: gy),
                      to:   CGPoint(x: handleRect.maxX + 2, y: gy + handleW))
            gy += 6 * s
        }
        ctx.restoreGState()

        ctx.restoreGState()
    }

    private func drawSkull(_ ctx: CGContext, center: CGPoint, scale s: CGFloat) {
        let white = CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1)
        let dark  = CGColor(red: 0.17, green: 0.20, blue: 0.21, alpha: 1)
        let headR: CGFloat = 20 * s

        // Crossbones (two crossed capsules behind skull)
        ctx.setStrokeColor(white)
        ctx.setLineWidth(5 * s)
        ctx.setLineCap(.round)
        let bl = headR * 1.7
        for ang in [CGFloat.pi / 4, -CGFloat.pi / 4] {
            let dx = cos(ang) * bl, dy = sin(ang) * bl
            line(ctx, from: CGPoint(x: center.x - dx, y: center.y - dy),
                      to:   CGPoint(x: center.x + dx, y: center.y + dy))
        }
        // Bone knobs at the four ends
        ctx.setFillColor(white)
        for ang in [CGFloat.pi / 4, 3 * CGFloat.pi / 4, 5 * CGFloat.pi / 4, 7 * CGFloat.pi / 4] {
            let dx = cos(ang) * bl, dy = sin(ang) * bl
            let kr = 3.2 * s
            ctx.fillEllipse(in: CGRect(x: center.x + dx - kr, y: center.y + dy - kr, width: kr * 2, height: kr * 2))
        }
        ctx.setLineCap(.butt)

        // Skull head
        ctx.setFillColor(white)
        ctx.fillEllipse(in: CGRect(x: center.x - headR, y: center.y - headR * 0.85,
                                   width: headR * 2, height: headR * 1.85))
        // Jaw
        ctx.fillEllipse(in: CGRect(x: center.x - headR * 0.55, y: center.y - headR * 1.25,
                                   width: headR * 1.1, height: headR * 0.7))

        // Eyes
        ctx.setFillColor(dark)
        let eyeR = headR * 0.32
        ctx.fillEllipse(in: CGRect(x: center.x - headR * 0.5 - eyeR, y: center.y + headR * 0.1 - eyeR,
                                   width: eyeR * 2, height: eyeR * 2))
        ctx.fillEllipse(in: CGRect(x: center.x + headR * 0.5 - eyeR, y: center.y + headR * 0.1 - eyeR,
                                   width: eyeR * 2, height: eyeR * 2))
        // Nose
        let nb = headR * 0.18
        ctx.beginPath()
        ctx.move(to: CGPoint(x: center.x, y: center.y - headR * 0.05))
        ctx.addLine(to: CGPoint(x: center.x - nb, y: center.y - headR * 0.45))
        ctx.addLine(to: CGPoint(x: center.x + nb, y: center.y - headR * 0.45))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - Rally counter

    private func drawRallyCounter(ctx: CGContext, rect: NSRect) {
        let label = "Rally  \(rallyCount)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.45)
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.height * 0.04))
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

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
