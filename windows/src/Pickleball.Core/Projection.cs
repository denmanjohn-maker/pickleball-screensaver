namespace Pickleball.Core;

public readonly record struct Point2(double X, double Y);
public readonly record struct SceneRect(double X, double Y, double Width, double Height)
{
    public double CenterX => X + Width / 2;
    public double CenterY => Y + Height / 2;
}
internal readonly record struct Feet(double L, double W, double Y)
{
    public static Feet operator -(Feet a, Feet b) => new(a.L - b.L, a.W - b.W, a.Y - b.Y);
    public double Dot(Feet b) => L * b.L + W * b.W + Y * b.Y;
    public Feet Cross(Feet b) => new(W * b.Y - Y * b.W, Y * b.L - L * b.Y, L * b.W - W * b.L);
    public Feet Normalized() { var d = Math.Sqrt(Dot(this)); return new(L / d, W / d, Y / d); }
}
public sealed class Projection
{
    private readonly Feet camera, forward, right, up;
    private readonly double focal, offsetX, offsetY, width, height, unit;
    private double yaw, scale = 1, targetScale = 1;
    public SceneRect Scene { get; }
    public double RailWidth => Math.Min(width * .35, unit * .82);
    public double Unit => unit;
    public string CacheKey => $"{width:R}/{height:R}/{yaw:R}/{scale:R}/{focal:R}";
    public Projection(double width, double height, bool rotates, bool reduced)
    {
        if (!double.IsFinite(width) || width <= 0 || !double.IsFinite(height) || height <= 0)
            throw new ArgumentOutOfRangeException(nameof(width));
        this.width = width; this.height = height; unit = Math.Min(height, width / 1.6);
        var left = unit * .075 + Math.Min(width * .35, unit * .82);
        Scene = new(left, unit * .05, Math.Max(1, width - unit * .05 - left), Math.Max(1, height * .75 - unit * .05));
        var horizontal = Math.Sqrt(22 * 22 + 10 * 10) + 10;
        var dir = new Feet(-22, -10, 0).Normalized();
        camera = new(dir.L * horizontal, dir.W * horizontal, horizontal);
        forward = (new Feet() - camera).Normalized();
        right = forward.Cross(new(0, 0, 1)).Normalized(); up = right.Cross(forward);
        var minX = double.PositiveInfinity; var maxX = double.NegativeInfinity;
        var minY = double.PositiveInfinity; var maxY = double.NegativeInfinity; var lobTop = double.NegativeInfinity;
        for (var degree = 0; degree < (rotates ? 360 : 1); degree++)
        {
            yaw = degree * Math.PI / 180;
            foreach (var p in new Vec3[] { new(-1.25, 0, -.08), new(1.25, 0, -.08), new(1.25, 0, 1.08), new(-1.25, 0, 1.08),
                new(-1.15,.4,-.055),new(1.15,.4,-.055),new(-1.15,.4,1.055),new(1.15,.4,1.055) })
            {
                var q = UnitProject(p); minX = Math.Min(minX, q.X); maxX = Math.Max(maxX, q.X);
                minY = Math.Min(minY, q.Y); maxY = Math.Max(maxY, q.Y);
            }
            if (reduced) foreach (var p in new Vec3[] { new(-.8, 2.1, .35), new(.8, 2.1, .35), new(-.8, 2.1, .65), new(.8, 2.1, .65) })
                lobTop = Math.Max(lobTop, UnitProject(p).Y);
        }
        yaw = 0;
        focal = Math.Min(Scene.Width / (maxX - minX), Scene.Height / (maxY - minY));
        if (reduced) focal = Math.Min(focal, (height - unit * .02 - (height - Scene.CenterY)) / (lobTop - (minY + maxY) / 2));
        offsetX = Scene.CenterX - focal * (minX + maxX) / 2;
        offsetY = height - Scene.CenterY - focal * (minY + maxY) / 2;
    }
    private (double X, double Y, double Depth) UnitProject(Vec3 p)
    {
        var l = (p.Z - .5) * 44; var w = p.X * 10; var c = Math.Cos(yaw); var s = Math.Sin(yaw);
        var feet = new Feet(l * c - w * s, l * s + w * c, p.Y * 9.375) - camera;
        var depth = feet.Dot(forward);
        return (feet.Dot(right) / depth, feet.Dot(up) / depth, depth);
    }
    public Point2 Project(Vec3 p)
    {
        var q = UnitProject(p);
        return new(Scene.CenterX + (offsetX + focal * q.X - Scene.CenterX) * scale,
            Scene.CenterY - (offsetY + focal * q.Y - (height - Scene.CenterY)) * scale);
    }
    public double PixelsPerFoot(Vec3 p) => focal * scale / UnitProject(p with { Y = 0 }).Depth;
    public double Depth(Vec3 p) => UnitProject(p).Depth;
    public bool IsBehindNet(Vec3 p) => (p.Z - .5) * (camera.L * Math.Cos(yaw) + camera.W * Math.Sin(yaw)) < 0;
    public void Update(RenderFrame frame)
    {
        yaw = frame.Yaw;
        if (frame.ReducedMotion) { scale = targetScale = 1; return; }
        foreach (var e in frame.Events)
        {
            if (e.Contact is not { } contact) continue;
            targetScale = 1;
            if (contact.Type == ShotType.Lob)
            {
                var origin = contact.Ball; var v = contact.Velocity;
                var total = (v.Y + Math.Sqrt(v.Y * v.Y + 6.4 * origin.Y)) / 3.2;
                for (var i = 0; i <= 24; i++)
                {
                    var t = total * i / 24;
                    targetScale = Math.Min(targetScale, VisibleScale(new(origin.X + v.X * t, origin.Y + v.Y * t - 1.6 * t * t, origin.Z + v.Z * t)));
                }
            }
        }
        if (frame.Match.Phase == RallyPhase.BetweenPoints) targetScale = 1;
        scale += (targetScale - scale) * (1 - Math.Exp(-frame.Delta * 5));
        if (frame.Match.Phase is not (RallyPhase.Dead or RallyPhase.BetweenPoints)) scale = Math.Min(scale, VisibleScale(frame.Match.Ball));
    }
    private double VisibleScale(Vec3 p)
    {
        var q = UnitProject(p);
        var dx = offsetX + focal * q.X - Scene.CenterX; var dy = offsetY + focal * q.Y - (height - Scene.CenterY);
        var margin = unit * .02; var result = 1.0;
        if (dx > 0) result = Math.Min(result, (width - margin - Scene.CenterX) / dx);
        if (dx < 0) result = Math.Min(result, (Scene.CenterX - margin) / -dx);
        if (dy > 0) result = Math.Min(result, (Scene.CenterY - margin) / dy);
        if (dy < 0) result = Math.Min(result, (height - Scene.CenterY - margin) / -dy);
        return Math.Max(.1, result);
    }
}
