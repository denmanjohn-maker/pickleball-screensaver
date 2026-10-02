import AppKit

enum ArtEvent {
    case contact(position: Vec3, facing: CGFloat)
    case bounce(Vec3)
}

struct ArtFrame {
    let number: Int
    let events: [ArtEvent]
    let ball: Vec3
    let live: Bool
    let games: Int
}

struct ArtPulse {
    let position: Vec3
    let facing: CGFloat
    var age: CGFloat = 0
}

struct PaintSample {
    let position: Vec3
    var anchor: Bool
}

struct PaintStroke {
    let id: Int
    let facing: CGFloat
    var samples: [PaintSample]
    var fadeRemaining: CGFloat?

    var opacity: CGFloat { fadeRemaining.map { smoothstep($0 / ArtEffects.gameFadeDuration) } ?? 1 }
}

final class ArtEffects {
    static let maxRipples = 24
    static let maxHalos = 16
    static let maxStrokes = 96
    static let maxSamples = 128
    static let rippleDuration: CGFloat = 1.2
    static let haloDuration: CGFloat = 0.35
    static let gameFadeDuration: CGFloat = 2

    private(set) var ripples: [ArtPulse] = []
    private(set) var halos: [ArtPulse] = []
    private(set) var strokes: [PaintStroke] = []
    private var lastFrame: Int?
    private var lastGames: Int?
    private var nextStrokeID = 0
    private var painting = false
    private var sampleClock: CGFloat = 0
    private var projectionKey: [CGPoint] = []
    private var brushCache: [Int: (ribbon: CGPath, spine: CGPath)] = [:]

    func reset() {
        ripples.removeAll()
        halos.removeAll()
        strokes.removeAll()
        lastFrame = nil
        lastGames = nil
        nextStrokeID = 0
        painting = false
        sampleClock = 0
        projectionKey.removeAll()
        brushCache.removeAll()
    }

    func update(preset: AppearancePreset, frame: ArtFrame, dt: CGFloat) {
        guard preset == .livingCourt || preset == .rallyPainting else { return }
        guard lastFrame != frame.number else { return }
        lastFrame = frame.number

        for i in ripples.indices { ripples[i].age += dt }
        for i in halos.indices { halos[i].age += dt }
        ripples.removeAll { $0.age >= Self.rippleDuration }
        halos.removeAll { $0.age >= Self.haloDuration }
        for i in strokes.indices {
            if let remaining = strokes[i].fadeRemaining { strokes[i].fadeRemaining = remaining - dt }
        }
        strokes.removeAll { ($0.fadeRemaining ?? 1) <= 0 }
        if let games = lastGames, games != frame.games {
            painting = false
            for i in strokes.indices { strokes[i].fadeRemaining = Self.gameFadeDuration }
        }
        lastGames = frame.games

        for event in frame.events {
            switch event {
            case .contact(let position, let facing):
                if preset == .livingCourt {
                    halos.append(ArtPulse(position: position, facing: facing))
                    if halos.count > Self.maxHalos { halos.removeFirst() }
                } else {
                    appendSample(position, anchor: true)
                    startStroke(position, facing: facing)
                }
            case .bounce(let position):
                if preset == .livingCourt {
                    ripples.append(ArtPulse(position: position, facing: 0))
                    if ripples.count > Self.maxRipples { ripples.removeFirst() }
                } else {
                    appendSample(position, anchor: true)
                }
            }
        }
        if preset == .rallyPainting {
            sampleClock += dt
            if frame.live && sampleClock >= 1 / 30 {
                appendSample(frame.ball, anchor: false)
                sampleClock.formTruncatingRemainder(dividingBy: 1 / 30)
            }
            if !frame.live { painting = false; sampleClock = 0 }
        }
        let liveIDs = Set(strokes.map(\.id))
        brushCache = brushCache.filter { liveIDs.contains($0.key) }
    }

    private func startStroke(_ position: Vec3, facing: CGFloat) {
        if strokes.count >= Self.maxStrokes { strokes.removeFirst() }
        nextStrokeID += 1
        strokes.append(PaintStroke(id: nextStrokeID, facing: facing,
                                   samples: [PaintSample(position: floor(position), anchor: true)]))
        painting = true
        sampleClock = 0
        // Start fading before eviction, leaving room for the next several rallies.
        for i in 0..<max(0, strokes.count - 80) where strokes[i].fadeRemaining == nil {
            strokes[i].fadeRemaining = Self.gameFadeDuration
        }
    }

