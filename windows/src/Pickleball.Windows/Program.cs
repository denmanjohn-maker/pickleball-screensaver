using System.Diagnostics;
using System.Windows;
using System.Windows.Interop;
using Pickleball.Core;

namespace Pickleball.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            var options = HostOptions.Parse(args, IntPtr.Size * 8);
            var parent = options.ParentHandle == 0 ? 0 : NativeMethods.ValidateParent(options.ParentHandle);
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            app.DispatcherUnhandledException += (_, error) =>
            {
                Diagnostics.Report("dispatcher", error.Exception);
                error.Handled = true;
                app.Shutdown(1);
            };
            var store = new SettingsStore(System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PickleballScreensaver", "settings.json"));
            if (options.Mode == HostMode.Configure)
            {
                var config = new ConfigureWindow(store);
                if (parent != 0) new WindowInteropHelper(config).Owner = parent;
                using var modalOwner = new ModalOwnerScope(parent);
                config.ShowDialog();
                return 0;
            }
            var loaded = store.Load();
            if (loaded.Status is not (SettingsStatus.Loaded or SettingsStatus.Missing))
                Diagnostics.Report("settings-" + loaded.Status.ToString().ToLowerInvariant());
            var wall = options.Mode == HostMode.Preview
                ? (IWallClock)new ReplayClock(new DateTimeOffset(2026, 1, 1, 12, 0, 0, TimeSpan.Zero))
                : new WallClock();
            using var session = new RenderSession(new MonotonicClock(), wall,
                networkAllowed: options.Mode == HostMode.Fullscreen);
            IDisposable? host = null;
            app.Startup += (_, _) =>
            {
                try
                {
                    host = options.Mode == HostMode.Preview
                        ? new PreviewHost(parent, session, loaded.Value)
                        : new FullscreenHost(session, loaded.Value, () => app.Shutdown());
                    if (host is PreviewHost preview) preview.Closed += () => app.Shutdown();
                    session.Start();
                }
                catch (ArgumentException error) { Diagnostics.Report("invalid-preview-parent", error); app.Shutdown(2); }
                catch (Exception error) { Diagnostics.Report("host-startup", error); app.Shutdown(1); }
            };
            try { return app.Run(); }
            finally { host?.Dispose(); }
        }
        catch (ArgumentException error) { Diagnostics.Report("invalid-host-arguments", error); return 2; }
        catch (Exception error) { Diagnostics.Report("startup", error); return 1; }
    }
}

internal static class Diagnostics
{
    private static int count;
    internal static void Report(string category, Exception? error = null)
    {
        if (Interlocked.Increment(ref count) > 8) return;
        // No paths, handles, location, settings contents, telemetry or persistent log files.
        var message = $"Pickleball foundation: {category} ({error?.GetType().Name ?? "notice"}).";
        Trace.WriteLine(message);
        Console.Error.WriteLine(message);
    }
}
