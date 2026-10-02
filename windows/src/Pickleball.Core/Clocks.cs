using System.Diagnostics;

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

public enum ImpactKind { Contact, Bounce }
public sealed record ImpactEvent(long Order, TimeSpan SimulationTime, ImpactKind Kind);

// This is a foundation marker, NOT a port of RallyEngine or its physical coordinates.
public sealed record RenderFrame(long Sequence, TimeSpan SimulationTime, DateTimeOffset WallTime,
    double MarkerX, double MarkerY, IReadOnlyList<ImpactEvent> Events);

public sealed class RenderTimeline(IMonotonicClock clock, IWallClock wallClock, uint seed = 1)
{
    private TimeSpan previous = clock.Elapsed;
    private TimeSpan simulationTime;
    private long sequence;
    public RenderFrame Current { get; private set; } = CreateFrame(0, TimeSpan.Zero, wallClock.Now, seed);

    public RenderFrame Advance()
    {
        var now = clock.Elapsed;
        var dt = now - previous;
        previous = now;
        if (dt < TimeSpan.Zero) dt = TimeSpan.Zero;
        if (dt > TimeSpan.FromSeconds(.25)) dt = TimeSpan.FromSeconds(.25);
        simulationTime += dt;
        Current = CreateFrame(++sequence, simulationTime, wallClock.Now, seed);
        return Current;
    }

    private static RenderFrame CreateFrame(long sequence, TimeSpan elapsed, DateTimeOffset wall, uint seed)
    {
        var phase = elapsed.TotalSeconds + (seed % 997) / 997.0;
        return new(sequence, elapsed, wall, .5 + .3 * Math.Sin(phase), .5 + .2 * Math.Cos(phase),
            Array.Empty<ImpactEvent>());
    }
}
