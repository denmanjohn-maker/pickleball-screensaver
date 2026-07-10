#!/usr/bin/env swift
// Generates the System Settings thumbnails (Contents/Resources/thumbnail.png and
// thumbnail@2x.png) from the paddle sprite. Run from the repo root:
//   swift scripts/make_thumbnails.swift
// The output PNGs are committed; this script is not part of the build.
import AppKit

let paddleURL = URL(fileURLWithPath: "PickleballScreensaver/Resources/paddle.png")
guard let paddle = NSImage(contentsOf: paddleURL)?
    .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("paddle.png not found — run from the repo root")
}

func writeThumbnail(width: Int, height: Int, to path: String) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let W = CGFloat(width), H = CGFloat(height)

    // Dark teal background matching the screensaver
    ctx.setFillColor(CGColor(red: 0.05, green: 0.09, blue: 0.10, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // Subtle radial glow in the center
    let glowColors = [CGColor(red: 0.12, green: 0.24, blue: 0.23, alpha: 0.45),
                      CGColor(red: 0.05, green: 0.09, blue: 0.10, alpha: 0)] as CFArray
    let locs: [CGFloat] = [0, 1]
    if let grad = CGGradient(colorsSpace: space, colors: glowColors, locations: locs) {
        let center = CGPoint(x: W * 0.45, y: H * 0.55)
        let radius = max(W, H) * 0.65
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
    }

    // Paddle — angled −25°, large, pivot at center-left
    let ph = H * 0.92
    let pw = ph * CGFloat(paddle.width) / CGFloat(paddle.height)
    ctx.saveGState()
    ctx.translateBy(x: W * 0.40, y: H * 0.50)
    ctx.rotate(by: -25 * .pi / 180)
    ctx.draw(paddle, in: CGRect(x: -pw / 2, y: -ph / 2, width: pw, height: ph))
    ctx.restoreGState()

    // Pickleball — yellow circle with a few holes suggesting the real thing
    let ballR = H * 0.19
    let ballX = W * 0.76
    let ballY = H * 0.31
    ctx.setFillColor(CGColor(red: 0.91, green: 0.87, blue: 0.18, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: ballX - ballR, y: ballY - ballR,
                               width: ballR * 2, height: ballR * 2))
    // Holes
    ctx.setFillColor(CGColor(red: 0.55, green: 0.52, blue: 0.06, alpha: 0.85))
    let holeR = ballR * 0.22
    for (dx, dy): (CGFloat, CGFloat) in [(-ballR * 0.38,  ballR * 0.20),
                                          ( ballR * 0.10, -ballR * 0.35),
                                          ( ballR * 0.38,  ballR * 0.22)] {
        ctx.fillEllipse(in: CGRect(x: ballX + dx - holeR, y: ballY + dy - holeR,
                                   width: holeR * 2, height: holeR * 2))
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: width, height: height)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(width)x\(height))")
}

writeThumbnail(width: 90,  height: 58,  to: "PickleballScreensaver/Resources/thumbnail.png")
writeThumbnail(width: 180, height: 116, to: "PickleballScreensaver/Resources/thumbnail@2x.png")
