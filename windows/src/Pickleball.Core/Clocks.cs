using System.Diagnostics;
using System.Collections.Immutable;

namespace Pickleball.Core;

public interface IMonotonicClock { TimeSpan Elapsed { get; } }
public interface IWallClock { DateTimeOffset Now { get; } }

public sealed class MonotonicClock : IMonotonicClock
{
    private readonly Stopwatch stopwatch = Stopwatch.StartNew();
    public TimeSpan Elapsed => stopwatch.Elapsed;
}

public sealed class WallClock : IWallClock
{
    public DateTimeOffset Now => DateTimeOffset.Now;
}

public sealed class ReplayClock(DateTimeOffset epoch) : IMonotonicClock, IWallClock
{
    public TimeSpan Elapsed { get; private set; }
    public DateTimeOffset Now => epoch + Elapsed;
    public void Advance(TimeSpan amount)
    {
        if (amount < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(amount));
        Elapsed += amount;
    }
}

public sealed record MatchSnapshot(Vec3 Ball, Vec3 Velocity, double BallSpin, ImmutableArray<PlayerState> Players,
    ImmutableArray<Vec3> Trail, RallyPhase Phase, int NearScore, int FarScore, int NearGames, int FarGames,
    bool NearServing, int ServerNumber, double GameBannerTimer, ShotContact? LastContact);
public sealed record AmbientGhost(double X, double Y, double Size, double Age, double Duration, double Angle, double Speed, bool Paddle);
public sealed record RenderFrame(long Sequence, TimeSpan SimulationTime, DateTimeOffset WallTime,
    MatchSnapshot Match, ArtSnapshot Art, ImmutableArray<RallyEvent> Events, ImmutableArray<AmbientGhost> Ghosts,
    double Yaw, bool ReducedMotion, Preferences Settings, double Delta, long ArtGeneration);

public sealed class RenderTimeline
{
    private readonly IMonotonicClock clock;
    private readonly IWallClock wallClock;
    private TimeSpan previous;
    private TimeSpan simulationTime;
    private long sequence;
    private long artGeneration;
    private readonly RallyEngine engine;
    private readonly ArtEffects art = new();
    private readonly List<AmbientGhost> ghosts = [];
    private SeededGenerator decoration;
    private double spawnTimer = 8, spin = -1, yaw;
    private long minute;
    public Preferences Settings { get; private set; }
    public RenderFrame Current { get; private set; }
    public bool ReducedMotion { get; set; }
    public RenderTimeline(IMonotonicClock clock, IWallClock wallClock, uint seed = 1, Preferences? settings = null)
    {
        this.clock = clock; this.wallClock = wallClock; previous = clock.Elapsed;
        Settings = settings ?? new(); Settings.Validate();
        engine = new(); engine.SetFormat(Settings.Format == "singles" ? GameFormat.Singles : GameFormat.Doubles); engine.Reseed(seed);
        decoration = new(seed ^ 0x415254UL);
        minute = wallClock.Now.ToUnixTimeSeconds() / 60;
        Current = Capture(0);
    }
    public bool ApplyAppearance(string preset)
    {
        if (Settings.Theme == preset) return false;
        var updated = Settings with { Theme = preset }; updated.Validate(); Settings = updated;
        ClearArt(); Current = Capture(0); return true;
    }
    public void ApplySettings(Preferences value)
    {
        value.Validate();
        if (value.Theme != Settings.Theme || value.Format != Settings.Format) ClearArt();
        engine.SetFormat(value.Format == "singles" ? GameFormat.Singles : GameFormat.Doubles);
        Settings = value; Current = Capture(0);
    }
    public void Reseed(uint seed)
    {
        engine.Reseed(seed); decoration = new(seed ^ 0x415254UL); ClearArt(); Current = Capture(0);
    }
    public void ResetArt() { ClearArt(); Current = Capture(0); }
    private void ClearArt() { art.Reset(); ghosts.Clear(); spawnTimer = 8; artGeneration++; }

    public RenderFrame Advance()
    {
        var now = clock.Elapsed;
        var dt = now - previous;
        previous = now;
        if (dt < TimeSpan.Zero) dt = TimeSpan.Zero;
        if (dt > TimeSpan.FromSeconds(.25)) dt = TimeSpan.FromSeconds(.25);
        simulationTime += dt;
        var seconds = dt.TotalSeconds;
        var mark = wallClock.Now.ToUnixTimeSeconds() / 60;
        if (mark != minute) { minute = mark; if (!ReducedMotion && Settings.CourtMotion != "still") spin = 0; }
        if (ReducedMotion || Settings.CourtMotion == "still") { spin = -1; yaw = 0; }
        if (spin >= 0)
        {
            spin += seconds / (Settings.CourtMotion == "standard" ? 6 : 12);
            if (spin >= 1) { spin = -1; yaw = 0; } else yaw = 2 * Math.PI * Court.Smoothstep(spin);
        }
        if (ReducedMotion) ghosts.Clear();
        else
        {
            for (var i = 0; i < ghosts.Count; i++)
            {
                var g = ghosts[i]; ghosts[i] = g with { Age = g.Age + seconds, X = g.X + g.Speed * seconds, Angle = g.Angle + seconds * .5 };
            }
            ghosts.RemoveAll(g => g.Age >= g.Duration);
            spawnTimer -= seconds;
            if (spawnTimer <= 0)
            {
                spawnTimer = 6 + decoration.Unit() * 9;
                if (ghosts.Count < 2) ghosts.Add(new(.7 + decoration.Unit() * .2, .91, .035 + decoration.Unit() * .025, 0,
                    5 + decoration.Unit() * 4, decoration.Unit() * 6, .008, decoration.Bool()));
            }
        }
        engine.Step(seconds);
        art.Update(Settings.Theme, new(++sequence, engine.FrameEvents, engine.Ball,
            engine.Phase is not (RallyPhase.Dead or RallyPhase.BetweenPoints), engine.NearGames + engine.FarGames), seconds);
        Current = Capture(seconds);
        return Current;
    }

    private RenderFrame Capture(double dt) => new(sequence, simulationTime, wallClock.Now,
        new(engine.Ball, engine.Velocity, engine.BallSpin, [.. engine.Players], [.. engine.TrailPoints], engine.Phase,
            engine.NearScore, engine.FarScore, engine.NearGames, engine.FarGames, engine.NearServing, engine.ServerNumber,
            engine.GameBannerTimer, engine.LastContact),
        art.Capture(), [.. engine.FrameEvents], [.. ghosts], yaw, ReducedMotion, Settings, dt, artGeneration);
}
