using System.Text.Json;
using Pickleball.Core;

namespace Pickleball.Core.Tests;

public sealed class EngineParityTests
{
    [Fact]
    public void SplitMixAndSwiftRandomMappingMatch()
    {
        var bits = new SeededGenerator(42);
        Assert.Equal(13679457532755275413UL, bits.Next());
        var uniform = new SeededGenerator(42);
        Assert.Equal(.7415648787718234, uniform.Unit());
        var boolean = new SeededGenerator(42);
        Assert.False(boolean.Bool());
        var integer = new SeededGenerator(42);
        Assert.Equal(3, integer.Integer(1, 3));
    }

    [Fact]
    public void UnchangedMergedSwiftContactTracesMatch()
    {
        using var resource = typeof(EngineParityTests).Assembly.GetManifestResourceStream(
            "Pickleball.Core.Tests.Fixtures.final-main-seed42.json")!;
        using var document = JsonDocument.Parse(resource);
        foreach (var run in document.RootElement.GetProperty("runs").EnumerateArray())
        {
            var engine = new RallyEngine();
            engine.SetFormat(run.GetProperty("format").GetString() == "singles" ? GameFormat.Singles : GameFormat.Doubles);
            engine.Reseed(42);
            var expected = run.GetProperty("contacts").EnumerateArray().ToArray();
            var contactIndex = 0;
            for (var frame = 0; frame < 180 * 120; frame++)
            {
                engine.Step(1.0 / 120);
                foreach (var e in engine.FrameEvents)
                {
                    if (e.Contact is not { } c) continue;
                    Assert.True(contactIndex < expected.Length, "Port produced an extra contact.");
                    var golden = expected[contactIndex++];
                    Assert.Equal(golden.GetProperty("frame").GetInt32(), frame);
                    Assert.Equal(golden.GetProperty("number").GetInt32(), c.Number);
                    Assert.Equal(golden.GetProperty("type").GetString(), RallyEngine.ShotId(c.Type));
                    Assert.Equal(golden.GetProperty("player").GetInt32(), c.PlayerIndex);
                    Assert.Equal(golden.GetProperty("bounces").GetInt32(), c.ReceivedBounces);
                    var context = $"{engine.Format} contact={contactIndex} frame={frame} type={c.Type}";
                    var playerGolden = golden.GetProperty("players");
                    for (var i = 0; i < engine.Players.Count; i++)
                    {
                        Assert.True(Math.Abs(playerGolden[i][0].GetDouble() - engine.Players[i].X) <= 1e-7, context);
                        Assert.True(Math.Abs(playerGolden[i][1].GetDouble() - engine.Players[i].Z) <= 1e-7, context);
                    }
                    Compare(golden.GetProperty("ball"), c.Ball, context);
                    Compare(golden.GetProperty("velocity"), c.Velocity, context);
                    Compare(golden.GetProperty("landing"), c.Landing, context);
                }
            }
            Assert.Equal(expected.Length, contactIndex);
            Assert.Equal(run.GetProperty("nearScore").GetInt32(), engine.NearScore);
            Assert.Equal(run.GetProperty("farScore").GetInt32(), engine.FarScore);
            Assert.Equal(run.GetProperty("nearGames").GetInt32(), engine.NearGames);
            Assert.Equal(run.GetProperty("farGames").GetInt32(), engine.FarGames);
        }
    }
    private static void Compare(JsonElement expected, Vec3 actual, string context)
    {
        var values = expected.EnumerateArray().Select(v => v.GetDouble()).ToArray();
        Assert.True(Math.Abs(values[0] - actual.X) <= 1e-7 && Math.Abs(values[1] - actual.Y) <= 1e-7
            && Math.Abs(values[2] - actual.Z) <= 1e-7, $"{context} expected={expected} actual={actual}");
    }
}
