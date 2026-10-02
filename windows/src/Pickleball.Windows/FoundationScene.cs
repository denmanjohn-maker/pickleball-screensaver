using System.Globalization;
using System.Windows;
using System.Windows.Media;
using Pickleball.Core;

namespace Pickleball.Windows;

public sealed class FoundationScene : FrameworkElement, IDisposable
{
    private readonly RenderSession session;
    private readonly bool blacklight;
    public RenderFrame Frame { get; private set; }

    public FoundationScene(RenderSession session, Preferences settings)
    {
        this.session = session;
        blacklight = settings.Theme == "blacklight";
        Frame = session.Frame;
        session.FrameReady += OnFrame;
        Focusable = false;
        IsHitTestVisible = false;
    }

    private void OnFrame(RenderFrame frame) { Frame = frame; InvalidateVisual(); }
    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        drawing.DrawRectangle(blacklight ? Brushes.Black : new SolidColorBrush(Color.FromRgb(18, 26, 32)),
            null, new Rect(RenderSize));
        var view = Viewport.Fit(ActualWidth, ActualHeight);
        drawing.PushTransform(new TranslateTransform(view.X, view.Y));
        drawing.PushTransform(new ScaleTransform(view.Scale, view.Scale));
        var accent = blacklight ? Brushes.Lime : Brushes.LightSeaGreen;
        drawing.DrawRoundedRectangle(null, new Pen(accent, 2), new Rect(40, 40, 1200, 640), 12, 12);
        DrawText(drawing, "Windows foundation — NOT the finished screensaver", 48, 76, 28, Brushes.White);
        DrawText(drawing, "Rally, artwork, widgets and final appearances await the merged source gate.",
            48, 125, 20, Brushes.LightGray);
        drawing.DrawEllipse(accent, null, new Point(240 + 800 * Frame.MarkerX, 220 + 320 * Frame.MarkerY), 12, 12);
        DrawText(drawing, Frame.WallTime.ToString("yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture),
            48, 608, 22, Brushes.White);
        drawing.Pop();
        drawing.Pop();
    }

    private void DrawText(DrawingContext drawing, string text, double x, double y, double size, Brush brush) =>
        drawing.DrawText(new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface("Segoe UI"), size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip), new Point(x, y));
    public void Dispose() => session.FrameReady -= OnFrame;
}
