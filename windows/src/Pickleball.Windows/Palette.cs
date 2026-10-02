using System.Windows.Media;

namespace Pickleball.Windows;

public sealed record Palette(Color Surface, Color Service, Color Line, Color Mesh, Color Strand, Color Tape, Color Post,
    Color Ball, Color BallOutline, Color Trail, Color Background, Color Glass, Color Text, Color Accent, Color TeamA, Color TeamB,
    bool Wallpaper, bool Glow)
{
    public Color Team(double facing) => facing > 0 ? TeamA : TeamB;
    public static Color Rgb(double r, double g, double b, double a = 1) =>
        Color.FromArgb((byte)Math.Round(a * 255), (byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));
    public static Palette Named(string preset)
    {
        var classic = new Palette(Rgb(.30, .53, .40), Rgb(.13, .32, .62), Rgb(1, 1, 1, .95), Rgb(.09, .10, .11, .5),
            Rgb(.16, .17, .18, .65), Rgb(1, 1, 1, .95), Rgb(.08, .09, .10), Rgb(.96, .82, .05), Rgb(.05, .05, .05),
            Rgb(1, .85, .1), Rgb(.05, .09, .10), Rgb(0, 0, 0, .75), Colors.White, Rgb(.96, .82, .05), Rgb(.25, .80, 1), Rgb(1, .48, .32), true, false);
        return preset switch
        {
            "blacklight" => classic with
            {
                Surface = Rgb(.02, .06, .04),
                Service = Rgb(.02, .03, .09),
                Line = Rgb(.25, 1, .4, .95),
                Mesh = Rgb(.01, .01, .02, .55),
                Strand = Rgb(.85, .25, .75, .3),
                Tape = Rgb(1, .3, .78, .95),
                Post = Rgb(.05, .05, .07),
                Ball = Rgb(.78, 1, .15),
                BallOutline = Rgb(.02, .02, .02),
                Trail = Rgb(1, .3, .78),
                Background = Colors.Black,
                Glass = Rgb(0, 0, 0, .82),
                Accent = Rgb(1, .55, .10),
                TeamA = Rgb(.15, .9, 1),
                TeamB = Rgb(1, .3, .78),
                Wallpaper = false,
                Glow = true
            },
            "ink-and-paper" => classic with
            {
                Surface = Rgb(.9, .87, .78),
                Service = Rgb(.69, .78, .79, .62),
                Line = Rgb(.22, .23, .22, .85),
                Mesh = Rgb(.29, .28, .25, .18),
                Strand = Rgb(.23, .24, .23, .38),
                Tape = Rgb(.27, .28, .26, .9),
                Post = Rgb(.22, .24, .23),
                Ball = Rgb(.75, .54, .16),
                BallOutline = Rgb(.20, .23, .21),
                Trail = Rgb(.24, .30, .28),
                Background = Rgb(.96, .94, .88),
                Glass = Rgb(.99, .98, .94, .94),
                Text = Rgb(.15, .19, .18),
                Accent = Rgb(.44, .30, .09),
                TeamA = Rgb(.06, .4, .49),
                TeamB = Rgb(.65, .25, .17),
                Wallpaper = false
            },
            "rally-painting" => classic with
            {
                Surface = Rgb(.09, .13, .15),
                Service = Rgb(.08, .11, .14),
                Line = Rgb(.66, .74, .76, .7),
                Background = Rgb(.025, .035, .05),
                Wallpaper = false
            },
            _ => classic
        };
    }
    public static SolidColorBrush Brush(Color color, double alpha = 1)
    {
        var brush = new SolidColorBrush(color) { Opacity = alpha }; brush.Freeze(); return brush;
    }
}
