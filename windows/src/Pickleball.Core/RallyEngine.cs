using System.Globalization;

namespace Pickleball.Core;

public static class Court
{
    public const double FeetPerX = 10, FeetPerZ = 44, FeetPerY = 9.375, NetHeight = .32;
    public const double KitchenNearZ = 15.0 / 44, KitchenFarZ = 29.0 / 44;
    public static double NetTopY(double x) => (34 + 2 * x * x) / (12 * FeetPerY);
    public static bool FeetInKitchen(double z) => z >= KitchenNearZ - .01 && z <= KitchenFarZ + .01;
    public static double Smoothstep(double x) { var c = Math.Clamp(x, 0, 1); return c * c * (3 - 2 * c); }
}

public record struct Vec3(double X, double Y, double Z);
public enum GameFormat { Singles, Doubles }
public enum RallyPhase { BetweenPoints, Serve, Returning, Third, Transition, Kitchen, Firefight, Dead }
public enum ShotType { Serve, ServiceReturn, ThirdDrop, ThirdDrive, Drop, Drive, Dink, Reset, Speedup, Counter, Lob }
public enum RallyEnding { NetError, WideError, LongError, Winner }

public struct PlayerState
{
    public double X, Z, Facing, Hand, TargetX, TargetZ, HomeX, Stance, CommittedStance;
    public int Court;
    public bool SwingPhase, Armed, HasPrediction, KitchenEstablished;
    public double SwingT, SwingDur, SwingAmp, SwingAngle, FaceDZ, FaceY, ContactY;
    public double ReactionTimer, PredictedX, PredNoise, PredClock, SwingReach, ContactDZ, VolleyRecovery;
    public PlayerState()
    {
        Facing = Hand = Stance = SwingAmp = 1;
        SwingDur = .5; SwingAngle = 1.2; FaceY = .08; ContactY = .12;
        Armed = KitchenEstablished = true; SwingReach = .18;
    }
}

public sealed record ShotContact(int Number, ShotType Type, int PlayerIndex, PlayerState Player,
    Vec3 Ball, int ReceivedBounces, Vec3 Velocity, Vec3 Landing, RallyEnding? IntendedEnding, int ServingScore);
public sealed record RallyEvent(ShotContact? Contact, Vec3 Position)
{
    public static RallyEvent Hit(ShotContact contact) => new(contact, contact.Ball);
    public static RallyEvent Bounce(Vec3 point) => new(null, point);
}

public struct SeededGenerator(ulong seed)
{
    private ulong state = seed;
    public ulong Next()
    {
        unchecked
        {
            state += 0x9E3779B97F4A7C15;
            var z = state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
            return z ^ (z >> 31);
        }
    }
    // Swift's closed CGFloat range samples 2^53 + 1 discrete values, including 1.
    // Its multiply-high rejection can consume an extra draw; dividing UInt64 directly
    // looks equivalent but eventually changes the entire rally trace.
    public double Unit() => Bounded((1UL << 53) + 1) / (double)(1UL << 53);
    public bool Bool() => (Next() & 1) == 0;
    public int Integer(int low, int high)
    {
        var width = (ulong)(high - low + 1);
        return low + (int)Bounded(width);
    }
    private ulong Bounded(ulong width)
    {
        var threshold = unchecked(0UL - width) % width;
        UInt128 product;
        do { product = (UInt128)Next() * width; } while ((ulong)product < threshold);
        return (ulong)(product >> 64);
    }
}

// Mechanical behavioral port of RallyEngine.swift at f0dc816. UI/appearance never mutates this engine.
public sealed class RallyEngine
{
    private Vec3 ball = new(0, .1, .04), velocity;
    private PlayerState[] players = [];
    private IReadOnlyList<PlayerState> playerView = Array.Empty<PlayerState>();
    private readonly List<Vec3> trail = [];
    private readonly List<RallyEvent> events = [];
    public Vec3 Ball => ball;
    public Vec3 Velocity => velocity;
    public IReadOnlyList<PlayerState> Players => playerView;
    public IReadOnlyList<Vec3> TrailPoints => trail.AsReadOnly();
    public IReadOnlyList<RallyEvent> FrameEvents => events.AsReadOnly();
    public double BallSpin { get; private set; }
    public GameFormat Format { get; private set; } = GameFormat.Doubles;
    public double Gravity { get; set; } = -3.2;
    public double ThirdDriveFraction { get; set; } = .5;
    public double DinkCrossFraction { get; set; } = .80;
    public double EndingErrorFraction { get; set; } = .66;
    public double LeftyProbability { get; set; } = 1.0 / 6;
    public double SpeedupProbability { get; set; } = .07;
    public double LobProbability { get; set; } = .03;
    public double RunAroundProbability { get; set; } = .30;
    private const double BounceDamp = .55, NearBaseline = -.035, FarBaseline = 1.035, KitchenStandoff = .02;
    private const double LateralMax = .60, LateralNear = .35, AdvanceSpeed = .11, RunSpeed = .15;
    private const double Reach = .18, HitWindow = .06, BackhandReach = .14;
    private const double BackswingFraction = .45, RecoveryFraction = .50, BackswingAngle = -1.6;
    private const double FollowAngle = .8, ReadyAngle = 1.2, SwingLength = .075, SwingDrop = .13, RestFaceY = .08;
    private const double ContactFraction = BackswingFraction + (1 - BackswingFraction) / 2;
    private double LateralSpeed => Format == GameFormat.Singles ? .85 : LateralMax;
    public RallyPhase Phase { get; private set; } = RallyPhase.BetweenPoints;
    private double phaseTimer = 1.2, accumulatedTime, flightElapsed;
    private int shotIndex, scriptLength = 7, bounceCount, hitterIndex, serverIndex, dinkStreak;
    private RallyEnding scriptEnding = RallyEnding.NetError;
    private bool mustBounce, lastHitNear = true, rallyLostByNear, serveArmed, leaveOutBall, reportedMiss;
    private ShotType lastShot = ShotType.Serve;
    public int ContactCount { get; private set; }
    public ShotContact? LastContact { get; private set; }
    public int NearScore { get; private set; }
    public int FarScore { get; private set; }
    public bool NearServing { get; private set; }
    public int ServerNumber { get; private set; } = 2;
    private bool needsFirstServer = true;
    public int NearGames { get; private set; }
    public int FarGames { get; private set; }
    public double GameBannerTimer { get; private set; }
    private SeededGenerator rng;
    public Action<string>? StatsSink { get; set; }

