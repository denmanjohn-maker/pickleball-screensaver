import ScreenSaver
import AppKit
import EventKit

// MARK: - Types

private struct Vec3 {
    var x: CGFloat   // court width: -1 = left sideline, +1 = right sideline (0 = center line)
    var y: CGFloat   // height above floor
    var z: CGFloat   // depth: 0 = near baseline (bottom of screen), 1 = far baseline (top)
}

private struct PlayerState {
    var x: CGFloat = 0          // body position across court width
    var stance: CGFloat = 1     // contact-offset side for this swing: +1 = wx+ side, -1 = wx- side
    var swingPhase = false
    var swingT: CGFloat = 0     // normalized swing time [0, 1]
    var swingAngle: CGFloat = 0
    var pivotLift: CGFloat = 0  // extra grip height during the low-to-high sweep
    var armed = true            // ready to start a new backswing
}

// MARK: - Screensaver

class PickleballScreensaverView: ScreenSaverView {

    // Ball state
    private var ball = Vec3(x: 0, y: 0.0, z: 0.04)
    private var bVel = Vec3(x: 0, y: 0, z: 0.55)
    private var trailPoints: [Vec3] = []

    // Invisible players — left (z≈0, screen left) and right (z≈1, screen right).
    // Both are right-handed: the left player faces +z so their forehand side is +x;
    // the right player faces -z so theirs is -x. `side` (+1 left / -1 right) encodes both.
    private var leftPlayer  = PlayerState()
    private var rightPlayer = PlayerState()

    // Physics
    private let gravity:    CGFloat = -2.6
    private let bounceDamp: CGFloat = 0.55
    private let netHeight:  CGFloat = 0.32
    private let zSpeed:     CGFloat = 0.52   // depth speed of the ball (units / sec)
    private let paddleSpeed: CGFloat = 1.30  // lateral tracking speed (units / sec)

    // Court depth landmarks (normalised over 44 ft court length)
    private let kitchenNearZ: CGFloat = 15.0 / 44.0   // ≈ 0.341
    private let kitchenFarZ:  CGFloat = 29.0 / 44.0   // ≈ 0.659
    private let leftPlayerZ:  CGFloat = 0.04
    private let rightPlayerZ: CGFloat = 0.96

    // Camera — side view from beyond the near sideline at midcourt, 6 ft eye height
    private let ftPerX: CGFloat = 10.0    // feet per world-x unit (half court width)
    private let ftPerZ: CGFloat = 44.0    // feet per world-z unit (court length)
    private let ftPerY: CGFloat = 9.375   // feet per world-y unit (netHeight 0.32 = 3 ft)
    private let eyeHeightFt: CGFloat = 6.0
    private let camDist:     CGFloat = 40.0   // ft from court centerline (30 ft to near sideline)
    private let horizonFrac: CGFloat = 0.58   // screen y of eye level (fraction of height)

    // Players (invisible bodies holding the paddles; both right-handed)
    private let reach:     CGFloat = 0.18     // paddle contact offset from body (1.8 ft)
    private let hitWindow: CGFloat = 0.45     // max |ball.x - contact point| for a clean hit

    // Swing timing — low-to-high arc with ball contact 3/4 of the way through
    private let swingDuration:  CGFloat = 0.45   // seconds
    private let contactFrac:    CGFloat = 0.75   // fraction of swing at which contact occurs
    private let backswingAngle: CGFloat = -1.1   // rad, paddle tipped low behind the body
    private let followAngle:    CGFloat = 0.8    // rad, high finish toward the net

