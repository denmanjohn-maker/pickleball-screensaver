using System.Text.Json;

namespace Pickleball.Core;

public sealed record Preferences
{
    public const int CurrentVersion = 1;
    public static IReadOnlyList<string> Themes { get; } = Array.AsReadOnly(
        new[] { "classic", "blacklight", "living-court", "ink-and-paper", "rally-painting" });
    public int SchemaVersion { get; init; } = CurrentVersion;
    public string Theme { get; init; } = "classic";
    public string CourtMotion { get; init; } = "slow";
    public string Format { get; init; } = "doubles";
    public bool DrillEnabled { get; init; } = true;
    public string DrillLevel { get; init; } = "all";
    public bool WeatherEnabled { get; init; }
    public bool TournamentsEnabled { get; init; }
    public int TournamentMonths { get; init; } = 3;
    public string LocationName { get; init; } = "";
    public double Latitude { get; init; }
    public double Longitude { get; init; }
    public bool UseFahrenheit { get; init; } = true;
    [System.Text.Json.Serialization.JsonIgnore]
    public bool HasLocation => !string.IsNullOrWhiteSpace(LocationName) && (Latitude != 0 || Longitude != 0);
    public Preferences Offline() => this with { WeatherEnabled = false, TournamentsEnabled = false, LocationName = "", Latitude = 0, Longitude = 0 };
    public void Validate()
    {
        if (SchemaVersion != CurrentVersion || !Themes.Contains(Theme)
            || CourtMotion is not ("standard" or "slow" or "still") || Format is not ("singles" or "doubles")
            || DrillLevel is not ("all" or "3.0" or "3.5" or "4.0" or "5.0")
            || TournamentMonths is not (1 or 3) || LocationName is null || LocationName.Length > 200
            || LocationName.Any(char.IsControl) || !double.IsFinite(Latitude) || Latitude is < -90 or > 90
            || !double.IsFinite(Longitude) || Longitude is < -180 or > 180)
            throw new ArgumentException("Unsupported or invalid preferences.");
    }
}

public enum SettingsStatus { Missing, Loaded, Corrupt, Unsupported, Unavailable }
public sealed record SettingsLoad(SettingsStatus Status, Preferences Value)
{
    public bool RequiresExplicitReset => Status is SettingsStatus.Corrupt or SettingsStatus.Unsupported;
}

public sealed class SettingsStore(string path)
{
    private const int MaximumBytes = 16 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        UnmappedMemberHandling = System.Text.Json.Serialization.JsonUnmappedMemberHandling.Disallow
    };
    public string Path { get; } = System.IO.Path.GetFullPath(path);

    public SettingsLoad Load()
    {
        try
        {
            if (!File.Exists(Path)) return new(SettingsStatus.Missing, new());
            using var stream = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            if (stream.Length > MaximumBytes) return new(SettingsStatus.Corrupt, new());
            using var document = JsonDocument.Parse(stream);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("schemaVersion", out var version)
                || version.ValueKind != JsonValueKind.Number
                || !version.TryGetInt32(out var number))
                return new(SettingsStatus.Corrupt, new());
            if (number != Preferences.CurrentVersion) return new(SettingsStatus.Unsupported, new());
            var settings = root.Deserialize<Preferences>(JsonOptions);
            if (settings is null || !root.TryGetProperty("theme", out var theme)
                || theme.ValueKind != JsonValueKind.String || !Preferences.Themes.Contains(settings.Theme))
                return new(SettingsStatus.Corrupt, new());
            settings.Validate();
            return new(SettingsStatus.Loaded, settings);
        }
        catch (JsonException) { return new(SettingsStatus.Corrupt, new()); }
        catch (ArgumentException) { return new(SettingsStatus.Corrupt, new()); }
        catch (IOException) { return new(SettingsStatus.Unavailable, new()); }
        catch (UnauthorizedAccessException) { return new(SettingsStatus.Unavailable, new()); }
    }

    public void Save(Preferences settings, bool explicitlyReset = false)
    {
        settings.Validate();
        var existing = Load();
        if (existing.Status == SettingsStatus.Unavailable
            || (existing.RequiresExplicitReset && !explicitlyReset))
            throw new IOException("Settings cannot be replaced without an explicit reset.");
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        var staging = Path + "." + Guid.NewGuid().ToString("N") + ".new";
        try
        {
            using (var file = new FileStream(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(file, settings, JsonOptions);
                file.Flush(flushToDisk: true);
            }
            // Same-directory rename avoids exposing partially written JSON to readers.
            File.Move(staging, Path, overwrite: true);
        }
        finally
        {
            if (File.Exists(staging)) File.Delete(staging);
        }
    }
}
