import AppKit

var failures: [String] = []
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition(), failures.count < 30 { failures.append(message) }
}
let origin = Vec3(x: -0.4, y: 0.2, z: 0.1)
let bounce = Vec3(x: 0.3, y: 0, z: 0.75)
func frame(_ number: Int, events: [ArtEvent] = [], ball: Vec3 = origin,
           live: Bool = true, games: Int = 0) -> ArtFrame {
    ArtFrame(number: number, events: events, ball: ball, live: live, games: games)
}
func bitmap(width: Int = 320, height: Int = 180, draw: (CGContext) -> Void) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(ctx)
    return Data(bytes: ctx.data!, count: width * height * 4)
}

let suite = "com.pickleball.art-tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
check(ThemeSettings.load(from: defaults).appearance == .classic, "Fresh settings are not Classic")
check(ThemeSettings(theme: "classic").appearance == .classic, "Classic saved identifier changed")
check(ThemeSettings(theme: "blacklight").appearance == .blacklight, "Black Light saved identifier changed")
check(ThemeSettings(theme: "future-preset").appearance == .classic, "Unknown saved choice not compatible")
for preset in AppearancePreset.allCases {
    var settings = ThemeSettings()
    settings.appearance = preset
    settings.save(to: defaults)
    check(ThemeSettings.load(from: defaults).appearance == preset, "Appearance did not persist: \(preset)")
    check(Theme.named(preset.rawValue).backgroundBase == preset.theme.backgroundBase, "Theme resolution differs")
}
defaults.removePersistentDomain(forName: suite)
check(AppearancePreset.allCases.map(\.title) ==
      ["Classic", "Black Light", "Living Court", "Ink-and-paper", "Rally Painting"], "Preset catalog differs")

let living = ArtEffects()
let impactFrame = frame(1, events: [.contact(position: origin, facing: 1), .bounce(bounce),
                                    .contact(position: bounce, facing: -1)])
living.update(preset: .livingCourt, frame: impactFrame, dt: 1 / 60)
check(living.ripples.count == 1 && living.halos.count == 2, "Ordered frame batch dropped impacts")
check(living.ripples[0].position.y == 0 && living.halos[0].position.y == origin.y, "Impact positions altered")
living.update(preset: .livingCourt, frame: impactFrame, dt: 1)
check(living.ripples.count == 1 && living.halos[0].age == 0, "Duplicate frame replayed or aged effects")
for n in 2...40 {
    living.update(preset: .livingCourt,
                  frame: frame(n, events: [.contact(position: origin, facing: 1), .bounce(bounce)]), dt: 0)
}
check(living.ripples.count == ArtEffects.maxRipples, "Ripple hard limit not enforced")
check(living.halos.count == ArtEffects.maxHalos, "Halo hard limit not enforced")
for n in 41...120 { living.update(preset: .livingCourt, frame: frame(n, live: false), dt: 1 / 60) }
check(living.ripples.isEmpty && living.halos.isEmpty, "Expired impacts retained")

let paint = ArtEffects()
paint.update(preset: .rallyPainting,
             frame: frame(1, events: [.contact(position: origin, facing: 1), .bounce(bounce),
                                      .contact(position: bounce, facing: -1)]), dt: 0)
check(paint.strokes.count == 2 && paint.strokes[0].samples.count == 2, "Contact did not separate strokes")
check(paint.strokes[0].facing == 1 && paint.strokes[1].facing == -1, "Team identity lost")
paint.update(preset: .rallyPainting, frame: frame(2, live: false), dt: 1 / 60)
let completedCount = paint.strokes.last!.samples.count
paint.update(preset: .rallyPainting, frame: frame(3, ball: Vec3(x: 8, y: 0, z: 8), live: false), dt: 1 / 60)
check(paint.strokes.last!.samples.count == completedCount, "Dead-ball settling painted")
paint.update(preset: .rallyPainting, frame: frame(4, events: [.contact(position: origin, facing: 1)]), dt: 0)
check(paint.strokes.count == 3 && paint.strokes.last!.samples.count == 1, "Rally restart joined old artwork")
paint.update(preset: .rallyPainting, frame: frame(5, live: false, games: 1), dt: 0)
check(paint.strokes.allSatisfy { $0.fadeRemaining == 2 }, "Game end did not begin dissolve")
paint.update(preset: .rallyPainting,
             frame: frame(6, events: [.contact(position: origin, facing: -1)], games: 1), dt: 0.25)