    // Colors (matched to reference photo)
    private let greenCourt = CGColor(red: 0.30, green: 0.53, blue: 0.40, alpha: 1)
    private let blueBox    = CGColor(red: 0.13, green: 0.32, blue: 0.62, alpha: 1)
    private let whiteLine  = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)

    // Calendar
    private let eventStore = EKEventStore()
    private var todayEvents: [EKEvent] = []

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
        resetRally(leftServes: true)
        fetchTodayEvents()
    }

    private func fetchTodayEvents() {
        let request = { [weak self] in
            guard let self else { return }
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            let end   = cal.date(byAdding: .day, value: 1, to: start)!
            let pred  = self.eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = self.eventStore.events(matching: pred)
                .sorted { $0.startDate < $1.startDate }
            DispatchQueue.main.async { self.todayEvents = events }
        }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            request()
        } else {
            eventStore.requestFullAccessToEvents { granted, _ in
                if granted { request() }
            }
        }
    }

    // MARK: - Projection (side-on pinhole camera at midcourt, AppKit Y-up)
    // Level optical axis with a shifted principal point (horizonFrac), so straight
    // world lines stay straight on screen — no rotation matrix needed.

    // Derived from bounds so the whole court always fits horizontally: the widest
    // content is the apron corner wx = -1.15 (28.5 ft deep) at wz = 1.05 (24.2 ft out).
    private var focal: CGFloat {
        (bounds.width / 2) * (camDist - 11.5) / 24.2 * 0.95
    }

    private var horizonY: CGFloat { bounds.height * horizonFrac }

    // Pixels per foot for sprite sizing at a given court-width position
    private func ppf(atWx wx: CGFloat) -> CGFloat { focal / (camDist + wx * ftPerX) }

    private func proj(_ wx: CGFloat, _ wz: CGFloat, _ wy: CGFloat) -> CGPoint {
        let cx = (wz - 0.5) * ftPerZ         // court length -> screen x
        let cy = wy * ftPerY - eyeHeightFt   // height relative to eye
        let cz = camDist + wx * ftPerX       // court width -> camera depth
        return CGPoint(x: bounds.width / 2 + focal * cx / cz,
                       y: horizonY + focal * cy / cz)
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

    private func resetRally(leftServes: Bool) {
        let startZ = leftServes ? leftPlayerZ : rightPlayerZ
        let dir: CGFloat = leftServes ? 1 : -1
        ball = Vec3(x: CGFloat.random(in: -0.4...0.4), y: 0.02, z: startZ)
        let vy0 = launchVy(fromZ: startZ, zSpd: zSpeed, margin: netHeight * 0.7)
        bVel = Vec3(x: CGFloat.random(in: -0.1...0.1), y: vy0, z: dir * zSpeed)
        leftPlayer  = PlayerState()
        rightPlayer = PlayerState()
        // Server plays a follow-through from the contact pose
        if leftServes {
            leftPlayer.x = ball.x - reach
            leftPlayer.swingPhase = true; leftPlayer.swingT = contactFrac
        } else {
            rightPlayer.x = ball.x + reach
            rightPlayer.swingPhase = true; rightPlayer.swingT = contactFrac
        }
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
            // Let an in-progress swing finish (reads as a natural whiff)
            updateSwing(&leftPlayer, dt: dt)
            updateSwing(&rightPlayer, dt: dt)
            if faultTimer <= 0 { resetRally(leftServes: Bool.random()) }
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

        // Invisible players run to intercept and wind up their swings
        updatePlayer(&leftPlayer,  playerZ: leftPlayerZ,  side:  1, approaching: bVel.z < 0, dt: dt)
        updatePlayer(&rightPlayer, playerZ: rightPlayerZ, side: -1, approaching: bVel.z > 0, dt: dt)

        updateSwing(&leftPlayer,  dt: dt)
        updateSwing(&rightPlayer, dt: dt)

        // Net clearance safety check
        if (prevZ - 0.5) * (ball.z - 0.5) < 0 {
            let t = (0.5 - prevZ) / (ball.z - prevZ)
            let yAtNet = (ball.y - bVel.y * dt) + bVel.y * dt * t
            if yAtNet < netHeight { faultTimer = 1.0 }
        }

        // Hit detection — left player (ball arriving at screen left)
        if bVel.z < 0 && ball.z <= leftPlayerZ {
            if abs(ball.x - contactX(leftPlayer, side: 1)) < hitWindow {
                returnBall(fromZ: leftPlayerZ, goingFar: true, player: &leftPlayer)
                rallyCount += 1
            } else {
                faultTimer = 1.0
            }
        }

        // Hit detection — right player (ball arriving at screen right)
        if bVel.z > 0 && ball.z >= rightPlayerZ {
            if abs(ball.x - contactX(rightPlayer, side: -1)) < hitWindow {
                returnBall(fromZ: rightPlayerZ, goingFar: false, player: &rightPlayer)
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

    private func returnBall(fromZ: CGFloat, goingFar: Bool, player: inout PlayerState) {
        ball.z = fromZ
        ball.y = max(ball.y, 0.02)
        let dir: CGFloat = goingFar ? 1 : -1
        let vy0 = launchVy(fromZ: fromZ, zSpd: zSpeed, margin: netHeight * CGFloat.random(in: 0.6...1.0))
        bVel.y = vy0
        bVel.z = dir * zSpeed
        bVel.x = CGFloat.random(in: -0.18...0.18)
        // The windup normally began 0.75 of a swing ago; if it didn't (edge case),
        // snap to the contact pose so the follow-through always plays from impact.
        if !player.swingPhase || player.swingT < contactFrac {
            player.swingPhase = true
            player.swingT = contactFrac
        }
    }

    // Body movement + swing anticipation for one invisible player.
    // side: +1 = left player (faces +z), -1 = right player (faces -z).
    // For right-handed players the forehand side in world-x equals `side`.
    private func updatePlayer(_ p: inout PlayerState, playerZ: CGFloat, side: CGFloat,
                              approaching: Bool, dt: CGFloat) {
        // Run so the forehand contact point meets the predicted ball; drift home otherwise
        let target = approaching ? predictX(toZ: playerZ) - side * reach : 0
        let spd = paddleSpeed * dt * (approaching ? 1.0 : 0.6)
        p.x = moveVal(p.x, toward: target, speed: spd, lo: -1, hi: 1)

        guard approaching else { p.armed = true; return }

        // Start the backswing so contact lands 3/4 of the way through the swing
        let tta = (playerZ - ball.z) / bVel.z   // time to arrival, seconds
        guard tta > 0 else { return }
        if p.armed && tta <= contactFrac * swingDuration {
            // Forehand or backhand: which side of the body will the ball arrive on?
            p.stance = (predictX(toZ: playerZ) - p.x >= 0) ? 1 : -1
            p.swingPhase = true
            p.swingT = max(0, contactFrac - tta / swingDuration)  // frame-quantization catch-up
            p.armed = false
        }
    }

    // Where this player's paddle meets the ball, given their current stance
    private func contactX(_ p: PlayerState, side: CGFloat) -> CGFloat {
        p.x + (p.swingPhase ? p.stance : side) * reach
    }

    // Where the paddle is drawn: at the contact offset while swinging,
    // otherwise held ready slightly on the forehand side
    private func paddleWx(_ p: PlayerState, side: CGFloat) -> CGFloat {
        p.x + (p.swingPhase ? p.stance : side * 0.7) * reach
    }

    private func updateSwing(_ p: inout PlayerState, dt: CGFloat) {
        guard p.swingPhase else { return }
        p.swingT += dt / swingDuration
        let t = min(p.swingT, 1)
        if t < contactFrac {
            // Backswing: accelerate from low-back ready into contact (angle 0 at contact)
            let u = t / contactFrac
            p.swingAngle = backswingAngle * (1 - u * u)
            p.pivotLift = 0.05 * u
        } else {
            // Follow-through: decelerate up and forward
            let u = (t - contactFrac) / (1 - contactFrac)
            p.swingAngle = followAngle * (1 - (1 - u) * (1 - u))
            p.pivotLift = 0.05 + 0.10 * u
        }
        if p.swingT >= 1 { p.swingPhase = false; p.swingAngle = 0; p.swingT = 0; p.pivotLift = 0 }
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
        // The net plane contains the camera, so it can never occlude (or be occluded
        // by) anything off its plane — safe to draw before all sprites.
        drawNet(ctx: ctx)
        drawBallShadow(ctx: ctx)
        drawTrail(ctx: ctx)

        // Painter's sort: court width is the camera depth axis; draw farthest (largest wx) first
        let sprites: [(wx: CGFloat, draw: () -> Void)] = [
            (ball.x, { self.drawBall(ctx: ctx) }),
            (paddleWx(leftPlayer, side: 1),
             { self.drawPaddle(ctx: ctx, state: self.leftPlayer, wz: self.leftPlayerZ, side: 1) }),
            (paddleWx(rightPlayer, side: -1),
             { self.drawPaddle(ctx: ctx, state: self.rightPlayer, wz: self.rightPlayerZ, side: -1) }),
        ]
        for sprite in sprites.sorted(by: { $0.wx > $1.wx }) { sprite.draw() }

        drawClock(ctx: ctx, rect: rect)
        drawCalendar(ctx: ctx, rect: rect)
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
                startCenter: CGPoint(x: rect.midX, y: horizonY), startRadius: 0,
                endCenter:   CGPoint(x: rect.midX, y: horizonY),
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

        // Court surface texture — perspective-correct horizontal + vertical grain lines
        ctx.saveGState()
        let courtPath = CGMutablePath()
        courtPath.move(to: proj(-1.15, -0.05, 0)); courtPath.addLine(to: proj(1.15, -0.05, 0))
        courtPath.addLine(to: proj(1.15, 1.05, 0)); courtPath.addLine(to: proj(-1.15, 1.05, 0))
        courtPath.closeSubpath()
        ctx.addPath(courtPath); ctx.clip()

        // Horizontal rows (follow court depth perspective)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
        ctx.setLineWidth(0.7)
        var tz: CGFloat = -0.02
        while tz <= 1.1 {
            line(ctx, from: proj(-1.3, tz, 0), to: proj(1.3, tz, 0))
            tz += 0.028
        }

        // Vertical columns (fixed-width in world-x, narrow toward the far end)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.08))
        ctx.setLineWidth(0.5)
        var tx: CGFloat = -1.15
        while tx <= 1.15 {
            line(ctx, from: proj(tx, -0.05, 0), to: proj(tx, 1.05, 0))
            tx += 0.07
        }

        ctx.restoreGState()

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

    // MARK: - Net (edge-on vertical sliver at z = 0.5, screen center)

    private func drawNet(ctx: CGContext) {
        let nh = netHeight
        // All net points share screen x = W/2 (the net plane contains the camera);
        // the visible extent runs from the near-sideline base up to the far-sideline top.
        let baseNear = proj(-1, 0.5, 0)
        let topNear  = proj(-1, 0.5, nh)
        let topFar   = proj(1, 0.5, nh)

        // Far post behind the mesh
        drawPost(ctx, atX: 1)

        // Mesh body — thin vertical band
        let bandHalf = max(1.0, 0.06 * ppf(atWx: 0))
        ctx.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 0.80))
        ctx.fill(CGRect(x: baseNear.x - bandHalf, y: baseNear.y,
                        width: bandHalf * 2, height: topFar.y - baseNear.y))

        // White top tape seen edge-on (near-sideline top to far-sideline top)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.setLineWidth(4.0)
        line(ctx, from: topNear, to: topFar)

        // Near post in front
        drawPost(ctx, atX: -1)
    }

    private func drawPost(_ ctx: CGContext, atX wx: CGFloat) {
        let base = proj(wx, 0.5, 0)
        let top  = proj(wx, 0.5, netHeight)
        let w: CGFloat = 0.25 * ppf(atWx: wx)
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
        let s = ppf(atWx: ball.x)
        let rw: CGFloat = 0.55 * s * fade
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
        let count = trailPoints.count
        for (i, t) in trailPoints.enumerated() {
            let frac = CGFloat(i) / CGFloat(count)
            let r = 0.40 * ppf(atWx: t.x) * frac
            let p = proj(t)
            ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: frac * 0.28))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Ball (yellow holed pickleball)

    private func drawBall(ctx: CGContext) {
        let p = proj(ball)
        let s = ppf(atWx: ball.x)
        let r: CGFloat = 0.60 * s
        let rim: CGFloat = 0.05 * s

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
        let hr: CGFloat = max(1.5, r * 0.15)
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

    private func drawPaddle(ctx: CGContext, state: PlayerState, wz: CGFloat, side: CGFloat) {
        let wx = paddleWx(state, side: side)
        let s = ppf(atWx: wx) / 32.0   // art was authored at ~32 px/ft
        // Grip pivot rises through the swing (low-to-high sweep)
        let pivot = proj(wx, wz, 0.06 + state.pivotLift)

        let faceW: CGFloat = 82 * s
        let faceH: CGFloat = 108 * s
        let handleLen: CGFloat = 58 * s
        let handleW:   CGFloat = 14 * s

        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        // Negate for the left player so the head tips back on the windup and
        // toward the net on the follow-through for both sides
        ctx.rotate(by: -side * state.swingAngle)

        // Handle hangs DOWN from grip pivot; face extends UP
        let handleRect = CGRect(x: -handleW / 2, y: -handleLen, width: handleW, height: handleLen)
        let faceRect   = CGRect(x: -faceW / 2,   y: 0,          width: faceW,   height: faceH)
        let faceCenter = CGPoint(x: 0, y: faceH * 0.52)

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

    // MARK: - Clock (bottom-left screen overlay)

    private func drawClock(ctx: CGContext, rect: NSRect) {
        let now = Date()
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "h:mm a"
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "EEEE, MMMM d"

        let m = rect.height * 0.05
        let tSize = rect.height * 0.075
        let dSize = tSize * 0.35

        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: tSize, weight: .thin),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.90)
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: dSize, weight: .light),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.65)
        ]

        let timeAS = NSAttributedString(string: timeFmt.string(from: now), attributes: timeAttrs)
        let dateAS = NSAttributedString(string: dateFmt.string(from: now), attributes: dateAttrs)

        dateAS.draw(at: NSPoint(x: m, y: m))
        timeAS.draw(at: NSPoint(x: m, y: m + dSize * 1.4))
    }

    // MARK: - Calendar (bottom-right screen overlay)

    private func drawCalendar(ctx: CGContext, rect: NSRect) {
        let m    = rect.height * 0.05
        let maxW = rect.width * 0.24
        let x    = rect.width - m - maxW

        let headerSize: CGFloat = rect.height * 0.022
        let rowSize:    CGFloat = rect.height * 0.018
        let lineH       = rowSize * 1.45

        let timeFmt = DateFormatter(); timeFmt.dateFormat = "h:mm a"

        // "TODAY" header at the top of the block
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: headerSize, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.55)
        ]
        let headerStr = NSAttributedString(string: "TODAY", attributes: headerAttrs)
        var curY = rect.height * 0.28
        headerStr.draw(at: NSPoint(x: x, y: curY))
        curY -= headerSize * 0.4

        // Divider line
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.20))
        ctx.setLineWidth(0.8)
        line(ctx, from: CGPoint(x: x, y: curY), to: CGPoint(x: x + maxW, y: curY))
        curY -= rowSize * 0.6

        let rowAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: rowSize, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.85)
        ]
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: rowSize * 0.80, weight: .light),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.50)
        ]

        if todayEvents.isEmpty {
            let none = NSAttributedString(string: "No events", attributes: timeAttrs)
            none.draw(at: NSPoint(x: x, y: curY - lineH))
        } else {
            for event in todayEvents {
                curY -= lineH
                if curY < m { break }

                // Time label
                let timeStr = event.isAllDay ? "All day" : timeFmt.string(from: event.startDate)
                NSAttributedString(string: timeStr, attributes: timeAttrs)
                    .draw(at: NSPoint(x: x, y: curY))

                // Event title (truncated to fit box width)
                let titleX = x + rowSize * 4.5
                let titleAS = NSAttributedString(string: event.title ?? "", attributes: rowAttrs)
                let titleRect = CGRect(x: titleX, y: curY, width: maxW - rowSize * 4.5, height: lineH)
                titleAS.draw(with: titleRect, options: .truncatesLastVisibleLine)
            }
        }
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
