using System.Text.Json;
using Pickleball.Core;

namespace Pickleball.Core.Tests;

public sealed class HostTests
{
    [Theory]
    [InlineData("/s", HostMode.Fullscreen, 0)]
    [InlineData("/S", HostMode.Fullscreen, 0)]
    [InlineData("-s", HostMode.Fullscreen, 0)]
    [InlineData("/c", HostMode.Configure, 0)]
    [InlineData("/C:42", HostMode.Configure, 42)]
    [InlineData("/p:4294967296", HostMode.Preview, 4294967296)]
    [InlineData("/P:18446744073709551615", HostMode.Preview, ulong.MaxValue)]
    public void ParsesColonForms(string input, HostMode mode, ulong handle) =>
        Assert.Equal(new(mode, handle), HostOptions.Parse([input]));

    [Theory]
    [InlineData("/c")]
    [InlineData("/P")]
    public void ParsesSpaceForms(string option) =>
        Assert.Equal(17UL, HostOptions.Parse([option, "17"]).ParentHandle);

    [Fact]
    public void NoArgumentsConfigure() => Assert.Equal(HostMode.Configure, HostOptions.Parse([]).Mode);

    [Theory]
    [InlineData("/p")]
    [InlineData("/p:0")]
    [InlineData("/p:")]
    [InlineData("/p:-1")]
    [InlineData("/p:1:2")]
    [InlineData("/p:0x20")]
    [InlineData("/p:18446744073709551616")]
    [InlineData("/p: 42")]
    [InlineData("/p:+42")]
    [InlineData("/c:garbage")]
    [InlineData("/c:0")]
    [InlineData("/s:42")]
    [InlineData("/x")]
    [InlineData("/screensaver")]
    [InlineData("s")]
    [InlineData("")]
    public void InvalidOptionsNeverFallback(string input) =>
        Assert.Throws<ArgumentException>(() => HostOptions.Parse([input]));

    [Fact]
    public void ExtraArgumentsAndPointerOverflowRejected()
    {
        Assert.Throws<ArgumentException>(() => HostOptions.Parse(["/c:4", "5"]));
        Assert.Throws<ArgumentException>(() => HostOptions.Parse(["/s", "5"]));
        Assert.Throws<ArgumentException>(() => HostOptions.Parse(["/p", "5", "6"]));
        Assert.Throws<ArgumentException>(() => HostOptions.Parse(["/p:4294967296"], 32));
        Assert.Equal(uint.MaxValue, HostOptions.Parse(["/p:4294967295"], 32).ParentHandle);
    }
}

public sealed class ClockAndViewportTests
{
    private static readonly DateTimeOffset Epoch = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private sealed class ManualClock : IMonotonicClock, IWallClock
    {
        public TimeSpan Elapsed { get; set; }
        public DateTimeOffset Now { get; set; } = Epoch;
    }

    [Fact]
    public void ReplayIsDeterministicAndSeeded()
    {
        var a = new ReplayClock(Epoch);
        var b = new ReplayClock(Epoch);
        var first = new RenderTimeline(a, a, 123);
        var second = new RenderTimeline(b, b, 123);
        for (var index = 0; index < 240; index++)
        {
            a.Advance(TimeSpan.FromSeconds(1.0 / 60));
            b.Advance(TimeSpan.FromSeconds(1.0 / 60));
            // ImmutableArray<T>'s default equality is reference-based, so compare frames
            // structurally via JSON rather than relying on record equality.
            Assert.Equal(JsonSerializer.Serialize(first.Advance()), JsonSerializer.Serialize(second.Advance()));
        }
        Assert.NotEqual(first.Current.Match.Ball, new RenderTimeline(a, a, 124).Current.Match.Ball);
        Assert.Empty(first.Current.Events);
        Assert.Throws<ArgumentOutOfRangeException>(() => a.Advance(TimeSpan.FromSeconds(-1)));
    }

    [Fact]
    public void WallClockJumpDoesNotStepSimulationAndStallsAreBounded()
    {
        var clock = new ManualClock();
        var timeline = new RenderTimeline(clock, clock);
        clock.Now = Epoch.AddDays(-1);
        Assert.Equal(TimeSpan.Zero, timeline.Advance().SimulationTime);
        clock.Elapsed = TimeSpan.FromSeconds(4);
        Assert.Equal(TimeSpan.FromSeconds(.25), timeline.Advance().SimulationTime);
        clock.Elapsed = TimeSpan.Zero;
        Assert.Equal(TimeSpan.FromSeconds(.25), timeline.Advance().SimulationTime);
    }