check(paint.strokes.last!.fadeRemaining == nil, "New-game stroke dissolved with old game")
for n in 7...15 { paint.update(preset: .rallyPainting, frame: frame(n, games: 1), dt: 0.25) }
check(paint.strokes.count == 1, "Old-game painting not removed after dissolve")

paint.reset()
paint.update(preset: .rallyPainting, frame: frame(1, events: [.contact(position: origin, facing: 1)]), dt: 0)
for n in 2...1200 {
    let p = Vec3(x: -0.4 + CGFloat(n) / 1000, y: 0.2, z: 0.1 + CGFloat(n) / 2000)
    let events: [ArtEvent] = n == 100 ? [.bounce(bounce)] : []
    paint.update(preset: .rallyPainting, frame: frame(n, events: events, ball: p), dt: 1 / 30)
    check(paint.strokes[0].samples.count <= ArtEffects.maxSamples, "Stroke sample budget exceeded")
}
check(paint.strokes[0].samples[0].position.x == origin.x, "Decimation lost launch anchor")
check(paint.strokes[0].samples.contains { $0.anchor && $0.position.x == bounce.x && $0.position.z == bounce.z },
      "Decimation lost bounce anchor")
let project: (Vec3) -> CGPoint = { CGPoint(x: 80 + $0.x * 100, y: 20 + $0.z * 130) }
let corners = [Vec3(x: -1, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0),
               Vec3(x: 1, y: 0, z: 1), Vec3(x: -1, y: 0, z: 1)].map(project)
let sampleCount = paint.strokes[0].samples.count
let image1 = bitmap { paint.drawFloor($0, preset: .rallyPainting, theme: AppearancePreset.rallyPainting.theme,
                                     project: project, courtCorners: corners) }
let image2 = bitmap { paint.drawFloor($0, preset: .rallyPainting, theme: AppearancePreset.rallyPainting.theme,
                                     project: project, courtCorners: corners) }
check(image1 == image2 && paint.strokes[0].samples.count == sampleCount, "Redraw mutated painting or cache output")
let paper1 = bitmap { ArtTextures.drawPaper($0, in: CGRect(x: 0, y: 0, width: 320, height: 180)) }
let paper2 = bitmap { ArtTextures.drawPaper($0, in: CGRect(x: 0, y: 0, width: 320, height: 180)) }
check(paper1 == paper2, "Paper texture changes on redraw")
for n in 1201...1400 {
    paint.update(preset: .rallyPainting,
                 frame: frame(n, events: [.contact(position: origin, facing: 1)]), dt: 0)
}
check(paint.strokes.count == ArtEffects.maxStrokes, "Stroke history hard limit not enforced")
check(paint.strokes.prefix(16).allSatisfy { $0.fadeRemaining != nil }, "Capacity eviction has no fade")
paint.reset()
check(paint.strokes.isEmpty && paint.ripples.isEmpty && paint.halos.isEmpty, "Reset left visual history")

for format in [GameFormat.singles, .doubles] {
    var reference: [String]?
    for preset in AppearancePreset.allCases {
        let view = PickleballScreensaverView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), isPreview: true)!
        view.ambientEnabled = false
        view.courtMotion = .still
        view.setFormat(format)
        view.applyAppearance(preset)
        var fingerprint: [String] = []
        view.simStats = { fingerprint.append($0) }
        view.reseed(42)
        for n in 0..<36000 { view.step(now: 90 + Double(n) / 60, dt: 1 / 60) }
        check(!fingerprint.isEmpty, "Game comparison produced no shots")
        if let reference { check(reference == fingerprint, "\(preset) changes \(format) gameplay") }
        else { reference = fingerprint }
    }
}

