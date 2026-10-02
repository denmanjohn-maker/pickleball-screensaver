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
            if (args.Length != 5)
                throw new ArgumentException("Usage: Pickleball.Preview <output.png> <frame:0..36000> <seed:uint> <width>x<height> <ISO-8601 epoch>");
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
            using var session = new RenderSession(clock, clock, networkAllowed: false, seed);
            using var scene = new FoundationScene(session, new());
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
            using var output = File.Create(Path.GetFullPath(args[0]));
            encoder.Save(output);
            Console.WriteLine($"Foundation only; frame={scene.Frame.Sequence}; seed={seed}; {width}x{height}; no providers.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); return 2; }
    }
}
