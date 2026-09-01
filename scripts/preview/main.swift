// Offscreen preview harness: drives the screensaver with a synthetic clock and
// writes numbered PNG frames, so animation changes can be reviewed without
// installing the saver. Not part of the `make` build. Build and run from the
// repo root (asset loading falls back to paths relative to the CWD):
//
//   swiftc -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" \
//     -framework Cocoa -framework ScreenSaver \
//     PickleballScreensaver/*.swift scripts/preview/main.swift -o /tmp/pbpreview
//   /tmp/pbpreview /tmp/frames [seconds] [startClock] [flags]
//
// startClock sets the synthetic wall clock (seconds): the turntable spin fires
// at each minute boundary, so 55 shows a spin 5 s in, 90 keeps short runs flat.
// Flags:
//   --seed=N       deterministic simulation (replays the same rallies every run)
//   --stats        print per-shot log lines and end-of-run aggregates
//   --sim-only     run the simulation without rendering (fast; for distributions)
//   --singles / --doubles        force the game format
//   --blacklight / --classic     force the theme (overrides saved settings)
//   --force-drop / --force-drive every third shot is a drop / drive
//   --force-speedup / --force-lob / --lefty   force those behaviors
//   --no-runaround time-rich backhands are never run around for a forehand
//   --clean        rallies end on winners only (no scripted errors)
import AppKit

let args = CommandLine.arguments
let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
let outDir = positional.count > 0 ? positional[positional.startIndex] : "/tmp/pbpreview-frames"
let seconds = positional.count > 1 ? Double(positional[positional.index(positional.startIndex, offsetBy: 1)]) ?? 10 : 10
let startClock = positional.count > 2 ? Double(positional[positional.index(positional.startIndex, offsetBy: 2)]) ?? 90 : 90
let simOnly = args.contains("--sim-only")
let wantStats = args.contains("--stats")

let outURL = URL(fileURLWithPath: outDir, isDirectory: true)
if !simOnly {
    do {
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
    } catch {
        fatalError("cannot create output directory \(outURL.path): \(error.localizedDescription)")
    }
}

guard let view = PickleballScreensaverView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                           isPreview: true) else {
    fatalError("failed to create PickleballScreensaverView")
}
if args.contains("--force-drop")  { view.thirdDriveFrac = 0.0 }
if args.contains("--force-drive") { view.thirdDriveFrac = 1.0 }
if args.contains("--clean")       { view.endingErrorFrac = 0.0 }
if args.contains("--singles")       { view.setFormat(.singles) }
if args.contains("--doubles")       { view.setFormat(.doubles) }
if args.contains("--lefty")         { view.leftyProb = 1.0 }
if args.contains("--force-speedup") { view.speedupProbPerDink = 1.0 }
if args.contains("--force-lob")     { view.lobProb = 1.0 }
if args.contains("--no-runaround")  { view.runAroundProb = 0.0 }
if args.contains("--blacklight")    { view.applyTheme(.blacklight) }
if args.contains("--classic")       { view.applyTheme(.classic) }   // override a saved theme

// Aggregates accumulated from the engine's stats lines
var rallyLengths: [Int] = []
var strokes = (fh: 0, bh: 0)
var endings: [String: Int] = [:]
var dinks = (cross: 0, total: 0)
if wantStats {
    view.simStats = { line in
        print(line)
        let fields = line.split(separator: " ")
        func value(_ key: String) -> String? {
            fields.first(where: { $0.hasPrefix(key + "=") }).map { String($0.dropFirst(key.count + 1)) }
        }
        if line.hasPrefix("rally ") {
            if let n = value("shots").flatMap({ Int($0) }) { rallyLengths.append(n) }
            if let e = value("ending") { endings[e, default: 0] += 1 }
        }
        if line.hasPrefix("shot ") {
            if line.contains(" stance=FH") { strokes.fh += 1 }
            if line.contains(" stance=BH") { strokes.bh += 1 }
            if value("type") == "dink" {
                dinks.total += 1
                if value("cross") == "1" { dinks.cross += 1 }
            }
        }
    }
}

// Seed AFTER the tunables and sink are wired so the whole run is deterministic.
// Flags that change per-player rolls (--lefty) need a reseed to take effect
// immediately, so an unseeded run still gets a fresh (entropy) reseed.
var seeded = false
for a in args where a.hasPrefix("--seed=") {
    guard let s = UInt64(a.dropFirst("--seed=".count)) else { fatalError("bad \(a)") }
    view.reseed(s)
    seeded = true
}
if !seeded && args.contains("--lefty") {
    view.reseed(UInt64.random(in: .min ... .max))
}

let fps = 60.0
let frames = Int(seconds * fps)
var now = startClock
var written = 0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for i in 0..<frames {
    now += 1.0 / fps
    view.step(now: now, dt: CGFloat(1.0 / fps))
    guard !simOnly, i % 2 == 0 else { continue }   // save at 30 png/s
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

if wantStats, !rallyLengths.isEmpty {
    let total = rallyLengths.count
    let mid = rallyLengths.reduce(0) { $0 + ($1 >= 3 && $1 <= 10 ? 1 : 0) }
    let strokesTotal = strokes.fh + strokes.bh
    let bhFrac = strokesTotal > 0 ? Double(strokes.bh) / Double(strokesTotal) : 0
    let endingStr = endings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    let dinkCross = dinks.total > 0 ? String(format: "%.0f%%", 100 * Double(dinks.cross) / Double(dinks.total)) : "n/a"
    print("summary rallies=\(total) shots-min=\(rallyLengths.min()!) shots-max=\(rallyLengths.max()!) " +
          "shots-3to10=\(String(format: "%.0f%%", 100 * Double(mid) / Double(total))) " +
          "backhands=\(String(format: "%.0f%%", 100 * bhFrac)) (\(strokes.bh)/\(strokesTotal)) " +
          "dink-cross=\(dinkCross) (\(dinks.cross)/\(dinks.total)) endings: \(endingStr)")
}
if simOnly {
    print("simulated \(seconds) s (\(frames) steps), no frames written")
} else {
    print("wrote \(written) frames to \(outDir)")
}
