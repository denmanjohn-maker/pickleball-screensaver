namespace Pickleball.Core;

public readonly record struct PixelRect(int X, int Y, int Width, int Height);
public readonly record struct FittedViewport(double X, double Y, double Width, double Height, double Scale);

public static class Viewport
{
    public static FittedViewport Fit(double width, double height, double sceneWidth = 1280, double sceneHeight = 720)
    {
        if (!double.IsFinite(width) || !double.IsFinite(height) || width <= 0 || height <= 0
            || !double.IsFinite(sceneWidth) || !double.IsFinite(sceneHeight) || sceneWidth <= 0 || sceneHeight <= 0)
            throw new ArgumentOutOfRangeException(nameof(width));
        var scale = Math.Min(width / sceneWidth, height / sceneHeight);
        return new((width - sceneWidth * scale) / 2, (height - sceneHeight * scale) / 2,
            sceneWidth * scale, sceneHeight * scale, scale);
    }

    public static FittedViewport FitMonitor(PixelRect monitor, double dpiX, double dpiY)
    {
        if (!double.IsFinite(dpiX) || !double.IsFinite(dpiY) || dpiX <= 0 || dpiY <= 0)
            throw new ArgumentOutOfRangeException(nameof(dpiX));
        return Fit(monitor.Width * 96.0 / dpiX, monitor.Height * 96.0 / dpiY);
    }
}

public sealed class MouseExitTracker(int initialX, int initialY, int thresholdPixels = 4)
{
    public bool ShouldExit(int x, int y) =>
        Math.Abs((long)x - initialX) > thresholdPixels || Math.Abs((long)y - initialY) > thresholdPixels;
}
