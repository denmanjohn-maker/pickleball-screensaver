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
    var swingT: CGFloat = 0     // normalized swing time [0, 1+recovery]
    var swingAngle: CGFloat = 0 // rad from the horizontal contact pose: - = wound back/down, + = finish
    var faceDZ: CGFloat = 0     // paddle face-center depth offset from the body (world z)
    var faceY: CGFloat = 0.08   // paddle face-center height (world y); default must match restFaceY
    var contactY: CGFloat = 0.12 // predicted ball height at contact — face center meets it there
    var armed = true            // ready to start a new backswing
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

    // Camera — 10 ft behind the near-left court corner (on the center-corner diagonal,
    // extended), looking down 45° at the court center
    private let ftPerX: CGFloat = 10.0    // feet per world-x unit (half court width)
    private let ftPerZ: CGFloat = 44.0    // feet per world-z unit (court length)
    private let ftPerY: CGFloat = 9.375   // feet per world-y unit (netHeight 0.32 = 3 ft)
    private let camPitch:    CGFloat = .pi / 4   // downward tilt from horizontal
    private let camBehindFt: CGFloat = 10.0      // horizontal distance beyond the corner

    // Players (invisible bodies holding the paddles; both right-handed)
    private let reach:     CGFloat = 0.18     // paddle contact offset from body (1.8 ft)
    private let hitWindow: CGFloat = 0.45     // max |ball.x - contact point| for a clean hit

    // Real-world equipment sizes
    private let paddleLenFt: CGFloat = 16.0 / 12.0   // regulation ~16 in overall
    private let ballRFt: CGFloat = 0.121 * 1.75      // regulation 1.45 in radius, drawn 1.75x for visibility
    private var minBallPx: CGFloat { max(2.0, bounds.height * 0.004) }   // keep the ball visible at the far court

    // Swing shape — the paddle sweeps back and down into the windup, then makes
    // one fluid low-to-high forward stroke. Ball contact lands at the exact
    // midpoint of that stroke with the face horizontal and the ball on the face
    // center; the finish is forward and up, then the paddle settles back to ready.
    // Angles are relative to the horizontal contact pose (0 = face at the net).
    private let swingDuration:  CGFloat = 0.60   // seconds, windup through finish
    private let backswingFrac:  CGFloat = 0.45   // fraction of the swing spent going back and down
    private var contactFrac: CGFloat { backswingFrac + (1 - backswingFrac) / 2 }
    private let recoveryFrac:   CGFloat = 0.50   // extra fraction to settle back to ready after the finish
    private let backswingAngle: CGFloat = -1.6   // rad, head hanging low behind the body
    private let followAngle:    CGFloat = 0.8    // rad, high finish past the net
    private let swingLen:       CGFloat = 0.075  // stroke depth each side of contact (≈3.3 ft)
    private let swingDrop:      CGFloat = 0.13   // how far below contact height the stroke bottoms out
    private let restFaceY:      CGFloat = 0.08   // face-center height at the ready position

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
        F3(l: (wz - 0.5) * ftPerZ, w: wx * ftPerX, y: wy * ftPerY)
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
        for (wx, wz) in [(-1.15, -0.05), (1.15, -0.05), (1.15, 1.05), (-1.15, 1.05)] {
            let u = unitProj(CGFloat(wx), CGFloat(wz), 0)
            minX = min(minX, u.x); maxX = max(maxX, u.x)
            minY = min(minY, u.y); maxY = max(maxY, u.y)
        }
        let W = bounds.width, H = bounds.height
        let focal = min(W * 0.94 / (maxX - minX), H * 0.72 / (maxY - minY))
        let xOff = W / 2 - focal * (minX + maxX) / 2
        let yOff = H * 0.60 - focal * (minY + maxY) / 2   // content centered above the overlays
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
            leftPlayer.contactY = max(0.03, ball.y)
            leftPlayer.swingPhase = true; leftPlayer.swingT = contactFrac
        } else {
            rightPlayer.x = ball.x + reach
            rightPlayer.contactY = max(0.03, ball.y)
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
            updateSwing(&leftPlayer,  side:  1, dt: dt)
            updateSwing(&rightPlayer, side: -1, dt: dt)
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

        updateSwing(&leftPlayer,  side:  1, dt: dt)
        updateSwing(&rightPlayer, side: -1, dt: dt)

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

    // Simulate the ball's height at depth targetZ (gravity + floor bounces)
    private func predictY(toZ targetZ: CGFloat) -> CGFloat {
        guard abs(bVel.z) > 0.0001 else { return ball.y }
        var t = (targetZ - ball.z) / bVel.z
        guard t > 0 else { return ball.y }
        var y = ball.y, vy = bVel.y
        let step: CGFloat = 1.0 / 120.0
        while t > 0 {
            let dt = min(step, t)
            y += vy * dt
            vy += gravity * dt
            if y < 0 { y = 0; vy = abs(vy) * bounceDamp }
            t -= dt
        }
        return y
    }

    private func returnBall(fromZ: CGFloat, goingFar: Bool, player: inout PlayerState) {
        ball.z = fromZ
        ball.y = max(ball.y, 0.02)
        let dir: CGFloat = goingFar ? 1 : -1
        let vy0 = launchVy(fromZ: fromZ, zSpd: zSpeed, margin: netHeight * CGFloat.random(in: 0.6...1.0))
        bVel.y = vy0
        bVel.z = dir * zSpeed
        bVel.x = CGFloat.random(in: -0.18...0.18)
        // The windup normally began contactFrac of a swing ago; if it didn't
        // (edge case), snap to the contact pose so the follow-through plays from impact.
        player.contactY = max(0.03, ball.y)   // face center meets the ball exactly here
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

        // Start the backswing so contact lands at the midpoint of the forward sweep
        let tta = (playerZ - ball.z) / bVel.z   // time to arrival, seconds
        guard tta > 0 else { return }
        if p.armed && tta <= contactFrac * swingDuration {
            // Forehand or backhand: which side of the body will the ball arrive on?
            p.stance = (predictX(toZ: playerZ) - p.x >= 0) ? 1 : -1
            // Aim the swing so the face center arrives at the ball's height
            p.contactY = min(0.55, max(0.03, predictY(toZ: playerZ)))
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

    // Advance the swing pose. The paddle face center traces the stroke path:
    // ready → back-and-down windup → one fluid low-to-high sweep whose midpoint
    // is ball contact (face horizontal, ball on the face center) → high forward
    // finish → settle back to ready. `side` is the direction of the net in
    // world z for this player (+1 left player, -1 right player).
    private func updateSwing(_ p: inout PlayerState, side: CGFloat, dt: CGFloat) {
        guard p.swingPhase else { return }
        p.swingT += dt / swingDuration
        let yLow  = max(0.03, p.contactY - swingDrop)
        let yHigh = p.contactY + (p.contactY - yLow)   // symmetric: contact at the sweep midpoint
        let t = p.swingT
        if t < backswingFrac {
            // Windup: paddle drifts back (away from the net) and down
            let e = smoothstep(t / backswingFrac)
            p.faceDZ = -side * swingLen * e
            p.faceY  = restFaceY + (yLow - restFaceY) * e
            p.swingAngle = backswingAngle * e
        } else if t < 1 {
            // Forward stroke: one continuous low-back → high-forward sweep,
            // fastest at the middle where the ball is struck. The angle is
            // interpolated piecewise so the face is exactly horizontal at the
            // midpoint despite the asymmetric windup/finish angles.
            let e = smoothstep((t - backswingFrac) / (1 - backswingFrac))
            p.faceDZ = side * swingLen * (2 * e - 1)
            p.faceY  = yLow + (yHigh - yLow) * e
            p.swingAngle = e < 0.5 ? backswingAngle * (1 - 2 * e)
                                   : followAngle * (2 * e - 1)
        } else if t < 1 + recoveryFrac {
            // Recovery: ease from the high finish back to the ready position
            let e = smoothstep((t - 1) / recoveryFrac)
            p.faceDZ = side * swingLen * (1 - e)
            p.faceY  = yHigh + (restFaceY - yHigh) * e
            p.swingAngle = followAngle * (1 - e)
        } else {
            p.swingPhase = false
            p.swingT = 0; p.swingAngle = 0; p.faceDZ = 0; p.faceY = restFaceY
        }
    }

    // Ease curve: gentle start and finish, peak velocity mid-segment
    private func smoothstep(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
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
        drawBallShadow(ctx: ctx)
        drawTrail(ctx: ctx)

        // Painter's algorithm: sprites beyond the net plane (wz > 0.5) render first,
        // then the net, then near-side sprites; each group sorted farthest-first.
        let sprites: [(wz: CGFloat, depth: CGFloat, draw: () -> Void)] = [
            (ball.z, unitProj(ball.x, ball.z, ball.y).depth,
             { self.drawBall(ctx: ctx) }),
            (leftPlayerZ, unitProj(paddleWx(leftPlayer, side: 1), leftPlayerZ, 0.1).depth,
             { self.drawPaddle(ctx: ctx, state: self.leftPlayer, wz: self.leftPlayerZ, side: 1) }),
            (rightPlayerZ, unitProj(paddleWx(rightPlayer, side: -1), rightPlayerZ, 0.1).depth,
             { self.drawPaddle(ctx: ctx, state: self.rightPlayer, wz: self.rightPlayerZ, side: -1) }),
        ]
        for s in sprites.filter({ $0.wz > 0.5 }).sorted(by: { $0.depth > $1.depth }) { s.draw() }
        drawNet(ctx: ctx)
        for s in sprites.filter({ $0.wz <= 0.5 }).sorted(by: { $0.depth > $1.depth }) { s.draw() }

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
                startCenter: CGPoint(x: rect.midX, y: rect.height * 0.60), startRadius: 0,
                endCenter:   CGPoint(x: rect.midX, y: rect.height * 0.60),
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

    // MARK: - Net (vertical band at z = 0.5, seen at an angle from the corner camera)

    // Regulation net height: 36 in at the sidelines sagging to 34 in at the center
    private func netTopY(_ wx: CGFloat) -> CGFloat {
        (34 + 2 * wx * wx) / (12 * ftPerY)
    }

    private func drawNet(ctx: CGContext) {
        let sagSteps = 16
        let topPts: [CGPoint] = (0...sagSteps).map { i in
            let wx = -1 + 2 * CGFloat(i) / CGFloat(sagSteps)
            return proj(wx, 0.5, netTopY(wx))
        }
        let bl = proj(-1, 0.5, 0); let br = proj(1, 0.5, 0)

        // Mesh body (top edge follows the sag)
        ctx.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 0.50))
        ctx.beginPath()
        ctx.move(to: bl)
        ctx.addLine(to: br)
        for p in topPts.reversed() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.fillPath()

        // Vertical strands
        ctx.setStrokeColor(CGColor(red: 0.16, green: 0.17, blue: 0.18, alpha: 0.65))
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

        // White top tape
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.setLineWidth(5.0)
        ctx.beginPath()
        for (i, p) in topPts.enumerated() {
            i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
        }
        ctx.strokePath()

        // Posts: center + sides
        drawPost(ctx, atX: 0)
        drawPost(ctx, atX: -1)
        drawPost(ctx, atX: 1)
    }

    private func drawPost(_ ctx: CGContext, atX wx: CGFloat) {
        let base = proj(wx, 0.5, 0)
        let top  = proj(wx, 0.5, netTopY(wx))
        let w: CGFloat = 0.25 * ppf(atWx: wx, atWz: 0.5)
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
        let count = trailPoints.count
        for (i, t) in trailPoints.enumerated() {
            let frac = CGFloat(i) / CGFloat(count)
            let r = max(minBallPx, ballRFt * ppf(atWx: t.x, atWz: t.z)) * frac
            let p = proj(t)
            ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: frac * 0.28))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: - Ball (yellow holed pickleball)

    private func drawBall(ctx: CGContext) {
        let p = proj(ball)
        let s = ppf(atWx: ball.x, atWz: ball.z)
        let r: CGFloat = max(minBallPx, ballRFt * s)
        let rim: CGFloat = max(0.6, r * 0.09)

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
        ctx.setFillColor(CGColor(red: 1, green: 0.96, blue: 0.55, alpha: 0.50))
        ctx.fillEllipse(in: CGRect(x: p.x - r * 0.38, y: p.y + r * 0.15,
                                   width: r * 0.76, height: r * 0.50))
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

    private func drawPaddle(ctx: CGContext, state: PlayerState, wz: CGFloat, side: CGFloat) {
        let wx = paddleWx(state, side: side)
        let hPx = paddleLenFt * ppf(atWx: wx, atWz: wz)
        let wPx = hPx * Self.paddleAspect

        // The face center rides the stroke path (back-and-down, low-to-high,
        // finish, recover); the grip pivot hangs off it along the paddle axis.
        // At contact the face is horizontal and the face center lands exactly
        // on the ball; at every other pose the same offset keeps the paddle
        // rotating rigidly about the grip.
        let face = proj(wx, wz + state.faceDZ, state.faceY)
        let faceCenterPx = (Self.paddleFaceCenterFrac - Self.paddlePivotFrac) * hPx
        // Rest pose is HORIZONTAL: face points at the net, handle toward the body.
        // The paddle axis lives in the world z-y plane (toward-net tilted by the
        // swing angle); project a short probe along it through the camera so the
        // on-screen rotation matches the perspective at either baseline.
        let kFt: CGFloat = 0.5   // probe length in feet
        let tip = proj(wx,
                       wz + state.faceDZ + side * cos(state.swingAngle) * kFt / ftPerZ,
                       state.faceY + sin(state.swingAngle) * kFt / ftPerY)
        let phi = atan2(tip.y - face.y, tip.x - face.x) - .pi / 2
        let pivot = CGPoint(x: face.x + faceCenterPx * sin(phi),
                            y: face.y - faceCenterPx * cos(phi))

        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: phi)
        // The far paddle is seen from its other side; mirror so the players
        // read as mirror images of each other
        if side < 0 { ctx.scaleBy(x: -1, y: 1) }

        // Sprite is authored upright: handle hangs DOWN from the grip pivot,
        // face extends UP; the image rect places the pivot at the grip junction
        let spriteRect = CGRect(x: -wPx / 2, y: -Self.paddlePivotFrac * hPx,
                                width: wPx, height: hPx)
        ctx.setShadow(offset: CGSize(width: 0.05 * hPx, height: -0.06 * hPx),
                      blur: 0.10 * hPx,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        if let img = Self.paddleImage {
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
        // Cap the block below the court's near apron edge (~0.24 H with the 45° camera)
        var curY = rect.height * 0.18
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
