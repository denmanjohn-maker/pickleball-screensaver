namespace Pickleball.Core;

public interface IProcessProvider : IDisposable
{
    void Start(CancellationToken lifetime);
}

// Register cached background providers once by name before the process starts rendering.
public sealed class ProcessProviders(bool networkAllowed) : IDisposable
{
    private readonly Dictionary<string, IProcessProvider> providers = new(StringComparer.Ordinal);
    private readonly CancellationTokenSource lifetime = new();
    private bool started, disposed;
    public bool NetworkAllowed { get; } = networkAllowed;
    public CancellationToken Lifetime => lifetime.Token;

    public IProcessProvider RegisterNetwork(string name, Func<IProcessProvider> factory)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!NetworkAllowed) throw new InvalidOperationException("Network providers are disabled for this process.");
        if (started) throw new InvalidOperationException("Register providers before starting the process session.");
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentNullException.ThrowIfNull(factory);
        if (providers.TryGetValue(name, out var existing)) return existing;
        var provider = factory() ?? throw new InvalidOperationException("Provider factory returned null.");
        providers.Add(name, provider);
        return provider;
    }

    public void Start()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (started) return;
        started = true;
        try
        {
            foreach (var provider in providers.Values) provider.Start(lifetime.Token);
        }
        catch { Dispose(); throw; }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        var failures = new List<Exception>();
        try { lifetime.Cancel(); }
        catch (AggregateException error) { failures.Add(error); }
        foreach (var provider in providers.Values)
        {
            try { provider.Dispose(); }
            catch (Exception error) { failures.Add(error); }
        }
        providers.Clear();
        lifetime.Dispose();
        if (failures.Count > 0) throw new AggregateException("Provider disposal failed.", failures);
    }
}
