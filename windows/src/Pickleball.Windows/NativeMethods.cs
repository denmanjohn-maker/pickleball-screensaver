using System.ComponentModel;
using System.Runtime.InteropServices;
using Pickleball.Core;

namespace Pickleball.Windows;

internal static class NativeMethods
{
    internal const int ChildStyle = 0x40000000 | 0x10000000 | 0x02000000;
    internal const int WmDisplayChange = 0x007e;
    internal const int WmDpiChanged = 0x02e0;
    internal const int WmActivateApp = 0x001c;
    internal const int WmMouseMove = 0x0200;

    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Point { public int X, Y; }
    internal delegate bool MonitorCallback(nint monitor, nint dc, ref Rect rect, nint data);
    internal delegate bool WindowCallback(nint window, nint data);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindow(nint window);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetClientRect(nint window, out Rect rect);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetWindowPos(nint window, nint insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplayMonitors(nint dc, nint clip, MonitorCallback callback, nint data);
    [DllImport("user32.dll")]
    internal static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")]
    internal static extern nint GetParent(nint window);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool EnumChildWindows(nint parent, WindowCallback callback, nint data);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindowEnabled(nint window);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool EnableWindow(nint window, [MarshalAs(UnmanagedType.Bool)] bool enabled);

    internal static nint ValidateParent(ulong value)
    {
        var handle = unchecked((nint)value);
        if (!IsWindow(handle))
            throw new ArgumentException("Parent HWND is not a live window.");
        return handle;
    }

    internal static IReadOnlyDictionary<nint, PixelRect> Monitors()
    {
        var result = new Dictionary<nint, PixelRect>();
        if (!EnumDisplayMonitors(0, 0, (nint monitor, nint dc, ref Rect rect, nint data) =>
        {
            result.Add(monitor, new(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top));
            return true;
        }, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (result.Count == 0) throw new InvalidOperationException("No display monitors available.");
        return result;
    }

    internal static void Place(nint handle, PixelRect rect)
    {
        // Physical desktop coordinates include negative origins; never convert the origin to DIPs.
        if (!SetWindowPos(handle, 0, rect.X, rect.Y, rect.Width, rect.Height, 0x0004 | 0x0010))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    internal static bool ForegroundBelongsToProcess()
    {
        GetWindowThreadProcessId(GetForegroundWindow(), out var process);
        return process == Environment.ProcessId;
    }
}
