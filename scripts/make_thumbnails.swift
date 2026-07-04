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

    // Court-green background with a thin white boundary, echoing the court lines
    ctx.setFillColor(CGColor(red: 0.30, green: 0.53, blue: 0.40, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let inset = H * 0.06
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.setLineWidth(max(1, H * 0.025))
    ctx.stroke(CGRect(x: inset, y: inset, width: W - 2 * inset, height: H - 2 * inset))

    // Paddle aspect-fit, centered (tall sprite, so height-constrained)
    let pad = H * 0.10
    let ph = H - 2 * pad
    let pw = ph * CGFloat(paddle.width) / CGFloat(paddle.height)
    ctx.draw(paddle, in: CGRect(x: (W - pw) / 2, y: (H - ph) / 2, width: pw, height: ph))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: width, height: height)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(width)x\(height))")
}

writeThumbnail(width: 90,  height: 58,  to: "PickleballScreensaver/Resources/thumbnail.png")
writeThumbnail(width: 180, height: 116, to: "PickleballScreensaver/Resources/thumbnail@2x.png")
