using System.IO;
using System.Windows;
using System.Windows.Controls;
using Pickleball.Core;

namespace Pickleball.Windows;

public sealed class ConfigureWindow : Window
{
    private readonly SettingsStore store;
    private readonly ComboBox appearance;
    private readonly TextBlock status;
    private readonly CheckBox reset;
    public ConfigureWindow(SettingsStore store)
    {
        this.store = store;
        var loaded = store.Load();
        Title = "Pickleball — Windows foundation settings";
        Width = 540; Height = 300;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(new TextBlock
        {
            Text = "Foundation only. Final rendering and widgets are not ported.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 16)
        });
        panel.Children.Add(new TextBlock { Text = "Appearance" });
        appearance = new ComboBox { ItemsSource = Preferences.Themes, SelectedItem = loaded.Value.Theme };
        panel.Children.Add(appearance);
        status = new TextBlock
        {
            Text = loaded.Status is SettingsStatus.Loaded or SettingsStatus.Missing
                ? "Only Appearance is currently persisted."
                : $"Settings are {loaded.Status.ToString().ToLowerInvariant()}. No file has been changed.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 12, 0, 8)
        };
        panel.Children.Add(status);
        reset = new CheckBox
        {
            Content = "Explicitly replace corrupt or unsupported settings when saving",
            Visibility = loaded.RequiresExplicitReset ? Visibility.Visible : Visibility.Collapsed
        };
        panel.Children.Add(reset);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var save = new Button { Content = "Save", MinWidth = 80, Margin = new Thickness(8), IsDefault = true };
        var cancel = new Button { Content = "Cancel", MinWidth = 80, Margin = new Thickness(8), IsCancel = true };
        save.Click += (_, _) => { if (TrySave()) DialogResult = true; };
        cancel.Click += (_, _) => Close();
        buttons.Children.Add(save);
        buttons.Children.Add(cancel);
        panel.Children.Add(buttons);
        Content = panel;
    }

    internal bool TrySave()
    {
        try
        {
            store.Save(new() { Theme = (string)appearance.SelectedItem }, reset.IsChecked == true);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            status.Text = "Settings were not saved. Check file access or explicitly confirm replacement.";
            return false;
        }
    }
}