    public RallyEngine(ulong seed = 1) => Reseed(seed);
    public void Reseed(ulong seed)
    {
        rng = new(seed);
        NearScore = FarScore = NearGames = FarGames = 0;
        ServerNumber = 2; needsFirstServer = true; GameBannerTimer = accumulatedTime = 0;
        LastContact = null; ContactCount = 0; events.Clear();
        NearServing = rng.Bool();
        BuildPlayers(); BeginBetweenPoints(1);
    }
    public void SetFormat(GameFormat format)
    {
        if (Format == format) return;
        Format = format;
        NearScore = FarScore = NearGames = FarGames = 0;
        GameBannerTimer = accumulatedTime = 0; ServerNumber = 2; needsFirstServer = true;
        LastContact = null; ContactCount = 0; events.Clear();
        BuildPlayers(); BeginBetweenPoints(1);
    }
    private void BuildPlayers()
    {
        PlayerState Make(double facing, int court)
        {
            var p = new PlayerState { Facing = facing, Court = court };
            p.Z = p.TargetZ = BaselineZ(facing);
            p.X = p.TargetX = p.HomeX = HomeX(facing, court);
            return p;
        }
        players = Format == GameFormat.Singles ? [Make(1, 0), Make(-1, 0)]
            : [Make(1, 0), Make(1, 1), Make(-1, 0), Make(-1, 1)];
        playerView = Array.AsReadOnly(players);
        RollHands();
    }
    private void RollHands() { for (var i = 0; i < players.Length; i++) players[i].Hand = Chance(LeftyProbability) ? -1 : 1; }
    private static double Forehand(PlayerState p) => p.Facing * p.Hand;
    private double Rand(double low, double high) => low + (high - low) * rng.Unit();
    private bool Chance(double probability) => rng.Unit() < probability;
    private double Gauss(double mean, double sd)
    {
        var u1 = Rand(1e-6, 1); var u2 = Rand(0, 1);
        return mean + sd * Math.Sqrt(-2 * Math.Log(u1)) * Math.Cos(2 * Math.PI * u2);
    }
    private int[] Indices(double facing) => Enumerable.Range(0, players.Length).Where(i => players[i].Facing == facing).ToArray();
    private static double CourtX(double facing, int court) => (court == 0 ? (facing > 0 ? -1 : 1) : (facing > 0 ? 1 : -1)) * .5;
    private double HomeX(double facing, int court) => Format == GameFormat.Singles ? 0 : CourtX(facing, court) * .9;
    private static double BaselineZ(double facing) => facing > 0 ? NearBaseline : FarBaseline;
    private static double KitchenZ(double facing) => facing > 0 ? Court.KitchenNearZ - KitchenStandoff : Court.KitchenFarZ + KitchenStandoff;
    private static bool AtKitchen(PlayerState p) => p.Facing > 0 ? p.Z > Court.KitchenNearZ - KitchenStandoff - .06 : p.Z < Court.KitchenFarZ + KitchenStandoff + .06;
    private bool TeamAtKitchen(double facing) => Indices(facing).All(i => AtKitchen(players[i]));
    private (Vec3 V, double Time) SolveLanding(double x0, double z0, double y0, double x, double z, double margin)
    {
        var alpha = Math.Clamp((.5 - z0) / (z - z0), .05, .95);
        var netY = Court.NetTopY(x * alpha + x0 * (1 - alpha));
        var m = Math.Max(margin, y0 * (1 - alpha) - netY + .05);
        var square = 2 * (netY + m - y0 * (1 - alpha)) / (Gravity * (alpha * alpha - alpha));
        var t = Math.Sqrt(Math.Max(.05, square));
        var vy = -y0 / t - Gravity * t / 2;
        return (new((x - x0) / t, vy, (z - z0) / t), t);
    }
    private (Vec3 V, double Time) SolveApex(double x0, double z0, double y0, double x, double z, double apex)
    {
        var vy = Math.Sqrt(Math.Max(.1, -2 * Gravity * (apex - y0)));
        var t = (vy + Math.Sqrt(vy * vy + 2 * -Gravity * y0)) / -Gravity;
        return (new((x - x0) / t, vy, (z - z0) / t), t);
    }
    private void SampleScript()
    {
        var r = Rand(0, 1);
        scriptLength = r < .007 ? 1 : r < .031 ? 2 : Math.Min(25, 3 + (int)(-7.5 * Math.Log(Rand(1e-6, 1))));
        if (Chance(EndingErrorFraction))
        {
            var k = Rand(0, 1);
            scriptEnding = k < .5 ? RallyEnding.NetError : k < .75 ? RallyEnding.WideError : RallyEnding.LongError;
        }
        else scriptEnding = RallyEnding.Winner;
        if (scriptLength <= 2 && EndingErrorFraction > 0) scriptEnding = Chance(.6) ? RallyEnding.NetError : RallyEnding.LongError;
    }
    private void BeginBetweenPoints(double? firstDelay = null)
    {
        SampleScript();
        Phase = RallyPhase.BetweenPoints; phaseTimer = firstDelay ?? Rand(2, 3.5);
        serveArmed = false; shotIndex = bounceCount = dinkStreak = 0; leaveOutBall = false;
        trail.Clear(); BallSpin = 0;
        var facing = NearServing ? 1 : -1;
        var score = NearServing ? NearScore : FarScore;
        var servers = Indices(facing); var receivers = Indices(-facing);
        if (Format == GameFormat.Singles)
        {
            serverIndex = servers[0];
            players[serverIndex].Court = score % 2; players[receivers[0]].Court = score % 2;
        }
        else if (needsFirstServer) serverIndex = servers.First(i => players[i].Court == 0);
        needsFirstServer = false;
        var receiverIndex = receivers.FirstOrDefault(i => players[i].Court == players[serverIndex].Court, receivers[0]);
        for (var i = 0; i < players.Length; i++)
        {
            var p = players[i];
            p.HasPrediction = false; p.Armed = true; p.VolleyRecovery = 0;
            p.TargetX = CourtX(p.Facing, p.Court);
            p.TargetZ = i == serverIndex || p.Facing == facing || i == receiverIndex ? BaselineZ(p.Facing) : KitchenZ(p.Facing);
            p.HomeX = p.TargetX; players[i] = p;
        }
        hitterIndex = receiverIndex;
    }
    private void LaunchServe()
    {
        shotIndex = 1; lastHitNear = NearServing; lastShot = ShotType.Serve; Phase = RallyPhase.Serve;
        mustBounce = true; bounceCount = 0;
        StatsSink?.Invoke($"script n={scriptLength} ending={EndingId(scriptEnding)}");
        for (var i = 0; i < players.Length; i++) players[i].HomeX = HomeX(players[i].Facing, players[i].Court);
        var server = players[serverIndex];
        ball = new(server.X + server.Stance * Reach, .24, server.Z);
        var boxSign = -(server.X / Math.Max(.001, Math.Abs(server.X)));
        var x = boxSign * Rand(.30, .78); var depth = Rand(.87, .955);
        var z = server.Facing > 0 ? depth : 1 - depth; var margin = Rand(.10, .22);
        velocity = SolveLanding(ball.X, ball.Z, ball.Y, x, z, margin).V;
        ApplyEnding(1, x, z, margin);
        PlaceContactPose(ref server); server.SwingAmp = .9; players[serverIndex] = server;
        RecordContact(1, ShotType.Serve, serverIndex, server, 0);
        PrimeReceiver(hitterIndex);
        EmitShot(1, ShotType.Serve, server.Facing, server.Stance == Forehand(server) ? "FH" : "BH", ball.X);
    }
    private void DesignateReceiver(double facing)
    {
        var indices = Indices(facing); var chosen = indices[0];
        if (indices.Length == 2)
        {
            var a = indices[0]; var b = indices[1]; var mid = (players[a].X + players[b].X) / 2;
            var px = InterceptX((players[a].Z + players[b].Z) / 2);
            if (Math.Abs(px - mid) < .15)
            {
                var aFh = -players[a].X * Forehand(players[a]) > 0; var bFh = -players[b].X * Forehand(players[b]) > 0;
                var preferred = aFh && !bFh ? a : bFh && !aFh ? b : Math.Abs(players[a].X - px) < Math.Abs(players[b].X - px) ? a : b;
                chosen = Chance(.8) ? preferred : preferred == a ? b : a;
            }
            else chosen = Math.Abs(players[a].X - px) < Math.Abs(players[b].X - px) ? a : b;
        }
        PrimeReceiver(chosen);
    }
    private void PrimeReceiver(int i)
    {
        hitterIndex = i; players[i].ReactionTimer = Math.Clamp(Gauss(.22, .05), .12, .35);
        players[i].PredNoise = Gauss(0, .08); players[i].HasPrediction = false;
        players[i].CommittedStance = players[i].PredClock = 0;
    }
    private void ApplyEnding(int number, double x, double z, double margin, double? apex = null)
    {
        if (number == scriptLength)
        {
            switch (scriptEnding)
            {
                case RallyEnding.NetError:
                    var t = (.5 - ball.Z) / velocity.Z;
                    var netX = ball.X + velocity.X * t;
                    velocity.Y = (Court.NetTopY(netX) - Rand(.025, .055) - ball.Y - Gravity * t * t / 2) / t;
                    break;
                case RallyEnding.WideError:
                    x = (x >= 0 ? 1 : -1) * Rand(1.06, 1.12);
                    velocity = apex.HasValue ? SolveApex(ball.X, ball.Z, ball.Y, x, z, apex.Value).V
                        : SolveLanding(ball.X, ball.Z, ball.Y, x, z, margin).V;
                    break;
                case RallyEnding.LongError:
                    z = velocity.Z > 0 ? Rand(1.03, 1.08) : Rand(-.08, -.03);
                    velocity = apex.HasValue ? SolveApex(ball.X, ball.Z, ball.Y, x, z, apex.Value).V
                        : SolveLanding(ball.X, ball.Z, ball.Y, x, z, margin).V;
                    break;
            }
        }
        var landing = LandingPoint();
        leaveOutBall = Math.Abs(landing.X) > 1.025 || landing.Z < -.025 || landing.Z > 1.025;
        flightElapsed = 0; reportedMiss = false;
    }
    public void Step(double dt)
    {
        if (!double.IsFinite(dt) || dt < 0 || dt > .25) throw new ArgumentOutOfRangeException(nameof(dt));
        events.Clear(); accumulatedTime += dt;
        const double fixedDT = 1.0 / 120;
        while (accumulatedTime + 1e-9 >= fixedDT)
        {
            accumulatedTime = Math.Max(0, accumulatedTime - fixedDT); StepSimulation(fixedDT);
        }
    }
    private void StepSimulation(double dt)
    {
        if (GameBannerTimer > 0) GameBannerTimer -= dt;
        if (Phase == RallyPhase.BetweenPoints) StepBetweenPoints(dt);
        else if (Phase == RallyPhase.Dead)
        {
            phaseTimer -= dt; IntegrateBall(dt, false); UpdateSwings(dt); MovePlayers(dt);
            if (phaseTimer <= 0) ScoreRally();
        }
        else StepRally(dt);
        BallSpin += Math.Sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z) * 18 * dt;
        if (Phase != RallyPhase.BetweenPoints)
        {
            trail.Add(ball); if (trail.Count > 36) trail.RemoveAt(0);
        }
    }
    private void StepBetweenPoints(double dt)
    {
        phaseTimer -= dt; MovePlayers(dt); UpdateSwings(dt);
        var server = players[serverIndex]; var facing = server.Facing;
        if (!serveArmed) { ball = new(server.X + facing * .7 * Reach, .14, server.Z); velocity = new(); }
        var ready = players.All(p => Math.Abs(p.X - p.TargetX) < .02 && Math.Abs(p.Z - p.TargetZ) < .005);
        if (!serveArmed && phaseTimer <= 0 && ready)
        {
            serveArmed = true;
            server.Stance = Forehand(server); server.ContactY = .24; server.SwingPhase = true; server.SwingT = 0;
            server.SwingDur = .55; server.SwingAmp = .9; server.SwingReach = Reach; server.ContactDZ = 0;
            players[serverIndex] = server;
        }
        if (serveArmed)
        {
            var s = players[serverIndex];
            if (s.SwingT >= ContactFraction) LaunchServe();
            else ball = new(s.X + facing * .7 * Reach, .20, s.Z);
        }
    }
    private void StepRally(double dt)
    {
        flightElapsed += dt; var previous = ball;
        IntegrateBall(dt, true); if (Phase == RallyPhase.Dead) return;
        MovePlayers(dt); UpdateSwings(dt);
        if ((previous.Z - .5) * (ball.Z - .5) < 0)
        {
            var t = (.5 - previous.Z) / (ball.Z - previous.Z);
            var y = previous.Y + (ball.Y - previous.Y) * t; var x = previous.X + (ball.X - previous.X) * t;
            if (y < Court.NetTopY(x))
            {
                ball.Z = .5 - (velocity.Z > 0 ? .012 : -.012);
                velocity.Z = (velocity.Z > 0 ? -1 : 1) * .04; velocity.X *= .15; velocity.Y = Math.Min(velocity.Y, 0) * .3;
                PointOver(lastHitNear, "net"); return;
            }
        }
        var h = players[hitterIndex]; var coming = h.Facing > 0 ? velocity.Z < 0 : velocity.Z > 0;
        if (!leaveOutBall && coming && Math.Abs(ball.Z - h.Z) <= .012 && (h.Facing > 0 ? ball.Z <= h.Z : ball.Z >= h.Z)) AttemptHit();
    }
    private void AttemptHit()
    {
        var index = hitterIndex; var p = players[index];
        if (p.CommittedStance != 0) p.Stance = p.CommittedStance;
        else if (!p.SwingPhase)
        {
            var fh = Forehand(p); p.Stance = (ball.X - p.X) * fh > .04 ? fh : -fh;
        }
        if ((ball.X - p.X) * p.Stance < 0 && Math.Abs(ball.X - p.X) < .025) p.Stance = -p.Stance;
        var maxReach = (p.Stance != Forehand(p) ? BackhandReach : Reach) + HitWindow;
        var offset = (ball.X - p.X) * p.Stance;
        var canStrike = bounceCount >= 1 || (!mustBounce && p.KitchenEstablished && !Court.FeetInKitchen(p.Z));
        if (canStrike && offset >= 0 && offset <= maxReach && ball.Y < .70)
        {
            StrikeBall(ref p); players[index] = p;
        }
        else if (!reportedMiss)
        {
            reportedMiss = true;
            StatsSink?.Invoke(FormattableString.Invariant($"miss n={shotIndex} type={ShotId(lastShot)} offset={offset} reach={maxReach} y={ball.Y} bounces={bounceCount} kitchen={Court.FeetInKitchen(p.Z)}"));
        }
    }
    private void StrikeBall(ref PlayerState p)
    {
        var n = ++shotIndex; var facing = p.Facing; var receivedBounces = bounceCount;
        if (n > scriptLength)
        {
            scriptLength = n + rng.Integer(1, 3);
            if (EndingErrorFraction > 0 && Chance(.75))
            {
                var k = Rand(0, 1); scriptEnding = k < .5 ? RallyEnding.NetError : k < .75 ? RallyEnding.WideError : RallyEnding.LongError;
            }
        }
        var opponents = Indices(-facing); var atKitchen = AtKitchen(p); var opponentKitchen = TeamAtKitchen(-facing);
        ShotType type;
        if (n == 2) type = ShotType.ServiceReturn;
        else if (n == 3) type = Chance(ThirdDriveFraction) ? ShotType.ThirdDrive : ShotType.ThirdDrop;
        else if (lastShot is ShotType.Speedup or ShotType.Counter) type = Chance(Format == GameFormat.Singles ? .82 : .62) ? ShotType.Counter : ShotType.Reset;
        else if (lastShot is ShotType.ThirdDrive or ShotType.Drive) type = Chance(Format == GameFormat.Singles ? .22 : .66) ? ShotType.Reset : ShotType.Drive;
        else if (Format == GameFormat.Singles)
        {
            if (atKitchen && opponentKitchen && Chance(LobProbability)) type = ShotType.Lob;
            else if (atKitchen && opponentKitchen && Chance(Math.Min(1, SpeedupProbability + .18 + dinkStreak * .04))) type = ShotType.Speedup;
            else if (atKitchen && opponentKitchen) type = Chance(.35) ? ShotType.Dink : ShotType.Drive;
            else type = Chance(atKitchen ? .85 : .75) ? ShotType.Drive : ShotType.Drop;
        }
        else if (atKitchen && opponentKitchen)
        {
            if (Chance(LobProbability)) type = ShotType.Lob;
            else if (Chance(Math.Min(.5, SpeedupProbability + dinkStreak * .012))) type = ShotType.Speedup;
            else type = ShotType.Dink;
        }
        else if (atKitchen) type = Chance(.7) ? ShotType.Dink : ShotType.Drive;
        else type = Chance(.7) ? ShotType.Drop : ShotType.Drive;
        if (n == scriptLength && scriptEnding == RallyEnding.Winner && n > 2) type = atKitchen ? ShotType.Speedup : ShotType.Drive;
        if (n == scriptLength && scriptEnding == RallyEnding.LongError && n > 2) type = atKitchen ? ShotType.Lob : ShotType.Drive;
        dinkStreak = type == ShotType.Dink ? dinkStreak + 1 : 0;
        double targetX, depth, margin; var cross = false;
        switch (type)
        {
            case ShotType.ServiceReturn:
                targetX = Format == GameFormat.Singles ? AimAcross(ball.X, true) : Math.Clamp(Gauss(-.05, .35), -.7, .7);
                depth = Rand(.82, .94); margin = Rand(.25, .40); break;
            case ShotType.ThirdDrop:
            case ShotType.Drop:
            case ShotType.Reset:
                cross = Chance(.55); targetX = AimAcross(ball.X, cross); depth = Rand(.53, .64); margin = Rand(.10, .18); break;
            case ShotType.ThirdDrive:
            case ShotType.Drive:
                cross = Chance(.5);
                if (Format == GameFormat.Singles)
                {
                    targetX = (players[opponents[0]].X >= 0 ? -1 : 1) * Rand(.65, .88); cross = targetX * ball.X < 0;
                }
                else targetX = AimAcross(ball.X, cross);
                depth = Rand(.84, .95); margin = Rand(.03, .07); break;
            case ShotType.Dink:
                cross = Chance(DinkCrossFraction); targetX = AimAcross(ball.X, cross); depth = Rand(.53, .645);
                margin = cross ? Rand(.13, .20) : Rand(.10, .16); break;
            case ShotType.Speedup:
            case ShotType.Counter:
                var target = opponents.MinBy(i => Math.Abs(players[i].X - ball.X));
                targetX = players[target].X + Rand(-.12, .12); depth = Rand(.72, .86); margin = Rand(.02, .06); break;
            case ShotType.Lob:
                cross = Chance(.4); targetX = AimAcross(ball.X, cross) * .7; depth = Rand(.86, .94); margin = 0; break;
            default: throw new InvalidOperationException("Serve is handled separately.");
        }
        if (n + 1 == scriptLength && scriptEnding == RallyEnding.Winner && n >= 3 && type != ShotType.Lob) margin = Math.Max(margin, Rand(.25, .32));
        var targetZ = facing > 0 ? depth : 1 - depth; double? apex = type == ShotType.Lob ? Rand(1.5, 2) : null;
        var solution = apex.HasValue ? SolveApex(ball.X, ball.Z, ball.Y, targetX, targetZ, apex.Value)
            : SolveLanding(ball.X, ball.Z, ball.Y, targetX, targetZ, margin);
        var opponent = players[opponents.MinBy(i => Math.Abs(players[i].X - targetX))];
        if (type is ShotType.ThirdDrop or ShotType.Drop or ShotType.Reset or ShotType.Dink)
        {
            var t2 = 2 * Math.Abs(solution.V.Y + Gravity * solution.Time) * BounceDamp / -Gravity;
            var bounce2Z = targetZ + solution.V.Z * t2;
            var deficit = facing > 0 ? opponent.Z + .02 - bounce2Z : bounce2Z - (opponent.Z - .02);
            if (deficit > 0)
            {
                targetZ = facing > 0 ? Math.Min(.88, targetZ + deficit) : Math.Max(.12, targetZ - deficit);
                solution = SolveLanding(ball.X, ball.Z, ball.Y, targetX, targetZ, margin);
            }
        }
        if (n == scriptLength && scriptEnding == RallyEnding.Winner)
        {
            double Opening(double x) => opponents.Min(i =>
            {
                var defender = players[i]; var fraction = Math.Max(.1, (defender.Z - ball.Z) / (targetZ - ball.Z));
                var intercept = ball.X + (x - ball.X) * fraction;
                var cover = LateralSpeed * Math.Max(0, solution.Time * fraction - .22) + Reach + HitWindow;
                return Math.Abs(intercept - defender.X) - cover;
            });
            targetX = new[] { -.98, 0, .98 }.MaxBy(Opening);
        }
        else if (n < scriptLength)
        {
            var fraction = Math.Max(.1, (opponent.Z - ball.Z) / (targetZ - ball.Z));
            var cover = LateralSpeed * Math.Max(0, solution.Time * fraction - .35) * .65 + BackhandReach * .8;
            var intercept = ball.X + (targetX - ball.X) * fraction;
            var reachable = Math.Clamp(intercept, opponent.X - cover, opponent.X + cover);
            targetX = Math.Clamp(ball.X + (reachable - ball.X) / fraction, -.88, .88);
        }
        solution.V.X = (targetX - ball.X) / solution.Time; velocity = solution.V;
        ApplyEnding(n, targetX, targetZ, margin, apex);
        lastHitNear = facing > 0; lastShot = type; mustBounce = n == 2; bounceCount = 0;
        AdvanceAfterShot(n, type, facing, ref p);
        p.SwingDur = SwingDuration(type); p.SwingAmp = SwingAmplitude(type); PlaceContactPose(ref p);
        if (receivedBounces == 0) p.VolleyRecovery = p.SwingDur * (1 + RecoveryFraction - ContactFraction);
        RecordContact(n, type, hitterIndex, p, receivedBounces);
        DesignateReceiver(-facing);
        EmitShot(n, type, facing, p.Stance == Forehand(p) ? "FH" : "BH", ball.X, cross);
    }
    private double AimAcross(double x, bool cross) => cross ? (x >= 0 ? -1 : 1) * Rand(.30, .85) : Math.Clamp(x + Rand(-.22, .22), -.85, .85);
    private void AdvanceAfterShot(int n, ShotType type, double facing, ref PlayerState hitter)
    {
        if (Format == GameFormat.Singles)
        {
            var deepHome = facing > 0 ? .14 : .86;
            hitter.TargetZ = n == 2 ? (Chance(.45) ? KitchenZ(facing) : deepHome)
                : n == 3 ? (type == ShotType.ThirdDrop && Chance(.4) ? KitchenZ(facing) : deepHome)
                : AtKitchen(hitter) ? KitchenZ(facing) : deepHome;
            if (type == ShotType.Lob) foreach (var i in Indices(-facing)) players[i].TargetZ = BaselineZ(-facing);
            Phase = n == 2 ? RallyPhase.Returning : n == 3 ? RallyPhase.Third : type is ShotType.Speedup or ShotType.Counter ? RallyPhase.Firefight
                : TeamAtKitchen(1) && TeamAtKitchen(-1) ? RallyPhase.Kitchen : RallyPhase.Transition;
            return;
        }
        if (n == 2) { Phase = RallyPhase.Returning; hitter.TargetZ = KitchenZ(facing); }
        else if (n == 3)
        {
            Phase = RallyPhase.Third;
            if (type == ShotType.ThirdDrop) { TeamAdvance(facing, null); hitter.TargetZ = KitchenZ(facing); }
        }
        else
        {
            if (type is ShotType.Drop or ShotType.Reset or ShotType.Dink) { TeamAdvance(facing, hitterIndex); hitter.TargetZ = KitchenZ(facing); }
            if (type is ShotType.Speedup or ShotType.Counter) Phase = RallyPhase.Firefight;
            else if (type == ShotType.Lob)
            {
                Phase = RallyPhase.Transition;
                foreach (var i in Indices(-facing)) players[i].TargetZ = BaselineZ(-facing) + (facing > 0 ? -.06 : .06);
            }
            else Phase = TeamAtKitchen(1) && TeamAtKitchen(-1) ? RallyPhase.Kitchen : RallyPhase.Transition;
        }
    }
    private void TeamAdvance(double facing, int? except) { foreach (var i in Indices(facing)) if (i != except) players[i].TargetZ = KitchenZ(facing); }
    private static double SwingDuration(ShotType type) => type switch
    {
        ShotType.Speedup or ShotType.Counter => .24,
        ShotType.Dink or ShotType.Reset => .38,
        ShotType.Drive or ShotType.ThirdDrive => .45,
        ShotType.Serve => .55,
        _ => .50
    };
    private static double SwingAmplitude(ShotType type) => type switch
    {
        ShotType.Speedup or ShotType.Counter => .5,
        ShotType.Dink => .55,
        ShotType.Reset => .6,
        ShotType.ThirdDrop or ShotType.Drop or ShotType.Lob => .8,
        ShotType.Serve => .9,
        _ => 1
    };
    private void IntegrateBall(double dt, bool adjudicate)
    {
        if (!adjudicate && ball.Y == 0 && Math.Abs(velocity.Y) < .02)
        {
            ball.X += velocity.X * dt; ball.Z += velocity.Z * dt;
            velocity.X *= Math.Exp(-2 * dt); velocity.Z *= Math.Exp(-2 * dt); velocity.Y = 0; return;
        }
        var nextY = ball.Y + velocity.Y * dt + Gravity * dt * dt / 2;
        var flightDT = nextY < 0 ? Math.Min(dt, LandingTime()) : dt;
        ball.Y += velocity.Y * flightDT + Gravity * flightDT * flightDT / 2;
        velocity.Y += Gravity * flightDT; ball.X += velocity.X * flightDT; ball.Z += velocity.Z * flightDT;
        if (nextY < 0)
        {
            ball.Y = 0; velocity.Y = Math.Abs(velocity.Y) * BounceDamp;
            if (adjudicate)
            {
                events.Add(RallyEvent.Bounce(ball)); bounceCount++;
                if (bounceCount == 1)
                {
                    var isOut = Math.Abs(ball.X) > 1.005 || ball.Z < -.005 || ball.Z > 1.005;
                    var badServe = lastShot == ShotType.Serve && (ball.X * LastContact!.Ball.X >= 0
                        || (lastHitNear ? ball.Z <= Court.KitchenFarZ : ball.Z >= Court.KitchenNearZ));
                    if (isOut || badServe) PointOver(lastHitNear, badServe ? "service-box" : Math.Abs(ball.X) > 1.005 ? "wide" : "long");
                }
                else if (bounceCount >= 2) PointOver(!lastHitNear, "winner");
            }
            var remaining = dt - flightDT;
            if (remaining > 1e-9) IntegrateBall(remaining, adjudicate && Phase != RallyPhase.Dead);
        }
    }
    private void PointOver(bool loserNear, string reason)
    {
        rallyLostByNear = loserNear; Phase = RallyPhase.Dead; phaseTimer = 1.3;
        StatsSink?.Invoke($"rally shots={shotIndex} ending={reason} loser={(loserNear ? "N" : "F")} planned={scriptLength} intended={EndingId(scriptEnding)}");
        for (var i = 0; i < players.Length; i++) players[i].HasPrediction = false;
    }
    private void ScoreRally()
    {
        if (NearServing == rallyLostByNear)
        {
            if (Format == GameFormat.Doubles && ServerNumber == 1)
            {
                ServerNumber = 2; serverIndex = Indices(NearServing ? 1 : -1).First(i => i != serverIndex);
            }
            else { NearServing = !NearServing; ServerNumber = 1; needsFirstServer = true; }
        }
        else
        {
            if (NearServing) NearScore++; else FarScore++;
            if (Format == GameFormat.Doubles) foreach (var i in Indices(NearServing ? 1 : -1)) players[i].Court = 1 - players[i].Court;
            var server = NearServing ? NearScore : FarScore; var receiver = NearServing ? FarScore : NearScore;
            if (server >= 11 && server - receiver >= 2)
            {
                if (NearServing) NearGames++; else FarGames++;
                GameBannerTimer = 3; NearScore = FarScore = 0; ServerNumber = 2; needsFirstServer = true; RollHands();
            }
        }
        BeginBetweenPoints();
    }
    private void MovePlayers(double dt) { for (var i = 0; i < players.Length; i++) UpdatePlayer(i, dt); }
    private void UpdatePlayer(int i, double dt)
    {
        var p = players[i];
        var inRally = Phase is not (RallyPhase.BetweenPoints or RallyPhase.Dead);
        var coming = inRally && (p.Facing > 0 ? velocity.Z < 0 : velocity.Z > 0);
        var isHitter = i == hitterIndex && coming;
        if (p.ReactionTimer > 0) p.ReactionTimer -= dt;
        p.VolleyRecovery = Math.Max(0, p.VolleyRecovery - dt);
        if (isHitter && !leaveOutBall && p.ReactionTimer <= 0)
        {
            p.PredClock -= dt; var arrival = TimeToArrival(p.Z);
            if (!p.HasPrediction || p.PredClock <= 0 || arrival < .25)
            {
                p.PredClock = .15; var total = Math.Max(.2, FlightTotal(p.Z));
                p.PredictedX = InterceptX(p.Z) + p.PredNoise * Math.Clamp(arrival / total, 0, 1); p.HasPrediction = true;
            }
            if ((mustBounce || lastShot == ShotType.Lob || !p.KitchenEstablished) && bounceCount == 0)
            {
                var z = LandingPoint().Z; var behind = p.Facing > 0 ? Math.Min(z - .05, p.Z) : Math.Max(z + .05, p.Z);
                p.TargetZ = p.Facing > 0 ? Math.Min(p.TargetZ, behind) : Math.Max(p.TargetZ, behind);
            }
            else if (bounceCount == 0 && Math.Abs(velocity.Z) < .45 && p.VolleyRecovery == 0)
            {
                var z = LandingPoint().Z;
                if (p.Facing > 0) { var intercept = z - .04; if (intercept > p.Z) p.TargetZ = Math.Min(.47, intercept); }
                else { var intercept = z + .04; if (intercept < p.Z) p.TargetZ = Math.Max(.53, intercept); }
            }
            var fh = Forehand(p); var dxRead = p.PredictedX - p.X;
            if (p.CommittedStance == 0)
            {
                if (dxRead * fh > .04) p.CommittedStance = fh;
                else if (arrival - .5 > .9 && Chance(RunAroundProbability)) p.CommittedStance = fh;
                else p.CommittedStance = -fh;
            }
            else if (dxRead * p.CommittedStance < -.10 && arrival > .35) p.CommittedStance = -p.CommittedStance;
            var side = p.CommittedStance == 0 ? fh : p.CommittedStance; var offset = side == fh ? Reach : BackhandReach;
            var dx0 = p.PredictedX - p.X;
            p.TargetX = Math.Abs(dx0) > offset * .9 || dx0 * side < 0 ? p.PredictedX - side * offset : p.X;
            if (p.Armed && arrival > 0 && arrival <= ContactFraction * p.SwingDur)
            {
                var dx = p.PredictedX - p.X;
                p.Stance = p.CommittedStance != 0 ? p.CommittedStance : dx * fh > .04 ? fh : -fh;
                p.ContactY = Math.Clamp(PredictY(p.Z), .03, .70); p.SwingDur = AtKitchen(p) ? .38 : .5;
                p.SwingPhase = true; p.SwingT = Math.Max(0, ContactFraction - arrival / p.SwingDur); p.ContactDZ = 0; p.Armed = false;
            }
        }
        else if (inRally && !isHitter)
        {
            var shift = Math.Clamp(ball.X * (Format == GameFormat.Singles ? .25 : .15), -.20, .20);
            p.TargetX = p.HomeX + shift - Forehand(p) * .04; p.Armed = true; p.CommittedStance = 0;
            if (!coming) p.HasPrediction = false;
        }
        else if (!inRally) p.CommittedStance = 0;
        if (!p.SwingPhase) p.FaceY = .08 - .02 * Math.Min(1, Math.Max(0, p.ReactionTimer) / .15);
        var latCap = Math.Abs(p.TargetX - p.X) < .25 ? LateralNear : LateralSpeed;
        p.X = MoveValue(p.X, p.TargetX, latCap * dt, -1.1, 1.1);
        if (isHitter && p.SwingPhase)
        {
            var maxReach = (p.Stance == Forehand(p) ? Reach : BackhandReach) + HitWindow;
            p.SwingReach = Math.Clamp((p.PredictedX - p.X) * p.Stance, .02, maxReach);
        }
        var zSpeed = (Math.Abs(p.TargetZ - p.Z) > .12 ? RunSpeed : AdvanceSpeed) * (Format == GameFormat.Singles ? 1.2 : 1) * (isHitter ? .6 : 1);
        if (p.VolleyRecovery > 0) p.TargetZ = p.Facing > 0 ? Math.Min(p.TargetZ, KitchenZ(1)) : Math.Max(p.TargetZ, KitchenZ(-1));
        p.Z = MoveValue(p.Z, p.TargetZ, zSpeed * dt, -.12, 1.12); p.KitchenEstablished = !Court.FeetInKitchen(p.Z);
        players[i] = p;
    }
    private double TimeToArrival(double z) => Math.Abs(velocity.Z) > .0001 ? (z - ball.Z) / velocity.Z : -1;
    private double FlightTotal(double z) => Math.Abs(velocity.Z) > .0001 ? flightElapsed + Math.Abs((z - ball.Z) / velocity.Z) : 1;
    private double InterceptX(double z) { var t = TimeToArrival(z); return t > 0 ? ball.X + velocity.X * t : ball.X; }
    private double LandingTime() => (velocity.Y + Math.Sqrt(Math.Max(0, velocity.Y * velocity.Y - 2 * Gravity * ball.Y))) / -Gravity;
    private Vec3 LandingPoint() { var t = LandingTime(); return new(ball.X + velocity.X * t, 0, ball.Z + velocity.Z * t); }
    private double PredictY(double z)
    {
        if (Math.Abs(velocity.Z) <= .0001) return ball.Y;
        var time = (z - ball.Z) / velocity.Z; if (time <= 0) return ball.Y;
        var y = ball.Y; var vy = velocity.Y;
        while (time > 0)
        {
            var dt = Math.Min(1.0 / 120, time); y += vy * dt + Gravity * dt * dt / 2; vy += Gravity * dt;
            if (y < 0) { y = 0; vy = Math.Abs(vy) * BounceDamp; }
            time -= dt;
        }
        return y;
    }
    public static double PaddleX(PlayerState p)
    {
        var fh = Forehand(p); var ready = p.CommittedStance != 0 ? p.CommittedStance : fh;
        var backhand = (p.SwingPhase ? p.Stance : ready) != fh;
        return p.X + (p.SwingPhase ? p.Stance * p.SwingReach : ready * .7 * (backhand ? BackhandReach : Reach));
    }
    private void PlaceContactPose(ref PlayerState p)
    {
        p.ContactY = ball.Y; p.ContactDZ = ball.Z - p.Z; p.SwingReach = Math.Abs(ball.X - p.X);
        p.SwingPhase = true; p.SwingT = ContactFraction; p.FaceY = ball.Y; p.FaceDZ = p.ContactDZ; p.SwingAngle = 0;
    }
    private void RecordContact(int n, ShotType type, int index, PlayerState player, int receivedBounces)
    {
        ContactCount++;
        LastContact = new(n, type, index, player, ball, receivedBounces, velocity, LandingPoint(),
            n == scriptLength ? scriptEnding : null, NearServing ? NearScore : FarScore);
        events.Add(RallyEvent.Hit(LastContact));
    }
    private void UpdateSwings(double dt) { for (var i = 0; i < players.Length; i++) UpdateSwing(ref players[i], dt); }
    private static void UpdateSwing(ref PlayerState p, double dt)
    {
        if (!p.SwingPhase) return;
        p.SwingT += dt / p.SwingDur;
        var drop = SwingDrop * p.SwingAmp; var len = SwingLength * p.SwingAmp;
        var low = Math.Max(.03, p.ContactY - drop); var high = p.ContactY + (p.ContactY - low);
        var t = p.SwingT;
        if (t < BackswingFraction)
        {
            var e = Court.Smoothstep(t / BackswingFraction);
            p.FaceDZ = p.ContactDZ - p.Facing * len * e; p.FaceY = RestFaceY + (low - RestFaceY) * e;
            p.SwingAngle = ReadyAngle + (BackswingAngle - ReadyAngle) * e;
        }
        else if (t < 1)
        {
            var e = Court.Smoothstep((t - BackswingFraction) / (1 - BackswingFraction));
            p.FaceDZ = p.ContactDZ + p.Facing * len * (2 * e - 1); p.FaceY = low + (high - low) * e;
            p.SwingAngle = e < .5 ? BackswingAngle * (1 - 2 * e) : FollowAngle * (2 * e - 1);
        }
        else if (t < 1 + RecoveryFraction)
        {
            var e = Court.Smoothstep((t - 1) / RecoveryFraction);
            p.FaceDZ = (p.ContactDZ + p.Facing * len) * (1 - e); p.FaceY = high + (RestFaceY - high) * e;
            p.SwingAngle = FollowAngle + (ReadyAngle - FollowAngle) * e;
        }
        else
        {
            p.SwingPhase = false; p.SwingT = 0; p.SwingAngle = ReadyAngle; p.FaceDZ = p.ContactDZ = 0; p.FaceY = RestFaceY;
        }
    }
    public static string ShotId(ShotType type) => type switch
    {
        ShotType.ServiceReturn => "return",
        ShotType.ThirdDrop => "3rd-drop",
        ShotType.ThirdDrive => "3rd-drive",
        _ => type.ToString().ToLowerInvariant()
    };
    public static string EndingId(RallyEnding ending) => ending switch
    {
        RallyEnding.NetError => "net",
        RallyEnding.WideError => "wide",
        RallyEnding.LongError => "long",
        _ => "winner"
    };
    private void EmitShot(int n, ShotType type, double facing, string stance, double x, bool cross = false)
    {
        if (StatsSink is null) return;
        var speed = Math.Sqrt(Math.Pow(velocity.X * Court.FeetPerX, 2) + Math.Pow(velocity.Z * Court.FeetPerZ, 2)) / 1.4667;
        var landing = LandingPoint(); var didCross = type == ShotType.Dink ? x * landing.X < 0 : cross;
        StatsSink(FormattableString.Invariant($"shot n={n} type={ShotId(type)} side={(facing > 0 ? "N" : "F")} stance={stance} x={x:F2} tx={landing.X:F2} tz={landing.Z:F2} mph={speed:F0} t={LandingTime():F2} cross={(didCross ? 1 : 0)}"));
    }
    private static double MoveValue(double value, double target, double speed, double low, double high)
    {
        var d = target - value; return Math.Clamp(value + Math.Min(Math.Abs(d), speed) * (d >= 0 ? 1 : -1), low, high);
    }
}
