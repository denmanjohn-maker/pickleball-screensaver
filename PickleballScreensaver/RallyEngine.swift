import Foundation
import CoreGraphics

// MARK: - Court geometry (shared by the simulation and the renderer)

enum Court {
    static let ftPerX: CGFloat = 10.0    // feet per world-x unit (half court width)
    static let ftPerZ: CGFloat = 44.0    // feet per world-z unit (court length)
    static let ftPerY: CGFloat = 9.375   // feet per world-y unit (netHeight 0.32 = 3 ft)
    static let netHeight: CGFloat = 0.32 // sideline/post height (36 in); netTopY(_:) gives the sagging top
    static let kitchenNearZ: CGFloat = 15.0 / 44.0   // ≈ 0.341
    static let kitchenFarZ:  CGFloat = 29.0 / 44.0   // ≈ 0.659

    // Regulation net height: 36 in at the sidelines sagging to 34 in at the center
    static func netTopY(_ wx: CGFloat) -> CGFloat {
        (34 + 2 * wx * wx) / (12 * ftPerY)
    }
}

// MARK: - Types

struct Vec3 {
    var x: CGFloat   // court width: -1 = left sideline, +1 = right sideline (0 = center line)
    var y: CGFloat   // height above floor
    var z: CGFloat   // depth: 0 = near baseline (bottom of screen), 1 = far baseline (top)
}

enum GameFormat: String {
    case singles, doubles
}

// A rally moves through the phases of a real pickleball point. The phase names
// follow the shot that is currently in flight (or the pause that replaces one).
enum RallyPhase {
    case betweenPoints   // players walk to their spots; serve fires when ready
    case serve           // shot 1 in flight (must bounce)
    case returning       // shot 2 in flight (must bounce)
    case third           // shot 3 in flight (drop or drive)
    case transition      // shots 4+ while the serving side works its way in
    case kitchen         // dink exchange at the non-volley zone
    case firefight       // a speed-up turned it into a hands battle
    case dead            // point decided; the ball rolls out
}

enum ShotType: String {
    case serve, serviceReturn = "return", thirdDrop = "3rd-drop", thirdDrive = "3rd-drive"
    case drop, drive, dink, reset, speedup, counter, lob
}

// How the scripted final shot of a rally goes wrong (or wins)
enum RallyEnding: String {
    case netError = "net", wideError = "wide", longError = "long", winner
}

struct PlayerState {
    var x: CGFloat = 0          // body position across court width
    var z: CGFloat = 0          // body depth
    var facing: CGFloat = 1     // +1 near team (hits toward +z), -1 far team
    var hand: CGFloat = 1       // +1 right-handed, -1 lefty; forehand world-x side = facing * hand
    var court: Int = 0          // 0 = the team's right-hand service court, 1 = left
    var targetX: CGFloat = 0    // where the feet are shuffling toward
    var targetZ: CGFloat = 0    // depth the body moves toward each frame
    var homeX: CGFloat = 0      // recovery spot between shots
    var stance: CGFloat = 1     // contact-offset side for this swing: +1 = wx+ side, -1 = wx- side
    var swingPhase = false
    var swingT: CGFloat = 0     // normalized swing time [0, 1+recovery]
    var swingDur: CGFloat = 0.5 // seconds for this swing, windup through finish
    var swingAmp: CGFloat = 1.0 // stroke size: dinks are compact, drives full
    var swingAngle: CGFloat = 1.2 // rad from the horizontal contact pose; default must match readyAngle
    var faceDZ: CGFloat = 0     // paddle face-center depth offset from the body (world z)
    var faceY: CGFloat = 0.08   // paddle face-center height (world y); default must match restFaceY
    var contactY: CGFloat = 0.12 // predicted ball height at contact — face center meets it there
    var armed = true            // ready to start a new backswing
    // Human imperfection: nobody reads the ball instantly or exactly
    var reactionTimer: CGFloat = 0   // countdown after the opponent's contact before responding
    var predictedX: CGFloat = 0      // noisy read of where the ball will arrive
    var predNoise: CGFloat = 0       // this flight's read error, decaying as the ball nears
    var predClock: CGFloat = 0       // re-read cadence
    var hasPrediction = false
}

// Ease curve: gentle start and finish, peak velocity mid-segment.
// Shared by the swing animation (engine) and the turntable spin (view).
func smoothstep(_ x: CGFloat) -> CGFloat {
    let c = max(0, min(1, x))
    return c * c * (3 - 2 * c)
}

// SplitMix64 — a tiny deterministic generator so the preview harness can
// replay identical rallies with --seed=N. The engine always routes its
// randomness through one of these (seeded from entropy by default).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Rally engine
// Owns the ball, the players, the rally lifecycle, and the score. The view
// calls step(dt:) once per frame and reads state for drawing; it never
// mutates simulation state.

final class RallyEngine {

    // Ball state
    private(set) var ball = Vec3(x: 0, y: 0.1, z: 0.04)
    private var bVel = Vec3(x: 0, y: 0, z: 0)
    private(set) var trailPoints: [Vec3] = []
    private(set) var ballSpin: CGFloat = 0

    // Players — 2 (singles) or 4 (doubles), invisible bodies holding paddles.
    // Near-team players face +z; far-team players face -z.
    private(set) var players: [PlayerState] = []
    private(set) var format: GameFormat = .doubles

    // Physics. Gravity is a `var` tunable: -3.2 y-units/s² ≈ 30 ft/s², slightly
    // soft of true gravity so the ball reads clearly at screensaver scale.
    var gravity: CGFloat = -3.2
    private let bounceDamp: CGFloat = 0.55

    // Court depth landmarks
    private let nearBaselineZ: CGFloat = 0.03
    private let farBaselineZ:  CGFloat = 0.97
    private let kitchenStandoffZ: CGFloat = 0.02      // players hold this far behind their kitchen line

    // Movement — real players shuffle, they don't teleport.
    // (x-units = ft/10, z-units = ft/44.)
    private let latSpeedMax:  CGFloat = 0.60   // ~6 ft/s lateral shuffle ceiling
    private let latSpeedNear: CGFloat = 0.35   // small kitchen adjustments are slower
    private let advanceSpeed: CGFloat = 0.11   // ~4.8 ft/s working up through transition
    private let runInSpeed:   CGFloat = 0.15   // ~6.6 ft/s covering real ground (run-ins, retreats)
    private let reach:     CGFloat = 0.18      // paddle contact offset from body (1.8 ft)
    private let hitWindow: CGFloat = 0.35      // max |ball.x - contact point| for a clean hit

