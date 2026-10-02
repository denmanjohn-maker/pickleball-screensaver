using System.Windows.Threading;
using System.Windows;
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
    public WeatherProvider? Weather { get; }
    public TournamentProvider? Tournaments { get; }
    public string TournamentStatus { get; } = "Disabled";
    public event Action<RenderFrame>? FrameReady;

    public RenderSession(IMonotonicClock monotonic, IWallClock wallClock, bool networkAllowed, uint seed = 1,
        Preferences? settings = null, bool? reducedMotion = null)
    {
        Providers = new(networkAllowed);
        settings = networkAllowed ? settings ?? new() : (settings ?? new()).Offline();
        timeline = new(monotonic, wallClock, seed, settings);
        this.reducedMotion = reducedMotion;
        if (networkAllowed && settings.HasLocation)
        {
            if (settings.WeatherEnabled)
                Weather = (WeatherProvider)Providers.RegisterNetwork("weather", () => new WeatherProvider(settings, BoundedHttp.Create(), wallClock));
            if (settings.TournamentsEnabled)
            {
                var nearest = TournamentMetros.Nearest(settings.Latitude, settings.Longitude);
                if (nearest.Miles <= 60)
                {
                    Tournaments = (TournamentProvider)Providers.RegisterNetwork("tournaments",
                        () => new TournamentProvider(settings, nearest.Metro, BoundedHttp.Create(), wallClock));
                    TournamentStatus = "Loading";
                }
                else TournamentStatus = $"Unsupported region — nearest supported metro: {nearest.Metro.Name}, {nearest.Metro.State}";
            }
        }
        else if (settings.TournamentsEnabled) TournamentStatus = "Choose a city in settings";
        timer = new(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(1.0 / 60) };
        timer.Tick += OnTick;
    }
    private readonly bool? reducedMotion;
    public bool ApplyAppearance(string preset) => timeline.ApplyAppearance(preset);
    public void Reseed(uint seed) => timeline.Reseed(seed);

    public void Start()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        Providers.Start();
        timer.Start();
    }
    public void Advance()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        timeline.ReducedMotion = reducedMotion ?? !SystemParameters.ClientAreaAnimation;
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