    [Theory]
    [InlineData(-3840, -200, 3840, 2160, 192)]
    [InlineData(0, 0, 1080, 1920, 96)]
    [InlineData(1920, 0, 3440, 1440, 144)]
    public void FitsMixedDpiPortraitAndNegativeMonitorOrigins(int x, int y, int width, int height, int dpi)
    {
        var fit = Viewport.FitMonitor(new(x, y, width, height), dpi, dpi);
        Assert.True(fit.X >= 0 && fit.Y >= 0);
        Assert.True(fit.Width <= width * 96.0 / dpi + .001);
        Assert.True(fit.Height <= height * 96.0 / dpi + .001);
        Assert.Equal(16.0 / 9, fit.Width / fit.Height, 8);
    }

    [Fact]
    public void InvalidViewportRejected()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => Viewport.Fit(0, 100));
        Assert.Throws<ArgumentOutOfRangeException>(() => Viewport.Fit(double.NaN, 100));
        Assert.Throws<ArgumentOutOfRangeException>(() => Viewport.FitMonitor(new(0, 0, 10, 10), 0, 96));
    }

    [Fact]
    public void CursorNoiseIsIgnoredButMovementHasNoDelay()
    {
        var input = new MouseExitTracker(-2000, 100);
        Assert.False(input.ShouldExit(-2000, 100));
        Assert.False(input.ShouldExit(-1996, 104));
        Assert.True(input.ShouldExit(-1995, 100));
        Assert.True(input.ShouldExit(int.MaxValue, int.MinValue));
    }

    [Theory]
    [InlineData("drills.json")]
    [InlineData("paddle.png")]
    [InlineData("background.png")]
    [InlineData("icon.svg")]
    public void SharedResourcesAreAssemblyEmbedded(string name)
    {
        using var resource = SharedResources.Open(name);
        Assert.True(resource.Length > 0);
        if (name.EndsWith(".json", StringComparison.Ordinal))
            using (JsonDocument.Parse(resource)) { }
    }
}

public sealed class SettingsTests : IDisposable
{
    // Never touch the user's LOCALAPPDATA; test artifacts live beneath the test working directory.
    private readonly string directory = System.IO.Path.Combine(Directory.GetCurrentDirectory(), "TestResults", Guid.NewGuid().ToString("N"));
    private readonly SettingsStore store;
    public SettingsTests()
    {
        Directory.CreateDirectory(directory);
        store = new(System.IO.Path.Combine(directory, "settings.json"));
    }
    [Fact]
    public void MissingDoesNotWriteAndCancelCanDiscardDraft()
    {
        Assert.Equal(SettingsStatus.Missing, store.Load().Status);
        _ = store.Load().Value with { Theme = "blacklight" };
        Assert.False(File.Exists(store.Path));
    }
    [Theory]
    [InlineData("classic")]
    [InlineData("blacklight")]
    [InlineData("living-court")]
    [InlineData("ink-and-paper")]
    [InlineData("rally-painting")]
    public void SaveRoundTripsAndLeavesNoStagingFile(string theme)
    {
        store.Save(new() { Theme = theme });
        Assert.Equal(SettingsStatus.Loaded, new SettingsStore(store.Path).Load().Status);
        Assert.Equal(theme, store.Load().Value.Theme);
        store.Save(new() { Theme = "classic" });
        Assert.Single(Directory.GetFiles(directory));
    }
    [Theory]
    [InlineData("bad json", SettingsStatus.Corrupt)]
    [InlineData("null", SettingsStatus.Corrupt)]
    [InlineData("[]", SettingsStatus.Corrupt)]
    [InlineData("{\"schemaVersion\":\"1\"}", SettingsStatus.Corrupt)]
    [InlineData("{\"schemaVersion\":1}", SettingsStatus.Corrupt)]
    [InlineData("{\"schemaVersion\":1,\"theme\":null}", SettingsStatus.Corrupt)]
    [InlineData("{\"schemaVersion\":1,\"theme\":false}", SettingsStatus.Corrupt)]
    [InlineData("{\"schemaVersion\":1,\"theme\":\"unknown\"}", SettingsStatus.Corrupt)]
    [InlineData("{\"schemaVersion\":2,\"theme\":\"classic\"}", SettingsStatus.Unsupported)]
    public void InvalidFilesArePreservedUntilExplicitReset(string content, SettingsStatus expected)
    {
        File.WriteAllText(store.Path, content);
        Assert.Equal(expected, store.Load().Status);
        Assert.Throws<IOException>(() => store.Save(new()));
        Assert.Equal(content, File.ReadAllText(store.Path));
        store.Save(new(), explicitlyReset: true);
        Assert.Equal(SettingsStatus.Loaded, store.Load().Status);
    }
    [Fact]
    public void OversizedAndInvalidPreferencesRejected()
    {
        File.WriteAllText(store.Path, new string(' ', 17 * 1024));
        Assert.Equal(SettingsStatus.Corrupt, store.Load().Status);
        Assert.Throws<ArgumentException>(() => store.Save(new() { Theme = "unknown" }, true));
        Assert.Throws<ArgumentException>(() => store.Save(new() { SchemaVersion = 2 }, true));
    }
    [Fact]
    public async Task ReadersObserveCompleteDocumentsDuringAtomicReplacement()
    {
        store.Save(new());
        var writer = Task.Run(() =>
        {
            for (var i = 0; i < 50; i++) store.Save(new() { Theme = i % 2 == 0 ? "classic" : "blacklight" });
        });
        while (!writer.IsCompleted)
            Assert.Equal(SettingsStatus.Loaded, store.Load().Status);
        await writer;
        Assert.Single(Directory.GetFiles(directory));
    }
    public void Dispose() => Directory.Delete(directory, recursive: true);
}

