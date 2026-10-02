import AppKit

var failures: [String] = []
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition(), failures.count < 30 { failures.append(message) }
}

struct RunResult {
    var fingerprint: [String] = []
    var shots = 0
    var serves = 0
    var kitchenGroundstrokes = 0
    var dinks = 0
    var maxDinkMPH: CGFloat = 0
    var endings: [String: Int] = [:]
    var lengths: [Int] = []
    var types: [ShotType: Int] = [:]
}

func run(
    format: GameFormat, seed: UInt64, fps: Int = 60, seconds: Int = 3600,
    configure: (RallyEngine) -> Void = { _ in }
) -> RunResult {
    let engine = RallyEngine()
    engine.setFormat(format)
    configure(engine)
    engine.reseed(seed)
    var result = RunResult()
    var lastID = 0
    var previousServe: ShotContact?
    var activeContact: ShotContact?
    var flightBounces = 0
    engine.statsSink = { line in
        result.fingerprint.append(line)
        if line.hasPrefix("rally ") {
            let fields = Dictionary(
                uniqueKeysWithValues: line.split(separator: " ").dropFirst().map {
                    let pair = $0.split(separator: "=", maxSplits: 1)
                    return (String(pair[0]), String(pair[1]))
                })
            result.endings[fields["ending"]!, default: 0] += 1
            result.lengths.append(Int(fields["shots"]!)!)
            if let expected = engine.lastContact?.intendedEnding, expected != .winner {
                check(
                    fields["ending"] == expected.rawValue, "Scripted \(expected.rawValue) became \(fields["ending"]!)")
            }
        }
    }
    for _ in 0..<(seconds * fps) {
        engine.step(dt: 1 / CGFloat(fps))
        check(
            engine.ball.x.isFinite && engine.ball.y.isFinite && engine.ball.z.isFinite,
            "Non-finite ball state")
        for player in engine.players where player.volleyRecovery > 0 {
            check(!Court.feetInKitchen(player.z), "Volley momentum entered kitchen")
        }
        var eventsSeen = 0
        for event in engine.frameEvents {
            if case .bounce(let point) = event {
                check(point.y == 0, "Floor bounce not on floor")
                if flightBounces == 0, let contact = activeContact {
                    check(
                        abs(point.x - contact.landing.x) < 1e-6 && abs(point.z - contact.landing.z) < 1e-6,
                        "Bounce event not at exact predicted landing")
                }
                flightBounces += 1
                continue
            }
            guard case .contact(let contact) = event else { continue }
            eventsSeen += 1
            activeContact = contact
            flightBounces = 0
            result.shots += 1
            result.types[contact.type, default: 0] += 1
            let player = contact.player
            let label = "\(format.rawValue) seed=\(seed) shot=\(contact.number)"
            check(abs(engine.paddleWx(player) - contact.ball.x) < 1e-9, "Lateral contact gap: \(label)")
            check(abs(player.faceY - contact.ball.y) < 1e-9, "Vertical contact gap: \(label)")
            check(abs(player.z + player.faceDZ - contact.ball.z) < 1e-9, "Depth contact gap: \(label)")
            check(player.swingAngle == 0, "Impact not synchronized with swing: \(label)")
            if contact.number == 1 {
                result.serves += 1
                check(
                    player.facing > 0 ? player.z < -0.01 : player.z > 1.01,
                    "Server inside baseline: \(label)")
                let rightSign: CGFloat = player.facing > 0 ? -1 : 1
                check(
                    player.x * rightSign * (player.court == 0 ? 1 : -1) > 0,
                    "Server outside assigned service court: \(label)")
                if format == .singles {
                    check(player.court == contact.servingScore % 2, "Wrong singles service parity: \(label)")
                } else if let previous = previousServe {
                    if previous.player.facing != player.facing {
                        check(player.court == 0 && engine.serverNumber == 1, "Side-out did not start on right")
                    } else if contact.servingScore == previous.servingScore + 1 {
                        check(contact.playerIndex == previous.playerIndex, "Server changed after scoring")
                        check(player.court != previous.player.court, "Serving pair did not swap courts")
                    } else if contact.servingScore == previous.servingScore {
                        check(
                            contact.playerIndex != previous.playerIndex && engine.serverNumber == 2,
                            "Second server did not take over")
                    }
                } else {
                    check(player.court == 0 && engine.serverNumber == 2, "Invalid 0-0-2 opener")
                }
                if contact.intendedEnding == nil {
                    check(contact.landing.x * contact.ball.x < 0, "Serve not diagonal")
                    check(
                        player.facing > 0
                            ? contact.landing.z > Court.kitchenFarZ : contact.landing.z < Court.kitchenNearZ,
                        "Serve landed in kitchen")
                }
                previousServe = contact
            } else {
                check(
                    player.swingReach <= (player.stance == player.facing * player.hand ? 0.24 : 0.20) + 1e-9,
                    "Contact outside physical arm reach: \(label)")
                if contact.number <= 3 { check(contact.receivedBounces == 1, "Two-bounce rule violated: \(label)") }
                if contact.receivedBounces == 0 {
                    check(player.kitchenEstablished && !Court.feetInKitchen(player.z), "Kitchen volley: \(label)")
                } else if Court.feetInKitchen(player.z) {
                    result.kitchenGroundstrokes += 1
                }
            }
            let mph = hypot(contact.velocity.x * Court.ftPerX, contact.velocity.z * Court.ftPerZ) / 1.4667
            if contact.type == .dink {
                result.dinks += 1
                result.maxDinkMPH = max(result.maxDinkMPH, mph)
                check(mph < 25, "Implausibly fast dink: \(mph) mph")
            }
        }
        check(engine.contactCount - lastID == eventsSeen, "Contact batch lost events")
        lastID = engine.contactCount
    }
    let mid = result.lengths.filter { (3...10).contains($0) }.count
    print(
        "\(format.rawValue) seed=\(seed) fps=\(fps): rallies=\(result.lengths.count) shots=\(result.shots) "
            + "3to10=\(mid) dinks=\(result.dinks) maxDinkMPH=\(String(format: "%.1f", result.maxDinkMPH)) "
            + "kitchenGroundstrokes=\(result.kitchenGroundstrokes) endings=\(result.endings)")
    check(result.shots > seconds / 4, "Simulation stalled")
    return result
}