    // Rally behavior — `var` (not `let`) so an offscreen harness can force behaviors
    var thirdDriveFrac:   CGFloat = 0.5    // third shots that are drives (vs drops)
    var dinkCrossFrac:    CGFloat = 0.80   // dinks hit cross-court
    var endingErrorFrac:  CGFloat = 0.66   // rallies ending on an error (vs a winner)
    var leftyProb:        CGFloat = 1.0 / 6.0   // chance each player is left-handed
    var speedupProbPerDink: CGFloat = 0.07 // chance a dink turns into an attack (escalates)
    var lobProb:          CGFloat = 0.03   // chance a kitchen ball goes up instead

    // Backhand contact is cross-body — a little closer in than full reach
    private let reachBackhand: CGFloat = 0.14

    // Swing shape (see updateSwing). Durations/amplitudes are per-shot fields.
    private let backswingFrac:  CGFloat = 0.45
    private var contactFrac: CGFloat { backswingFrac + (1 - backswingFrac) / 2 }
    private let recoveryFrac:   CGFloat = 0.50
    private let backswingAngle: CGFloat = -1.6
    private let followAngle:    CGFloat = 0.8
    private let readyAngle:     CGFloat = 1.2
    private let swingLen:       CGFloat = 0.075
    private let swingDrop:      CGFloat = 0.13
    private let restFaceY:      CGFloat = 0.08

    // Rally lifecycle
    private(set) var phase: RallyPhase = .betweenPoints
    private var phaseTimer: CGFloat = 1.2     // betweenPoints / dead countdown
    private var shotIndex = 0                 // shots struck this rally (serve = 1)
    private var scriptN = 7                   // scripted rally length
    private var scriptEnding: RallyEnding = .netError
    private var bounceCount = 0               // floor bounces since the last strike
    private var mustBounce = false            // the receiver must let this flight bounce
    private var lastHitNear = true            // which team struck the flight in progress
    private var lastShotType: ShotType = .serve
    private var rallyLostByNear = false
    private var serveArmed = false            // server's swing has started pre-launch
    private var hitterIdx = 0                 // designated receiver of the current flight
    private var serverIdx = 0                 // who serves the current point
    private var dinkStreak = 0                // consecutive dinks — pressure to speed up builds
    private var winnerFlight = false          // this flight is the scripted put-away

    // Score — side-out scoring; games to 11, win by 2. Doubles uses the real
    // three-number call: server score, receiver score, server number — with
    // both partners serving before a side-out and the 0-0-2 game start.
    private(set) var nearScore = 0
    private(set) var farScore  = 0
    private(set) var nearServing = false
    private(set) var serverNumber = 2      // doubles: 1 or 2; game starts on 2
    private(set) var nearGames = 0
    private(set) var farGames  = 0
    private(set) var gameBannerTimer: CGFloat = 0

    // All randomness flows through this so --seed=N replays identical games
    private var rng: SeededGenerator

    // Optional per-event log line sink for the preview harness (--stats)
    var statsSink: ((String) -> Void)?

    init() {
        rng = SeededGenerator(seed: UInt64.random(in: .min ... .max))
        nearServing = Bool.random(using: &rng)
        buildPlayers()
        beginBetweenPoints(firstDelay: 1.0)
    }

    // Restart the whole match from a known seed (deterministic from here on)
    func reseed(_ seed: UInt64) {
        rng = SeededGenerator(seed: seed)
        nearScore = 0; farScore = 0
        nearGames = 0; farGames = 0
        serverNumber = 2
        gameBannerTimer = 0
        nearServing = Bool.random(using: &rng)
        buildPlayers()
        beginBetweenPoints(firstDelay: 1.0)
    }

    // Switch between singles and doubles (rebuilds the on-court players)
    func setFormat(_ f: GameFormat) {
        guard f != format else { return }
        format = f
        nearScore = 0; farScore = 0
        serverNumber = 2
        buildPlayers()
        beginBetweenPoints(firstDelay: 1.0)
    }

    private func buildPlayers() {
        func make(facing: CGFloat, court: Int) -> PlayerState {
            var p = PlayerState()
            p.facing = facing
            p.court = court
            p.z = facing > 0 ? nearBaselineZ : farBaselineZ
            p.targetZ = p.z
            p.x = courtHomeX(facing: facing, court: court)
            p.targetX = p.x; p.homeX = p.x
            return p
        }
        switch format {
        case .singles:
            players = [make(facing: 1, court: 0), make(facing: -1, court: 0)]
        case .doubles:
            players = [make(facing: 1, court: 0), make(facing: 1, court: 1),
                       make(facing: -1, court: 0), make(facing: -1, court: 1)]
        }
        rollHands()
    }

    // New game, new (invisible) people — occasionally one plays lefty,
    // which flips their forehand side and un-mirrors the rallies
    private func rollHands() {
        for i in players.indices {
            players[i].hand = chance(leftyProb) ? -1 : 1
        }
    }

    private func fhSide(_ p: PlayerState) -> CGFloat { p.facing * p.hand }

    // MARK: - Random helpers

    private func rand(_ range: ClosedRange<CGFloat>) -> CGFloat {
        CGFloat.random(in: range, using: &rng)
    }

    private func chance(_ p: CGFloat) -> Bool {
        CGFloat.random(in: 0...1, using: &rng) < p
    }