let engine = RallyEngine()
engine.reseed(42)
let longPainting = ArtEffects()
var impactCount = 0
var gamesSeen = 0
for n in 0..<216000 {
    engine.step(dt: 1 / 60)
    let events: [ArtEvent] = engine.frameEvents.map {
        switch $0 {
        case .contact(let c): impactCount += 1; return .contact(position: c.ball, facing: c.player.facing)
        case .bounce(let p): return .bounce(p)
        }
    }
    gamesSeen = engine.nearGames + engine.farGames
    longPainting.update(preset: .rallyPainting,
                        frame: frame(n, events: events, ball: engine.ball,
                                     live: engine.phase != .betweenPoints && engine.phase != .dead,
                                     games: gamesSeen), dt: 1 / 60)
    check(longPainting.strokes.count <= ArtEffects.maxStrokes, "Long simulation exceeded stroke limit")
    check(longPainting.strokes.allSatisfy { $0.samples.count <= ArtEffects.maxSamples },
          "Long simulation exceeded sample limit")
}
check(impactCount > 1000 && gamesSeen > 0, "Long artwork check did not cover games and many shots")

_ = NSApplication.shared
let controller = ConfigureSheetController()
controller.refresh()
let content = controller.window.contentView!
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let controls = descendants(content)
let popup = controls.compactMap { $0 as? NSPopUpButton }
    .first { $0.itemTitles == AppearancePreset.allCases.map(\.title) }
check(popup != nil, "Appearance menu missing choices")
let saved = ThemeSettings.load().theme
for preset in AppearancePreset.allCases {
    popup?.selectItem(withTitle: preset.title)
    content.layoutSubtreeIfNeeded()
    check(content.bounds.contains(popup!.convert(popup!.bounds, to: content)), "Appearance menu clipped")
}
let cancel = controls.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!
cancel.performClick(nil)
check(ThemeSettings.load().theme == saved, "Cancel saved a selection")
controller.refresh()
check(popup?.titleOfSelectedItem == ThemeSettings(theme: saved).appearance.title, "Refresh kept cancelled selection")

func render(_ view: PickleballScreensaverView) -> Data {
    bitmap(width: Int(view.bounds.width), height: Int(view.bounds.height)) { ctx in
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        view.draw(view.bounds)
        NSGraphicsContext.current = nil
    }
}
func artView(_ preset: AppearancePreset) -> PickleballScreensaverView {
    let view = PickleballScreensaverView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), isPreview: true)!
    view.ambientEnabled = false
    view.courtMotion = .still
    view.previewDate = Date(timeIntervalSince1970: 1_791_014_400)
    view.applyAppearance(preset)
    view.reseed(42)
    return view
}
let retained = artView(.rallyPainting)
for n in 0..<1200 { retained.step(now: 90 + Double(n) / 60, dt: 1 / 60) }
let beforeUnchangedOptions = render(retained)
retained.applyAppearance(.rallyPainting)
check(render(retained) == beforeUnchangedOptions, "Unchanged appearance erased accumulated painting")
retained.applyAppearance(.classic)
retained.applyAppearance(.rallyPainting)
check(render(retained) != beforeUnchangedOptions, "Changing appearance did not reset painting")

let classicView = artView(.classic)
let livingView = artView(.livingCourt)
var comparedImpact = false
for n in 0..<600 {
    classicView.step(now: 90 + Double(n) / 60, dt: 1 / 60)
    livingView.step(now: 90 + Double(n) / 60, dt: 1 / 60)
    if !livingView.rallyEvents.isEmpty {
        check(render(classicView) != render(livingView), "Living Court impact is not visibly rendered")
        comparedImpact = true
        break
    }
}
check(comparedImpact, "Living Court visual comparison did not reach an impact")

for preset in AppearancePreset.allCases {
    for size in [NSSize(width: 320, height: 180), NSSize(width: 1280, height: 720),
                 NSSize(width: 1080, height: 1920)] {
        let view = PickleballScreensaverView(frame: NSRect(origin: .zero, size: size), isPreview: true)!
        view.ambientEnabled = false
        view.previewDate = Date(timeIntervalSince1970: 1_791_014_400)
        view.applyAppearance(preset)
        view.reseed(42)
        for n in 0..<600 { view.step(now: 55 + Double(n) / 60, dt: 1 / 60) }
        for motion in CourtMotion.allCases {
            view.courtMotion = motion
            for yaw in [0, 90, 180, 270] {
                view.previewYaw = CGFloat(yaw) * .pi / 180
                view.step(now: 65, dt: 0)
                let data = bitmap(width: Int(size.width), height: Int(size.height)) { ctx in
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                    view.draw(view.bounds)
                    NSGraphicsContext.current = nil
                }
                check(!data.isEmpty, "Appearance render failed")
            }
        }
    }
}

if !failures.isEmpty {
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    exit(1)
}
print("All artwork regression checks passed")
