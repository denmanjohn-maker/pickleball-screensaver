import Foundation

/// One entry from the bundled drill library (Resources/drills.json).
struct Drill: Decodable {
    let name: String
    let level: String       // DUPR tier: "3.0", "3.5", "4.0", "5.0"
    let category: String
    let minutes: Int
    let description: String
}

/// Drill library for the "Drill of the Day" card.
enum PickleballDrills {
    static let all: [Drill] = {
        // Bundle first, then the offscreen-harness fallbacks (executable dir, cwd).
        let candidates: [URL?] = [
            Bundle(for: PickleballScreensaverView.self).url(forResource: "drills", withExtension: "json"),
            Bundle.main.url(forResource: "drills", withExtension: "json"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("drills.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("PickleballScreensaver/Resources/drills.json"),
        ]
        for c in candidates {
            if let c, let data = try? Data(contentsOf: c),
               let drills = try? JSONDecoder().decode([Drill].self, from: data),
               !drills.isEmpty { return drills }
        }
        return []
    }()

    /// Deterministic daily pick: same drill all day, next one at midnight.
    /// `level` of "all" draws from the whole library; otherwise one DUPR tier.
    static func drillOfTheDay(level: String, date: Date = Date()) -> Drill? {
        let pool = level == "all" ? all : all.filter { $0.level == level }
        guard !pool.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return pool[day % pool.count]
    }
}
