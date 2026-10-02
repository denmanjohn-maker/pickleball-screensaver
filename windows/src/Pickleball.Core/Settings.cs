using System.Text.Json;

namespace Pickleball.Core;

public sealed record Preferences
{
    public const int CurrentVersion = 1;
    public static IReadOnlyList<string> Themes { get; } = Array.AsReadOnly(
        new[] { "classic", "blacklight", "living-court", "ink-and-paper", "rally-painting" });
    public int SchemaVersion { get; init; } = CurrentVersion;
    public string Theme { get; init; } = "classic";
    public void Validate()
    {
        if (SchemaVersion != CurrentVersion || !Themes.Contains(Theme))
            throw new ArgumentException("Unsupported settings version or Appearance value.");
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
        WriteIndented = true
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
            return new(SettingsStatus.Loaded, settings);
        }
        catch (JsonException) { return new(SettingsStatus.Corrupt, new()); }
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
