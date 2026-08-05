import Cocoa

// usage: rasterize <in.svg> <out.png> <width> [height]
let args = CommandLine.arguments
guard args.count >= 4, let pw = Int(args[3]),
      let img = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: rasterize <in.svg> <out.png> <width> [height]\n".data(using: .utf8)!)
    exit(1)
}
let px = pw
let ph = args.count > 4 ? Int(args[4]) ?? pw : pw
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: ph,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(2) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: px, height: ph),
         from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { exit(3) }
try! data.write(to: URL(fileURLWithPath: args[2]))
