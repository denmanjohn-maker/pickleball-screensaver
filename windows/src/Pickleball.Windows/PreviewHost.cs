using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using Pickleball.Core;

namespace Pickleball.Windows;

public sealed class PreviewHost : IDisposable
{
    private readonly nint parent;
    private readonly uint parentThread, parentProcess;
    private readonly HwndSource source;
    private readonly RallyScene scene;
    private readonly DispatcherTimer timer;
    private int width = -1, height = -1;
    public bool IsDisposed { get; private set; }
    public nint Handle => IsDisposed ? 0 : source.Handle;
    public event Action? Closed;

    public PreviewHost(nint parent, RenderSession session, Preferences settings)
    {
        if (session.NetworkAllowed) throw new ArgumentException("Embedded preview must not enable providers.");
        this.parent = NativeMethods.ValidateParent(unchecked((ulong)parent));
        parentThread = NativeMethods.GetWindowThreadProcessId(parent, out parentProcess);
        var parameters = new HwndSourceParameters("Pickleball embedded foundation")
        {
            ParentWindow = parent,
            WindowStyle = NativeMethods.ChildStyle,
            PositionX = 0,
            PositionY = 0,
            Width = 1,
            Height = 1,
            TreatAsInputRoot = false
        };
        source = new(parameters);
        scene = new(session, settings);
        source.RootVisual = scene;
        source.AddHook(OnMessage);
        timer = new(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(100) };
        timer.Tick += OnTick;
        try
        {
            PollParent();
            if (IsDisposed) throw new ArgumentException("Preview parent closed during initialization.");
            timer.Start();
        }
        catch { Dispose(); throw; }
    }

    private void OnTick(object? sender, EventArgs args) => PollParent();
    internal void PollParent()
    {
        if (IsDisposed) return;
        var thread = NativeMethods.GetWindowThreadProcessId(parent, out var process);
        if (!NativeMethods.IsWindow(parent) || thread != parentThread || process != parentProcess
            || source.IsDisposed || NativeMethods.GetParent(source.Handle) != parent)
        {
            Dispose();
            Closed?.Invoke();
            return;
        }
        if (!NativeMethods.GetClientRect(parent, out var rect))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        var newWidth = Math.Max(0, rect.Right - rect.Left);
        var newHeight = Math.Max(0, rect.Bottom - rect.Top);
        if (newWidth == width && newHeight == height) return;
        width = newWidth;
        height = newHeight;
        NativeMethods.Place(source.Handle, new(0, 0, width, height));
    }

    private nint OnMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == NativeMethods.WmDpiChanged) { width = -1; height = -1; }
        return 0;
    }

    public void Dispose()
    {
        if (IsDisposed) return;
        IsDisposed = true;
        timer.Stop();
        timer.Tick -= OnTick;
        scene.Dispose();
        if (!source.IsDisposed)
        {
            source.RemoveHook(OnMessage);
            source.Dispose();
        }
    }
}