if !CommandLine.arguments.contains("--camera-only") {
    var referenceResults: [GameFormat: RunResult] = [:]
    for format in [GameFormat.doubles, .singles] {
        for seed: UInt64 in [1, 42, 314159] {
            let reference = run(format: format, seed: seed)
            let rallyCount = Double(reference.lengths.count)
            let midFraction = Double(reference.lengths.filter { (3...10).contains($0) }.count) / rallyCount
            let errorFraction = 1 - Double(reference.endings["winner", default: 0]) / rallyCount
            check((0.50...0.80).contains(midFraction), "Rally-length distribution drifted")
            check((0.45...0.85).contains(errorFraction), "Error/winner mix drifted")
            if seed == 42 {
                referenceResults[format] = reference
                for fps in [144, 30, 20] {
                    let other = run(format: format, seed: seed, fps: fps)
                    check(other.fingerprint == reference.fingerprint, "Frame-rate-dependent simulation at \(fps) fps")
                }
            }
        }
    }

    let doubles = referenceResults[.doubles]!
    let singles = referenceResults[.singles]!
    check(
        Double(singles.dinks) / Double(singles.shots) < Double(doubles.dinks) / Double(doubles.shots) * 0.5,
        "Singles is not tactically distinct from doubles")
    check(doubles.kitchenGroundstrokes > 0 && singles.kitchenGroundstrokes > 0, "Kitchen groundstrokes disappeared")
    for result in [doubles, singles] {
        check(result.endings["long", default: 0] >= 10, "Long errors disappeared")
        check(result.endings["wide", default: 0] >= 10, "Wide errors disappeared")
        check(result.endings["net", default: 0] >= 10, "Net errors disappeared")
    }
    for format in [GameFormat.doubles, .singles] {
        let drive = run(format: format, seed: 7, seconds: 600) { $0.thirdDriveFrac = 1 }
        check(drive.types[.thirdDrop, default: 0] == 0, "Forced drive produced third-shot drop")
        let drop = run(format: format, seed: 7, seconds: 600) { $0.thirdDriveFrac = 0 }
        check(drop.types[.thirdDrive, default: 0] == 0, "Forced drop produced third-shot drive")
        let lob = run(format: format, seed: 7, seconds: 600) { $0.lobProb = 1 }
        check(lob.types[.lob, default: 0] > 0, "Forced lob produced no lobs")
        let hands = run(format: format, seed: 7, seconds: 600) { $0.speedupProbPerDink = 1 }
        check(hands.types[.speedup, default: 0] > 0, "Forced speed-up produced none")
        _ = run(format: format, seed: 7, seconds: 600) {
            $0.leftyProb = 1
            $0.runAroundProb = 0
            $0.endingErrorFrac = 0
        }
    }

}

