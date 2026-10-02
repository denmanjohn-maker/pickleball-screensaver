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
//   --size=WxH     render at a different size (default 1280x720)
//   --motion=slow|standard|still  override saved court motion
//   --yaw=N        hold the camera at N degrees for an occlusion snapshot
//   --frame=N      write only the Nth sampled frame
//   --sample-every=N  write every Nth simulation step (default every 2 at 60 fps)
//   --fps=N        simulation/display cadence (default 60; engine stays at 120 Hz)
import AppKit

let args = CommandLine.arguments
func usageError(_ message: String) -> Never {
    fputs("preview: \(message)\n", stderr)
    exit(2)
}
func flagValue(_ name: String) -> String? {
    args.first(where: { $0.hasPrefix("--\(name)=") }).map { String($0.dropFirst(name.count + 3)) }
}
func positiveInt(_ name: String, fallback: Int) -> Int {
    guard let value = flagValue(name) else { return fallback }
    guard let number = Int(value), number > 0 else { fatalError("bad --\(name)=\(value)") }
    return number
}
let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
let outDir = positional.count > 0 ? positional[positional.startIndex] : "/tmp/pbpreview-frames"
let seconds = positional.count > 1 ? Double(positional[positional.index(positional.startIndex, offsetBy: 1)]) ?? 10 : 10
let startClock = positional.count > 2 ? Double(positional[positional.index(positional.startIndex, offsetBy: 2)]) ?? 90 : 90
guard seconds.isFinite, seconds > 0, startClock.isFinite, startClock >= 0 else {
    fatalError("seconds must be positive and startClock must be nonnegative")
}
let simOnly = args.contains("--sim-only")
let wantStats = args.contains("--stats")
let fps = positiveInt("fps", fallback: 60)
guard (4...240).contains(fps) else { fatalError("--fps must be between 4 and 240") }
guard let frames = Int(exactly: (seconds * Double(fps)).rounded(.towardZero)), frames > 0 else {
    usageError("duration must contain at least one display step and fit an integer step count")
}
let sampleEvery = positiveInt("sample-every", fallback: max(1, fps / 30))
let size = (flagValue("size") ?? "1280x720").split(separator: "x")
guard size.count == 2, let width = Int(size[0]), let height = Int(size[1]), width > 0, height > 0 else {
    fatalError("--size must be positive WIDTHxHEIGHT")
}
var selectedFrame: Int?
if let value = flagValue("frame") {
    guard let frame = Int(value), frame >= 0, frame <= (frames - 1) / sampleEvery else {
        usageError("--frame must identify a sampled frame within the requested duration")
    }
    selectedFrame = frame
}

let outURL = URL(fileURLWithPath: outDir, isDirectory: true)
if !simOnly {
    do {
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
    } catch {
        fatalError("cannot create output directory \(outURL.path): \(error.localizedDescription)")
    }
}

guard let view = PickleballScreensaverView(frame: NSRect(x: 0, y: 0, width: width, height: height),
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
if let value = flagValue("motion") {
    guard let motion = CourtMotion(rawValue: value) else { fatalError("bad --motion=\(value)") }
    view.courtMotion = motion
}
if let value = flagValue("yaw") {
    guard let yaw = Double(value), yaw.isFinite else { fatalError("bad --yaw=\(value)") }
    view.previewYaw = CGFloat(yaw) * .pi / 180
}

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
if seeded { view.ambientEnabled = false }

var now = startClock
var written = 0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for i in 0..<frames {
    now += 1.0 / Double(fps)
    if seeded { view.previewDate = Date(timeIntervalSince1970: 1_791_014_400 + now) }
    view.step(now: now, dt: 1 / CGFloat(fps))
    guard !simOnly, i % sampleEvery == 0,
          selectedFrame == nil || selectedFrame == i / sampleEvery else { continue }
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
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
    let frameURL = outURL.appendingPathComponent(String(format: "frame_%05d.png", i / sampleEvery))
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
