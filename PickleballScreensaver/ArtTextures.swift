import AppKit

private struct PaperNoise {
    private var state: UInt64 = 0x5041_5045_525F_4152
    mutating func unit() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
    }
}

enum ArtTextures {
    private static let paper: CGImage = {
        guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            preconditionFailure("Unable to allocate paper texture")
        }
        var noise = PaperNoise()
        for _ in 0..<3000 {
            let x = noise.unit() * 256, y = noise.unit() * 256
            let width = 0.3 + noise.unit() * 1.5
            ctx.setFillColor(CGColor(red: 0.30, green: 0.24, blue: 0.14, alpha: 0.015 + noise.unit() * 0.06))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: width, height: 0.4 + noise.unit()))
        }
        guard let image = ctx.makeImage() else { preconditionFailure("Unable to create paper texture") }
        return image
    }()

    private static let washes: [[Vec3]] = {
        var noise = PaperNoise()
        return (0..<48).map { index in
            let x = (index % 2 == 0 ? -0.5 : 0.5) + (noise.unit() - 0.5) * 0.6
            let z = (index % 4 < 2 ? 0.16 : 0.84) + (noise.unit() - 0.5) * 0.18
            let rx = 0.10 + noise.unit() * 0.32, rz = 0.025 + noise.unit() * 0.06
            return (0..<24).map { i in
                let angle = CGFloat(i) * .pi * 2 / 24
                let roughness = 0.85 + noise.unit() * 0.25
                return Vec3(x: x + cos(angle) * rx * roughness, y: 0,
                            z: z + sin(angle) * rz * roughness)
            }
        }
    }()

    private static let fibers: [(Vec3, Vec3)] = {
        var noise = PaperNoise()
        return (0..<900).map { _ in
            let p = Vec3(x: noise.unit() * 2 - 1, y: 0, z: noise.unit())
            return (p, Vec3(x: p.x + noise.unit() * 0.012, y: 0, z: p.z + noise.unit() * 0.003))
        }
    }()

    static func drawPaper(_ ctx: CGContext, in rect: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        for x in stride(from: rect.minX, to: rect.maxX, by: 256) {
            for y in stride(from: rect.minY, to: rect.maxY, by: 256) {
                ctx.draw(paper, in: CGRect(x: x, y: y, width: 256, height: 256))
            }
        }
    }

    static func drawCourt(_ ctx: CGContext, theme: Theme, project: (Vec3) -> CGPoint) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        for (index, wash) in washes.enumerated() {
            let path = CGMutablePath()
            path.move(to: project(wash[0]))
            for p in wash.dropFirst() { path.addLine(to: project(p)) }
            path.closeSubpath()
            let color = index.isMultiple(of: 3) ? theme.teamB : theme.teamA
            ctx.setFillColor(color.withAlphaComponent(index.isMultiple(of: 3) ? 0.025 : 0.045).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.setLineWidth(0.45)
        ctx.setStrokeColor(CGColor(red: 0.30, green: 0.25, blue: 0.17, alpha: 0.08))
        ctx.beginPath()
        for (a, b) in fibers {
            ctx.move(to: project(a))
            ctx.addLine(to: project(b))
        }
        ctx.strokePath()
    }

    static func drawInkTrail(_ ctx: CGContext, points: [Vec3], color: NSColor, behindNet: Bool,
                             project: (Vec3) -> CGPoint, radius: (Vec3) -> CGFloat,
                             isBehindNet: (Vec3) -> Bool) {
        guard points.count > 1 else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            guard isBehindNet(a) == behindNet && isBehindNet(b) == behindNet else { continue }
            let t = CGFloat(i) / CGFloat(points.count)
            ctx.setStrokeColor(color.withAlphaComponent(t * 0.24).cgColor)
            ctx.setLineWidth(max(0.5, radius(b) * t * 0.7))
            ctx.move(to: project(a))
            ctx.addLine(to: project(b))
            ctx.strokePath()
        }
    }
}
