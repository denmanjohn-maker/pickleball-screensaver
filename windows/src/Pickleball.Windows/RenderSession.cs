using System.Windows.Threading;
using Pickleball.Core;

namespace Pickleball.Windows;

// One owner per process. Views consume the same immutable frame; they never step a simulation.
public sealed class RenderSession : IDisposable
{
    private readonly DispatcherTimer timer;
    private readonly RenderTimeline timeline;
    private bool disposed;
    public ProcessProviders Providers { get; }
    public bool NetworkAllowed => Providers.NetworkAllowed;
    public CancellationToken Lifetime => Providers.Lifetime;
    public RenderFrame Frame => timeline.Current;
    public event Action<RenderFrame>? FrameReady;

    public RenderSession(IMonotonicClock monotonic, IWallClock wallClock, bool networkAllowed, uint seed = 1)
    {
        Providers = new(networkAllowed);
        timeline = new(monotonic, wallClock, seed);
        timer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(1.0 / 60) };
        timer.Tick += OnTick;
    }

    public void Start()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        Providers.Start();
        timer.Start();
    }
    public void Advance()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        FrameReady?.Invoke(timeline.Advance());
    }
    private void OnTick(object? sender, EventArgs args) => Advance();
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        timer.Stop();
        timer.Tick -= OnTick;
        FrameReady = null;
        Providers.Dispose();
    }
}
