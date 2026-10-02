using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Pickleball.Core;
using Pickleball.Windows;

internal static class Program
{
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWow64Process2(nint process, out ushort processMachine, out ushort nativeMachine);

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (!OperatingSystem.IsWindows() || args.Length != 3)
                throw new ArgumentException("Usage: Windows.Tests <isolated-artifact-directory> <X64|Arm64> <published.scr>");
            var expected = Enum.Parse<Architecture>(args[1]);
            Check(RuntimeInformation.ProcessArchitecture == expected && RuntimeInformation.OSArchitecture == expected,
                "Tests must execute natively, not under architecture emulation.");
            var directory = Path.GetFullPath(args[0]);
            Directory.CreateDirectory(directory);
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            var clock = new ReplayClock(new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero));
            using var session = new RenderSession(clock, clock, networkAllowed: false, seed: 42);
            var lifetime = session.Lifetime;
            using var first = new RallyScene(session, new());
            using var second = new RallyScene(session, new());
            clock.Advance(TimeSpan.FromSeconds(1.0 / 60));
            session.Advance();
            Check(ReferenceEquals(first.Frame, second.Frame) && first.Frame.Sequence == 1,
                "Two renderers must share one frame and one simulation step.");

            using var parent = new HwndSource(new HwndSourceParameters("Isolated preview test parent")
            {
                WindowStyle = 0x00cf0000,
                Width = 320,
                Height = 240
            });
            using var preview = new PreviewHost(parent.Handle, session, new());
            using (new ModalOwnerScope(parent.Handle))
                Check(!NativeMethods.IsWindowEnabled(parent.Handle), "Configuration must disable its supplied modal owner.");
            Check(NativeMethods.IsWindowEnabled(parent.Handle), "Configuration must restore its previously enabled owner.");
            NativeMethods.EnableWindow(parent.Handle, false);
            using (new ModalOwnerScope(parent.Handle)) { }
            Check(!NativeMethods.IsWindowEnabled(parent.Handle), "An already-disabled owner must not be enabled by configuration.");
            NativeMethods.EnableWindow(parent.Handle, true);
            Check(NativeMethods.GetParent(preview.Handle) == parent.Handle, "Preview must be a true child HWND.");
            Check(NativeMethods.GetDpiForWindow(preview.Handle) > 0, "Child must have a DPI context.");
            NativeMethods.Place(parent.Handle, new(0, 0, 480, 360));
            preview.PollParent();
            NativeMethods.GetClientRect(parent.Handle, out var parentRect);
            NativeMethods.GetClientRect(preview.Handle, out var childRect);
            Check(childRect.Right == parentRect.Right && childRect.Bottom == parentRect.Bottom,
                "Preview must fit the parent's client rectangle after resize.");
            Pump();
            var closed = false;
            preview.Closed += () => closed = true;
            parent.Dispose();
            preview.PollParent();
            Check(preview.IsDisposed && closed, "Parent destruction must dispose preview and notify shutdown.");
            Check(!session.NetworkAllowed, "Embedded previews must never enable providers.");

            var settingsPath = Path.Combine(directory, "settings.json");
            var store = new SettingsStore(settingsPath);
            var cancel = new ConfigureWindow(store);
            cancel.Close();
            Check(!File.Exists(settingsPath), "Cancel must not create preferences.");
            var save = new ConfigureWindow(store);
            Check(save.TrySave(), "Save must persist validated preferences.");
            save.Close();
            Check(store.Load().Status == SettingsStatus.Loaded, "Saved configuration must round-trip.");
            using var drills = SharedResources.Open("drills.json");
            Check(drills.Length > 0, "Linked shared resources must be available.");
            var beforeRedraw = System.Text.Json.JsonSerializer.Serialize(session.Frame);
            ExportFrame(first, Path.Combine(directory, "rally.png"));
            ExportFrame(first, Path.Combine(directory, "rally-redraw.png"));
            Check(beforeRedraw == System.Text.Json.JsonSerializer.Serialize(session.Frame), "Redraw cannot mutate simulation or artwork.");
            Check(File.ReadAllBytes(Path.Combine(directory, "rally.png")).SequenceEqual(File.ReadAllBytes(Path.Combine(directory, "rally-redraw.png"))),
                "Repeated redraw must preserve exact pixels.");
            session.Dispose();
            Check(lifetime.IsCancellationRequested, "Provider cancellation must follow process render lifetime.");

            foreach (var option in new[] { "/p:0", "/c:0", "/s:123", "/unknown", "/p:18446744073709551615" })
            {
                var info = new ProcessStartInfo(Path.GetFullPath(args[2])) { UseShellExecute = false };
                info.ArgumentList.Add(option);
                info.Environment["DOTNET_BUNDLE_EXTRACT_BASE_DIR"] = Path.Combine(directory, "bundle");
                using var process = Process.Start(info) ?? throw new InvalidOperationException("Cannot launch .scr apphost.");
                if (!process.WaitForExit(15_000))
                {
                    process.Kill(entireProcessTree: true);
                    throw new InvalidOperationException("Invalid host option hung instead of exiting.");
                }
                Check(process.ExitCode == 2, "Invalid options/handles must fail explicitly without fullscreen fallback.");
            }
            using (var externalParent = new HwndSource(new HwndSourceParameters("Isolated published preview parent")
            {
                WindowStyle = 0x00cf0000,
                Width = 320,
                Height = 240
            }))
            {
                var info = new ProcessStartInfo(Path.GetFullPath(args[2])) { UseShellExecute = false };
                info.ArgumentList.Add("/p:" + unchecked((ulong)externalParent.Handle));
                info.Environment["DOTNET_BUNDLE_EXTRACT_BASE_DIR"] = Path.Combine(directory, "bundle");
                using var process = Process.Start(info) ?? throw new InvalidOperationException("Cannot start published preview.");
                try
                {
                    nint child = 0;
                    WaitWhilePumping(() =>
                    {
                        NativeMethods.EnumChildWindows(externalParent.Handle, (window, _) =>
                        {
                            NativeMethods.GetWindowThreadProcessId(window, out var pid);
                            if (pid == process.Id && NativeMethods.GetParent(window) == externalParent.Handle) child = window;
                            return true;
                        }, 0);
                        return child != 0 || process.HasExited;
                    });
                    Check(child != 0 && !process.HasExited, "Renamed bundled .scr must actually run embedded WPF.");
                    Check(IsWow64Process2(process.Handle, out var emulated, out var native) && emulated == 0
                        && native == (expected == Architecture.Arm64 ? 0xaa64 : 0x8664),
                        "Renamed published .scr must run natively, not as an emulated process.");
                    NativeMethods.Place(externalParent.Handle, new(0, 0, 640, 480));
                    WaitWhilePumping(() =>
                    {
                        NativeMethods.GetClientRect(externalParent.Handle, out var parentSize);
                        NativeMethods.GetClientRect(child, out var childSize);
                        return childSize.Right == parentSize.Right && childSize.Bottom == parentSize.Bottom;
                    });
                    externalParent.Dispose();
                    Check(process.WaitForExit(15_000) && process.ExitCode == 0, "Published preview must exit cleanly when its parent dies.");
                }
                finally
                {
                    if (!process.HasExited) process.Kill(entireProcessTree: true);
                }
            }
            app.Shutdown();
            Console.WriteLine($"PASS: native {expected}; synchronized frames, child preview/resize/disposal, settings, PNG, renamed self-contained .scr preview and failures.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }

    private static void Pump()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(() => frame.Continue = false, DispatcherPriority.Background);
        Dispatcher.PushFrame(frame);
    }
    private static void WaitWhilePumping(Func<bool> condition)
    {
        var elapsed = Stopwatch.StartNew();
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(50) };
        timer.Tick += (_, _) =>
        {
            if (condition() || elapsed.Elapsed > TimeSpan.FromSeconds(15)) frame.Continue = false;
        };
        timer.Start();
        try { Dispatcher.PushFrame(frame); }
        finally { timer.Stop(); }
        Check(condition(), "Bounded native preview wait timed out.");
    }
    private static void ExportFrame(RallyScene scene, string path)
    {
        scene.Measure(new(640, 360));
        scene.Arrange(new Rect(0, 0, 640, 360));
        scene.UpdateLayout();
        var bitmap = new RenderTargetBitmap(640, 360, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
        bitmap.Render(scene);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = File.Create(path);
        encoder.Save(output);
        Check(output.Length > 100, "Offscreen rendering must create a PNG.");
    }
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
