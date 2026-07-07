import Foundation
import ScreenSaver

// MARK: - Settings

/// Persisted tournament-display choices. Tournaments are always centered on
/// the weather location (WeatherSettings) — there's no separate city picker.
struct TournamentSettings {
    var enabled = false
    var windowMonths = 3   // 1 or 3

    private static let moduleName = "com.pickleball.screensaver"
    private static var defaults: ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    static func load() -> TournamentSettings {
        var s = TournamentSettings()
        guard let d = defaults else { return s }
        s.enabled = d.bool(forKey: "TournamentsEnabled")
        let months = d.integer(forKey: "TournamentsWindowMonths")
        if months == 1 || months == 3 { s.windowMonths = months }
        return s
    }

    func save() {
        guard let d = Self.defaults else { return }
        d.set(enabled, forKey: "TournamentsEnabled")
        d.set(windowMonths, forKey: "TournamentsWindowMonths")
        d.synchronize()
    }
}

// MARK: - Supported metro regions

/// The tournament API only tracks events within 100 miles of a fixed set of
/// metro areas — it has no raw lat/long search, and its city list endpoint
/// doesn't publish coordinates. This mirrors that API's seeded metro list
/// (name, state, lat/long) so the weather location can be matched to the
/// nearest tracked metro on-device.
struct TournamentMetro {
    var name: String
    var state: String
    var latitude: Double
    var longitude: Double
}

enum TournamentMetros {
    static let all: [TournamentMetro] = [
        TournamentMetro(name: "New York", state: "NY", latitude: 40.7128, longitude: -74.0060),
        TournamentMetro(name: "Los Angeles", state: "CA", latitude: 34.0522, longitude: -118.2437),
        TournamentMetro(name: "Chicago", state: "IL", latitude: 41.8781, longitude: -87.6298),
        TournamentMetro(name: "Dallas", state: "TX", latitude: 32.7767, longitude: -96.7970),
        TournamentMetro(name: "Houston", state: "TX", latitude: 29.7604, longitude: -95.3698),
        TournamentMetro(name: "Washington", state: "DC", latitude: 38.9072, longitude: -77.0369),
        TournamentMetro(name: "Philadelphia", state: "PA", latitude: 39.9526, longitude: -75.1652),
        TournamentMetro(name: "Atlanta", state: "GA", latitude: 33.7490, longitude: -84.3880),
        TournamentMetro(name: "Miami", state: "FL", latitude: 25.7617, longitude: -80.1918),
        TournamentMetro(name: "Phoenix", state: "AZ", latitude: 33.4484, longitude: -112.0740),
        TournamentMetro(name: "Boston", state: "MA", latitude: 42.3601, longitude: -71.0589),
        TournamentMetro(name: "San Francisco", state: "CA", latitude: 37.7749, longitude: -122.4194),
        TournamentMetro(name: "Riverside", state: "CA", latitude: 33.9806, longitude: -117.3755),
        TournamentMetro(name: "Detroit", state: "MI", latitude: 42.3314, longitude: -83.0458),
        TournamentMetro(name: "Seattle", state: "WA", latitude: 47.6062, longitude: -122.3321),
        TournamentMetro(name: "Minneapolis", state: "MN", latitude: 44.9778, longitude: -93.2650),
        TournamentMetro(name: "San Diego", state: "CA", latitude: 32.7157, longitude: -117.1611),
        TournamentMetro(name: "Tampa", state: "FL", latitude: 27.9506, longitude: -82.4572),
        TournamentMetro(name: "Denver", state: "CO", latitude: 39.7392, longitude: -104.9903),
        TournamentMetro(name: "Baltimore", state: "MD", latitude: 39.2904, longitude: -76.6122),
        TournamentMetro(name: "St. Louis", state: "MO", latitude: 38.6270, longitude: -90.1994),
        TournamentMetro(name: "Orlando", state: "FL", latitude: 28.5383, longitude: -81.3792),
        TournamentMetro(name: "Charlotte", state: "NC", latitude: 35.2271, longitude: -80.8431),
        TournamentMetro(name: "San Antonio", state: "TX", latitude: 29.4241, longitude: -98.4936),
        TournamentMetro(name: "Portland", state: "OR", latitude: 45.5152, longitude: -122.6784),
    ]

