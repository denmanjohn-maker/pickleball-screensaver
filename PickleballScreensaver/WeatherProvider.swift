import Foundation
import ScreenSaver

// MARK: - Settings

/// Persisted weather choices from the configure sheet, stored beside
/// PhotoSettings in the saver's ScreenSaverDefaults.
struct WeatherSettings {
    var enabled = false
    var locationName = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var useFahrenheit = true

    private static let moduleName = "com.pickleball.screensaver"
    private static var defaults: ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    var hasLocation: Bool { !locationName.isEmpty && (latitude != 0 || longitude != 0) }

    static func load() -> WeatherSettings {
        var s = WeatherSettings()
        guard let d = defaults else { return s }
        s.enabled = d.bool(forKey: "WeatherEnabled")
        s.locationName = d.string(forKey: "WeatherLocationName") ?? ""
        s.latitude = d.double(forKey: "WeatherLatitude")
        s.longitude = d.double(forKey: "WeatherLongitude")
        if d.object(forKey: "WeatherUseFahrenheit") != nil {
            s.useFahrenheit = d.bool(forKey: "WeatherUseFahrenheit")
        }
        return s
    }

    func save() {
        guard let d = Self.defaults else { return }
        d.set(enabled, forKey: "WeatherEnabled")
        d.set(locationName, forKey: "WeatherLocationName")
        d.set(latitude, forKey: "WeatherLatitude")
        d.set(longitude, forKey: "WeatherLongitude")
        d.set(useFahrenheit, forKey: "WeatherUseFahrenheit")
        d.synchronize()
    }
}

// MARK: - WMO weather codes

/// Open-Meteo reports conditions as WMO codes; map them to a short label and
/// an SF Symbol name.
enum WMOCode {
    static func label(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61, 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71, 73: return "Snow"
        case 75, 77: return "Heavy snow"
        case 80, 81: return "Showers"
        case 82: return "Heavy showers"
        case 85, 86: return "Snow showers"
        case 95, 96, 99: return "Thunderstorm"
        default: return "—"
        }
    }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

// MARK: - Snapshot

/// One decoded fetch, ready to draw. Temperatures are in the user's chosen
/// unit; wind is always fetched in mph (converted for display when metric).
struct WeatherSnapshot {
    enum PlayVerdict {
        case great, playable, indoor
        var label: String {
            switch self {
            case .great: return "GREAT DAY TO PLAY"
            case .playable: return "PLAYABLE TODAY"
            case .indoor: return "INDOOR DAY"
            }
        }
    }

    var temperature: Double
    var apparentTemperature: Double
    var weatherCode: Int
    var windSpeed: Double        // mph
    var todayMax: Double
    var todayMin: Double
    var todayPrecipProb: Int     // %
    var todayWindMax: Double     // mph
    var sunrise: String          // "6:34 AM"
    var sunset: String
    var tomorrowMax: Double?
    var tomorrowMin: Double?
    var tomorrowPrecipProb: Int?
    var isFahrenheit: Bool

    func tempText(_ v: Double) -> String { "\(Int(v.rounded()))°" }

    var windText: String {
        isFahrenheit ? "\(Int(windSpeed.rounded())) mph"
                     : "\(Int((windSpeed * 1.609344).rounded())) km/h"
    }

    var playVerdict: PlayVerdict {
        let hiF = isFahrenheit ? todayMax : todayMax * 9 / 5 + 32
        if todayPrecipProb < 20 && todayWindMax < 12 && (55...90).contains(hiF) { return .great }
        if todayPrecipProb < 45 && todayWindMax < 18 && (45...98).contains(hiF) { return .playable }
        return .indoor
    }

    fileprivate init?(api: OpenMeteoResponse, isFahrenheit: Bool) {
        guard let hi = api.daily.temperature_2m_max.first,
              let lo = api.daily.temperature_2m_min.first,
              let wMax = api.daily.wind_speed_10m_max.first else { return nil }
        temperature = api.current.temperature_2m
        apparentTemperature = api.current.apparent_temperature
        weatherCode = api.current.weather_code
        windSpeed = api.current.wind_speed_10m
        todayMax = hi
        todayMin = lo
        todayPrecipProb = api.daily.precipitation_probability_max?.first.flatMap { $0 } ?? 0
        todayWindMax = wMax
        sunrise = Self.clockText(api.daily.sunrise.first)
        sunset = Self.clockText(api.daily.sunset.first)
        tomorrowMax = api.daily.temperature_2m_max.dropFirst().first
        tomorrowMin = api.daily.temperature_2m_min.dropFirst().first
        tomorrowPrecipProb = api.daily.precipitation_probability_max?.dropFirst().first.flatMap { $0 }
        self.isFahrenheit = isFahrenheit
    }

    // "2026-07-04T06:34" (location-local, timezone=auto) → "6:34 AM"
    private static func clockText(_ iso: String?) -> String {
        guard let iso, let tIdx = iso.firstIndex(of: "T") else { return "—" }
        let hm = iso[iso.index(after: tIdx)...].prefix(5).split(separator: ":")
        guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) else { return "—" }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, h < 12 ? "AM" : "PM")
    }
}

// Open-Meteo JSON — property names mirror the API's snake_case fields
private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let weather_code: Int
        let wind_speed_10m: Double
    }
    struct Daily: Decodable {
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Int?]?   // null where no data
        let wind_speed_10m_max: [Double]
        let sunrise: [String]
        let sunset: [String]
    }
    let current: Current
    let daily: Daily
}

// MARK: - Provider

/// Fetches Open-Meteo on demand from the animation loop: at most every 30
/// minutes (2-minute retry after a failure), never blocking a frame. The
/// snapshot is only ever replaced, so a network outage keeps the last data.
final class WeatherProvider {
    let settings: WeatherSettings
    private(set) var snapshot: WeatherSnapshot?
    private var nextFetch: TimeInterval = 0
    private var inFlight = false

    init(settings: WeatherSettings) {
        self.settings = settings
    }

    func updateIfNeeded() {
        guard settings.enabled, settings.hasLocation, !inFlight else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now >= nextFetch else { return }
        inFlight = true

        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(settings.latitude)),
            URLQueryItem(name: "longitude", value: String(settings.longitude)),
            URLQueryItem(name: "current",
                         value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily",
                         value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,"
                              + "wind_speed_10m_max,sunrise,sunset"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "temperature_unit", value: settings.useFahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = comps.url else { inFlight = false; return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                let now = Date().timeIntervalSinceReferenceDate
                guard let data,
                      let api = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data),
                      let snap = WeatherSnapshot(api: api, isFahrenheit: self.settings.useFahrenheit) else {
                    self.nextFetch = now + 120
                    return
                }
                self.snapshot = snap
                self.nextFetch = now + 1800
            }
        }.resume()
    }
}

// MARK: - Geocoding (used by the configure sheet)

struct GeocodedPlace {
    var name: String
    var region: String
    var latitude: Double
    var longitude: Double
    var displayName: String { region.isEmpty ? name : "\(name), \(region)" }
}

enum GeocodingClient {
    private struct Response: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let admin1: String?
            let country: String?
        }
        let results: [Result]?
    }

    static func lookup(_ query: String, completion: @escaping (GeocodedPlace?) -> Void) {
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let place = data
                .flatMap { try? JSONDecoder().decode(Response.self, from: $0) }?
                .results?.first
                .map { GeocodedPlace(name: $0.name, region: $0.admin1 ?? $0.country ?? "",
                                     latitude: $0.latitude, longitude: $0.longitude) }
            DispatchQueue.main.async { completion(place) }
        }.resume()
    }
}