    private func gauss(_ mean: CGFloat, _ sd: CGFloat) -> CGFloat {
        let u1 = rand(1e-6...1), u2 = rand(0...1)
        return mean + sd * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    // MARK: - Team geometry

    private func indices(facing: CGFloat) -> [Int] {
        players.indices.filter { players[$0].facing == facing }
    }

    // Court 0 is the team's right-hand service court. The near team faces +z,
    // so their right hand points toward -x; the far team mirrors to +x.
    private func courtX(facing: CGFloat, court: Int) -> CGFloat {
        let rightSign: CGFloat = facing > 0 ? -1 : 1
        return (court == 0 ? rightSign : -rightSign) * 0.5
    }

    private func courtHomeX(facing: CGFloat, court: Int) -> CGFloat {
        format == .singles ? 0 : courtX(facing: facing, court: court) * 0.9
    }

    private func baselineZ(facing: CGFloat) -> CGFloat {
        facing > 0 ? nearBaselineZ : farBaselineZ
    }

    private func kitchenZ(facing: CGFloat) -> CGFloat {
        facing > 0 ? Court.kitchenNearZ - kitchenStandoffZ
                   : Court.kitchenFarZ + kitchenStandoffZ
    }

    private func isAtKitchen(_ p: PlayerState) -> Bool {
        p.facing > 0 ? p.z > Court.kitchenNearZ - kitchenStandoffZ - 0.06
                     : p.z < Court.kitchenFarZ + kitchenStandoffZ + 0.06
    }

    private func teamAtKitchen(facing: CGFloat) -> Bool {
        indices(facing: facing).allSatisfy { isAtKitchen(players[$0]) }
    }

    // MARK: - Trajectory solver

    // Mode A — landing-constrained. Solve the flight that leaves (x0,z0,y0),
    // clears the net crossing by `margin`, and lands (y = 0) exactly at
    // (targetX, targetZ). Flight time falls out of the two constraints:
    //   y(t) = y0 + vy·t + g·t²/2,  landing y(T)=0, net y(αT) = netY + margin
    //   → T² = 2(netY + m − y0(1−α)) / (g(α² − α)),  α = net-crossing fraction
    // Ball speed is then emergent from the arc: tight margins give fast flat
    // drives, tall margins give slow floaty dinks.
    private func solveLanding(fromX x0: CGFloat, fromZ z0: CGFloat, fromY y0: CGFloat,
                              targetX: CGFloat, targetZ: CGFloat, margin: CGFloat) -> (v: Vec3, flightT: CGFloat) {
        let alpha = min(0.95, max(0.05, (0.5 - z0) / (targetZ - z0)))
        let netY = Court.netTopY(targetX * alpha + x0 * (1 - alpha))
        // Guarantee a positive arc even from high contact points
        let m = max(margin, y0 * (1 - alpha) - netY + 0.05)
        let tSq = 2 * (netY + m - y0 * (1 - alpha)) / (gravity * (alpha * alpha - alpha))
        let T = sqrt(max(0.05, tSq))
        let vy = -y0 / T - gravity * T / 2
        return (Vec3(x: (targetX - x0) / T, y: vy, z: (targetZ - z0) / T), T)
    }

    // Mode C — apex-constrained (lobs): pick how high, land deep, hang time follows.
    private func solveApex(fromX x0: CGFloat, fromZ z0: CGFloat, fromY y0: CGFloat,
                           targetX: CGFloat, targetZ: CGFloat, apexY: CGFloat) -> (v: Vec3, flightT: CGFloat) {
        let vy = sqrt(max(0.1, -2 * gravity * (apexY - y0)))
        let T = (vy + sqrt(vy * vy + 2 * -gravity * y0)) / -gravity
        return (Vec3(x: (targetX - x0) / T, y: vy, z: (targetZ - z0) / T), T)
    }

    // MARK: - Rally script

    // Sample the point at serve time: how many shots it will last and how it
    // ends. Non-terminal shots are then aimed reachable by construction, so
    // the distributions land where real match data says they should
    // (~60% of rallies at 3–10 shots, two thirds ending on errors).
    private func sampleScript() {
        let r = rand(0...1)
        if r < 0.007 {                    // missed serve — pros almost never do
            scriptN = 1
        } else if r < 0.031 {             // missed return
            scriptN = 2
        } else {
            scriptN = min(25, 3 + Int(-7.5 * log(rand(1e-6...1))))
        }
        if chance(endingErrorFrac) {
            let k = rand(0...1)
            scriptEnding = k < 0.5 ? .netError : (k < 0.75 ? .wideError : .longError)
        } else {
            scriptEnding = .winner
        }
        // Serve/return misses are always errors
        if scriptN <= 2 { scriptEnding = chance(0.6) ? .netError : .longError }
    }

    // MARK: - Point lifecycle

    private func beginBetweenPoints(firstDelay: CGFloat? = nil) {
        sampleScript()
        phase = .betweenPoints
        phaseTimer = firstDelay ?? rand(2.0...3.5)
        serveArmed = false
        shotIndex = 0
        bounceCount = 0
        dinkStreak = 0
        winnerFlight = false
        trailPoints.removeAll()
        ballSpin = 0

        // Who serves, from where, and who receives. The parity-court player
        // is the team's first server; their partner is the second.
        let servingFacing: CGFloat = nearServing ? 1 : -1
        let score = nearServing ? nearScore : farScore
        let serveCourt = score % 2 == 0 ? 0 : 1
        let servers = indices(facing: servingFacing)
        let receivers = indices(facing: -servingFacing)
        let firstServer = servers.first(where: { players[$0].court == serveCourt }) ?? servers[0]
        if format == .doubles && serverNumber == 2 && servers.count == 2 {
            serverIdx = servers.first(where: { $0 != firstServer }) ?? firstServer
        } else {
            serverIdx = firstServer
        }
        // The receiver stands in the court diagonal from the server
        let serverCourt = players[serverIdx].court
        let receiverIdx = receivers.first(where: { players[$0].court == serverCourt }) ?? receivers[0]

        for i in players.indices {
            var p = players[i]
            p.hasPrediction = false
            p.armed = true
            if i == serverIdx {
                p.targetX = courtX(facing: p.facing, court: p.court)
                p.targetZ = baselineZ(facing: p.facing)
            } else if p.facing == servingFacing {
                // Server's partner: both back (the third shot must bounce)
                p.targetX = courtX(facing: p.facing, court: p.court)
                p.targetZ = baselineZ(facing: p.facing)
            } else if i == receiverIdx {
                p.targetX = courtX(facing: p.facing, court: p.court)
                p.targetZ = baselineZ(facing: p.facing)
            } else {
                // Receiver's partner starts at the kitchen line — the
                // signature asymmetry of a pickleball point
                p.targetX = courtX(facing: p.facing, court: p.court)
                p.targetZ = kitchenZ(facing: p.facing)
            }
            p.homeX = p.targetX
            players[i] = p
        }
        hitterIdx = receiverIdx
    }

    private func launchServe() {
        shotIndex = 1
        lastHitNear = nearServing
        lastShotType = .serve
        phase = .serve
        mustBounce = true
        bounceCount = 0
        statsSink?("script n=\(scriptN) ending=\(scriptEnding.rawValue)")

        // Mid-rally recovery shifts to rally homes
        for i in players.indices {
            players[i].homeX = courtHomeX(facing: players[i].facing, court: players[i].court)
        }

        var server = players[serverIdx]
        let facing = server.facing
        ball = Vec3(x: server.x + server.stance * reach, y: 0.24, z: server.z)

        // Deep diagonal serve into the opposite service box
        let boxSign: CGFloat = -(server.x / max(0.001, abs(server.x)))
        let targetX = boxSign * rand(0.30...0.78)
        let depth = rand(0.87...0.955)                       // deep in the box
        let targetZ = facing > 0 ? depth : 1 - depth
        let sol = solveLanding(fromX: ball.x, fromZ: ball.z, fromY: ball.y,
                               targetX: targetX, targetZ: targetZ, margin: rand(0.10...0.22))
        bVel = sol.v
        applyEnding(shotN: 1, targetX: targetX, targetZ: targetZ, flightT: sol.flightT)

        server.contactY = ball.y
        server.swingAmp = 0.9
        if !server.swingPhase || server.swingT < contactFrac {
            server.swingPhase = true
            server.swingT = contactFrac
        }
        players[serverIdx] = server

        designateAndPrimeReceiver(facing: -facing)
        emitShot(n: 1, type: .serve, facing: facing,
                 stance: server.stance == fhSide(server) ? "FH" : "BH",
                 x: ball.x, targetX: targetX, flightT: sol.flightT)
    }

    // Pick which receiving player takes this flight and give them a human
    // reaction delay plus a noisy first read. Middle balls follow the
    // forehand-takes-the-middle convention (~80%).
    private func designateAndPrimeReceiver(facing: CGFloat) {
        let idxs = indices(facing: facing)
        var chosen = idxs[0]
        if idxs.count == 2 {
            let a = idxs[0], b = idxs[1]
            let mid = (players[a].x + players[b].x) / 2
            let px = interceptX(atZ: (players[a].z + players[b].z) / 2)
            if abs(px - mid) < 0.15 {
                // Forehand toward the middle wins the call most of the time.
                // (With two right-handers exactly one qualifies; handedness
                // generalizes this later.)
                let aFh = forehandTowardMiddle(players[a])
                let bFh = forehandTowardMiddle(players[b])
                let preferred = aFh && !bFh ? a : (bFh && !aFh ? b : (abs(players[a].x - px) < abs(players[b].x - px) ? a : b))
                let other = preferred == a ? b : a
                chosen = chance(0.8) ? preferred : other
            } else {
                chosen = abs(players[a].x - px) < abs(players[b].x - px) ? a : b
            }
        }
        hitterIdx = chosen
        players[chosen].reactionTimer = max(0.12, min(0.35, gauss(0.22, 0.05)))
        players[chosen].predNoise = gauss(0, 0.08)
        players[chosen].hasPrediction = false
    }

    // Does this player's forehand point from their body toward the center line?
    private func forehandTowardMiddle(_ p: PlayerState) -> Bool {
        (0 - p.x) * fhSide(p) > 0
    }

    // Modify the in-flight velocity so the scripted final shot misses (or wins)
    private func applyEnding(shotN: Int, targetX: CGFloat, targetZ: CGFloat, flightT: CGFloat) {
        guard shotN == scriptN else { return }
        switch scriptEnding {
        case .netError:
            // Re-solve with a clipping margin so the ball catches the tape
            let sol = solveLanding(fromX: ball.x, fromZ: ball.z, fromY: ball.y,
                                   targetX: targetX, targetZ: targetZ, margin: rand(-0.075 ... -0.025))
            bVel = sol.v
        case .wideError:
            let sign: CGFloat = chance(0.5) ? 1 : -1
            bVel.x = (sign * rand(1.06...1.20) - ball.x) / flightT
        case .longError:
            // Stretch the flight so the first bounce clears the baseline
            let needed = bVel.z > 0 ? rand(1.03...1.10) : rand(-0.10 ... -0.03)
            let over = max(1.04, (needed - ball.z) / (targetZ - ball.z))
            bVel.z *= over
            bVel.x *= over
        case .winner:
            break   // handled at aim time (placed beyond the defender's reach)
        }
    }

    // MARK: - Frame step

    func step(dt: CGFloat) {
        if gameBannerTimer > 0 { gameBannerTimer -= dt }

        switch phase {
        case .betweenPoints:
            stepBetweenPoints(dt: dt)
        case .dead:
            phaseTimer -= dt
            integrateBall(dt: dt, adjudicate: false)
            updateSwings(dt: dt)
            movePlayers(dt: dt)
            if phaseTimer <= 0 { scoreRally() }
        default:
            stepRally(dt: dt)
        }

        // Spin + trail run in every phase so the ball never freezes mid-frame
        let linearSpd = sqrt(bVel.x * bVel.x + bVel.z * bVel.z)
        ballSpin += linearSpd * 18.0 * dt
        if phase != .betweenPoints {
            trailPoints.append(ball)
            if trailPoints.count > 18 { trailPoints.removeFirst() }
        }
    }

    private func stepBetweenPoints(dt: CGFloat) {
        phaseTimer -= dt
        movePlayers(dt: dt)
        updateSwings(dt: dt)

        // The ball rests on the server's paddle while everyone gets set
        let server = players[serverIdx]
        let facing = server.facing
        if !serveArmed {
            ball = Vec3(x: server.x + facing * 0.7 * reach, y: 0.14, z: server.z)
            bVel = Vec3(x: 0, y: 0, z: 0)
        }

        // Wait for the players to reach their spots, then wind up and strike
        let ready = players.allSatisfy {
            abs($0.x - $0.targetX) < 0.06 && abs($0.z - $0.targetZ) < 0.03
        }
        if !serveArmed && phaseTimer <= 0 && ready {
            serveArmed = true
            var s = server
            s.stance = fhSide(s)   // serves are forehands
            s.contactY = 0.24
            s.swingPhase = true
            s.swingT = 0
            s.swingDur = 0.55
            s.swingAmp = 0.9
            players[serverIdx] = s
        }
        if serveArmed {
            let s = players[serverIdx]
            if s.swingT >= contactFrac { launchServe() }
            else {
                // Ball rides the toss hand until the paddle comes through
                ball = Vec3(x: s.x + facing * 0.7 * reach, y: 0.20, z: s.z)
            }
        }
    }

    private func stepRally(dt: CGFloat) {
        let prevZ = ball.z
        integrateBall(dt: dt, adjudicate: true)
        guard phase != .dead else { return }

        movePlayers(dt: dt)
        updateSwings(dt: dt)

        // Net cord: the ball clips the tape, dies, and dribbles back
        if (prevZ - 0.5) * (ball.z - 0.5) < 0 {
            let t = (0.5 - prevZ) / (ball.z - prevZ)
            let yAtNet = (ball.y - bVel.y * dt) + bVel.y * dt * t
            if yAtNet < Court.netTopY(ball.x) {
                ball.z = 0.5 - (bVel.z > 0 ? 0.012 : -0.012)
                bVel.z = (bVel.z > 0 ? -1 : 1) * 0.04
                bVel.x *= 0.15
                bVel.y = min(bVel.y, 0) * 0.3
                pointOver(loserNear: lastHitNear, reason: "net")
                return
            }
        }

        // Hit detection: the designated receiver strikes as the ball crosses
        // their plane
        let h = players[hitterIdx]
        let ballComing = h.facing > 0 ? bVel.z < 0 : bVel.z > 0
        if ballComing && (h.facing > 0 ? ball.z <= h.z : ball.z >= h.z) {
            attemptHit()
        }
    }

    private func attemptHit() {
        // strikeBall re-designates hitterIdx for the next flight, so capture
        // the striker's index before it moves
        let idx = hitterIdx
        var p = players[idx]
        let backhand = p.swingPhase && p.stance != fhSide(p)
        let contact = p.x + (p.swingPhase ? p.stance : fhSide(p)) * (backhand ? reachBackhand : reach)
        let canVolley = !mustBounce || bounceCount >= 1
        if canVolley && !winnerFlight && abs(ball.x - contact) < hitWindow && ball.y < 0.42 {
            strikeBall(&p)
            players[idx] = p
        }
        // A miss is not an instant fault: the ball flies on and the landing
        // (or second bounce) decides the point in integrateBall.
    }

    // MARK: - Shot selection

    private func strikeBall(_ p: inout PlayerState) {
        shotIndex += 1
        let n = shotIndex
        let facing = p.facing
        ball.z = p.z
        ball.y = max(ball.y, 0.03)

        // The scripted ending didn't stick (a defender ran the winner down,
        // or an error shot clipped over) — script another ending soon,
        // usually an error so long rallies still die like real ones
        if n > scriptN {
            scriptN = n + Int.random(in: 1...3, using: &rng)
            if endingErrorFrac > 0 && chance(0.75) {
                let k = rand(0...1)
                scriptEnding = k < 0.5 ? .netError : (k < 0.75 ? .wideError : .longError)
            }
        }

        let oppIdxs = indices(facing: -facing)
        let atKitchen = isAtKitchen(p)
        let oppAtKitchen = teamAtKitchen(facing: -facing)

        // What shot does this phase call for?
        var type: ShotType
        if n == 2 {
            type = .serviceReturn
        } else if n == 3 {
            type = chance(thirdDriveFrac) ? .thirdDrive : .thirdDrop
        } else if lastShotType == .speedup || lastShotType == .counter {
            // Hands battle: fire back, or defuse it soft into the kitchen
            type = chance(0.62) ? .counter : .reset
        } else if lastShotType == .thirdDrive || lastShotType == .drive {
            // Blunting a drive: mostly soft resets into the kitchen
            type = chance(0.66) ? .reset : .drive
        } else if atKitchen && oppAtKitchen {
            // Patient dinking, with mounting pressure to end it — a lob or a
            // sudden speed-up into a hands battle
            if chance(lobProb) {
                type = .lob
            } else if chance(min(0.5, speedupProbPerDink + CGFloat(dinkStreak) * 0.012)) {
                type = .speedup
            } else {
                type = .dink
            }
        } else if atKitchen {
            type = chance(0.7) ? .dink : .drive
        } else {
            type = chance(0.7) ? .drop : .drive
        }
        // A scripted winner is an attack, not a patient ball — real points
        // are finished with speed-ups, volleys, and drives
        if n == scriptN && scriptEnding == .winner && n > 2 {
            type = atKitchen ? .speedup : .drive
        }
        dinkStreak = type == .dink ? dinkStreak + 1 : 0

        // Aim it: target landing spot + net margin by shot type
        var targetX: CGFloat
        var depth: CGFloat        // landing depth into the opponent's half (0.5–1 scale)
        var margin: CGFloat
        var cross = false
        switch type {
        case .serve:
            return   // handled by launchServe
        case .serviceReturn:
            // Deep, loopy, favoring the middle
            targetX = max(-0.7, min(0.7, gauss(-0.05, 0.35)))
            depth = rand(0.82...0.94)
            margin = rand(0.25...0.40)
        case .thirdDrop, .drop, .reset:
            // Soft, descending, into the kitchen
            cross = chance(0.55)
            targetX = aimAcross(from: ball.x, cross: cross)
            depth = rand(0.53...0.64)
            margin = rand(0.10...0.18)
        case .thirdDrive, .drive:
            // Flat and deep, at the opponent or the open court
            cross = chance(0.5)
            targetX = aimAcross(from: ball.x, cross: cross)
            depth = rand(0.84...0.95)
            margin = rand(0.03...0.07)
        case .dink:
            cross = chance(dinkCrossFrac)
            targetX = aimAcross(from: ball.x, cross: cross)
            depth = rand(0.53...0.645)
            // Cross-court dinks fly the long diagonal — give them more air
            margin = cross ? rand(0.13...0.20) : rand(0.10...0.16)
        case .speedup, .counter:
            // Fast and flat, at a body — the surprise directions
            let tgt = oppIdxs.min(by: { abs(players[$0].x - ball.x) < abs(players[$1].x - ball.x) }) ?? oppIdxs[0]
            targetX = players[tgt].x + rand(-0.12...0.12)
            depth = rand(0.72...0.86)
            margin = rand(0.02...0.06)
        case .lob:
            // Over everyone's heads, landing deep
            cross = chance(0.4)
            targetX = aimAcross(from: ball.x, cross: cross) * 0.7
            depth = rand(0.86...0.94)
            margin = 0   // unused; lobs solve by apex
        }
        let targetZ = facing > 0 ? depth : 1 - depth

        var sol = type == .lob
            ? solveApex(fromX: ball.x, fromZ: ball.z, fromY: ball.y,
                        targetX: targetX, targetZ: targetZ, apexY: rand(1.5...2.0))
            : solveLanding(fromX: ball.x, fromZ: ball.z, fromY: ball.y,
                           targetX: targetX, targetZ: targetZ, margin: margin)

        // The player most likely to take this ball, for aiming purposes
        let provisionalIdx = oppIdxs.min(by: {
            abs(players[$0].x - targetX) < abs(players[$1].x - targetX)
        }) ?? oppIdxs[0]
        let opponent = players[provisionalIdx]

        // Soft shots must survive to the receiver: if the second bounce would
        // die short of where they are, land the ball deeper (at their feet —
        // exactly what a real drop against a deep opponent turns into)
        switch type {
        case .thirdDrop, .drop, .reset, .dink:
            let t2 = 2 * abs(sol.v.y + gravity * sol.flightT) * bounceDamp / -gravity
            let bounce2Z = targetZ + sol.v.z * t2
            if facing > 0 {
                let deficit = (opponent.z + 0.02) - bounce2Z
                if deficit > 0 {
                    let deeper = min(0.88, targetZ + deficit)
                    sol = solveLanding(fromX: ball.x, fromZ: ball.z, fromY: ball.y,
                                       targetX: targetX, targetZ: deeper, margin: margin)
                }
            } else {
                let deficit = bounce2Z - (opponent.z - 0.02)
                if deficit > 0 {
                    let deeper = max(0.12, targetZ - deficit)
                    sol = solveLanding(fromX: ball.x, fromZ: ball.z, fromY: ball.y,
                                       targetX: targetX, targetZ: deeper, margin: margin)
                }
            }
        default:
            break
        }

        if n == scriptN && scriptEnding == .winner {
            // Find the spot inside the lines that every defender is furthest
            // from — a sideline or the middle seam — and hit it there
            let cover = reachCover(flightT: sol.flightT)
            func minDist(_ t: CGFloat) -> CGFloat {
                oppIdxs.map { abs(players[$0].x - t) }.min() ?? 2
            }
            let best = [-CGFloat(0.92), 0.92, 0].max(by: { minDist($0) < minDist($1) })!
            if minDist(best) > cover * 1.05 {
                targetX = best
            }
            // else: no clean winner exists against this coverage — play on
            // and let the re-armed script end the rally soon
        } else if n < scriptN {
            // Keep every non-terminal shot honestly reachable given the
            // receiver's shuffle speed, reaction delay, and read noise
            let cover = reachCover(flightT: sol.flightT)
            targetX = max(opponent.x - cover, min(opponent.x + cover, targetX))
            targetX = max(-0.88, min(0.88, targetX))
        }
        sol.v.x = (targetX - ball.x) / sol.flightT
        bVel = sol.v
        applyEnding(shotN: n, targetX: targetX, targetZ: targetZ, flightT: sol.flightT)

        lastHitNear = facing > 0
        lastShotType = type
        mustBounce = (n == 2)   // the third shot must bounce (two-bounce rule)
        bounceCount = 0
        // The scripted put-away handcuffs the defender: they swing, but the
        // clean return isn't there (how most real winners actually win)
        winnerFlight = (n == scriptN && scriptEnding == .winner)

        // Phase bookkeeping + who advances where
        advanceAfterShot(n: n, type: type, facing: facing, hitter: &p)

        // Swing pose: contact happens now; the follow-through plays from impact
        p.contactY = min(0.70, max(0.03, ball.y))
        p.swingDur = swingDur(for: type)
        p.swingAmp = swingAmp(for: type)
        if !p.swingPhase || p.swingT < contactFrac {
            p.swingPhase = true
            p.swingT = contactFrac
        }

        designateAndPrimeReceiver(facing: -facing)

        let stance = p.stance == fhSide(p) ? "FH" : "BH"
        emitShot(n: n, type: type, facing: facing, stance: stance, x: ball.x,
                 targetX: targetX, flightT: sol.flightT, cross: cross)
    }

    // How far laterally the receiver can honestly cover during a flight —
    // deliberately conservative (reaction, read noise, and the slow final
    // adjustment all eat into the raw shuffle-speed × time budget)
    private func reachCover(flightT: CGFloat) -> CGFloat {
        latSpeedMax * max(0, flightT - 0.35) * 0.8 + hitWindow * 0.6
    }

    // Pick a landing x on the same side (straight) or across the body (cross-court)
    private func aimAcross(from x: CGFloat, cross: Bool) -> CGFloat {
        if cross {
            let sign: CGFloat = x >= 0 ? -1 : 1
            return sign * rand(0.30...0.85)
        }
        return max(-0.85, min(0.85, x + rand(-0.22...0.22)))
    }

    // Movement consequences of the shot just struck, and the phase label
    private func advanceAfterShot(n: Int, type: ShotType, facing: CGFloat, hitter: inout PlayerState) {
        switch n {
        case 1:
            phase = .serve
        case 2:
            phase = .returning
            // Run in behind the return — the receiving team owns the net first
            hitter.targetZ = kitchenZ(facing: facing)
        case 3:
            phase = .third
            if type == .thirdDrop {
                // The serving team advances together behind the drop
                teamAdvance(facing: facing, exceptIdx: nil)
                hitter.targetZ = kitchenZ(facing: facing)
            }
        default:
            // Soft shots buy time to keep working in — partners move as a unit
            if type == .drop || type == .reset || type == .dink {
                teamAdvance(facing: facing, exceptIdx: hitterIdx)
                hitter.targetZ = kitchenZ(facing: facing)
            }
            if type == .speedup || type == .counter {
                phase = .firefight
            } else if type == .lob {
                // The lob chases the other team off the kitchen line
                phase = .transition
                for i in indices(facing: -facing) {
                    players[i].targetZ = baselineZ(facing: -facing) + (facing > 0 ? -0.06 : 0.06)
                }
            } else {
                let bothIn = teamAtKitchen(facing: 1) && teamAtKitchen(facing: -1)
                phase = bothIn ? .kitchen : .transition
            }
        }
    }

    private func teamAdvance(facing: CGFloat, exceptIdx: Int?) {
        for i in indices(facing: facing) where i != exceptIdx {
            players[i].targetZ = kitchenZ(facing: facing)
        }
    }

    private func swingDur(for type: ShotType) -> CGFloat {
        switch type {
        case .speedup, .counter: return 0.24   // hands-battle flicks
        case .dink, .reset: return 0.38
        case .drive, .thirdDrive: return 0.45
        case .serve: return 0.55
        default: return 0.50
        }
    }

    private func swingAmp(for type: ShotType) -> CGFloat {
        switch type {
        case .speedup, .counter: return 0.5
        case .dink: return 0.55
        case .reset: return 0.6
        case .thirdDrop, .drop, .lob: return 0.8
        case .serve: return 0.9
        default: return 1.0
        }
    }

    // MARK: - Ball integration + adjudication

    private func integrateBall(dt: CGFloat, adjudicate: Bool) {
        ball.y += bVel.y * dt
        bVel.y += gravity * dt
        ball.x += bVel.x * dt
        ball.z += bVel.z * dt

        if ball.y < 0 {
            ball.y = 0
            bVel.y = abs(bVel.y) * bounceDamp
            guard adjudicate else { return }
            bounceCount += 1
            if bounceCount == 1 {
                // First bounce: out ends the point against the hitter
                let out = abs(ball.x) > 1.005 || ball.z < -0.005 || ball.z > 1.005
                if out {
                    pointOver(loserNear: lastHitNear,
                              reason: abs(ball.x) > 1.005 ? "wide" : "long")
                }
            } else if bounceCount >= 2 {
                // Nobody got there — clean winner for the last hitter
                pointOver(loserNear: !lastHitNear, reason: "winner")
            }
        }
    }

    private func pointOver(loserNear: Bool, reason: String) {
        rallyLostByNear = loserNear
        phase = .dead
        phaseTimer = 1.3
        statsSink?("rally shots=\(shotIndex) ending=\(reason) loser=\(loserNear ? "N" : "F")")
        for i in players.indices { players[i].hasPrediction = false }
    }

    // MARK: - Scoring (side-out; doubles rotates through both servers)

    private func scoreRally() {
        let serverLost = (nearServing == rallyLostByNear)
        if serverLost {
            if format == .doubles && serverNumber == 1 {
                // First server loses the rally: the partner serves next
                serverNumber = 2
            } else {
                // Side-out: serve passes to the other team
                nearServing.toggle()
                serverNumber = 1
            }
        } else {
            if nearServing { nearScore += 1 } else { farScore += 1 }
            if format == .doubles {
                // The serving pair swaps courts each time they score
                for i in indices(facing: nearServing ? 1 : -1) {
                    players[i].court = 1 - players[i].court
                }
            }
            let server   = nearServing ? nearScore : farScore
            let receiver = nearServing ? farScore : nearScore
            if server >= 11 && server - receiver >= 2 {
                if nearServing { nearGames += 1 } else { farGames += 1 }
                gameBannerTimer = 3.0
                nearScore = 0; farScore = 0
                serverNumber = 2   // every game opens on the 0-0-2 exception
                // Game winner (the server) serves first in the next game;
                // fresh game, fresh chance of a lefty in the lineup
                rollHands()
            }
        }
        beginBetweenPoints()
    }

    // MARK: - Player movement

    private func movePlayers(dt: CGFloat) {
        for i in players.indices { updatePlayer(i, dt: dt) }
    }

    private func updatePlayer(_ i: Int, dt: CGFloat) {
        var p = players[i]
        defer { players[i] = p }

        let inRally = phase != .betweenPoints && phase != .dead
        let ballComing = inRally && (p.facing > 0 ? bVel.z < 0 : bVel.z > 0)
        let isHitter = i == hitterIdx && ballComing

        if p.reactionTimer > 0 { p.reactionTimer -= dt }

        if isHitter && p.reactionTimer <= 0 {
            // Re-read the incoming ball every 0.15 s; the read error decays
            // as the ball gets closer, like a real player's tracking
            p.predClock -= dt
            let tta = timeToArrival(atZ: p.z)
            if !p.hasPrediction || p.predClock <= 0 {
                p.predClock = 0.15
                let total = max(0.2, flightTotalT(toZ: p.z))
                let frac = max(0, min(1, tta / total))
                p.predictedX = interceptX(atZ: p.z) + p.predNoise * frac
                p.hasPrediction = true
            }

            // Step deeper when a must-bounce ball (or a lob sailing overhead)
            // will land behind the body
            if (mustBounce || lastShotType == .lob) && bounceCount == 0 {
                let bz = bounceZ()
                let behind = p.facing > 0 ? min(bz - 0.05, p.z) : max(bz + 0.05, p.z)
                p.targetZ = p.facing > 0 ? min(p.targetZ, behind) : max(p.targetZ, behind)
            } else if bounceCount == 0 && abs(bVel.z) < 0.45 {
                // Soft incoming: step up and take the ball just past its
                // bounce (into the kitchen if needed — legal off the bounce)
                // instead of waiting at the line while it drifts wide
                let bz = bounceZ()
                if p.facing > 0 {
                    let intercept = bz - 0.04
                    if intercept > p.z { p.targetZ = min(0.47, intercept) }
                } else {
                    let intercept = bz + 0.04
                    if intercept < p.z { p.targetZ = max(0.53, intercept) }
                }
            }

            // Move the feet only when the ball is outside comfortable paddle
            // reach — real players hold their spot and take what comes to
            // them, stepping across (or running around to the forehand when
            // there's real time) only for wider balls.
            let fh = fhSide(p)
            let dx0 = p.predictedX - p.x
            if abs(dx0) > reach * 1.1 {
                let bias: CGFloat = (tta - 0.5) > 0.9 ? 1.0 : 0.3
                p.targetX = p.predictedX - fh * reach * bias
            } else {
                p.targetX = p.x
            }

            // Arm the backswing when contact is a windup away. Stroke side
            // follows the paddle-hip rule: only balls clearly on the paddle
            // side are forehands — anything at or across the body is a
            // backhand, exactly like a real player.
            if p.armed && tta > 0 && tta <= contactFrac * p.swingDur {
                let dx = p.predictedX - p.x
                let forehand = dx * fh > 0.04
                p.stance = forehand ? fh : -fh
                p.contactY = min(0.70, max(0.03, predictY(toZ: p.z)))
                p.swingDur = isAtKitchen(p) ? 0.38 : 0.5
                p.swingPhase = true
                p.swingT = max(0, contactFrac - tta / p.swingDur)
                p.armed = false
            }
        } else if inRally && !isHitter {
            // Off the ball: hold position, shifting with the play as a unit
            // and shading a touch to the backhand side so the forehand
            // covers more court (as real players are taught to)
            let shift = max(-0.15, min(0.15, ball.x * 0.15))
            p.targetX = p.homeX + shift - fhSide(p) * 0.04
            p.armed = true
            if !ballComing { p.hasPrediction = false }
        }

        // Split-step: a small dip of the ready paddle during the reaction
        // beat after every opponent contact
        if !p.swingPhase {
            p.faceY = 0.08 - 0.02 * min(1, max(0, p.reactionTimer) / 0.15)
        }

        // Feet: capped shuffle laterally, slower fine adjustments up close
        let dxAbs = abs(p.targetX - p.x)
        let latCap = dxAbs < 0.25 ? latSpeedNear : latSpeedMax
        p.x = moveVal(p.x, toward: p.targetX, speed: latCap * dt, lo: -1.1, hi: 1.1)

        // Depth: run when there's ground to cover, jog the final steps,
        // and slow (not stop) while lining up a hit
        let zDist = abs(p.targetZ - p.z)
        let zSpd = (zDist > 0.12 ? runInSpeed : advanceSpeed) * (isHitter ? 0.6 : 1.0)
        p.z = moveVal(p.z, toward: p.targetZ, speed: zSpd * dt, lo: 0.01, hi: 0.99)
    }

    // Both timing helpers tolerate floor bounces because z-velocity is
    // unchanged by a bounce.
    private func timeToArrival(atZ z: CGFloat) -> CGFloat {
        guard abs(bVel.z) > 0.0001 else { return -1 }
        return (z - ball.z) / bVel.z
    }

    private func flightTotalT(toZ z: CGFloat) -> CGFloat {
        guard abs(bVel.z) > 0.0001 else { return 1 }
        return abs((z - ball.z) / bVel.z)
    }

    private func interceptX(atZ z: CGFloat) -> CGFloat {
        let t = timeToArrival(atZ: z)
        guard t > 0 else { return ball.x }
        return ball.x + bVel.x * t
    }

    // Where the current flight's first bounce lands (z), from the closed form
    private func bounceZ() -> CGFloat {
        let disc = bVel.y * bVel.y + 2 * -gravity * ball.y
        let t = (bVel.y + sqrt(max(0, disc))) / -gravity
        return ball.z + bVel.z * t
    }

    // Vertical speed the current flight will land with
    private func landingVy() -> CGFloat {
        -sqrt(max(0, bVel.y * bVel.y + 2 * -gravity * ball.y))
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

    // Where the paddle is drawn: at the contact offset while swinging,
    // otherwise held ready slightly on the forehand side
    func paddleWx(_ p: PlayerState) -> CGFloat {
        let fh = p.facing * p.hand
        let backhand = p.swingPhase && p.stance != fh
        return p.x + (p.swingPhase ? p.stance : fh * 0.7) * (backhand ? reachBackhand : reach)
    }

    // MARK: - Swing animation

    private func updateSwings(dt: CGFloat) {
        for i in players.indices {
            updateSwing(&players[i], dt: dt)
        }
    }

    // Advance the swing pose. The paddle face center traces the stroke path:
    // ready → back-and-down windup → one fluid low-to-high sweep whose midpoint
    // is ball contact (face horizontal, ball on the face center) → high forward
    // finish → settle back to ready.
    private func updateSwing(_ p: inout PlayerState, dt: CGFloat) {
        guard p.swingPhase else { return }
        let facing = p.facing
        p.swingT += dt / p.swingDur
        let drop = swingDrop * p.swingAmp
        let len = swingLen * p.swingAmp
        let yLow  = max(0.03, p.contactY - drop)
        let yHigh = p.contactY + (p.contactY - yLow)   // symmetric: contact at the sweep midpoint
        let t = p.swingT
        if t < backswingFrac {
            // Windup: paddle drifts back (away from the net) and down
            let e = smoothstep(t / backswingFrac)
            p.faceDZ = -facing * len * e
            p.faceY  = restFaceY + (yLow - restFaceY) * e
            p.swingAngle = readyAngle + (backswingAngle - readyAngle) * e
        } else if t < 1 {
            // Forward stroke: one continuous low-back → high-forward sweep,
            // fastest at the middle where the ball is struck. The angle is
            // interpolated piecewise so the face is exactly horizontal at the
            // midpoint despite the asymmetric windup/finish angles.
            let e = smoothstep((t - backswingFrac) / (1 - backswingFrac))
            p.faceDZ = facing * len * (2 * e - 1)
            p.faceY  = yLow + (yHigh - yLow) * e
            p.swingAngle = e < 0.5 ? backswingAngle * (1 - 2 * e)
                                   : followAngle * (2 * e - 1)
        } else if t < 1 + recoveryFrac {
            // Recovery: ease from the high finish back to the ready position
            let e = smoothstep((t - 1) / recoveryFrac)
            p.faceDZ = facing * len * (1 - e)
            p.faceY  = yHigh + (restFaceY - yHigh) * e
            p.swingAngle = followAngle + (readyAngle - followAngle) * e
        } else {
            p.swingPhase = false
            p.swingT = 0; p.swingAngle = readyAngle; p.faceDZ = 0; p.faceY = restFaceY
        }
    }

    // MARK: - Stats

    private func emitShot(n: Int, type: ShotType, facing: CGFloat, stance: String,
                          x: CGFloat, targetX: CGFloat, flightT: CGFloat, cross: Bool = false) {
        guard let sink = statsSink else { return }
        // Ground speed in mph from the unit velocities
        let ftps = sqrt(pow(bVel.x * Court.ftPerX, 2) + pow(bVel.z * Court.ftPerZ, 2))
        let mph = ftps / 1.4667
        sink("shot n=\(n) type=\(type.rawValue) side=\(facing > 0 ? "N" : "F") " +
             "stance=\(stance) x=\(String(format: "%.2f", x)) " +
             "tx=\(String(format: "%.2f", targetX)) mph=\(String(format: "%.0f", mph)) " +
             "t=\(String(format: "%.2f", flightT)) cross=\(cross ? 1 : 0)")
    }

    // MARK: - Helpers

    private func moveVal(_ v: CGFloat, toward t: CGFloat, speed: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        let d = t - v
        let step = min(abs(d), speed) * (d >= 0 ? 1 : -1)
        return max(lo, min(hi, v + step))
    }
}