public sealed class ProviderTests
{
    private sealed class Provider(bool failStart = false, bool failDispose = false) : IProcessProvider
    {
        public int Starts, Disposals;
        public CancellationToken Token;
        public void Start(CancellationToken lifetime)
        {
            Starts++;
            Token = lifetime;
            if (failStart) throw new InvalidOperationException("Test start failure.");
        }
        public void Dispose()
        {
            Disposals++;
            if (failDispose) throw new InvalidOperationException("Test disposal failure.");
        }
    }

    [Fact]
    public void OfflineScopeCannotEvenCreateNetworkProviders()
    {
        using var scope = new ProcessProviders(networkAllowed: false);
        var created = false;
        Assert.Throws<InvalidOperationException>(() => scope.RegisterNetwork("weather", () =>
        {
            created = true;
            return new Provider();
        }));
        scope.Start();
        Assert.False(created);
    }

    [Fact]
    public void SharedProvidersStartAndDisposeOnlyOnce()
    {
        var scope = new ProcessProviders(networkAllowed: true);
        var provider = new Provider();
        var token = scope.Lifetime;
        Assert.Same(provider, scope.RegisterNetwork("weather", () => provider));
        Assert.Same(provider, scope.RegisterNetwork("weather", () => throw new Exception("Duplicate factory invoked.")));
        scope.Start();
        scope.Start();
        Assert.Equal(1, provider.Starts);
        Assert.Throws<InvalidOperationException>(() => scope.RegisterNetwork("tournaments", () => new Provider()));
        scope.Dispose();
        scope.Dispose();
        Assert.True(token.IsCancellationRequested);
        Assert.Equal(1, provider.Disposals);
        Assert.Throws<ObjectDisposedException>(() => scope.Start());
    }

    [Fact]
    public void FailedStartupCancelsAndDisposesAllRegisteredProviders()
    {
        var scope = new ProcessProviders(true);
        var first = new Provider(failStart: true);
        var second = new Provider();
        var token = scope.Lifetime;
        scope.RegisterNetwork("first", () => first);
        scope.RegisterNetwork("second", () => second);
        Assert.Throws<InvalidOperationException>(() => scope.Start());
        Assert.True(token.IsCancellationRequested);
        Assert.Equal(1, first.Disposals);
        Assert.Equal(1, second.Disposals);
        scope.Dispose();
    }

    [Fact]
    public void FailedDisposalDoesNotLeakOtherProviders()
    {
        var scope = new ProcessProviders(true);
        var first = new Provider(failDispose: true);
        var second = new Provider();
        scope.RegisterNetwork("first", () => first);
        scope.RegisterNetwork("second", () => second);
        Assert.Throws<AggregateException>(() => scope.Dispose());
        Assert.Equal(1, second.Disposals);
        scope.Dispose();
    }
}
