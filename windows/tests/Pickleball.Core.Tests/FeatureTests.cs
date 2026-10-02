using System.Net;
using System.Text.Json;
using Pickleball.Core;

namespace Pickleball.Core.Tests;

public sealed class ArtTests
{
    private static RallyEvent Hit(Vec3 p, double facing = 1) => RallyEvent.Hit(new(1, ShotType.Dink, 0, new() { Facing = facing }, p, 1, new(), new(), null, 0));
    [Fact]
    public void DuplicateFrameDoesNotReplayOrAge()
    {
        var art = new ArtEffects(); var frame = new ArtFrame(1, [Hit(new(.1, .3, .4)), RallyEvent.Bounce(new(.2, 0, .6))], new(), true, 0);
        art.Update("living-court", frame, .1); var before = art.Capture();
        art.Update("living-court", frame, 1);
        Assert.Equal(JsonSerializer.Serialize(before), JsonSerializer.Serialize(art.Capture()));
    }
    [Fact]
    public void LivingPulsesRetainContactHeightAndExpire()
    {
        var art = new ArtEffects();
        for (var i = 0; i < 50; i++) art.Update("living-court", new(i, [Hit(new(0, .4, .5)), RallyEvent.Bounce(new())], new(), true, 0), 0);
        Assert.Equal(24, art.Capture().Ripples.Length); Assert.Equal(16, art.Capture().Halos.Length);
        Assert.All(art.Capture().Halos, h => Assert.Equal(.4, h.Position.Y));
        art.Update("living-court", new(51, [], new(), false, 0), 1.2);
        Assert.Empty(art.Capture().Ripples); Assert.Empty(art.Capture().Halos);
    }
    [Fact]
    public void PaintAnchorsFloorSamplingCapsAndGameFadeAreBounded()
    {
        var art = new ArtEffects(); long n = 0;
        art.Update("rally-painting", new(n++, [Hit(new(0, .3, 0))], new(), true, 0), 0);
        for (var i = 1; i < 1000; i++) art.Update("rally-painting", new(n++, i % 100 == 0 ? [RallyEvent.Bounce(new(i * .001, 0, .3))] : [], new(i * .001, .5, .3), true, 0), 1.0 / 30);
        var stroke = Assert.Single(art.Capture().Strokes); Assert.InRange(stroke.Samples.Length, 2, 128);
        Assert.All(stroke.Samples, s => Assert.Equal(0, s.Position.Y));
        Assert.True(stroke.Samples[0].Anchor); Assert.True(stroke.Samples.Count(s => s.Anchor) >= 8);
        var samples = stroke.Samples;
        art.Update("rally-painting", new(n++, [], new(99, 0, 99), false, 0), 1);
        Assert.Equal(samples, art.Capture().Strokes[0].Samples);
        art.Update("rally-painting", new(n++, [Hit(new(.8, .3, .8), -1)], new(), true, 1), 0);
        Assert.Equal(2, art.Capture().Strokes[0].FadeRemaining); Assert.Null(art.Capture().Strokes[1].FadeRemaining);
        art.Update("rally-painting", new(n++, [], new(), false, 1), 1);
        Assert.Equal(.5, art.Capture().Strokes[0].Opacity);
        art.Update("rally-painting", new(n++, [], new(), false, 1), 1);
        Assert.Single(art.Capture().Strokes);
        for (var i = 0; i < 200; i++) art.Update("rally-painting", new(n++, [Hit(new(i, 0, 0))], new(), true, 1), 0);
        Assert.Equal(96, art.Capture().Strokes.Length); Assert.NotNull(art.Capture().Strokes[0].FadeRemaining);
    }
    [Fact]
    public void SamePresetIsStrictNoOpAndTextureIsIndependent()
    {
        var clock = new ReplayClock(new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)); var timeline = new RenderTimeline(clock, clock, 42, new() { Theme = "rally-painting" });
        for (var i = 0; i < 600; i++) { clock.Advance(TimeSpan.FromSeconds(1.0 / 60)); timeline.Advance(); }
        var frame = timeline.Current; Assert.NotEmpty(frame.Art.Strokes);
        Assert.False(timeline.ApplyAppearance("rally-painting")); Assert.Same(frame, timeline.Current);
        var read = timeline.Current.Art; _ = ArtTextures.Washes; _ = ArtTextures.Fibers; _ = ArtTextures.Dots;
        Assert.Equal(read, timeline.Current.Art);
        Assert.True(timeline.ApplyAppearance("classic")); Assert.Empty(timeline.Current.Art.Strokes);
        timeline.ApplyAppearance("rally-painting"); timeline.Reseed(42); Assert.Empty(timeline.Current.Art.Strokes);
        Assert.Equal(3000, ArtTextures.Dots.Length); Assert.Equal(48, ArtTextures.Washes.Length);
        Assert.All(ArtTextures.Washes, w => Assert.Equal(24, w.Length)); Assert.Equal(900, ArtTextures.Fibers.Length);
        var a = new PaperNoise(); var b = new PaperNoise(); for (var i = 0; i < 10000; i++) Assert.Equal(a.Unit(), b.Unit());
    }
    [Theory]
    [InlineData("classic")]
    [InlineData("blacklight")]
    [InlineData("living-court")]
    [InlineData("ink-and-paper")]
    [InlineData("rally-painting")]
    public void AllAppearancesHaveIdenticalGames(string preset)
    {
        var clock = new ReplayClock(new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero));
        var actual = new RenderTimeline(clock, clock, 42, new() { Theme = preset }); var reference = new RenderTimeline(clock, clock, 42);
        for (var i = 0; i < 7200; i++)
        {
            clock.Advance(TimeSpan.FromSeconds(1.0 / 60));
            Assert.Equal(JsonSerializer.Serialize(reference.Advance().Match), JsonSerializer.Serialize(actual.Advance().Match));
        }
    }
}
public sealed class EngineRulesTests
{
    [Theory]
    [InlineData(GameFormat.Doubles)]
    [InlineData(GameFormat.Singles)]
    public void ServeTwoBounceKitchenOpeningSideoutAndGames(GameFormat format)
    {
        var engine = new RallyEngine(); engine.SetFormat(format); engine.Reseed(123);
        var contacts = 0; var opening = true; var priorGames = 0; var foundSideout = false; var foundSecondServer = false; bool? serving = null;
        var shots = new HashSet<ShotType>();
        for (var frame = 0; frame < 3600 * 60; frame++)
        {
            engine.Step(1.0 / 60);
            if (engine.NearGames + engine.FarGames != priorGames)
            {
                priorGames = engine.NearGames + engine.FarGames; opening = true;
                Assert.Equal(0, engine.NearScore); Assert.Equal(0, engine.FarScore); Assert.Equal(2, engine.ServerNumber);
            }
            foreach (var e in engine.FrameEvents)
            {
                if (e.Contact is not { } c) continue;
                contacts++; shots.Add(c.Type);
                if (c.Type == ShotType.Serve)
                {
                    if (opening) { Assert.Equal(2, engine.ServerNumber); opening = false; }
                    if (serving.HasValue && serving != engine.NearServing) foundSideout = true;
                    if (foundSideout && engine.ServerNumber == 2) foundSecondServer = true;
                    serving = engine.NearServing;
                    if (c.IntendedEnding is null)
                    {
                        Assert.True(c.Landing.X * c.Ball.X < 0);
                        Assert.True(c.Player.Facing > 0 ? c.Landing.Z > Court.KitchenFarZ : c.Landing.Z < Court.KitchenNearZ);
                    }
                }
                if (c.Number is 2 or 3) Assert.True(c.ReceivedBounces >= 1);
                if (c.Number > 1 && c.ReceivedBounces == 0) Assert.False(Court.FeetInKitchen(c.Player.Z));
                Assert.InRange(c.Ball.Y, 0, .7);
                Assert.True(double.IsFinite(c.Velocity.X + c.Velocity.Y + c.Velocity.Z));
            }
        }
        Assert.True(contacts > 100); Assert.True(foundSideout); Assert.True(priorGames > 0);
        if (format == GameFormat.Doubles) { Assert.True(foundSecondServer); Assert.Contains(ShotType.Dink, shots); Assert.Contains(ShotType.Lob, shots); }
        Assert.Contains(ShotType.ThirdDrive, shots); Assert.Contains(ShotType.ThirdDrop, shots);
    }
}
public sealed class ProjectionTests
{
    [Theory]
    [InlineData(1280, 720, false)]
    [InlineData(1080, 1920, true)]
    [InlineData(3840, 2160, false)]
    [InlineData(5120, 1440, true)]
    public void EntireRotationEnvelopeFitsIndependentViewports(double width, double height, bool reduced)
    {
        var projection = new Projection(width, height, !reduced, reduced);
        var clock = new ReplayClock(new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)); var frame = new RenderTimeline(clock, clock).Current;
        for (var degrees = 0; degrees < (reduced ? 1 : 360); degrees++)
        {
            projection.Update(frame with { Yaw = degrees * Math.PI / 180, ReducedMotion = reduced });
            foreach (var p in new Vec3[] { new(-1.25, 0, -.08), new(1.25, 0, -.08), new(1.25, 0, 1.08), new(-1.25, 0, 1.08) })
            {
                var q = projection.Project(p);
                Assert.InRange(q.X, projection.Scene.X - 1, width + 1); Assert.InRange(q.Y, -1, height + 1);
            }
            if (reduced) foreach (var p in new Vec3[] { new(-.8, 2.1, .35), new(.8, 2.1, .65) })
            {
                var q = projection.Project(p); Assert.InRange(q.Y, 0, height);
            }
        }
        projection.Update(frame with { Yaw = 0 }); var atZero = projection.IsBehindNet(new(0, 0, .8));
        projection.Update(frame with { Yaw = Math.PI }); Assert.NotEqual(atZero, projection.IsBehindNet(new(0, 0, .8)));
    }
}
public sealed class WidgetTests
{
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        public int Calls;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        { Calls++; return Task.FromResult(response(request)); }
    }
    [Fact]
    public void PreferencesValidateAllFieldsAndOfflineRemovesLocation()
    {
        Assert.Throws<ArgumentException>(() => (new Preferences { CourtMotion = "fast" }).Validate());
        Assert.Throws<ArgumentException>(() => (new Preferences { Latitude = double.NaN }).Validate());
        Assert.Throws<ArgumentException>(() => (new Preferences { Longitude = 181 }).Validate());
        Assert.Throws<ArgumentException>(() => (new Preferences { TournamentMonths = 2 }).Validate());
        var offline = (new Preferences { WeatherEnabled = true, TournamentsEnabled = true, LocationName = "Seattle", Latitude = 47.6, Longitude = -122.3 }).Offline();
        Assert.False(offline.HasLocation); Assert.False(offline.WeatherEnabled); Assert.False(offline.TournamentsEnabled);
        Assert.Equal("slow", new Preferences().CourtMotion); Assert.True(new Preferences().DrillEnabled);
    }
    [Fact]
    public void CalendarAndMetroFilteringAreDeterministic()
    {
        var before = new DateTimeOffset(2026, 3, 8, 1, 0, 0, TimeSpan.FromHours(-8));
        var after = new DateTimeOffset(2026, 3, 8, 23, 0, 0, TimeSpan.FromHours(-7));
        Assert.Equal(Drills.Daily("all", before), Drills.Daily("all", after));
        Assert.Equal("3.5", Drills.Daily("3.5", before)!.Level); Assert.Null(Drills.Daily("unknown", before));
        Assert.Equal(25, TournamentMetros.All.Length);
        Assert.True(TournamentMetros.Nearest(47.6, -122.3).Miles < 60);
        Assert.True(TournamentMetros.Nearest(51.5, -.1).Miles > 60);
    }
    [Fact]
    public async Task AsyncWeatherSnapshotUnitsVerdictAndCancellation()
    {
        const string payload = """{"current":{"temperature_2m":72,"apparent_temperature":71,"weather_code":0,"wind_speed_10m":8},"daily":{"temperature_2m_max":[80,81],"temperature_2m_min":[60,61],"precipitation_probability_max":[10,null],"wind_speed_10m_max":[10,11],"sunrise":["2026-01-01T06:34"],"sunset":["2026-01-01T17:00"]}}""";
        var handler = new Handler(r =>
        {
            Assert.Contains("wind_speed_unit=mph", r.RequestUri!.Query);
            return new(HttpStatusCode.OK) { Content = new StringContent(payload) };
        });
        var provider = new WeatherProvider(new() { WeatherEnabled = true, LocationName = "Test", Latitude = 40 }, new HttpClient(handler),
            new ReplayClock(new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)));
        using var lifetime = new CancellationTokenSource(); provider.Start(lifetime.Token);
        for (var i = 0; i < 100 && provider.State.Value is null; i++) await Task.Delay(10);
        var value = provider.State.Value!; Assert.NotNull(value); Assert.Equal("GREAT DAY TO PLAY", value.Verdict); Assert.Equal("6:34 AM", value.Sunrise);
        Assert.Equal("13 km/h", (value with { Fahrenheit = false }).WindText);
        Assert.Null(value.TomorrowPrecipitation); Assert.Equal(1, handler.Calls);
        lifetime.Cancel(); await provider.Completion.WaitAsync(TimeSpan.FromSeconds(2)); provider.Dispose();
    }
    [Fact]
    public async Task DisabledProviderDoesNotSendHttpAndOversizedPayloadIsExplicit()
    {
        var handler = new Handler(_ => new(HttpStatusCode.OK) { Content = new StringContent(new string(' ', 1024 * 1024 + 1)) });
        using var client = new HttpClient(handler);
        await Assert.ThrowsAsync<JsonException>(() => BoundedHttp.Get(client, "https://example.invalid", CancellationToken.None));
        var initial = handler.Calls;
        using var provider = new WeatherProvider(new(), client, new WallClock()); using var token = new CancellationTokenSource();
        provider.Start(token.Token); await Task.Delay(20); Assert.Equal(initial, handler.Calls); Assert.Contains("Unavailable", provider.State.Status);
        token.Cancel(); await provider.Completion.WaitAsync(TimeSpan.FromSeconds(2));
    }
}
