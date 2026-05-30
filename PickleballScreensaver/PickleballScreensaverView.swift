import ScreenSaver
import AppKit

class PickleballScreensaverView: ScreenSaverView {

    // MARK: - Ball state
    private var ballPos = CGPoint.zero
    private var ballVel = CGPoint(x: 340, y: 170)
    private var trailPoints: [(pos: CGPoint, alpha: CGFloat)] = []

    // MARK: - Paddle state
    private var leftPaddleY: CGFloat = 0
    private var rightPaddleY: CGFloat = 0

    // MARK: - Layout constants
    private let courtInset: CGFloat = 55
    private let paddleXOffset: CGFloat = 68     // distance from screen edge to paddle center
    private let paddleFaceW: CGFloat = 15        // paddle face width  (x-axis, thin)
    private let paddleFaceH: CGFloat = 74        // paddle face height (y-axis, tall)
    private let handleLen: CGFloat = 30
    private let handleW: CGFloat = 11
    private let ballR: CGFloat = 11

    // MARK: - Rally state
    private var rallyCount = 0
    private var lastFrameTime: TimeInterval = 0

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
        resetBall(goRight: true)
    }

    private func resetBall(goRight: Bool) {
        ballPos = CGPoint(x: bounds.midX, y: bounds.midY)
        let angle = CGFloat.random(in: -0.38...0.38)
        let spd: CGFloat = 320
        let dx: CGFloat = goRight ? 1 : -1
        ballVel = CGPoint(x: dx * spd * cos(angle), y: spd * sin(angle))
        leftPaddleY  = bounds.midY
        rightPaddleY = bounds.midY
        trailPoints.removeAll()
    }

    // MARK: - Animation loop

    override func animateOneFrame() {
        let now = Date().timeIntervalSinceReferenceDate
        let dt: CGFloat = lastFrameTime == 0 ? 1.0/60.0 : min(CGFloat(now - lastFrameTime), 0.05)
        lastFrameTime = now

        // Move ball
        ballPos.x += ballVel.x * dt
        ballPos.y += ballVel.y * dt

        // Bounce off top/bottom court walls
        let topWall    = courtInset + ballR
        let bottomWall = bounds.height - courtInset - ballR

        if ballPos.y < topWall {
            ballPos.y = topWall
            ballVel.y = abs(ballVel.y)
        } else if ballPos.y > bottomWall {
            ballPos.y = bottomWall
            ballVel.y = -abs(ballVel.y)
        }

        // Paddle AI – track the ball, capped to paddle speed
        let paddleSpeed: CGFloat = 240
        let pMin = courtInset + paddleFaceH / 2
        let pMax = bounds.height - courtInset - paddleFaceH / 2

        leftPaddleY  = move(leftPaddleY,  toward: ballPos.y, speed: paddleSpeed * dt, min: pMin, max: pMax)
        rightPaddleY = move(rightPaddleY, toward: ballPos.y, speed: paddleSpeed * dt, min: pMin, max: pMax)

        // Paddle collision
        let leftFaceX  = paddleXOffset + paddleFaceW / 2
        let rightFaceX = bounds.width - paddleXOffset - paddleFaceW / 2

        if ballVel.x < 0,
           ballPos.x - ballR <= leftFaceX,
           ballPos.x > leftFaceX - paddleFaceW - ballR,
           abs(ballPos.y - leftPaddleY) <= paddleFaceH / 2 + ballR {
            ballPos.x = leftFaceX + ballR
            reflectBall(paddleY: leftPaddleY, goingRight: true)
            rallyCount += 1
        }

        if ballVel.x > 0,
           ballPos.x + ballR >= rightFaceX,
           ballPos.x < rightFaceX + paddleFaceW + ballR,
           abs(ballPos.y - rightPaddleY) <= paddleFaceH / 2 + ballR {
            ballPos.x = rightFaceX - ballR
            reflectBall(paddleY: rightPaddleY, goingRight: false)
            rallyCount += 1
        }

        // Reset if ball exits (missed)
        if ballPos.x < -80 || ballPos.x > bounds.width + 80 {
            let goRight = ballPos.x < 0
            resetBall(goRight: goRight)
        }

        // Trail
        trailPoints.append((pos: ballPos, alpha: 1.0))
        if trailPoints.count > 14 { trailPoints.removeFirst() }

        setNeedsDisplay(bounds)
    }

    private func move(_ current: CGFloat, toward target: CGFloat, speed: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        let diff = target - current
        let step = min(abs(diff), speed) * (diff >= 0 ? 1 : -1)
        return Swift.max(min, Swift.min(max, current + step))
    }

    private func reflectBall(paddleY: CGFloat, goingRight: Bool) {
        let hitFrac = (ballPos.y - paddleY) / (paddleFaceH / 2)   // -1 … +1
        let currentSpeed = sqrt(ballVel.x * ballVel.x + ballVel.y * ballVel.y)
        let newSpeed = Swift.min(currentSpeed * 1.035, 680)
        let angle = hitFrac * 0.62
        let dx: CGFloat = goingRight ? 1 : -1
        ballVel = CGPoint(x: dx * newSpeed * cos(angle), y: newSpeed * sin(angle))
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawBackground(ctx: ctx, rect: rect)
        drawCourt(ctx: ctx, rect: rect)
        drawNet(ctx: ctx, rect: rect)
        drawTrail(ctx: ctx)
        drawPaddle(ctx: ctx, centerX: paddleXOffset, centerY: leftPaddleY, facingRight: true)
        drawPaddle(ctx: ctx, centerX: bounds.width - paddleXOffset, centerY: rightPaddleY, facingRight: false)
        drawBall(ctx: ctx, at: ballPos)
        drawRallyCounter(ctx: ctx, rect: rect)
    }

    // MARK: Background

    private func drawBackground(ctx: CGContext, rect: NSRect) {
        // Deep navy background
        ctx.setFillColor(CGColor(red: 0.04, green: 0.07, blue: 0.14, alpha: 1))
        ctx.fill(rect)

        // Subtle radial glow at center
        let colors = [CGColor(red: 0.10, green: 0.20, blue: 0.40, alpha: 0.6),
                      CGColor(red: 0.04, green: 0.07, blue: 0.14, alpha: 0)] as CFArray
        let locs: [CGFloat] = [0, 1]
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let grad = CGGradient(colorsSpace: space, colors: colors, locations: locs) {
            ctx.drawRadialGradient(
                grad,
                startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                endCenter:   CGPoint(x: rect.midX, y: rect.midY), endRadius: Swift.max(rect.width, rect.height) * 0.65,
                options: []
            )
        }
    }

    // MARK: Court surface + lines

    private func drawCourt(ctx: CGContext, rect: NSRect) {
        let court = rect.insetBy(dx: courtInset, dy: courtInset)

        // Court surface
        ctx.setFillColor(CGColor(red: 0.13, green: 0.42, blue: 0.72, alpha: 1))
        ctx.fill(court)

        // Non-volley zone (kitchen) shading
        let kitchenFrac: CGFloat = 0.155        // ~7 ft on a 44-ft court
        let kitchenW = court.width * kitchenFrac

        ctx.setFillColor(CGColor(red: 0.09, green: 0.32, blue: 0.60, alpha: 1))
        ctx.fill(CGRect(x: court.minX, y: court.minY, width: kitchenW, height: court.height))
        ctx.fill(CGRect(x: court.maxX - kitchenW, y: court.minY, width: kitchenW, height: court.height))

        // White court lines
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
        ctx.setLineWidth(2.5)

        // Outer boundary
        ctx.stroke(court)

        // Center line (horizontal — splits service courts top/bottom)
        let midY = rect.midY
        line(ctx, from: CGPoint(x: court.minX, y: midY), to: CGPoint(x: court.maxX, y: midY))

        // Kitchen lines (vertical, 7 ft from net on each side)
        let leftKitchenX  = rect.midX - kitchenW
        let rightKitchenX = rect.midX + kitchenW

        line(ctx, from: CGPoint(x: leftKitchenX,  y: court.minY), to: CGPoint(x: leftKitchenX,  y: court.maxY))
        line(ctx, from: CGPoint(x: rightKitchenX, y: court.minY), to: CGPoint(x: rightKitchenX, y: court.maxY))
    }

    // MARK: Net

    private func drawNet(ctx: CGContext, rect: NSRect) {
        let court     = rect.insetBy(dx: courtInset, dy: courtInset)
        let netX      = rect.midX
        let netTop    = court.minY
        let netBottom = court.maxY
        let netHalf: CGFloat = 5   // half-width of rendered net band

        // Net mesh lines (fine horizontal strands)
        ctx.setStrokeColor(CGColor(red: 0.55, green: 0.58, blue: 0.65, alpha: 0.55))
        ctx.setLineWidth(0.8)
        var y = netTop + 4
        while y < netBottom - 2 {
            line(ctx, from: CGPoint(x: netX - netHalf, y: y), to: CGPoint(x: netX + netHalf, y: y))
            y += 5
        }

        // Net band (solid vertical centre bar)
        ctx.setStrokeColor(CGColor(red: 0.85, green: 0.87, blue: 0.92, alpha: 1))
        ctx.setLineWidth(10)
        line(ctx, from: CGPoint(x: netX, y: netTop), to: CGPoint(x: netX, y: netBottom))

        // White tape at top of net
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(3)
        line(ctx, from: CGPoint(x: netX - netHalf, y: netBottom - 6), to: CGPoint(x: netX + netHalf, y: netBottom - 6))
        line(ctx, from: CGPoint(x: netX - netHalf, y: netTop  + 6), to: CGPoint(x: netX + netHalf, y: netTop  + 6))

        // Net post circles at top & bottom edges
        ctx.setFillColor(CGColor(red: 0.75, green: 0.78, blue: 0.82, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: netX - 6, y: netBottom - 6, width: 12, height: 12))
        ctx.fillEllipse(in: CGRect(x: netX - 6, y: netTop    - 6, width: 12, height: 12))
    }

    // MARK: Ball trail

    private func drawTrail(ctx: CGContext) {
        let count = trailPoints.count
        for (i, t) in trailPoints.enumerated() {
            let frac = CGFloat(i) / CGFloat(count)
            let r    = ballR * frac * 0.7
            let a    = frac * 0.35
            ctx.setFillColor(CGColor(red: 1, green: 0.92, blue: 0.2, alpha: a))
            ctx.fillEllipse(in: CGRect(x: t.pos.x - r, y: t.pos.y - r, width: r * 2, height: r * 2))
        }
    }

    // MARK: Paddle

    private func drawPaddle(ctx: CGContext, centerX: CGFloat, centerY: CGFloat, facingRight: Bool) {
        // Handle extends away from the net (opposite to hit direction)
        let handleSign: CGFloat = facingRight ? -1 : 1    // left paddle handle goes left

        let faceRect = CGRect(
            x: centerX - paddleFaceW / 2,
            y: centerY - paddleFaceH / 2,
            width: paddleFaceW,
            height: paddleFaceH
        )

        // Handle rect (x-axis only; same vertical centre as face)
        let handleStartX = facingRight ? (faceRect.minX - handleLen) : faceRect.maxX
        let handleRect = CGRect(
            x: handleStartX,
            y: centerY - handleW / 2,
            width: handleLen,
            height: handleW
        )

        // -- Drop shadow --
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 3, height: -4), blur: 8,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        // Handle grip (brown)
        ctx.setFillColor(CGColor(red: 0.32, green: 0.16, blue: 0.06, alpha: 1))
        ctx.addPath(CGPath(roundedRect: handleRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()

        // Paddle edge (dark)
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        ctx.addPath(CGPath(roundedRect: faceRect, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.fillPath()

        ctx.restoreGState()

        // Paddle face (vivid blue)
        let innerFace = faceRect.insetBy(dx: 2, dy: 2)
        ctx.setFillColor(CGColor(red: 0.14, green: 0.36, blue: 0.82, alpha: 1))
        ctx.addPath(CGPath(roundedRect: innerFace, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.fillPath()

        // Face highlight (upper half lighter)
        let highlightRect = CGRect(
            x: innerFace.minX + 2, y: innerFace.midY,
            width: innerFace.width - 4, height: innerFace.height / 2 - 2
        )
        ctx.setFillColor(CGColor(red: 0.30, green: 0.52, blue: 0.95, alpha: 0.45))
        ctx.addPath(CGPath(roundedRect: highlightRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()

        // Grip wrap lines on handle
        ctx.setStrokeColor(CGColor(red: 0.20, green: 0.10, blue: 0.03, alpha: 0.7))
        ctx.setLineWidth(1.2)
        let wrapStep: CGFloat = 5
        var wx = handleRect.minX + 4
        while wx < handleRect.maxX - 2 {
            line(ctx, from: CGPoint(x: wx, y: handleRect.minY + 1), to: CGPoint(x: wx, y: handleRect.maxY - 1))
            wx += wrapStep
        }
    }

    // MARK: Ball

    private func drawBall(ctx: CGContext, at pos: CGPoint) {
        // Shadow
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        ctx.fillEllipse(in: CGRect(x: pos.x - ballR + 3, y: pos.y - ballR - 4,
                                   width: ballR * 2, height: ballR * 2))

        // Body (outdoor pickleball yellow-green)
        ctx.setFillColor(CGColor(red: 0.94, green: 0.91, blue: 0.14, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: pos.x - ballR, y: pos.y - ballR,
                                   width: ballR * 2, height: ballR * 2))

        // Highlight
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.72, alpha: 0.65))
        ctx.fillEllipse(in: CGRect(x: pos.x - ballR * 0.45, y: pos.y + ballR * 0.1,
                                   width: ballR * 0.8, height: ballR * 0.55))

        // Holes (pickleball has 26–40 holes; show a representative pattern)
        ctx.setFillColor(CGColor(red: 0.74, green: 0.70, blue: 0.04, alpha: 0.85))
        let offsets: [(CGFloat, CGFloat)] = [
            (-0.42, 0), (0.42, 0), (0, 0.42), (0, -0.42),
            (-0.27,  0.30), (0.27,  0.30),
            (-0.27, -0.30), (0.27, -0.30)
        ]
        for (dx, dy) in offsets {
            let hr: CGFloat = 1.9
            ctx.fillEllipse(in: CGRect(
                x: pos.x + dx * ballR - hr,
                y: pos.y + dy * ballR - hr,
                width: hr * 2, height: hr * 2
            ))
        }
    }

    // MARK: Rally counter

    private func drawRallyCounter(ctx: CGContext, rect: NSRect) {
        let label = "Rally  \(rallyCount)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.45)
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: rect.midX - size.width / 2,
                             y: rect.height - courtInset + 8))
    }

    // MARK: Helpers

    private func line(_ ctx: CGContext, from a: CGPoint, to b: CGPoint) {
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    // MARK: ScreenSaverView overrides

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
