using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Pickleball.Core;
using Pickleball.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length is < 5 or > 9)
                throw new ArgumentException("Usage: Pickleball.Preview <output.png> <frame:0..36000> <seed:uint> <width>x<height> <ISO-8601 epoch> [appearance] [singles|doubles] [standard|slow|still|reduced] [wallpaper|widgets|widgets-metric]");
            var frame = int.Parse(args[1], CultureInfo.InvariantCulture);
            var seed = uint.Parse(args[2], CultureInfo.InvariantCulture);
            var size = args[3].Split('x');
            if (size.Length != 2) throw new ArgumentException("Expected WIDTHxHEIGHT.");
            var width = int.Parse(size[0], CultureInfo.InvariantCulture);
            var height = int.Parse(size[1], CultureInfo.InvariantCulture);
            if (frame is < 0 or > 36000 || width is < 64 or > 7680 || height is < 64 or > 7680)
                throw new ArgumentOutOfRangeException(nameof(args));
            var epoch = DateTimeOffset.ParseExact(args[4], "O", CultureInfo.InvariantCulture);
            var clock = new ReplayClock(epoch);
            var preferences = new Preferences
            {
                Theme = args.Length > 5 ? args[5] : "classic",
                Format = args.Length > 6 ? args[6] : "doubles",
                CourtMotion = args.Length > 7 && args[7] != "reduced" ? args[7] : "slow"
            };
            preferences.Validate();
            if (args.Length > 8 && args[8] is not ("wallpaper" or "widgets" or "widgets-metric")) throw new ArgumentException("Unknown export mode");
            using var session = new RenderSession(clock, clock, networkAllowed: false, seed, preferences,
                reducedMotion: args.Length > 7 && args[7] == "reduced");
            using var scene = new RallyScene(session, preferences)
            {
                WallpaperOnly = args.Length > 8 && args[8] == "wallpaper",
                Fixture = args.Length > 8 && args[8].StartsWith("widgets", StringComparison.Ordinal)
                    ? WidgetFixture.Create(epoch, args[8] != "widgets-metric") : null
            };
            for (var index = 0; index < frame; index++)
            {
                var target = TimeSpan.FromTicks((index + 1L) * TimeSpan.TicksPerSecond / 60);
                clock.Advance(target - clock.Elapsed);
                session.Advance();
            }
            scene.Measure(new(width, height));
            scene.Arrange(new Rect(0, 0, width, height));
            scene.UpdateLayout();
            var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(scene);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            var outputPath = Path.GetFullPath(args[0]);
            Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
            using var output = File.Create(outputPath);
            encoder.Save(output);
            Console.WriteLine($"frame={scene.Frame.Sequence}; seed={seed}; {width}x{height}; {preferences.Theme}/{preferences.Format}/{preferences.CourtMotion}; offline.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 2; }
    }
}
