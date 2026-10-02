using System.Collections.Immutable;
using System.Globalization;
using System.Net;
using System.Text.Json;

namespace Pickleball.Core;

public static class BoundedHttp
{
    public static HttpClient Create() => new(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All })
    { Timeout = TimeSpan.FromSeconds(15), MaxResponseContentBufferSize = 1024 * 1024 };
    public static async Task<JsonDocument> Get(HttpClient client, string url, CancellationToken token)
    {
        using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > 1024 * 1024) throw new JsonException("Provider payload too large");
        await using var source = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var bytes = new byte[8192];
        int read;
        while ((read = await source.ReadAsync(bytes, token).ConfigureAwait(false)) > 0)
        {
            if (buffer.Length + read > 1024 * 1024) throw new JsonException("Provider payload too large");
            buffer.Write(bytes, 0, read);
        }
        return JsonDocument.Parse(buffer.ToArray(), new JsonDocumentOptions { MaxDepth = 32 });
    }
    public static string Query(string endpoint, params (string Name, string Value)[] values) =>
        endpoint + "?" + string.Join("&", values.Select(p => Uri.EscapeDataString(p.Name) + "=" + Uri.EscapeDataString(p.Value)));
}

public abstract class CachedProvider<T>(HttpClient client, IWallClock clock, TimeSpan refresh, TimeSpan retry) : IProcessProvider where T : class
{
    private ProviderState<T> state = new(null, null, "Loading");
    private CancellationTokenSource? cancellation;
    private bool disposed;
    public ProviderState<T> State => Volatile.Read(ref state);
    public Task Completion { get; private set; } = Task.CompletedTask;
    protected HttpClient Client => client;
    protected abstract Task<T> Fetch(CancellationToken token);
    public void Start(CancellationToken lifetime)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (cancellation is not null) return;
        cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        Completion = Run(cancellation.Token);
    }
    private async Task Run(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            var delay = refresh;
            try
            {
                // HttpClient's timeout does not cover streaming after headers; bound the whole read.
                using var request = CancellationTokenSource.CreateLinkedTokenSource(token);
                request.CancelAfter(TimeSpan.FromSeconds(20));
                var result = await Fetch(request.Token).ConfigureAwait(false);
                Volatile.Write(ref state, new(result, clock.Now, "Available"));
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
            catch (Exception error) when (error is HttpRequestException or IOException or JsonException or OperationCanceledException
                or FormatException or InvalidOperationException or KeyNotFoundException or ArgumentOutOfRangeException)
            {
                var old = State;
                Volatile.Write(ref state, new(old.Value, old.Updated, old.Value is null ? "Unavailable — retrying" : "Stale — retrying"));
                delay = retry;
            }
            try { await Task.Delay(delay, token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
        }
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; cancellation?.Cancel(); client.Dispose();
        // Dispose the token source only after its asynchronous consumers finish.
        if (cancellation is { } source) _ = Completion.ContinueWith(_ => source.Dispose(), TaskScheduler.Default);
    }
}
public sealed class WeatherProvider(Preferences settings, HttpClient client, IWallClock clock)
    : CachedProvider<WeatherSnapshot>(client, clock, TimeSpan.FromMinutes(30), TimeSpan.FromMinutes(2))
{
    protected override async Task<WeatherSnapshot> Fetch(CancellationToken token)
    {
        if (!settings.WeatherEnabled || !settings.HasLocation) throw new InvalidOperationException("Weather disabled");
        var url = BoundedHttp.Query("https://api.open-meteo.com/v1/forecast",
            ("latitude", settings.Latitude.ToString("R", CultureInfo.InvariantCulture)),
            ("longitude", settings.Longitude.ToString("R", CultureInfo.InvariantCulture)),
            ("current", "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            ("daily", "temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max,sunrise,sunset"),
            ("forecast_days", "2"), ("temperature_unit", settings.UseFahrenheit ? "fahrenheit" : "celsius"),
            ("wind_speed_unit", "mph"), ("timezone", "auto"));
        using var json = await BoundedHttp.Get(Client, url, token).ConfigureAwait(false);
        return WeatherSnapshot.Parse(json.RootElement, settings.UseFahrenheit);
    }
}
public sealed class TournamentProvider(Preferences settings, TournamentMetro metro, HttpClient client, IWallClock clock)
    : CachedProvider<TournamentSnapshot>(client, clock, TimeSpan.FromHours(1), TimeSpan.FromMinutes(10))
{
    protected override async Task<TournamentSnapshot> Fetch(CancellationToken token)
    {
        if (!settings.TournamentsEnabled || !settings.HasLocation) throw new InvalidOperationException("Tournaments disabled");
        using var json = await BoundedHttp.Get(Client, BoundedHttp.Query("https://pickleballtournamentapi.com/api/tournaments",
            ("city", metro.Name), ("window", settings.TournamentMonths == 1 ? "1m" : "3m"), ("pageSize", "20")), token).ConfigureAwait(false);
        var entries = ImmutableArray.CreateBuilder<TournamentEntry>();
        foreach (var item in json.RootElement.GetProperty("items").EnumerateArray().Take(20))
        {
            if (!DateOnly.TryParseExact(item.GetProperty("startDate").GetString(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var start))
                continue;
            DateOnly? end = item.TryGetProperty("endDate", out var endValue)
                && DateOnly.TryParseExact(endValue.GetString(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed) ? parsed : null;
            var name = item.GetProperty("name").GetString() ?? "";
            entries.Add(new(name.Length > 200 ? name[..200] : name, start, end, item.GetProperty("isCanceled").GetBoolean()));
        }
        return new(metro, settings.TournamentMonths, entries.ToImmutable(), json.RootElement.GetProperty("totalCount").GetInt32());
    }
}
public sealed record GeocodedPlace(string Name, double Latitude, double Longitude);
public static class Geocoding
{
    public static async Task<GeocodedPlace?> Lookup(HttpClient client, string query, CancellationToken token)
    {
        if (string.IsNullOrWhiteSpace(query) || query.Length > 200) return null;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var json = await BoundedHttp.Get(client, BoundedHttp.Query("https://geocoding-api.open-meteo.com/v1/search",
            ("name", query.Trim()), ("count", "1"), ("language", "en"), ("format", "json")), timeout.Token).ConfigureAwait(false);
        if (!json.RootElement.TryGetProperty("results", out var results) || results.GetArrayLength() == 0) return null;
        var first = results[0];
        var region = first.TryGetProperty("admin1", out var admin) ? admin.GetString()
            : first.TryGetProperty("country", out var country) ? country.GetString() : null;
        var name = first.GetProperty("name").GetString() + (string.IsNullOrEmpty(region) ? "" : ", " + region);
        var place = new GeocodedPlace(name, first.GetProperty("latitude").GetDouble(), first.GetProperty("longitude").GetDouble());
        (new Preferences { LocationName = place.Name, Latitude = place.Latitude, Longitude = place.Longitude }).Validate();
        return place;
    }
}