if !CommandLine.arguments.contains("--engine-only") {
    for size in [
        NSSize(width: 1280, height: 720), NSSize(width: 1440, height: 900),
        NSSize(width: 1080, height: 1920), NSSize(width: 3440, height: 1440),
        NSSize(width: 320, height: 180)
    ] {
        let view = PickleballScreensaverView(frame: NSRect(origin: .zero, size: size), isPreview: true)!
        view.courtMotion = .slow
        view.ambientEnabled = false
        for degree in 0..<360 {
            view.previewYaw = CGFloat(degree) * .pi / 180
            view.step(now: 90, dt: 0)
            for (x, z, y) in [
                (-1.0, 0.0, 0.0), (1.0, 0.0, 0.0),
                (-1.0, 1.0, 0.0), (1.0, 1.0, 0.0),
                (-1.0, 0.5, 0.32), (1.0, 0.5, 0.32)
            ] {
                let point = view.projectedPoint(Vec3(x: x, y: y, z: z))
                check(
                    view.sceneRect.insetBy(dx: -0.5, dy: -0.5).contains(point),
                    "Scene clipped at \(size) yaw=\(degree)")
            }
            let lob = view.projectedPoint(Vec3(x: 0, y: 2.0, z: 0.5))
            check(view.bounds.contains(lob), "Central lob clipped at \(size)")
            if degree == 0 || degree == 180 {
                check(
                    view.isBehindNet(Vec3(x: 0, y: 0.1, z: 0.8)) == (degree == 0),
                    "Far-side net occlusion did not reverse")
                check(
                    view.isBehindNet(Vec3(x: 0, y: 0.1, z: 0.2)) == (degree == 180),
                    "Near-side net occlusion did not reverse")
            }
        }
        let before = view.projectedPoint(Vec3(x: 1, y: 0, z: 1))
        view.setFrameSize(NSSize(width: size.width + 100, height: size.height + 100))
        let after = view.projectedPoint(Vec3(x: 1, y: 0, z: 1))
        check(before != after, "Projection cache ignored a mid-spin resize")
        view.previewYaw = nil
        view.courtMotion = .still
        view.step(now: 59, dt: 1.0 / 60)
        view.step(now: 60, dt: 1.0 / 60)
        check(view.courtYaw == 0, "No-spin preference ignored")
        var active = false
        view.simStats = { line in
            if line.hasPrefix("shot ") { active = true }
            if line.hasPrefix("rally ") { active = false }
        }
        for motion in CourtMotion.allCases {
            view.courtMotion = motion
            view.lobProb = 1
            view.reseed(7)
            for i in 0..<9000 {
                view.step(now: 55 + Double(i) / 30, dt: 1.0 / 30)
                let ball = view.ballPosition
                if active && ball.y > 0.3 && abs(ball.x) < 1 && (0...1).contains(ball.z) {
                    check(
                        view.bounds.contains(view.projectedPoint(ball)),
                        "Live lob clipped with \(motion.rawValue) motion at \(size)")
                }
            }
        }
    }

    _ = NSApplication.shared
    let controller = ConfigureSheetController()
    controller.refresh()
    let content = controller.window.contentView!
    content.layoutSubtreeIfNeeded()
    func popups(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { popups(in: $0) }
    }
    check(
        popups(in: content).contains {
            $0.itemTitles == ["Slow spin (12 seconds)", "Original spin (6 seconds)", "No spin"]
        },
        "Court-motion choices missing from Options")
    for popup in popups(in: content) {
        check(content.bounds.contains(popup.convert(popup.bounds, to: content)), "Options popup clipped")
    }
}

if !failures.isEmpty {
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    exit(1)
}
print("All regression checks passed")