    /// Straight-line miles between two coordinates — good enough for picking a nearby metro.
    private static func distanceMiles(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 3958.8
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// The closest tracked metro to a point, and how far away it is.
    static func nearest(toLatitude lat: Double, longitude lon: Double) -> (metro: TournamentMetro, distanceMiles: Double)? {
        all.map { ($0, distanceMiles(lat, lon, $0.latitude, $0.longitude)) }
           .min { $0.1 < $1.1 }
    }
}

// MARK: - Snapshot

struct TournamentSnapshot {
    struct Entry {
        var name: String
        var startDate: Date
        var endDate: Date?
        var isCanceled: Bool
    }

    var metroName: String
    var metroState: String
    var windowMonths: Int
    var entries: [Entry]
    var totalCount: Int
}

// Tournament API JSON — property names mirror the API's camelCase fields
private struct TournamentApiDto: Decodable {
    let name: String
    let startDate: String   // "yyyy-MM-dd"
    let endDate: String?
    let isCanceled: Bool
}

private struct TournamentsPage: Decodable {
    let items: [TournamentApiDto]
    let totalCount: Int
}

// MARK: - Provider

/// Fetches pickleballtournamentapi.com on demand from the animation loop.
/// Tournament schedules change slowly (the API re-scrapes every ~12h), so this
/// refreshes hourly (10-minute retry after a failure) and never blocks a frame.
final class TournamentProvider {
    let settings: TournamentSettings
    private let weatherSettings: WeatherSettings
    private(set) var snapshot: TournamentSnapshot?
    private(set) var unsupportedRegion: (metroName: String, metroState: String, distanceMiles: Double)?
    private var nextFetch: TimeInterval = 0
    private var inFlight = false

    /// Beyond this, the weather city isn't close enough to any tracked metro
    /// for "tournaments near you" to be a meaningful claim.
    private static let maxMetroDistanceMiles = 60.0

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(settings: TournamentSettings, weatherSettings: WeatherSettings) {
        self.settings = settings
        self.weatherSettings = weatherSettings
    }

    func updateIfNeeded() {
        guard settings.enabled, weatherSettings.hasLocation, !inFlight else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now >= nextFetch else { return }
        guard let (metro, distance) = TournamentMetros.nearest(toLatitude: weatherSettings.latitude,
                                                                longitude: weatherSettings.longitude) else { return }
        guard distance <= Self.maxMetroDistanceMiles else {
            unsupportedRegion = (metro.name, metro.state, distance)
            snapshot = nil
            nextFetch = now + 1800
            return
        }
        unsupportedRegion = nil
        inFlight = true

        var comps = URLComponents(string: "https://pickleballtournamentapi.com/api/tournaments")!
        comps.queryItems = [
            URLQueryItem(name: "city", value: metro.name),
            URLQueryItem(name: "window", value: settings.windowMonths == 1 ? "1m" : "3m"),
            URLQueryItem(name: "pageSize", value: "20"),
        ]
        guard let url = comps.url else { inFlight = false; return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                let now = Date().timeIntervalSinceReferenceDate
                guard let data, let page = try? JSONDecoder().decode(TournamentsPage.self, from: data) else {
                    self.nextFetch = now + 600
                    return
                }
                let entries = page.items.compactMap { item -> TournamentSnapshot.Entry? in
                    guard let start = Self.dateFmt.date(from: item.startDate) else { return nil }
                    let end = item.endDate.flatMap { Self.dateFmt.date(from: $0) }
                    return TournamentSnapshot.Entry(name: item.name, startDate: start, endDate: end,
                                                     isCanceled: item.isCanceled)
                }
                self.snapshot = TournamentSnapshot(metroName: metro.name, metroState: metro.state,
                                                   windowMonths: self.settings.windowMonths,
                                                   entries: entries, totalCount: page.totalCount)
                self.nextFetch = now + 3600
            }
        }.resume()
    }
}
