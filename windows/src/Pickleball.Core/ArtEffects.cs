using System.Collections.Immutable;

namespace Pickleball.Core;

public sealed record ArtPulse(Vec3 Position, double Facing, double Age = 0);
public sealed record PaintSample(Vec3 Position, bool Anchor);
public sealed record PaintStroke(int Id, double Facing, ImmutableArray<PaintSample> Samples, double? FadeRemaining = null)
{
    public double Opacity => FadeRemaining.HasValue ? Court.Smoothstep(FadeRemaining.Value / 2) : 1;
}
public sealed record ArtSnapshot(ImmutableArray<ArtPulse> Ripples, ImmutableArray<ArtPulse> Halos, ImmutableArray<PaintStroke> Strokes);
public sealed record ArtFrame(long Number, IReadOnlyList<RallyEvent> Events, Vec3 Ball, bool Live, int Games);

public sealed class ArtEffects
{
    public const int MaxRipples = 24, MaxHalos = 16, MaxStrokes = 96, MaxSamples = 128;
    private readonly List<ArtPulse> ripples = [], halos = [];
    private readonly List<PaintStroke> strokes = [];
    private long? lastFrame;
    private int? lastGames;
    private int nextId;
    private bool painting;
    private double sampleClock;
    public ArtSnapshot Capture() => new([.. ripples], [.. halos], [.. strokes]);
    public void Reset()
    {
        ripples.Clear(); halos.Clear(); strokes.Clear();
        lastFrame = lastGames = null; nextId = 0; painting = false; sampleClock = 0;
    }
    public void Update(string preset, ArtFrame frame, double dt)
    {
        if (preset is not ("living-court" or "rally-painting") || lastFrame == frame.Number) return;
        if (!double.IsFinite(dt) || dt < 0) throw new ArgumentOutOfRangeException(nameof(dt));
        lastFrame = frame.Number;
        for (var i = 0; i < ripples.Count; i++) ripples[i] = ripples[i] with { Age = ripples[i].Age + dt };
        for (var i = 0; i < halos.Count; i++) halos[i] = halos[i] with { Age = halos[i].Age + dt };
        ripples.RemoveAll(p => p.Age >= 1.2); halos.RemoveAll(p => p.Age >= .35);
        for (var i = 0; i < strokes.Count; i++)
            if (strokes[i].FadeRemaining is { } fade) strokes[i] = strokes[i] with { FadeRemaining = fade - dt };
        strokes.RemoveAll(s => s.FadeRemaining <= 0);
        if (lastGames.HasValue && lastGames != frame.Games)
        {
            painting = false;
            for (var i = 0; i < strokes.Count; i++) strokes[i] = strokes[i] with { FadeRemaining = 2 };
        }
        lastGames = frame.Games;
        foreach (var e in frame.Events)
        {
            if (e.Contact is { } contact)
            {
                if (preset == "living-court")
                {
                    halos.Add(new(e.Position, contact.Player.Facing));
                    if (halos.Count > MaxHalos) halos.RemoveAt(0);
                }
                else { Append(e.Position, true); Start(e.Position, contact.Player.Facing); }
            }
            else if (preset == "living-court")
            {
                ripples.Add(new(e.Position, 0));
                if (ripples.Count > MaxRipples) ripples.RemoveAt(0);
            }
            else Append(e.Position, true);
        }
        if (preset != "rally-painting") return;
        sampleClock += dt;
        if (frame.Live && sampleClock >= 1.0 / 30)
        {
            Append(frame.Ball, false); sampleClock %= 1.0 / 30;
        }
        if (!frame.Live) { painting = false; sampleClock = 0; }
    }
    private static Vec3 Floor(Vec3 p) => p with { Y = 0 };
    private void Start(Vec3 p, double facing)
    {
        if (strokes.Count >= MaxStrokes) strokes.RemoveAt(0);
        strokes.Add(new(++nextId, facing, [new(Floor(p), true)]));
        painting = true; sampleClock = 0;
        for (var i = 0; i < strokes.Count - 80; i++)
            if (strokes[i].FadeRemaining is null) strokes[i] = strokes[i] with { FadeRemaining = 2 };
    }
    private void Append(Vec3 position, bool anchor)
    {
        if (!painting || strokes.Count == 0) return;
        var stroke = strokes[^1]; var p = Floor(position); var samples = stroke.Samples;
        var previous = samples[^1].Position;
        if (Math.Sqrt(Math.Pow((p.X - previous.X) * 10, 2) + Math.Pow((p.Z - previous.Z) * 44, 2)) < .01)
        {
            if (anchor && !samples[^1].Anchor)
                strokes[^1] = stroke with { Samples = samples.SetItem(samples.Length - 1, samples[^1] with { Anchor = true }) };
            return;
        }
        if (samples.Length >= MaxSamples)
        {
            samples = [.. samples.Where((s, i) => i == 0 || i == samples.Length - 1 || s.Anchor || i % 2 == 0)];
            if (samples.Length >= MaxSamples) samples = samples.RemoveAt(1);
        }
        strokes[^1] = stroke with { Samples = samples.Add(new(p, anchor)) };
    }
}