    private func appendSample(_ position: Vec3, anchor: Bool) {
        guard painting, let index = strokes.indices.last else { return }
        let point = floor(position)
        let previous = strokes[index].samples.last!.position
        if hypot((point.x - previous.x) * Court.ftPerX, (point.z - previous.z) * Court.ftPerZ) < 0.01 {
            if anchor { strokes[index].samples[strokes[index].samples.count - 1].anchor = true }
            return
        }
        if strokes[index].samples.count >= Self.maxSamples {
            let samples = strokes[index].samples
            strokes[index].samples = samples.enumerated().compactMap { i, sample in
                i == 0 || i == samples.count - 1 || sample.anchor || i.isMultiple(of: 2) ? sample : nil
            }
            // Real flights have at most two bounce anchors; retain a hard bound even for synthetic input.
            if strokes[index].samples.count >= Self.maxSamples { strokes[index].samples.remove(at: 1) }
        }
        strokes[index].samples.append(PaintSample(position: point, anchor: anchor))
        brushCache.removeValue(forKey: strokes[index].id)
    }

    private func floor(_ position: Vec3) -> Vec3 { Vec3(x: position.x, y: 0, z: position.z) }

    func drawFloor(_ ctx: CGContext, preset: AppearancePreset, theme: Theme,
                   project: (Vec3) -> CGPoint, courtCorners: [CGPoint]) {
        guard preset == .livingCourt || preset == .rallyPainting else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        if preset == .livingCourt {
            for ripple in ripples {
                let progress = ripple.age / Self.rippleDuration
                for ring in 0..<2 {
                    let radius = (0.25 + progress * 1.7) * (ring == 0 ? 1 : 0.68)
                    let path = CGMutablePath()
                    for i in 0...48 {
                        let angle = CGFloat(i) * .pi * 2 / 48
                        let p = project(Vec3(x: ripple.position.x + cos(angle) * radius / Court.ftPerX,
                                             y: 0, z: ripple.position.z + sin(angle) * radius / Court.ftPerZ))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    ctx.setStrokeColor(theme.accent.withAlphaComponent(0.30 * (1 - smoothstep(progress))).cgColor)
                    ctx.setLineWidth(ring == 0 ? 1.5 : 0.8)
                    ctx.addPath(path)
                    ctx.strokePath()
                }
            }
        } else if preset == .rallyPainting {
            if projectionKey != courtCorners {
                projectionKey = courtCorners
                brushCache.removeAll(keepingCapacity: true)
            }
            for stroke in strokes where stroke.samples.count > 1 {
                let paths = brushCache[stroke.id] ?? brushPaths(stroke, project: project)
                brushCache[stroke.id] = paths
                let color = theme.teamColor(facing: stroke.facing)
                ctx.setFillColor(color.withAlphaComponent(0.28 * stroke.opacity).cgColor)
                ctx.addPath(paths.ribbon)
                ctx.fillPath()
                ctx.setStrokeColor(color.withAlphaComponent(0.18 * stroke.opacity).cgColor)
                ctx.setLineWidth(0.7)
                ctx.addPath(paths.spine)
                ctx.strokePath()
            }
        }
    }

    func drawHalos(_ ctx: CGContext, theme: Theme, behindNet: Bool,
                   project: (Vec3) -> CGPoint, pixelsPerFoot: (Vec3) -> CGFloat,
                   isBehindNet: (Vec3) -> Bool) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        for halo in halos where isBehindNet(halo.position) == behindNet {
            let progress = halo.age / Self.haloDuration
            let r = max(3, pixelsPerFoot(halo.position) * (0.5 + progress * 0.7))
            let p = project(halo.position)
            ctx.setStrokeColor(theme.teamColor(facing: halo.facing)
                .withAlphaComponent(0.45 * (1 - smoothstep(progress))).cgColor)
            ctx.setLineWidth(1.5 * (1 - progress) + 0.5)
            ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
    }

    private func brushPaths(_ stroke: PaintStroke, project: (Vec3) -> CGPoint) -> (ribbon: CGPath, spine: CGPath) {
        let points = stroke.samples.map(\.position)
        var left: [CGPoint] = [], right: [CGPoint] = []
        let spine = CGMutablePath()
        for i in points.indices {
            let p = points[i], before = points[max(0, i - 1)], after = points[min(points.count - 1, i + 1)]
            let dx = (after.x - before.x) * Court.ftPerX, dz = (after.z - before.z) * Court.ftPerZ
            let length = max(0.001, hypot(dx, dz))
            let t = CGFloat(i) / CGFloat(points.count - 1)
            let halfWidth = 0.12 + 0.34 * sin(.pi * t)
            let ox = -dz / length * halfWidth / Court.ftPerX
            let oz = dx / length * halfWidth / Court.ftPerZ
            left.append(project(Vec3(x: p.x + ox, y: 0, z: p.z + oz)))
            right.append(project(Vec3(x: p.x - ox, y: 0, z: p.z - oz)))
            if i == 0 { spine.move(to: project(p)) } else { spine.addLine(to: project(p)) }
        }
        let ribbon = CGMutablePath()
        ribbon.move(to: left[0])
        for p in left.dropFirst() { ribbon.addLine(to: p) }
        for p in right.reversed() { ribbon.addLine(to: p) }
        ribbon.closeSubpath()
        return (ribbon, spine)
    }
}
