// Offscreen preview harness: drives the screensaver with a synthetic clock and
// writes numbered PNG frames, so animation changes can be reviewed without
// installing the saver. Not part of the `make` build. Build and run from the
// repo root (asset loading falls back to paths relative to the CWD):
//
//   swiftc -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" \
//     -framework Cocoa -framework ScreenSaver \
//     PickleballScreensaver/*.swift scripts/preview/main.swift -o /tmp/pbpreview
//   /tmp/pbpreview /tmp/frames [seconds] [startClock] [--rush|--no-rush] [--cross] [--clean]
//
// startClock sets the synthetic wall clock (seconds): the turntable spin fires
// at each minute boundary, so 55 shows a spin 5 s in, 90 keeps short runs flat.
// Flags: --rush forces a kitchen rush every rally, --no-rush disables rushes,
// --cross makes every backhand go cross-court, --clean disables random faults.
import AppKit

let args = CommandLine.arguments
let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
let outDir = positional.count > 0 ? positional[positional.startIndex] : "/tmp/pbpreview-frames"
let seconds = positional.count > 1 ? Double(positional[positional.index(positional.startIndex, offsetBy: 1)]) ?? 10 : 10
let startClock = positional.count > 2 ? Double(positional[positional.index(positional.startIndex, offsetBy: 2)]) ?? 90 : 90

let outURL = URL(fileURLWithPath: outDir, isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
} catch {
    fatalError("cannot create output directory \(outURL.path): \(error.localizedDescription)")
}

guard let view = PickleballScreensaverView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                           isPreview: true) else {
    fatalError("failed to create PickleballScreensaverView")
}
if args.contains("--rush")    { view.rushProb = 1.0 }
if args.contains("--no-rush") { view.rushProb = 0.0 }
if args.contains("--cross")   { view.crossCourtProb = 1.0 }
if args.contains("--clean")   { view.netFaultProb = 0; view.passingShotProb = 0 }

let fps = 60.0
let frames = Int(seconds * fps)
var now = startClock
var written = 0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for i in 0..<frames {
    now += 1.0 / fps
    view.step(now: now, dt: CGFloat(1.0 / fps))
    guard i % 2 == 0 else { continue }   // save at 30 png/s
    guard let ctx = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("failed to create bitmap context")
    }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    view.draw(view.bounds)
    NSGraphicsContext.current = nil
    guard let img = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
        fatalError("failed to encode frame \(i)")
    }
    let frameURL = outURL.appendingPathComponent(String(format: "frame_%05d.png", written))
    do {
        try png.write(to: frameURL)
    } catch {
        fatalError("cannot write \(frameURL.path): \(error.localizedDescription)")
    }
    written += 1
}
print("wrote \(written) frames to \(outDir)")
