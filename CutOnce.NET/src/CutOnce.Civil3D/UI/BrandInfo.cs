using System;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CutOnce.Core;

namespace CutOnce.UI;

/// <summary>
/// The firm's look, from CutOnce-Config.lsp: BrandName, BrandTagline, BrandColor
/// ("#RRGGBB" or an AutoCAD colour number 1-255) and BrandLogo (a PNG/JPG;
/// CutOnce-Logo.png in the install folder is used automatically).
/// </summary>
public sealed class BrandInfo
{
    private static BrandInfo _current;

    public static readonly Color DefaultColor = Color.FromRgb(0x1E, 0x5A, 0xA8);

    public string Name { get; private set; }
    public string Tagline { get; private set; }
    public Color Color { get; private set; }
    public ImageSource Logo { get; private set; }

    public static BrandInfo Current => _current ??= Create();

    /// <summary>Forget the cached brand (after the config is reloaded).</summary>
    public static void Reset() => _current = null;

    private static BrandInfo Create()
    {
        var cfg = CutOnceApp.Config;
        return new BrandInfo
        {
            Name = cfg.GetString("BrandName") ?? Product.DefaultName,
            Tagline = cfg.GetString("BrandTagline") ?? Product.DefaultTagline,
            Color = ParseColor(cfg.Get("BrandColor")) ?? DefaultColor,
            Logo = LoadImage(cfg.GetString("BrandLogo")) ?? LoadImage(Path.Combine(CutOnceApp.Home, "CutOnce-Logo.png")),
        };
    }

    /// <summary>"#1E5AA8", "1E5AA8" or an AutoCAD Color Index number.</summary>
    public static Color? ParseColor(object v)
    {
        try
        {
            if (v is string s && s.Trim().Length > 0)
            {
                string hex = s.Trim();
                if (!hex.StartsWith("#", StringComparison.Ordinal)) hex = "#" + hex;
                return (Color)ColorConverter.ConvertFromString(hex);
            }
            double? n = v is long l ? l : v is double d ? d : (double?)null;
            if (n.HasValue && n.Value >= 1 && n.Value <= 255)
            {
                var c = Autodesk.AutoCAD.Colors.Color.FromColorIndex(Autodesk.AutoCAD.Colors.ColorMethod.ByAci, (short)n.Value).ColorValue;
                return Color.FromRgb(c.R, c.G, c.B);
            }
        }
        catch (Exception)
        {
            // not a colour: use the default
        }
        return null;
    }

    private static ImageSource LoadImage(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return null;
        try
        {
            var img = new BitmapImage();
            img.BeginInit();
            img.UriSource = new Uri(Path.GetFullPath(path));
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.EndInit();
            img.Freeze();
            return img;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>The colour scaled toward black (factor &lt; 1) or white (factor &gt; 1).</summary>
    public static Color Shade(Color c, double factor)
    {
        byte Mix(byte v) => factor <= 1
            ? (byte)Math.Round(v * factor)
            : (byte)Math.Round(v + (255 - v) * Math.Min(1, factor - 1));
        return Color.FromRgb(Mix(c.R), Mix(c.G), Mix(c.B));
    }
}
