import Foundation

// Read-only reference exporter. Compile with the unchanged merged macOS RallyEngine.swift.
var runs: [[String: Any]] = []
for format in [GameFormat.doubles, .singles] {
    let engine = RallyEngine()
    engine.setFormat(format)
    engine.reseed(42)
    var contacts: [[String: Any]] = []
    for frame in 0..<(180 * 120) {
        engine.step(dt: 1.0 / 120)
        for event in engine.frameEvents {
            guard case .contact(let c) = event else { continue }
            contacts.append([
                "frame": frame, "number": c.number, "type": c.type.rawValue,
                "player": c.playerIndex, "bounces": c.receivedBounces,
                "ball": [c.ball.x, c.ball.y, c.ball.z],
                "velocity": [c.velocity.x, c.velocity.y, c.velocity.z],
                "landing": [c.landing.x, c.landing.y, c.landing.z],
                "players": engine.players.map { [$0.x, $0.z] }
            ])
        }
    }
    runs.append(["format": format.rawValue, "contacts": contacts,
                 "nearScore": engine.nearScore, "farScore": engine.farScore,
                 "nearGames": engine.nearGames, "farGames": engine.farGames])
}
let data = try JSONSerialization.data(withJSONObject: [
    "sourceSha": "f0dc8161d77215cd4fe5dd5ed73bfe8ae541b6c3",
    "seed": 42, "fps": 120, "seconds": 180, "runs": runs
], options: [.sortedKeys])
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
print("Exported unchanged Swift-engine reference traces (\(data.count) bytes)")
