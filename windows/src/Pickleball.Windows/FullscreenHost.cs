using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Pickleball.Core;

namespace Pickleball.Windows;

public sealed class FullscreenHost : IDisposable
{
    private readonly Dictionary<nint, MonitorWindow> windows = new();
    private readonly RenderSession session;
    private readonly Preferences settings;
    private readonly Action exit;
    private readonly MouseExitTracker mouse;
    private readonly DispatcherTimer displays;
    private bool changingDisplays, disposed, refreshQueued;

    public FullscreenHost(RenderSession session, Preferences settings, Action exit)
    {
        this.session = session;
        this.settings = settings;
        this.exit = exit;
        if (!NativeMethods.GetCursorPos(out var cursor))
            throw new InvalidOperationException("Cannot establish the initial cursor position.");
        mouse = new(cursor.X, cursor.Y);
        displays = new(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(1) };
        displays.Tick += OnDisplaysTick;
        try
        {
            RefreshDisplays();
            windows.Values.First().Activate();
            displays.Start();
        }
        catch { Dispose(); throw; }
    }

    private void OnDisplaysTick(object? sender, EventArgs args) => RefreshDisplays();
    private void RefreshDisplays(bool forcePlacement = false)
    {
        if (disposed) return;
        changingDisplays = true;
        try
        {
            var monitors = NativeMethods.Monitors();
            var foreground = NativeMethods.GetForegroundWindow();
            var removedForeground = false;
            foreach (var removed in windows.Keys.Except(monitors.Keys).ToArray())
            {
                removedForeground |= windows[removed].Handle == foreground;
                windows[removed].Dispose();
                windows.Remove(removed);
            }
            foreach (var (handle, rect) in monitors)
            {
                if (!windows.TryGetValue(handle, out var window))
                {
                    window = new(session, settings, OnMessage, () => { if (!disposed && !changingDisplays) exit(); });
                    windows.Add(handle, window);
                    window.Show();
                }
                window.Place(rect, forcePlacement);
            }
            if (removedForeground) windows.Values.First().Activate();
        }
        finally { changingDisplays = false; }
    }

    private void CheckDeactivation()
    {
        if (!disposed && !changingDisplays && !NativeMethods.ForegroundBelongsToProcess()) exit();
    }
    private nint OnMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (disposed) return 0;
        if (message is 0x0100 or 0x0104 or 0x0201 or 0x0204 or 0x0207 or 0x020b or 0x020a or 0x020e)
            exit();
        else if (message == NativeMethods.WmMouseMove && NativeMethods.GetCursorPos(out var position)
                 && mouse.ShouldExit(position.X, position.Y))
            exit();
        else if (message == NativeMethods.WmActivateApp && wParam == 0)
            Dispatcher.CurrentDispatcher.BeginInvoke(CheckDeactivation, DispatcherPriority.Background);
        else if (message is NativeMethods.WmDisplayChange or NativeMethods.WmDpiChanged && !refreshQueued)
        {
            refreshQueued = true;
            Dispatcher.CurrentDispatcher.BeginInvoke(() =>
            {
                refreshQueued = false;
                RefreshDisplays(forcePlacement: true);
            }, DispatcherPriority.Background);
        }
        return 0;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        displays.Stop();
        displays.Tick -= OnDisplaysTick;
        foreach (var window in windows.Values) window.Dispose();
        windows.Clear();
    }

    private sealed class MonitorWindow : Window, IDisposable
    {
        private readonly FoundationScene scene;
        private readonly HwndSourceHook hook;
        private PixelRect? bounds;
        private HwndSource? source;
        private readonly Action closed;
        public nint Handle => new WindowInteropHelper(this).Handle;
        public MonitorWindow(RenderSession session, Preferences settings, HwndSourceHook hook, Action closed)
        {
            this.hook = hook;
            this.closed = closed;
            Title = "Pickleball Windows foundation";
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = true;
            Cursor = Cursors.None;
            scene = new(session, settings);
            Content = scene;
            SourceInitialized += (_, _) =>
            {
                source = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
                source.AddHook(hook);
            };
            Closed += OnClosed;
        }
        private void OnClosed(object? sender, EventArgs args) => closed();
        public void Place(PixelRect rect, bool forcePlacement)
        {
            if (bounds == rect && !forcePlacement) return;
            NativeMethods.Place(new WindowInteropHelper(this).Handle, rect);
            bounds = rect;
        }
        public void Dispose()
        {
            Closed -= OnClosed;
            if (source is { IsDisposed: false }) source.RemoveHook(hook);
            scene.Dispose();
            Close();
        }
    }
}
