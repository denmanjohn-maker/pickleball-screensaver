using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;

namespace Pickleball.Core;

public sealed record Drill(string Name, string Level, string Category, int Minutes, string Description);
public static class Drills
{
    public static ImmutableArray<Drill> All { get; } = Load();
    private static ImmutableArray<Drill> Load()
    {
        using var data = SharedResources.Open("drills.json");
        return JsonSerializer.Deserialize<ImmutableArray<Drill>>(data, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
    }
    public static Drill? Daily(string level, DateTimeOffset date)
    {
        var pool = All.Where(d => level == "all" || d.Level == level).ToArray();
        // Gregorian day-in-era, not seconds/86400: local midnight and DST stay stable.
        var ordinal = DateOnly.FromDateTime(date.DateTime).DayNumber + 1;
        return pool.Length == 0 ? null : pool[ordinal % pool.Length];
    }
}
public sealed record ProviderState<T>(T? Value, DateTimeOffset? Updated, string Status) where T : class
{
    public bool IsStale(DateTimeOffset now, TimeSpan freshness) => Updated.HasValue && now - Updated > freshness;
}
public sealed record WeatherSnapshot(double Temperature, double Apparent, int Code, double WindMph,
    double High, double Low, int Precipitation, double WindMax, string Sunrise, string Sunset,
    double? TomorrowHigh, double? TomorrowLow, int? TomorrowPrecipitation, bool Fahrenheit)
{
    public string TemperatureText(double value) => $"{Math.Round(value, MidpointRounding.AwayFromZero):0}°";
    public string WindText => $"{Math.Round(Fahrenheit ? WindMph : WindMph * 1.609344):0} {(Fahrenheit ? "mph" : "km/h")}";
    public string Verdict
    {
        get
        {
            var hi = Fahrenheit ? High : High * 9 / 5 + 32;
            return Precipitation < 20 && WindMax < 12 && hi is >= 55 and <= 90 ? "GREAT DAY TO PLAY"
                : Precipitation < 45 && WindMax < 18 && hi is >= 45 and <= 98 ? "PLAYABLE TODAY" : "INDOOR DAY";
        }
    }
    public string Label => Code switch
    {
        0 => "Clear",
        1 => "Mostly clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45 or 48 => "Foggy",
        51 or 53 or 55 => "Drizzle",
        56 or 57 => "Freezing drizzle",
        61 or 63 => "Rain",
        65 => "Heavy rain",
        66 or 67 => "Freezing rain",
        71 or 73 => "Snow",
        75 or 77 => "Heavy snow",
        80 or 81 => "Showers",
        82 => "Heavy showers",
        85 or 86 => "Snow showers",
        95 or 96 or 99 => "Thunderstorm",
        _ => "Unavailable"
    };
    public static WeatherSnapshot Parse(JsonElement root, bool fahrenheit)
    {
        var current = root.GetProperty("current"); var daily = root.GetProperty("daily");
        double Number(JsonElement e, string name) { var n = e.GetProperty(name).GetDouble(); if (!double.IsFinite(n)) throw new JsonException("Nonfinite weather"); return n; }
        double DailyNumber(string name, int day) => daily.GetProperty(name)[day].GetDouble();
        double? Next(string name) => daily.GetProperty(name).GetArrayLength() > 1 ? DailyNumber(name, 1) : null;
        int? Precip(int index) => daily.TryGetProperty("precipitation_probability_max", out var a)
            && a.GetArrayLength() > index && a[index].ValueKind == JsonValueKind.Number ? a[index].GetInt32() : null;
        string Sun(string name) => daily.GetProperty(name).GetArrayLength() == 0 ? "—"
            : DateTime.TryParse(daily.GetProperty(name)[0].GetString(), CultureInfo.InvariantCulture, DateTimeStyles.None, out var time)
                ? time.ToString("h:mm tt", CultureInfo.InvariantCulture) : "—";
        var result = new WeatherSnapshot(Number(current, "temperature_2m"), Number(current, "apparent_temperature"),
            current.GetProperty("weather_code").GetInt32(), Number(current, "wind_speed_10m"),
            DailyNumber("temperature_2m_max", 0), DailyNumber("temperature_2m_min", 0), Precip(0) ?? 0,
            DailyNumber("wind_speed_10m_max", 0), Sun("sunrise"), Sun("sunset"),
            Next("temperature_2m_max"), Next("temperature_2m_min"), Precip(1), fahrenheit);
        if (!double.IsFinite(result.High) || !double.IsFinite(result.Low) || !double.IsFinite(result.WindMax)
            || result.Precipitation is < 0 or > 100) throw new JsonException("Invalid daily weather");
        return result;
    }
}
public sealed record TournamentMetro(string Name, string State, double Latitude, double Longitude);
public sealed record TournamentEntry(string Name, DateOnly Start, DateOnly? End, bool Canceled);
public sealed record TournamentSnapshot(TournamentMetro Metro, int Months, ImmutableArray<TournamentEntry> Entries, int Total);
public static class TournamentMetros
{
    public static ImmutableArray<TournamentMetro> All { get; } = [
        new("New York","NY",40.7128,-74.0060),new("Los Angeles","CA",34.0522,-118.2437),new("Chicago","IL",41.8781,-87.6298),
        new("Dallas","TX",32.7767,-96.7970),new("Houston","TX",29.7604,-95.3698),new("Washington","DC",38.9072,-77.0369),
        new("Philadelphia","PA",39.9526,-75.1652),new("Atlanta","GA",33.7490,-84.3880),new("Miami","FL",25.7617,-80.1918),
        new("Phoenix","AZ",33.4484,-112.0740),new("Boston","MA",42.3601,-71.0589),new("San Francisco","CA",37.7749,-122.4194),
        new("Riverside","CA",33.9806,-117.3755),new("Detroit","MI",42.3314,-83.0458),new("Seattle","WA",47.6062,-122.3321),
        new("Minneapolis","MN",44.9778,-93.2650),new("San Diego","CA",32.7157,-117.1611),new("Tampa","FL",27.9506,-82.4572),
        new("Denver","CO",39.7392,-104.9903),new("Baltimore","MD",39.2904,-76.6122),new("St. Louis","MO",38.6270,-90.1994),
        new("Orlando","FL",28.5383,-81.3792),new("Charlotte","NC",35.2271,-80.8431),new("San Antonio","TX",29.4241,-98.4936),
        new("Portland","OR",45.5152,-122.6784)
    ];
    public static (TournamentMetro Metro, double Miles) Nearest(double latitude, double longitude)
    {
        double Distance(TournamentMetro metro)
        {
            var lat = (metro.Latitude - latitude) * Math.PI / 180; var lon = (metro.Longitude - longitude) * Math.PI / 180;
            var a = Math.Pow(Math.Sin(lat / 2), 2) + Math.Cos(latitude * Math.PI / 180)
                * Math.Cos(metro.Latitude * Math.PI / 180) * Math.Pow(Math.Sin(lon / 2), 2);
            return 3958.8 * 2 * Math.Atan2(Math.Sqrt(a), Math.Sqrt(Math.Max(0, 1 - a)));
        }
        var nearest = All.MinBy(Distance)!; return (nearest, Distance(nearest));
    }
}
