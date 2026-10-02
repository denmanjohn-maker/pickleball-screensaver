using System.Globalization;

namespace Pickleball.Core;

public enum HostMode { Configure, Fullscreen, Preview }

public sealed record HostOptions(HostMode Mode, ulong ParentHandle = 0)
{
    public static HostOptions Parse(IReadOnlyList<string> args, int pointerBits = 64)
    {
        if (pointerBits is not (32 or 64))
            throw new ArgumentOutOfRangeException(nameof(pointerBits));
        if (args.Count == 0)
            return new(HostMode.Configure);
        if (args.Count > 2)
            throw new ArgumentException("Expected one screensaver option and an optional parent HWND.");

        var option = args[0];
        if (option.Length < 2 || option[0] is not ('/' or '-'))
            throw new ArgumentException("Expected /s, /c [HWND], or /p HWND.");
        var parts = option[1..].Split(':');
        if (parts.Length > 2 || parts[0].Length != 1)
            throw new ArgumentException("Invalid screensaver option.");
        var mode = char.ToLowerInvariant(parts[0][0]) switch
        {
            's' => HostMode.Fullscreen,
            'c' => HostMode.Configure,
            'p' => HostMode.Preview,
            _ => throw new ArgumentException("Unknown screensaver option.")
        };
        if (parts.Length == 2 && args.Count == 2)
            throw new ArgumentException("Parent HWND supplied twice.");
        var handleText = parts.Length == 2 ? parts[1] : args.Count == 2 ? args[1] : null;
        if (mode == HostMode.Fullscreen && handleText is not null)
            throw new ArgumentException("/s does not accept a parent HWND.");
        if (handleText is null)
        {
            if (mode == HostMode.Preview)
                throw new ArgumentException("/p requires a parent HWND.");
            return new(mode);
        }
        // HWND text is decimal and unsigned; conversion to nint preserves its bits.
        if (!ulong.TryParse(handleText, NumberStyles.None, CultureInfo.InvariantCulture, out var handle)
            || handle == 0 || (pointerBits == 32 && handle > uint.MaxValue))
            throw new ArgumentException("Parent HWND must be a nonzero pointer-sized decimal integer.");
        return new(mode, handle);
    }
}
