import ScreenSaver
import AppKit
import EventKit
import CoreImage
import CoreImage.CIFilterBuiltins

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
    private let netHeight:  CGFloat = 0.32   // sideline/post height (36 in); netTopY(_:) gives the sagging top
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

    // Real-world equipment sizes (drawn intentionally oversized for readability)
    private let paddleLenFt: CGFloat = (16.0 / 12.0) * 2.0   // regulation ~16 in, drawn 2x
    private let ballRFt: CGFloat = 0.121 * 3.5               // regulation 1.45 in radius, drawn 3.5x
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
    private let grayApron  = CGColor(red: 0.20, green: 0.21, blue: 0.22, alpha: 1)
    private let blueBox    = CGColor(red: 0.13, green: 0.32, blue: 0.62, alpha: 1)
    private let whiteLine  = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)

    // Calendar (refetched every 5 min and on EKEventStoreChanged)
    private let eventStore = EKEventStore()
    private var todayEvents: [EKEvent] = []
    private var tomorrowEvents: [EKEvent] = []
    private var lastEventFetch: TimeInterval = 0

    // Weather (fetched by WeatherProvider from the animation loop)
    private var weatherProvider: WeatherProvider?

    // Rotating pickleball facts
    private var tipsEnabled = true
    private var tipOrder = Array(PickleballFacts.all.indices).shuffled()
    private var tipIndex = 0
    private var tipTimer: CGFloat = 0
    private let tipPeriod: CGFloat = 30.0
    private let tipFadeSecs: CGFloat = 0.5

    // Drill of the day (deterministic per calendar day)
    private var drillEnabled = true
    private var drillLevel = "all"

    // Shared formatters and accent — the overlays redraw every frame
    private let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    private let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f }()
    private let accentYellow = NSColor(calibratedRed: 0.96, green: 0.82, blue: 0.05, alpha: 1)

    // Ball spin
    private var ballSpin: CGFloat = 0

    // Rally state
    private var lastFrameTime: TimeInterval = 0
    private var faultTimer: CGFloat = 0
    private var rallyLostByLeft = false   // who lost the rally that just ended

    // Score — singles side-out scoring: only the server can score; games to 11, win by 2
    private var leftScore  = 0
    private var rightScore = 0
    private var leftServing = Bool.random()
    private var leftGames  = 0
    private var rightGames = 0
    private var gameBannerTimer: CGFloat = 0

    // Photo dissolve overlay — the source image is perspective-warped once per
    // appearance to exactly fill a court quadrant's trapezoid; drawPhoto then
    // just blits the cached result every frame.
    private var photoController: PhotoOverlayController?
    private var photoWarpedImage: CGImage?
    private var photoWarpedRect: CGRect = .zero
    private var photoQuadCorners: (nearLeft: CGPoint, nearRight: CGPoint, farLeft: CGPoint, farRight: CGPoint) = (.zero, .zero, .zero, .zero)
    private static let ciContext = CIContext()

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
        resetRally(leftServes: leftServing)
        fetchUpcomingEvents()
        NotificationCenter.default.addObserver(self, selector: #selector(eventStoreChanged),
                                               name: .EKEventStoreChanged, object: eventStore)
        let tipSettings = TipSettings.load()
        tipsEnabled = tipSettings.enabled
        drillEnabled = tipSettings.drillEnabled
        drillLevel = tipSettings.drillLevel
        // File loading and networking stay out of the tiny System Settings preview
        if !isPreview {
            let photoSettings = PhotoSettings.load()
            if photoSettings.source != .off {
                photoController = PhotoOverlayController(settings: photoSettings)
            }
            let weatherSettings = WeatherSettings.load()
            if weatherSettings.enabled && weatherSettings.hasLocation {
                weatherProvider = WeatherProvider(settings: weatherSettings)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func eventStoreChanged() {
        fetchUpcomingEvents()
    }

    private func fetchUpcomingEvents() {
        lastEventFetch = Date().timeIntervalSinceReferenceDate
        let request = { [weak self] in
            guard let self else { return }
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            let tomorrowStart = cal.date(byAdding: .day, value: 1, to: start)!
            let end = cal.date(byAdding: .day, value: 2, to: start)!
            let pred = self.eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = self.eventStore.events(matching: pred)
                .sorted { $0.startDate < $1.startDate }
            DispatchQueue.main.async {
                self.todayEvents = events.filter { $0.startDate < tomorrowStart }
                self.tomorrowEvents = events.filter { $0.startDate >= tomorrowStart }
            }
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

    // MARK: - Launch math
    // Solve vy0 so the ball is at height (netHeight+margin) when it reaches the net (z=0.5).
    // y(t) = fromY + vy0*t + 0.5*g*t² ; t = |0.5 - fromZ| / zSpd
    private func launchVy(fromZ: CGFloat, fromY: CGFloat, zSpd: CGFloat, margin: CGFloat) -> CGFloat {
        let tNet = max(0.0001, abs(0.5 - fromZ) / zSpd)
        return (netHeight + margin - fromY - 0.5 * gravity * tNet * tNet) / tNet
    }

    // MARK: - Reset

    private func resetRally(leftServes: Bool) {
        let startZ = leftServes ? leftPlayerZ : rightPlayerZ
        let dir: CGFloat = leftServes ? 1 : -1
        ball = Vec3(x: CGFloat.random(in: -0.4...0.4), y: 0.02, z: startZ)
        let vy0 = launchVy(fromZ: startZ, fromY: ball.y, zSpd: zSpeed, margin: netHeight * 0.7)
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

    // Resolve the finished rally under side-out rules: the server keeps serving
    // and scores when they win; losing the rally as the server is a side-out
    // (serve passes, no point). Games to 11, win by 2.
    private func scoreRally() {
        let serverLost = (leftServing == rallyLostByLeft)
        if serverLost {
            leftServing.toggle()
        } else {
            if leftServing { leftScore += 1 } else { rightScore += 1 }
            let server   = leftServing ? leftScore : rightScore
            let receiver = leftServing ? rightScore : leftScore
            if server >= 11 && server - receiver >= 2 {
                if leftServing { leftGames += 1 } else { rightGames += 1 }
                gameBannerTimer = 3.0
                leftScore = 0; rightScore = 0
                // Game winner (the server) serves first in the next game
            }
        }
        resetRally(leftServes: leftServing)
    }

    // MARK: - Animation loop

    override func animateOneFrame() {
        let now = Date().timeIntervalSinceReferenceDate
        let dt: CGFloat = lastFrameTime == 0 ? 1/60.0 : min(CGFloat(now - lastFrameTime), 0.05)
        lastFrameTime = now

        updatePhotoOverlay(dt: dt)   // before the faultTimer early return

        // Overlay content keeps updating even during the fault pause
        weatherProvider?.updateIfNeeded()
        updateTip(dt: dt)
        if now - lastEventFetch > 300 { fetchUpcomingEvents() }

        if gameBannerTimer > 0 { gameBannerTimer -= dt }

        if faultTimer > 0 {
            faultTimer -= dt
            // Let an in-progress swing finish (reads as a natural whiff)
            updateSwing(&leftPlayer,  side:  1, dt: dt)
            updateSwing(&rightPlayer, side: -1, dt: dt)
            if faultTimer <= 0 { scoreRally() }
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

        // Net clearance safety check (against the sagging top at the crossing point)
        if (prevZ - 0.5) * (ball.z - 0.5) < 0 {
            let t = (0.5 - prevZ) / (ball.z - prevZ)
            let yAtNet = (ball.y - bVel.y * dt) + bVel.y * dt * t
            if yAtNet < netTopY(ball.x) {
                faultTimer = 1.0
                rallyLostByLeft = bVel.z > 0   // netted shot came off the left player
            }
        }

        // Hit detection — left player (ball arriving at screen left)
        if bVel.z < 0 && ball.z <= leftPlayerZ {
            if abs(ball.x - contactX(leftPlayer, side: 1)) < hitWindow {
                returnBall(fromZ: leftPlayerZ, goingFar: true, player: &leftPlayer)
            } else {
                faultTimer = 1.0
                rallyLostByLeft = true         // failed return
            }
        }

        // Hit detection — right player (ball arriving at screen right)
        if bVel.z > 0 && ball.z >= rightPlayerZ {
            if abs(ball.x - contactX(rightPlayer, side: -1)) < hitWindow {
                returnBall(fromZ: rightPlayerZ, goingFar: false, player: &rightPlayer)
            } else {
                faultTimer = 1.0
                rallyLostByLeft = false        // failed return
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
        // Mostly clean returns; occasionally one is netted, which ends the rally
        // and drives the scoring (the clearance check attributes the fault)
        let margin = CGFloat.random(in: 0...1) < 0.08
            ? netHeight * CGFloat.random(in: -0.15 ... -0.03)
            : netHeight * CGFloat.random(in: 0.6...1.0)
        let vy0 = launchVy(fromZ: fromZ, fromY: ball.y, zSpd: zSpeed, margin: margin)
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
        drawPhoto(ctx: ctx)   // under ball, net, paddles, and overlays
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

        // Widget-style left rail: clock hero, then agenda / weather cards
        // flowing down, with the facts card pinned to the bottom margin.
        let rail = railMetrics(rect)
        var railY = rect.height * 0.95
        railY = drawClock(ctx: ctx, rect: rect, rail: rail, top: railY) - rail.gap
        railY = drawAgenda(ctx: ctx, rect: rect, rail: rail, top: railY) - rail.gap
        _ = drawWeather(ctx: ctx, rect: rect, rail: rail, top: railY)
        let tipTop = drawTip(ctx: ctx, rect: rect, rail: rail)
        drawDrill(ctx: ctx, rect: rect, rail: rail, bottom: tipTop + rail.gap)
        drawScoreboard(ctx: ctx, rect: rect)
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
        // Dark gray apron (outside the lines), green court surface inside
        fillQuad(ctx,
                 proj(-1.15, -0.05, 0), proj(1.15, -0.05, 0),
                 proj(1.15, 1.05, 0),   proj(-1.15, 1.05, 0),
                 color: grayApron)
        fillQuad(ctx,
                 proj(-1, 0, 0), proj(1, 0, 0),
                 proj(1, 1, 0),  proj(-1, 1, 0),
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
        // The on-screen rotation comes from projecting a probe along the paddle
        // axis (toward-net tilted by the swing angle). The corner camera projects
        // the far player's toward-net axis downward into the court, which reads
        // as the paddle hanging at the floor, so the far pose is evaluated
        // mirrored through the net onto the near court and the angle reflected —
        // both players then read as screen-space mirror images.
        let kFt: CGFloat = 0.5   // probe length in feet
        let zBase = side > 0 ? wz + state.faceDZ : 1 - (wz + state.faceDZ)
        let base = proj(wx, zBase, state.faceY)
        let tip  = proj(wx, zBase + cos(state.swingAngle) * kFt / ftPerZ,
                        state.faceY + sin(state.swingAngle) * kFt / ftPerY)
        let phiNear = atan2(tip.y - base.y, tip.x - base.x) - .pi / 2
        let phi = side > 0 ? phiNear : -phiNear
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

    // MARK: - Overlay style (widget-style left rail)

    private struct Rail { var x, width, pad, corner, gap: CGFloat }

    private func railMetrics(_ rect: NSRect) -> Rail {
        Rail(x: rect.height * 0.05,
             width: min(rect.width * 0.24, rect.height * 0.55),
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
            .foregroundColor: (color ?? NSColor.white).withAlphaComponent(alpha),
        ]
        if kern != 0 { attrs[.kern] = kern }
        return attrs
    }

    // Small ALL-CAPS section header with wide tracking
    private func kickerAttrs(_ size: CGFloat, color: NSColor? = nil,
                             alpha: CGFloat = 0.40) -> [NSAttributedString.Key: Any] {
        textAttrs(size, .semibold, alpha: alpha, color: color, kern: size * 0.14)
    }

    // Translucent rounded "glass" panel; returns the padded content rect
    @discardableResult
    private func drawCard(_ ctx: CGContext, _ rail: Rail, top: CGFloat, height: CGFloat) -> CGRect {
        let rect = CGRect(x: rail.x, y: top - height, width: rail.width, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: rail.corner, cornerHeight: rail.corner,
                          transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -rail.pad * 0.3), blur: rail.pad,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
        ctx.setLineWidth(1)
        ctx.addPath(path); ctx.strokePath()
        return rect.insetBy(dx: rail.pad, dy: rail.pad)
    }

    // Tinted SF Symbol anchored at its bottom-left corner; returns the drawn rect
    @discardableResult
    private func drawSymbol(_ name: String, at origin: CGPoint, size: CGFloat,
                            alpha: CGFloat, color: NSColor = .white) -> CGRect {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return CGRect(origin: origin, size: .zero)
        }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [color.withAlphaComponent(alpha)]))
        let img = base.withSymbolConfiguration(config) ?? base
        let scale = img.size.height > 0 ? size / img.size.height : 1
        let rect = CGRect(x: origin.x, y: origin.y, width: img.size.width * scale, height: size)
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        return rect
    }

    // MARK: - Clock (rail hero, no card)

    private func drawClock(ctx: CGContext, rect: NSRect, rail: Rail, top: CGFloat) -> CGFloat {
        let now = Date()
        let tSize = rect.height * 0.075
        let dSize = rect.height * 0.026

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -tSize * 0.03), blur: tSize * 0.12,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.60))
        let timeY = top - tSize * 1.05
        NSAttributedString(string: timeFmt.string(from: now),
                           attributes: textAttrs(tSize, .thin, alpha: 0.95, monoDigits: true))
            .draw(at: NSPoint(x: rail.x, y: timeY))
        let dateY = timeY - dSize * 1.5
        NSAttributedString(string: dayFmt.string(from: now),
                           attributes: textAttrs(dSize, .light, alpha: 0.60))
            .draw(at: NSPoint(x: rail.x, y: dateY))
        ctx.restoreGState()
        return dateY - dSize * 0.2
    }

    // MARK: - Agenda card (today + tomorrow)

    private func drawAgenda(ctx: CGContext, rect: NSRect, rail: Rail, top: CGFloat) -> CGFloat {
        let kSize = rect.height * 0.0135
        let kickerH = kSize * 1.6
        let rowSize = rect.height * 0.0165
        let lineH = rowSize * 1.6
        let sectionGap = rail.pad * 0.7

        let today = Array(todayEvents.prefix(4))
        let tomorrow = Array(tomorrowEvents.prefix(3))

        var contentH = kickerH + lineH * CGFloat(max(1, today.count))
        if !tomorrow.isEmpty { contentH += sectionGap + kickerH + lineH * CGFloat(tomorrow.count) }
        let content = drawCard(ctx, rail, top: top, height: contentH + rail.pad * 2)

        let now = Date()
        // First event still in progress or upcoming gets the accent highlight
        let nextEvent = today.first { !$0.isAllDay && $0.endDate > now }

        var y = content.maxY - kickerH
        let glyph = drawSymbol("calendar", at: CGPoint(x: content.minX, y: y + kSize * 0.05),
                               size: kSize * 1.15, alpha: 0.40)
        NSAttributedString(string: "TODAY", attributes: kickerAttrs(kSize))
            .draw(at: NSPoint(x: glyph.maxX + kSize * 0.6, y: y))

        if today.isEmpty {
            y -= lineH
            NSAttributedString(string: "No events", attributes: textAttrs(rowSize, .regular, alpha: 0.40))
                .draw(at: NSPoint(x: content.minX, y: y))
        } else {
            for event in today {
                y -= lineH
                drawEventRow(event, atY: y, in: content, rowSize: rowSize, lineH: lineH,
                             highlighted: event === nextEvent,
                             dimmed: !event.isAllDay && event.endDate <= now)
            }
        }

        if !tomorrow.isEmpty {
            y -= sectionGap + kickerH
            NSAttributedString(string: "TOMORROW", attributes: kickerAttrs(kSize))
                .draw(at: NSPoint(x: content.minX, y: y))
            for event in tomorrow {
                y -= lineH
                drawEventRow(event, atY: y, in: content, rowSize: rowSize, lineH: lineH,
                             highlighted: false, dimmed: false)
            }
        }
        return content.minY - rail.pad   // card bottom
    }

    private func drawEventRow(_ event: EKEvent, atY y: CGFloat, in content: CGRect,
                              rowSize: CGFloat, lineH: CGFloat, highlighted: Bool, dimmed: Bool) {
        let timeStr = event.isAllDay ? "All day" : timeFmt.string(from: event.startDate)
        NSAttributedString(string: timeStr,
                           attributes: textAttrs(rowSize * 0.82, .medium,
                                                 alpha: highlighted ? 0.95 : (dimmed ? 0.30 : 0.50),
                                                 color: highlighted ? accentYellow : nil,
                                                 monoDigits: true))
            .draw(at: NSPoint(x: content.minX, y: y + rowSize * 0.09))

        let titleX = content.minX + rowSize * 4.6
        NSAttributedString(string: event.title ?? "",
                           attributes: textAttrs(rowSize, highlighted ? .semibold : .regular,
                                                 alpha: dimmed ? 0.35 : (highlighted ? 0.95 : 0.80)))
            .draw(with: CGRect(x: titleX, y: y, width: content.maxX - titleX, height: lineH),
                  options: .truncatesLastVisibleLine)
    }

    // MARK: - Weather card

    private func drawWeather(ctx: CGContext, rect: NSRect, rail: Rail, top: CGFloat) -> CGFloat {
        guard let snap = weatherProvider?.snapshot else { return top }
        let kSize = rect.height * 0.0135
        let kickerH = kSize * 1.6
        let bigSize = rect.height * 0.042
        let rowSize = rect.height * 0.0165
        let rowH = rowSize * 1.6
        let badgeH = rect.height * 0.026

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

    // MARK: - Pickleball fact card (bottom of the rail)

    private func updateTip(dt: CGFloat) {
        guard tipsEnabled else { return }
        tipTimer += dt
        if tipTimer >= tipPeriod {
            tipTimer = 0
            tipIndex += 1
            if tipIndex >= tipOrder.count { tipOrder.shuffle(); tipIndex = 0 }
        }
    }

    // 1 while showing; eases to 0 at the swap boundaries
    private var tipAlpha: CGFloat {
        if tipTimer < tipFadeSecs { return tipTimer / tipFadeSecs }
        if tipTimer > tipPeriod - tipFadeSecs { return (tipPeriod - tipTimer) / tipFadeSecs }
        return 1
    }

    // Returns the card's top edge so the drill card can stack above it
    @discardableResult
    private func drawTip(ctx: CGContext, rect: NSRect, rail: Rail) -> CGFloat {
        let cardBottom = rect.height * 0.05
        // With tips off the drill card takes the bottom slot (caller adds rail.gap)
        guard tipsEnabled else { return cardBottom - rail.gap }
        let fact = PickleballFacts.all[tipOrder[tipIndex]]

        let kSize = rect.height * 0.0135
        let kickerH = kSize * 1.6
        let bodySize = rect.height * 0.016
        let bodyAttrs = textAttrs(bodySize, .regular, alpha: 0.85)
        let maxW = rail.width - rail.pad * 2
        let bodyAS = NSAttributedString(string: fact, attributes: bodyAttrs)
        let bodyH = ceil(bodyAS.boundingRect(with: NSSize(width: maxW, height: 1000),
                                             options: .usesLineFragmentOrigin).height)
        let contentH = kickerH + kSize * 0.5 + bodyH
        let cardTop = cardBottom + contentH + rail.pad * 2
        let alpha = tipAlpha
        guard alpha > 0 else { return cardTop }

        // Card and text fade together across the 30 s rotation
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let content = drawCard(ctx, rail, top: cardTop,
                               height: contentH + rail.pad * 2)
        let y = content.maxY - kickerH
        let bulb = drawSymbol("lightbulb.fill", at: CGPoint(x: content.minX, y: y + kSize * 0.05),
                              size: kSize * 1.15, alpha: 0.85, color: accentYellow)
        NSAttributedString(string: "PICKLEBALL FACT", attributes: kickerAttrs(kSize))
            .draw(at: NSPoint(x: bulb.maxX + kSize * 0.6, y: y))
        bodyAS.draw(with: CGRect(x: content.minX, y: content.minY, width: maxW, height: bodyH),
                    options: .usesLineFragmentOrigin)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        return cardTop
    }

    // MARK: - Drill of the day card (above the fact card)

    private func drawDrill(ctx: CGContext, rect: NSRect, rail: Rail, bottom: CGFloat) {
        guard drillEnabled, let drill = PickleballDrills.drillOfTheDay(level: drillLevel) else { return }

        let kSize = rect.height * 0.0135
        let kickerH = kSize * 1.6
        let titleSize = rect.height * 0.018
        let metaSize = rect.height * 0.0135
        let bodySize = rect.height * 0.016
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
        score.append(NSAttributedString(string: "\(leftScore)  –  \(rightScore)", attributes: scoreAttrs))
        score.append(NSAttributedString(string: "  FAR", attributes: labelAttrs))
        let sz = score.size()
        let x0 = rect.midX - sz.width / 2

        // Glass pill behind the score line, matching the rail cards
        let padX = size * 0.9, padY = size * 0.42
        let pill = CGRect(x: x0 - padX, y: y - padY, width: sz.width + padX * 2, height: sz.height + padY * 2)
        let path = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2,
                          transform: nil)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
        ctx.setLineWidth(1)
        ctx.addPath(path); ctx.strokePath()

        score.draw(at: NSPoint(x: x0, y: y))

        // Serve dot (ball-yellow) beside the serving side
        let r = size * 0.16
        let dotX = leftServing ? x0 - r * 3 : x0 + sz.width + r
        ctx.setFillColor(accentYellow.withAlphaComponent(0.85).cgColor)
        ctx.fillEllipse(in: CGRect(x: dotX, y: y + sz.height * 0.38 - r, width: r * 2, height: r * 2))

        // Games tally above the pill once a game has been won
        if leftGames + rightGames > 0 {
            let games = NSAttributedString(string: "GAMES \(leftGames) – \(rightGames)",
                                           attributes: textAttrs(size * 0.45, .semibold, alpha: 0.40,
                                                                 kern: size * 0.04))
            let gsz = games.size()
            games.draw(at: NSPoint(x: rect.midX - gsz.width / 2, y: pill.maxY + gsz.height * 0.35))
        }

        // Brief GAME banner when a game is won
        if gameBannerTimer > 0 {
            let pulse = 0.35 + 0.45 * abs(sin(gameBannerTimer * .pi * 1.5))
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

    // MARK: - Photo overlay

    private func updatePhotoOverlay(dt: CGFloat) {
        guard let pc = photoController else { return }
        pc.maxPixelSize = max(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2)
        if pc.update(dt: dt), let img = pc.image {
            warpPhotoIntoQuadrant(img)
        }
    }

    // Perspective-warps `image` to exactly fill a randomly chosen blue court
    // quadrant's trapezoid (near edge wider/lower on screen, far edge
    // narrower/higher — matching the existing blue-box fillQuad winding), then
    // rasterizes the result once via a shared CIContext. drawPhoto just blits
    // the cached CGImage every frame, so this only runs when a new photo
    // appears, not per frame.
    private func warpPhotoIntoQuadrant(_ image: CGImage) {
        let quads: [(x0: CGFloat, x1: CGFloat, z0: CGFloat, z1: CGFloat)] = [
            (-1, 0, 0, kitchenNearZ), (0, 1, 0, kitchenNearZ),
            (-1, 0, kitchenFarZ, 1), (0, 1, kitchenFarZ, 1),
        ].shuffled()
        let overlays = CGRect(x: 0, y: 0,
                              width: bounds.width * 0.30, height: bounds.height)
        // Prefer the first shuffled quadrant that doesn't touch the left rail
        // column; fall back to the first if all four do (rare).
        let chosen = quads.first { !quadBoundingRect($0).intersects(overlays) } ?? quads[0]
        let corners = quadCorners(chosen, insetFrac: 0.08)
        photoQuadCorners = corners

        let ciImage = CIImage(cgImage: image)
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = ciImage
        filter.topLeft = corners.farLeft
        filter.topRight = corners.farRight
        filter.bottomLeft = corners.nearLeft
        filter.bottomRight = corners.nearRight

        guard let output = filter.outputImage else { photoWarpedImage = nil; return }
        let extent = output.extent
        guard !extent.isInfinite, !extent.isEmpty,
              let warped = Self.ciContext.createCGImage(output, from: extent) else {
            photoWarpedImage = nil
            return
        }
        photoWarpedImage = warped
        photoWarpedRect = extent
    }

    // Bounding rect of a quadrant's 4 projected corners — used only for the
    // quick overlay-avoidance test, not for drawing.
    private func quadBoundingRect(_ q: (x0: CGFloat, x1: CGFloat, z0: CGFloat, z1: CGFloat)) -> CGRect {
        let pts = [proj(q.x0, q.z0, 0), proj(q.x1, q.z0, 0), proj(q.x1, q.z1, 0), proj(q.x0, q.z1, 0)]
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // The 4 projected corners of a quadrant, pulled in toward the centroid by
    // `insetFrac` so the photo doesn't sit flush against the court lines.
    // Screen "left"/"right" are resolved from actual projected x (not world
    // x0/x1) since this oblique corner camera can flip that ordering on the
    // far side of the net.
    private func quadCorners(_ q: (x0: CGFloat, x1: CGFloat, z0: CGFloat, z1: CGFloat), insetFrac: CGFloat)
        -> (nearLeft: CGPoint, nearRight: CGPoint, farLeft: CGPoint, farRight: CGPoint) {
        let nearA = proj(q.x0, q.z0, 0), nearB = proj(q.x1, q.z0, 0)
        let farA  = proj(q.x0, q.z1, 0), farB  = proj(q.x1, q.z1, 0)
        let nearLeft  = nearA.x <= nearB.x ? nearA : nearB
        let nearRight = nearA.x <= nearB.x ? nearB : nearA
        let farLeft   = farA.x <= farB.x ? farA : farB
        let farRight  = farA.x <= farB.x ? farB : farA
        let cx = (nearLeft.x + nearRight.x + farLeft.x + farRight.x) / 4
        let cy = (nearLeft.y + nearRight.y + farLeft.y + farRight.y) / 4
        func pull(_ p: CGPoint) -> CGPoint {
            CGPoint(x: cx + (p.x - cx) * (1 - insetFrac), y: cy + (p.y - cy) * (1 - insetFrac))
        }
        return (pull(nearLeft), pull(nearRight), pull(farLeft), pull(farRight))
    }

    private func drawPhoto(ctx: CGContext) {
        guard let pc = photoController, let img = photoWarpedImage, pc.image != nil else { return }
        let alpha = pc.alpha
        guard alpha > 0 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.draw(img, in: photoWarpedRect)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.6))
        ctx.setLineWidth(2)
        let c = photoQuadCorners
        strokeQuad(ctx, c.nearLeft, c.nearRight, c.farRight, c.farLeft)
        ctx.restoreGState()
    }

    /// Test hook for the offscreen harness: dissolve this image in on the next
    /// frame without touching Photos or the filesystem.
    func _debugShowPhoto(_ image: CGImage) {
        let pc = photoController ?? PhotoOverlayController(settings: PhotoSettings())
        photoController = pc
        pc._debugInject(image)
    }

    // MARK: - ScreenSaverView

    private lazy var configureController = ConfigureSheetController()

    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? {
        configureController.refresh()
        return configureController.window
    }
}