public struct PaperNoise
{
    private ulong state;
    public PaperNoise() => state = 0x50415045525F4152;
    public double Unit()
    {
        state = unchecked(state * 6364136223846793005 + 1442695040888963407);
        return (state >> 11) / (double)(1UL << 53);
    }
}
public sealed record PaperDot(double X, double Y, double Width, double Height, double Alpha);
public static class ArtTextures
{
    public static ImmutableArray<PaperDot> Dots { get; } = MakeDots();
    public static ImmutableArray<ImmutableArray<Vec3>> Washes { get; } = MakeWashes();
    public static ImmutableArray<(Vec3 A, Vec3 B)> Fibers { get; } = MakeFibers();
    private static ImmutableArray<PaperDot> MakeDots()
    {
        var rng = new PaperNoise(); var dots = ImmutableArray.CreateBuilder<PaperDot>(3000);
        for (var i = 0; i < 3000; i++)
        {
            var x = rng.Unit() * 256; var y = rng.Unit() * 256; var w = .3 + rng.Unit() * 1.5;
            var a = .015 + rng.Unit() * .06; var h = .4 + rng.Unit();
            dots.Add(new(x, y, w, h, a));
        }
        return dots.MoveToImmutable();
    }
    private static ImmutableArray<ImmutableArray<Vec3>> MakeWashes()
    {
        var rng = new PaperNoise(); var washes = ImmutableArray.CreateBuilder<ImmutableArray<Vec3>>(48);
        for (var index = 0; index < 48; index++)
        {
            var x = (index % 2 == 0 ? -.5 : .5) + (rng.Unit() - .5) * .6;
            var z = (index % 4 < 2 ? .16 : .84) + (rng.Unit() - .5) * .18;
            var rx = .10 + rng.Unit() * .32; var rz = .025 + rng.Unit() * .06;
            var points = ImmutableArray.CreateBuilder<Vec3>(24);
            for (var i = 0; i < 24; i++)
            {
                var angle = i * Math.PI * 2 / 24; var rough = .85 + rng.Unit() * .25;
                points.Add(new(x + Math.Cos(angle) * rx * rough, 0, z + Math.Sin(angle) * rz * rough));
            }
            washes.Add(points.MoveToImmutable());
        }
        return washes.MoveToImmutable();
    }
    private static ImmutableArray<(Vec3, Vec3)> MakeFibers()
    {
        var rng = new PaperNoise(); var fibers = ImmutableArray.CreateBuilder<(Vec3, Vec3)>(900);
        for (var i = 0; i < 900; i++)
        {
            var p = new Vec3(rng.Unit() * 2 - 1, 0, rng.Unit());
            fibers.Add((p, new(p.X + rng.Unit() * .012, 0, p.Z + rng.Unit() * .003)));
        }
        return fibers.MoveToImmutable();
    }
}
