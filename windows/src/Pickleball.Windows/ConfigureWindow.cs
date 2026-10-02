using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Pickleball.Core;

namespace Pickleball.Windows;

public sealed class ConfigureWindow : Window
{
    private readonly SettingsStore store;
    private Preferences draft;
    private readonly ComboBox appearance, motion, format, level, months;
    private readonly CheckBox drills, weather, tournaments, fahrenheit, reset;
    private readonly TextBox city;
    private readonly TextBlock status, locationStatus;
    private readonly HttpClient geocoder = BoundedHttp.Create();
    private CancellationTokenSource? lookup;
    private long lookupRevision;
    private bool settingCity;
    public ConfigureWindow(SettingsStore store)
    {
        this.store = store; var loaded = store.Load(); draft = loaded.Value;
        Title = "Pickleball screensaver settings"; Width = 610; Height = 720; MinWidth = 480; MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var panel = new StackPanel { Margin = new Thickness(24) };
        appearance = Choice(panel, "Appearance", Preferences.Themes, draft.Theme);
        motion = Choice(panel, "Court motion (minute-boundary rotation)", ["standard", "slow", "still"], draft.CourtMotion);
        format = Choice(panel, "Match", ["doubles", "singles"], draft.Format);
        drills = Toggle(panel, "Show drill of the day", draft.DrillEnabled);
        level = Choice(panel, "Drill level", ["all", "3.0", "3.5", "4.0", "5.0"], draft.DrillLevel);
        weather = Toggle(panel, "Show weather (Open-Meteo)", draft.WeatherEnabled);
        fahrenheit = Toggle(panel, "Fahrenheit / mph (unchecked: Celsius / km/h)", draft.UseFahrenheit);
        tournaments = Toggle(panel, "Show nearby tournaments (supported US metros only)", draft.TournamentsEnabled);
        months = Choice(panel, "Tournament window", ["1", "3"], draft.TournamentMonths.ToString(System.Globalization.CultureInfo.InvariantCulture));
        city = new TextBox { Text = draft.LocationName, MaxLength = 200 };
        var cityLabel = new Label { Content = "City shared by weather and tournaments", Target = city, Padding = new Thickness(0), Margin = new Thickness(0, 12, 0, 4) };
        AutomationProperties.SetLabeledBy(city, cityLabel); panel.Children.Add(cityLabel);
        panel.Children.Add(city);
        locationStatus = new TextBlock { Text = draft.HasLocation ? draft.LocationName : "No city selected", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 6) };
        panel.Children.Add(locationStatus);
        var find = new Button { Content = "Find city (requires internet)", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 4, 10, 4) };
        find.Click += async (_, _) => await FindCity(); panel.Children.Add(find);
        city.TextChanged += (_, _) =>
        {
            if (settingCity) return;
            lookupRevision++; lookup?.Cancel();
            draft = draft with { LocationName = "", Latitude = 0, Longitude = 0 }; locationStatus.Text = "City changed — find again before saving a location";
        };
        status = new TextBlock
        {
            Text = loaded.Status is SettingsStatus.Loaded or SettingsStatus.Missing
            ? "Save changes only when you choose Save. Networking is disabled in embedded preview and export."
            : $"Settings are {loaded.Status.ToString().ToLowerInvariant()}. The existing file has not been changed.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 16, 0, 8)
        };
        panel.Children.Add(status);
        reset = new CheckBox
        {
            Content = "Explicitly replace corrupt or unsupported settings on Save",
            Visibility = loaded.RequiresExplicitReset ? Visibility.Visible : Visibility.Collapsed
        }; panel.Children.Add(reset);
        var defaults = new Button { Content = "Reset draft to defaults", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 8) };
        defaults.Click += (_, _) => ResetDraft(); panel.Children.Add(defaults);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var save = new Button { Content = "Save", MinWidth = 80, Margin = new Thickness(8), IsDefault = true };
        var cancel = new Button { Content = "Cancel", MinWidth = 80, Margin = new Thickness(8), IsCancel = true };
        save.Click += (_, _) => { if (TrySave()) DialogResult = true; }; cancel.Click += (_, _) => Close();
        buttons.Children.Add(save); buttons.Children.Add(cancel); panel.Children.Add(buttons);
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Closed += (_, _) => { lookupRevision++; lookup?.Cancel(); geocoder.Dispose(); };
    }
    private static ComboBox Choice(Panel panel, string title, IEnumerable<string> values, string selected)
    {
        var box = new ComboBox { ItemsSource = values, SelectedItem = selected };
        var label = new Label { Content = title, Target = box, Padding = new Thickness(0), Margin = new Thickness(0, 8, 0, 4) };
        AutomationProperties.SetLabeledBy(box, label); panel.Children.Add(label);
        panel.Children.Add(box); return box;
    }
    private static CheckBox Toggle(Panel panel, string title, bool selected)
    {
        var box = new CheckBox { Content = title, IsChecked = selected, Margin = new Thickness(0, 10, 0, 0) }; panel.Children.Add(box); return box;
    }
    private async Task FindCity()
    {
        lookup?.Cancel(); var cancellation = new CancellationTokenSource(); lookup = cancellation;
        var revision = ++lookupRevision; var query = city.Text; locationStatus.Text = "Finding city…";
        try
        {
            var place = await Geocoding.Lookup(geocoder, query, cancellation.Token);
            if (cancellation.IsCancellationRequested || revision != lookupRevision) return;
            if (place is null) { locationStatus.Text = "City unavailable. Try a more specific name."; return; }
            draft = draft with { LocationName = place.Name, Latitude = place.Latitude, Longitude = place.Longitude };
            settingCity = true; try { city.Text = place.Name; } finally { settingCity = false; }
            locationStatus.Text = place.Name;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error) when (error is HttpRequestException or IOException or JsonException or OperationCanceledException
            or ArgumentException or InvalidOperationException or KeyNotFoundException)
        {
            if (revision == lookupRevision) locationStatus.Text = "City lookup unavailable. No location saved; try again.";
        }
        finally { if (ReferenceEquals(lookup, cancellation)) lookup = null; cancellation.Dispose(); }
    }
    private void ResetDraft()
    {
        draft = new(); appearance.SelectedItem = draft.Theme; motion.SelectedItem = draft.CourtMotion; format.SelectedItem = draft.Format;
        drills.IsChecked = draft.DrillEnabled; level.SelectedItem = draft.DrillLevel; weather.IsChecked = false; tournaments.IsChecked = false;
        fahrenheit.IsChecked = true; months.SelectedItem = "3"; city.Text = ""; locationStatus.Text = "No city selected";
    }
    internal bool TrySave()
    {
        try
        {
            var value = draft with
            {
                Theme = (string)appearance.SelectedItem,
                CourtMotion = (string)motion.SelectedItem,
                Format = (string)format.SelectedItem,
                DrillEnabled = drills.IsChecked == true,
                DrillLevel = (string)level.SelectedItem,
                WeatherEnabled = weather.IsChecked == true,
                TournamentsEnabled = tournaments.IsChecked == true,
                UseFahrenheit = fahrenheit.IsChecked == true,
                TournamentMonths = months.SelectedItem?.ToString() == "1" ? 1 : 3
            };
            if ((value.WeatherEnabled || value.TournamentsEnabled) && !value.HasLocation) { status.Text = "Find a city or disable location widgets before saving."; return false; }
            store.Save(value, reset.IsChecked == true); return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            status.Text = "Settings were not saved. Check file access or explicitly confirm replacement."; return false;
        }
    }
}
