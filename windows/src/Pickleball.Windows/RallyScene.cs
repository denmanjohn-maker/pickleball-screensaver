using System.Collections.Immutable;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Pickleball.Core;

namespace Pickleball.Windows;

public sealed class RallyScene : FrameworkElement, IDisposable
{
    private readonly RenderSession session;
    private Projection? projection;
    private Size projectionSize;
    private Palette palette = Palette.Named("classic");
    private string preset = "";
    private DrawingGroup? projectedPaper;
    private string paperKey = "";
    private readonly Dictionary<int, (string Key, ImmutableArray<PaintSample> Samples, Geometry Ribbon, Geometry Spine)> brushCache = [];
    private readonly Dictionary<int, BitmapSource> paddles = [];
    private static readonly BitmapSource Background = ReadImage("background.png");
    private static readonly BitmapSource Paddle = ReadImage("paddle.png");
    private static readonly DrawingImage Paper = MakePaper();
    public RenderFrame Frame { get; private set; }
    public bool WallpaperOnly { get; init; }
    public WidgetFixture? Fixture { get; init; }
    public RallyScene(RenderSession session, Preferences settings)
    {
        settings.Validate(); this.session = session; Frame = session.Frame;
        session.FrameReady += OnFrame; Focusable = false; IsHitTestVisible = false;
        ClipToBounds = true;
    }
    private void OnFrame(RenderFrame frame)
    {
        if (Frame.Sequence == frame.Sequence && ReferenceEquals(Frame, frame)) return;
        var fitChanged = Frame.Settings.CourtMotion != frame.Settings.CourtMotion || Frame.ReducedMotion != frame.ReducedMotion;
        if (Frame.ArtGeneration != frame.ArtGeneration) { brushCache.Clear(); paddles.Clear(); projection = null; }
        Frame = frame;
        if (fitChanged) projection = null;
        projection?.Update(frame); InvalidateVisual();
    }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        if (preset != Frame.Settings.Theme)
        {
            preset = Frame.Settings.Theme; palette = Palette.Named(preset); paddles.Clear(); brushCache.Clear(); projectedPaper = null;
        }
        if (projection is null || projectionSize != RenderSize)
        {
            projectionSize = RenderSize;
            projection = new(ActualWidth, ActualHeight, Frame.Settings.CourtMotion != "still" && !Frame.ReducedMotion, Frame.ReducedMotion);
            projection.Update(Frame); brushCache.Clear();
        }
        DrawBackground(dc);
        if (!WallpaperOnly) DrawGhosts(dc);
        DrawCourt(dc);
        if (WallpaperOnly) { DrawNet(dc); return; }
        DrawShadow(dc);
        DrawFlight(dc, true);
        DrawSprites(dc, true);
        DrawNet(dc);
        DrawFlight(dc, false);
        DrawSprites(dc, false);
        DrawWidgets(dc);
    }
    private Point P(Vec3 p) { var q = projection!.Project(p); return new(q.X, q.Y); }
    private static Geometry Path(IEnumerable<Point> points, bool closed = false)
    {
        var array = points.ToArray(); var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
        {
            if (array.Length > 0) { ctx.BeginFigure(array[0], closed, closed); ctx.PolyLineTo(array.Skip(1).ToArray(), true, false); }
        }
        geometry.Freeze(); return geometry;
    }
    private void Line(DrawingContext dc, Vec3 a, Vec3 b, Color color, double width, double alpha = 1) =>
        dc.DrawLine(new Pen(Palette.Brush(color, alpha), width) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, P(a), P(b));
    private Geometry Quad(double x0, double z0, double x1, double z1) =>
        Path(new Vec3[] { new(x0, 0, z0), new(x1, 0, z0), new(x1, 0, z1), new(x0, 0, z1) }.Select(P), true);
    private void DrawBackground(DrawingContext dc)
    {
        dc.DrawRectangle(Palette.Brush(palette.Background), null, new Rect(RenderSize));
        if (preset == "ink-and-paper")
        {
            var brush = new ImageBrush(Paper) { TileMode = TileMode.Tile, ViewportUnits = BrushMappingMode.Absolute, Viewport = new(0, 0, 256, 256) };
            brush.Freeze(); dc.DrawRectangle(brush, null, new Rect(RenderSize));
        }
        else if (palette.Wallpaper)
        {
            dc.PushOpacity(.48); var factor = Math.Max(ActualWidth / Background.PixelWidth, ActualHeight / Background.PixelHeight);
            dc.DrawImage(Background, new((ActualWidth - Background.PixelWidth * factor) / 2, (ActualHeight - Background.PixelHeight * factor) / 2,
                Background.PixelWidth * factor, Background.PixelHeight * factor)); dc.Pop();
        }
        else
        {
            var glow = new RadialGradientBrush(preset == "blacklight" ? Palette.Rgb(.10, .02, .18, .4) : Palette.Rgb(.09, .14, .18, .28), Colors.Transparent)
            { Center = new(.5, .4), GradientOrigin = new(.5, .4), RadiusX = .7, RadiusY = .7 };
            glow.Freeze(); dc.DrawRectangle(glow, null, new Rect(RenderSize));
        }
    }
    private void DrawGhosts(DrawingContext dc)
    {
        foreach (var ghost in Frame.Ghosts)
        {
            var point = new Point(ghost.X * ActualWidth, ghost.Y * ActualHeight); var size = ghost.Size * projection!.Unit;
            // Ghosts live below the court/score envelope and outside the widget rail.
            if (point.X - size < projection.Scene.X || point.Y - size < ActualHeight * .88 || point.X + size > ActualWidth) continue;
            var f = ghost.Age / ghost.Duration; var alpha = Math.Max(0, Math.Min(1, Math.Min(f / .2, (1 - f) / .25))) * .12;
            dc.PushOpacity(alpha); dc.PushTransform(new RotateTransform(ghost.Angle * 180 / Math.PI, point.X, point.Y));
            if (ghost.Paddle) dc.DrawImage(Paddle, new(point.X - size * .514, point.Y - size, size * 1.028, size * 2));
            else dc.DrawEllipse(Palette.Brush(palette.Accent), null, point, size, size);
            dc.Pop(); dc.Pop();
        }
    }
    private void DrawCourt(DrawingContext dc)
    {
        var apron = Quad(-1.25, -.08, 1.25, 1.08);
        dc.DrawGeometry(Palette.Brush(Colors.Black, .22), null, apron);
        var court = Quad(-1, 0, 1, 1);
        dc.PushTransform(new TranslateTransform(projection!.Unit * .008, projection.Unit * .018));
        dc.DrawGeometry(Palette.Brush(Colors.Black, preset == "ink-and-paper" ? .18 : .55), new Pen(Palette.Brush(Colors.Black, .08), projection.Unit * .025), court);
        dc.Pop(); dc.DrawGeometry(Palette.Brush(palette.Surface), null, court);
        dc.DrawGeometry(Palette.Brush(palette.Service), null, Quad(-1, 0, 1, Court.KitchenNearZ));
        dc.DrawGeometry(Palette.Brush(palette.Service), null, Quad(-1, Court.KitchenFarZ, 1, 1));
        dc.PushClip(court);
        if (preset == "ink-and-paper")
        {
            if (projectedPaper is null || paperKey != projection.CacheKey)
            {
                var drawing = new DrawingGroup();
                using (var paper = drawing.Open())
                {
                    for (var i = 0; i < ArtTextures.Washes.Length; i++)
                        paper.DrawGeometry(Palette.Brush(i % 3 == 0 ? palette.TeamB : palette.TeamA, i % 3 == 0 ? .025 : .045), null,
                            Path(ArtTextures.Washes[i].Select(P), true));
                    var fiber = new Pen(Palette.Brush(Palette.Rgb(.30, .25, .17, .08)), .45)
                    { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
                    fiber.Freeze();
                    foreach (var (a, b) in ArtTextures.Fibers) paper.DrawLine(fiber, P(a), P(b));
                }
                drawing.Freeze(); projectedPaper = drawing; paperKey = projection.CacheKey;
            }
            dc.DrawDrawing(projectedPaper);
        }
        else
        {
            var grain = palette.Glow ? palette.Line : Colors.Black;
            for (var z = -.02; z <= 1.1; z += .028) Line(dc, new(-1.3, 0, z), new(1.3, 0, z), grain, .7, palette.Glow ? .1 : .18);
            for (var x = -1.15; x <= 1.15; x += .07) Line(dc, new(x, 0, -.05), new(x, 0, 1.05), grain, .5, palette.Glow ? .05 : .08);
            DrawFloorArt(dc);
        }
        dc.Pop();
        var lines = new[] { court, Path(new[]{P(new(-1,0,Court.KitchenNearZ)),P(new(1,0,Court.KitchenNearZ))}),
            Path(new[]{P(new(-1,0,Court.KitchenFarZ)),P(new(1,0,Court.KitchenFarZ))}),
            Path(new[]{P(new(0,0,0)),P(new(0,0,Court.KitchenNearZ))}),
            Path(new[]{P(new(0,0,Court.KitchenFarZ)),P(new(0,0,1))}) };
        foreach (var line in lines)
        {
            if (palette.Glow) dc.DrawGeometry(null, new Pen(Palette.Brush(palette.Line, .12), 9), line);
            dc.DrawGeometry(null, new Pen(Palette.Brush(palette.Line), 2.5), line);
        }
    }
    private void DrawFloorArt(DrawingContext dc)
    {
        if (preset == "living-court") foreach (var pulse in Frame.Art.Ripples)
            for (var ring = 0; ring < 2; ring++)
            {
                var t = pulse.Age / 1.2; var radius = (.25 + t * 1.7) * (ring == 0 ? 1 : .68);
                var points = Enumerable.Range(0, 49).Select(i => P(new(pulse.Position.X + Math.Cos(i * Math.PI * 2 / 48) * radius / 10, 0,
                    pulse.Position.Z + Math.Sin(i * Math.PI * 2 / 48) * radius / 44)));
                dc.DrawGeometry(null, new Pen(Palette.Brush(palette.Accent, .3 * (1 - Court.Smoothstep(t))), ring == 0 ? 1.5 : .8), Path(points));
            }
        if (preset != "rally-painting") return;
        var liveIds = Frame.Art.Strokes.Select(s => s.Id).ToHashSet();
        foreach (var id in brushCache.Keys.Where(id => !liveIds.Contains(id)).ToArray()) brushCache.Remove(id);
        foreach (var stroke in Frame.Art.Strokes.Where(s => s.Samples.Length > 1))
        {
            if (!brushCache.TryGetValue(stroke.Id, out var cache) || cache.Key != projection!.CacheKey || cache.Samples != stroke.Samples)
            {
                var left = new List<Point>(); var right = new List<Point>(); var spine = new List<Point>();
                var samples = stroke.Samples;
                for (var i = 0; i < samples.Length; i++)
                {
                    var p = samples[i].Position; var before = samples[Math.Max(0, i - 1)].Position; var after = samples[Math.Min(samples.Length - 1, i + 1)].Position;
                    var dx = (after.X - before.X) * 10; var dz = (after.Z - before.Z) * 44; var length = Math.Max(.001, Math.Sqrt(dx * dx + dz * dz));
                    var half = .12 + .34 * Math.Sin(Math.PI * i / (samples.Length - 1));
                    var ox = -dz / length * half / 10; var oz = dx / length * half / 44;
                    left.Add(P(new(p.X + ox, 0, p.Z + oz))); right.Add(P(new(p.X - ox, 0, p.Z - oz))); spine.Add(P(p));
                }
                right.Reverse(); cache = (projection!.CacheKey, samples, Path(left.Concat(right), true), Path(spine));
                brushCache[stroke.Id] = cache;
            }
            dc.DrawGeometry(Palette.Brush(palette.Team(stroke.Facing), .28 * stroke.Opacity), null, cache.Ribbon);
            dc.DrawGeometry(null, new Pen(Palette.Brush(palette.Team(stroke.Facing), .18 * stroke.Opacity), .7), cache.Spine);
        }
    }
    private void DrawNet(DrawingContext dc)
    {
        var top = Enumerable.Range(0, 17).Select(i => { var x = -1 + 2.0 * i / 16; return P(new(x, Court.NetTopY(x), .5)); }).ToArray();
        dc.DrawGeometry(Palette.Brush(palette.Mesh), null, Path(new[] { P(new(-1, 0, .5)), P(new(1, 0, .5)) }.Concat(top.Reverse()), true));
        for (var i = 0; i <= 55; i++) { var x = -1 + 2.0 * i / 55; Line(dc, new(x, 0, .5), new(x, Court.NetTopY(x), .5), palette.Strand, .8); }
        for (var i = 1; i < 10; i++)
            dc.DrawGeometry(null, new Pen(Palette.Brush(palette.Strand), .8),
                Path(Enumerable.Range(0, 17).Select(j => { var x = -1 + 2.0 * j / 16; return P(new(x, Court.NetTopY(x) * i / 10, .5)); })));
        if (palette.Glow) dc.DrawGeometry(null, new Pen(Palette.Brush(palette.Tape, .16), 12), Path(top));
        dc.DrawGeometry(null, new Pen(Palette.Brush(palette.Tape), 5), Path(top));
        foreach (var x in new[] { -1, 0, 1 }) Line(dc, new(x, 0, .5), new(x, Court.NetTopY(x), .5), palette.Post, Math.Max(1, .25 * projection!.PixelsPerFoot(new(x, 0, .5))));
    }
    private double Radius(Vec3 p) => Math.Max(Math.Max(2, ActualHeight * .004), .121 * 3.5 * projection!.PixelsPerFoot(p));
    private void DrawShadow(DrawingContext dc)
    {
        var ball = Frame.Match.Ball; var p = P(ball with { Y = 0 }); var fade = Math.Max(0, 1 - ball.Y / .6); var r = Radius(ball) * 1.1 * fade;
        dc.DrawEllipse(Palette.Brush(Colors.Black, .12 * fade), null, p, r * 1.5, r * .45);
        dc.DrawEllipse(Palette.Brush(Colors.Black, .45 * fade), null, p, r, r * .30);
    }
    private void DrawFlight(DrawingContext dc, bool behind)
    {
        var trail = Frame.Match.Trail;
        for (var i = 0; i < trail.Length; i++)
        {
            var p = trail[i]; if (projection!.IsBehindNet(p) != behind) continue;
            var t = (double)i / trail.Length;
            if (preset == "ink-and-paper")
            {
                if (i > 0 && projection.IsBehindNet(trail[i - 1]) == behind) Line(dc, trail[i - 1], p, palette.Trail, Math.Max(.5, Radius(p) * t * .7), t * .24);
            }
            else dc.DrawEllipse(Palette.Brush(palette.Trail, t * .28), null, P(p), Radius(p) * t, Radius(p) * t);
        }
        if (preset != "living-court") return;
        foreach (var halo in Frame.Art.Halos.Where(h => projection!.IsBehindNet(h.Position) == behind))
        {
            var t = halo.Age / .35; var r = Math.Max(3, projection!.PixelsPerFoot(halo.Position) * (.5 + t * .7));
            dc.DrawEllipse(null, new Pen(Palette.Brush(palette.Team(halo.Facing), .45 * (1 - Court.Smoothstep(t))), 1.5 * (1 - t) + .5), P(halo.Position), r, r);
        }
    }
    private void DrawSprites(DrawingContext dc, bool behind)
    {
        var sprites = new List<(Vec3 Position, PlayerState? Player, int Order)> { (Frame.Match.Ball, null, -1) };
        for (var i = 0; i < Frame.Match.Players.Length; i++)
        {
            var p = Frame.Match.Players[i]; sprites.Add((new(RallyEngine.PaddleX(p), p.FaceY, p.Z + p.FaceDZ), p, i));
        }
        foreach (var sprite in sprites.Where(s => projection!.IsBehindNet(s.Position) == behind)
            .OrderByDescending(s => projection!.Depth(s.Position)).ThenBy(s => s.Order))
            if (sprite.Player is { } player) DrawPaddle(dc, player); else DrawBall(dc);
    }
    private void DrawBall(DrawingContext dc)
    {
        var p = P(Frame.Match.Ball); var r = Radius(Frame.Match.Ball);
        if (palette.Glow) dc.DrawEllipse(Palette.Brush(palette.Ball, .15), null, p, r * 1.7, r * 1.7);
        Geometry shape = new EllipseGeometry(p, r, r);
        for (var ring = 0; ring < 2; ring++) for (var i = 0; i < (ring == 0 ? 5 : 6); i++)
        {
            var angle = i * Math.PI * 2 / (ring == 0 ? 5 : 6) + (ring == 0 ? 0 : Math.PI / 6) - Frame.Match.BallSpin;
            var center = new Point(p.X + Math.Cos(angle) * r * (ring == 0 ? .40 : .72), p.Y + Math.Sin(angle) * r * (ring == 0 ? .40 : .72));
            shape = new CombinedGeometry(GeometryCombineMode.Exclude, shape, new EllipseGeometry(center, Math.Max(.6, r * .15), Math.Max(.6, r * .15)));
        }
        shape.Freeze();
        dc.DrawGeometry(Palette.Brush(palette.Ball), new Pen(Palette.Brush(palette.BallOutline), Math.Max(.6, r * .09)), shape);
        dc.DrawEllipse(Palette.Brush(Colors.White, .3), null, new(p.X - r * .1, p.Y - r * .35), r * .38, r * .25);
    }
    private void DrawPaddle(DrawingContext dc, PlayerState player)
    {
        var wx = RallyEngine.PaddleX(player); var z = player.Z + player.FaceDZ; var face = P(new(wx, player.FaceY, z));
        var h = 2.0 * 16 / 12 * projection!.PixelsPerFoot(new(wx, 0, player.Z)); var w = h * .514; var offset = (.695 - .38) * h;
        var up = P(new(wx, player.FaceY + .5 / 9.375, z)); var net = P(new(wx, player.FaceY, z + player.Facing * .5 / 44));
        var ux = up.X - face.X; var uy = up.Y - face.Y; var ul = Math.Max(1e-9, Math.Sqrt(ux * ux + uy * uy)); ux /= ul; uy /= ul;
        var nx = net.X - face.X; var ny = net.Y - face.Y; var nl = Math.Sqrt(nx * nx + ny * ny); var down = Math.Min(0, nx * ux + ny * uy);
        nx -= down * ux; ny -= down * uy;
        var ax = Math.Cos(player.SwingAngle) * nx + Math.Sin(player.SwingAngle) * (up.X - face.X);
        var ay = Math.Cos(player.SwingAngle) * ny + Math.Sin(player.SwingAngle) * (up.Y - face.Y);
        var angle = Math.Atan2(ay, ax) + Math.PI / 2;
        var facePivot = new Point(face.X - offset * Math.Sin(angle), face.Y + offset * Math.Cos(angle));
        var clamped = Math.Max(1e-9, Math.Sqrt(nx * nx + ny * ny)); var anchor = P(new(wx, player.FaceY, player.Z + player.ContactDZ));
        var grip = new Point(anchor.X + .35 * (face.X - anchor.X) - offset * nx / clamped, anchor.Y + .35 * (face.Y - anchor.Y) - offset * ny / clamped);
        var blend = nl > 1e-9 ? Math.Min(1, -down / nl) : 0; var pivot = new Point(facePivot.X + blend * (grip.X - facePivot.X), facePivot.Y + blend * (grip.Y - facePivot.Y));
        dc.PushTransform(new TranslateTransform(pivot.X, pivot.Y)); dc.PushTransform(new RotateTransform(angle * 180 / Math.PI));
        var backhand = player.SwingPhase && player.Stance != player.Facing * player.Hand;
        if ((player.Facing < 0) != backhand) dc.PushTransform(new ScaleTransform(-1, 1));
        var rect = new Rect(-w / 2, -(1 - .38) * h, w, h);
        dc.DrawImage(TintedPaddle(player.Facing), rect);
        if ((player.Facing < 0) != backhand) dc.Pop(); dc.Pop(); dc.Pop();
    }
    private BitmapSource TintedPaddle(double facing)
    {
        var key = facing > 0 ? 0 : 1; if (paddles.TryGetValue(key, out var cached)) return cached;
        var source = new FormatConvertedBitmap(Paddle, PixelFormats.Bgra32, null, 0); var stride = source.PixelWidth * 4; var data = new byte[stride * source.PixelHeight];
        source.CopyPixels(data, stride, 0); var color = palette.Team(facing);
        for (var i = 0; i < data.Length; i += 4) { data[i] = (byte)(data[i] * .35 + color.B * .65); data[i + 1] = (byte)(data[i + 1] * .35 + color.G * .65); data[i + 2] = (byte)(data[i + 2] * .35 + color.R * .65); }
        cached = BitmapSource.Create(source.PixelWidth, source.PixelHeight, 96, 96, PixelFormats.Bgra32, null, data, stride); cached.Freeze(); paddles[key] = cached; return cached;
    }
    private void DrawWidgets(DrawingContext dc)
    {
        var u = projection!.Unit; var x = u * .05; var width = projection.RailWidth; var pad = u * .018; var top = ActualHeight * .05;
        if (Frame.Settings.WeatherEnabled || Fixture is not null)
        {
            var state = Fixture?.Weather ?? session.Weather?.State;
            var rows = new List<string> { Fixture is not null ? "Sample city — offline fixture" : Frame.Settings.HasLocation ? Frame.Settings.LocationName : "Choose a city in settings" };
            if (state?.Value is { } weather)
            {
                rows.Add($"{weather.TemperatureText(weather.Temperature)}   {weather.Label}   Feels {weather.TemperatureText(weather.Apparent)}");
                rows.Add($"H {weather.TemperatureText(weather.High)}  L {weather.TemperatureText(weather.Low)}   Wind {weather.WindText}  Rain {weather.Precipitation}%");
                rows.Add($"Sunrise {weather.Sunrise}   Sunset {weather.Sunset}");
                if (weather.TomorrowHigh is { } tomorrow)
                {
                    var low = weather.TomorrowLow is { } nextLow ? weather.TemperatureText(nextLow) : "—";
                    var rain = weather.TomorrowPrecipitation is { } chance ? $"{chance}%" : "—";
                    rows.Add($"Tomorrow  H {weather.TemperatureText(tomorrow)}  L {low}  Rain {rain}");
                }
                rows.Add(weather.Verdict);
                if (state.IsStale(Frame.WallTime, TimeSpan.FromMinutes(35)) || state.Status != "Available") rows.Add("Stale — retrying");
                DrawWeatherIcon(dc, new(x + width - pad - u * .07, top + pad), u * .04, weather.Code);
            }
            else rows.Add(state?.Status ?? "Unavailable");
            top = Card(dc, "WEATHER", rows, x, top, width, u * .018) + u * .02;
        }
        if (Frame.Settings.TournamentsEnabled || Fixture is not null)
        {
            var state = Fixture?.Tournaments ?? session.Tournaments?.State; var rows = new List<string>();
            if (state?.Value is { } tournaments)
            {
                rows.Add($"{tournaments.Metro.Name}, {tournaments.Metro.State} • Next {tournaments.Months} month(s)");
                var pageCount = Math.Max(1, (tournaments.Entries.Length + 2) / 3);
                var cycle = Frame.SimulationTime.TotalSeconds / 6; var page = (int)cycle % pageCount;
                foreach (var entry in tournaments.Entries.Skip(page * 3).Take(3)) rows.Add($"{entry.Start:MMM d}  {entry.Name}{(entry.Canceled ? " — CANCELED" : "")}");
                if (tournaments.Entries.Length == 0) rows.Add("No scheduled tournaments");
                rows.Add($"Page {page + 1}/{pageCount} • {tournaments.Total} total");
                if (state.IsStale(Frame.WallTime, TimeSpan.FromMinutes(65)) || state.Status != "Available") rows.Add("Stale — retrying");
                var t = Frame.SimulationTime.TotalSeconds % 6; dc.PushOpacity(Math.Min(1, Math.Min(t / .6, (6 - t) / .6)));
                Card(dc, "NEARBY TOURNAMENTS", rows, x, top, width, u * .018); dc.Pop();
            }
            else Card(dc, "NEARBY TOURNAMENTS", [state?.Status ?? session.TournamentStatus], x, top, width, u * .018);
        }
        if (Frame.Settings.DrillEnabled && Drills.Daily(Frame.Settings.DrillLevel, Frame.WallTime) is { } drill)
        {
            var y = ActualHeight * .64;
            Card(dc, "DRILL OF THE DAY", [$"{drill.Name} • {drill.Level} • {drill.Minutes} MIN", drill.Category, drill.Description], x, y, width, u * .019,
                Math.Max(1, ActualHeight * .95 - y));
        }
        var m = Frame.Match; var scoreY = ActualHeight * .79; var scoreSize = u * .038; var scoreWidth = Math.Min(projection.Scene.Width, u * .6);
        var pill = new Rect(projection.Scene.CenterX - scoreWidth / 2, scoreY, scoreWidth, scoreSize * 2.1);
        dc.DrawRoundedRectangle(Palette.Brush(palette.Glass), new Pen(Palette.Brush(palette.Line, .16), 1), pill, scoreSize, scoreSize);
        var teamA = Formatted("TEAM A  ", scoreSize * .5, palette.TeamA, true);
        var scores = Formatted($"{m.NearScore}  –  {m.FarScore}", scoreSize * .85, palette.Text, true);
        var teamB = Formatted("  TEAM B", scoreSize * .5, palette.TeamB, true);
        var scoreX = projection.Scene.CenterX - (teamA.Width + scores.Width + teamB.Width) / 2;
        dc.DrawText(teamA, new(scoreX, pill.Y + pad));
        dc.DrawText(scores, new(scoreX + teamA.Width, pill.Y + pad - scoreSize * .15));
        dc.DrawText(teamB, new(scoreX + teamA.Width + scores.Width, pill.Y + pad));
        var call = $"{(m.NearServing ? "A" : "B")} SERVES   {(m.NearServing ? m.NearScore : m.FarScore)} – {(m.NearServing ? m.FarScore : m.NearScore)}"
            + (Frame.Settings.Format == "doubles" ? $" – {m.ServerNumber}" : "");
        Text(dc, call, pill.X + pad, pill.Bottom + u * .008, u * .017, palette.Accent, pill.Width);
        dc.DrawEllipse(Palette.Brush(palette.Accent), null, new(m.NearServing ? pill.X - u * .012 : pill.Right + u * .012, pill.Y + scoreSize), u * .005, u * .005);
        if (m.NearGames + m.FarGames > 0) Text(dc, $"GAMES {m.NearGames} – {m.FarGames}", pill.X, scoreY - u * .03, u * .017, palette.Text, pill.Width);
        if (m.GameBannerTimer > 0) Text(dc, "GAME", pill.X, scoreY - u * .09, u * .055, palette.Accent, pill.Width, true);
        var time = Formatted(Frame.WallTime.ToString("h:mm tt", CultureInfo.InvariantCulture), u * .060, palette.Text, true);
        dc.DrawText(time, new(ActualWidth - u * .05 - time.Width, ActualHeight - u * .05 - u * .09));
        var date = Formatted(Frame.WallTime.ToString("dddd, MMMM d", CultureInfo.InvariantCulture), u * .023, palette.Text, false);
        dc.DrawText(date, new(ActualWidth - u * .05 - date.Width, ActualHeight - u * .05 - u * .027));
    }
    private double Card(DrawingContext dc, string title, IEnumerable<string> rows, double x, double top, double width, double size, double maxHeight = double.PositiveInfinity)
    {
        var pad = projection!.Unit * .018; var text = Formatted(string.Join("\n", rows), size, palette.Text, false);
        text.MaxTextWidth = Math.Max(1, width - pad * 2); var h = Math.Min(maxHeight, text.Height + pad * 3 + size * 1.2);
        dc.DrawRoundedRectangle(Palette.Brush(palette.Glass), new Pen(Palette.Brush(palette.Line, .16), 1), new(x, top, width, h), projection.Unit * .022, projection.Unit * .022);
        Text(dc, title, x + pad, top + pad, size * .8, palette.Accent, width - pad * 2, true);
        dc.PushClip(new RectangleGeometry(new(x + pad, top + pad + size * 1.5, width - pad * 2, Math.Max(1, h - pad * 2 - size * 1.5))));
        dc.DrawText(text, new(x + pad, top + pad + size * 1.5)); dc.Pop(); return top + h;
    }
    private FormattedText Formatted(string text, double size, Color color, bool bold) => new(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
        new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, bold ? FontWeights.SemiBold : FontWeights.Normal, FontStretches.Normal),
        Math.Max(1, size), Palette.Brush(color), VisualTreeHelper.GetDpi(this).PixelsPerDip);
    private void Text(DrawingContext dc, string text, double x, double y, double size, Color color, double width, bool bold = false)
    {
        var formatted = Formatted(text, size, color, bold); formatted.MaxTextWidth = Math.Max(1, width); dc.DrawText(formatted, new(x, y));
    }
    private void DrawWeatherIcon(DrawingContext dc, Point p, double size, int code)
    {
        var pen = new Pen(Palette.Brush(palette.Accent), Math.Max(1, size * .08));
        if (code <= 2)
        {
            dc.DrawEllipse(null, pen, p, size * .25, size * .25);
            for (var i = 0; i < 8; i++) { var a = i * Math.PI / 4; dc.DrawLine(pen, new(p.X + Math.Cos(a) * size * .35, p.Y + Math.Sin(a) * size * .35), new(p.X + Math.Cos(a) * size * .48, p.Y + Math.Sin(a) * size * .48)); }
        }
        if (code != 0)
        {
            dc.DrawEllipse(Palette.Brush(palette.Text, .7), null, new(p.X + size * .2, p.Y + size * .15), size * .36, size * .22);
            dc.DrawEllipse(Palette.Brush(palette.Text, .7), null, new(p.X, p.Y), size * .28, size * .25);
            if (code >= 51) for (var i = 0; i < 3; i++) dc.DrawLine(pen, new(p.X + size * (i * .2 - .2), p.Y + size * .5), new(p.X + size * (i * .2 - .3), p.Y + size * .7));
        }
    }
    private static BitmapSource ReadImage(string name)
    {
        using var stream = SharedResources.Open(name); var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = stream; image.EndInit(); image.Freeze(); return image;
    }
    private static DrawingImage MakePaper()
    {
        var group = new DrawingGroup(); using (var dc = group.Open()) foreach (var dot in ArtTextures.Dots)
            dc.DrawEllipse(Palette.Brush(Palette.Rgb(.3, .24, .14, dot.Alpha)), null, new(dot.X + dot.Width / 2, dot.Y + dot.Height / 2), dot.Width / 2, dot.Height / 2);
        group.Freeze(); var image = new DrawingImage(group); image.Freeze(); return image;
    }
    public void Dispose() => session.FrameReady -= OnFrame;
}
