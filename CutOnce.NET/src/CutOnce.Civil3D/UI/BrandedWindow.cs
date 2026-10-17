using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using CutOnce.Core;

namespace CutOnce.UI;

/// <summary>
/// The shared frame of every CutOnce dialog: a header band in the brand colour (logo
/// tile, name, tagline, close button), a severity strip and badge with the headline,
/// the dialog's own content, and a footer with the name, version and publisher. The
/// look is defined once, in Theme.xaml ("CutOnce.WindowStyle").
/// </summary>
public class BrandedWindow : Window
{
    private static readonly Uri ThemeUri;

    static BrandedWindow()
    {
        // make sure the pack:// scheme is registered (Civil 3D normally has done this already)
        _ = System.IO.Packaging.PackUriHelper.UriSchemePack;
        ThemeUri = new Uri("pack://application:,,,/CutOnce.Civil3D;component/UI/Theme.xaml", UriKind.Absolute);
    }

    /// <summary>The usable screen height, so tall dialogs scroll instead of running off the screen.</summary>
    protected static double ScreenHeight => SystemParameters.WorkArea.Height;

    public static readonly DependencyProperty HeadlineProperty = Register(nameof(Headline), typeof(string), "");
    public static readonly DependencyProperty BrandNameProperty = Register(nameof(BrandName), typeof(string), "");
    public static readonly DependencyProperty BrandTaglineProperty = Register(nameof(BrandTagline), typeof(string), "");
    public static readonly DependencyProperty LogoSourceProperty = Register(nameof(LogoSource), typeof(ImageSource), null);
    public static readonly DependencyProperty LogoVisibilityProperty = Register(nameof(LogoVisibility), typeof(Visibility), Visibility.Collapsed);
    public static readonly DependencyProperty MarkVisibilityProperty = Register(nameof(MarkVisibility), typeof(Visibility), Visibility.Visible);
    public static readonly DependencyProperty KindBrushProperty = Register(nameof(KindBrush), typeof(Brush), Brushes.SteelBlue);
    public static readonly DependencyProperty KindSoftBrushProperty = Register(nameof(KindSoftBrush), typeof(Brush), Brushes.AliceBlue);
    public static readonly DependencyProperty KindGlyphProperty = Register(nameof(KindGlyph), typeof(string), "");
    public static readonly DependencyProperty KindLabelProperty = Register(nameof(KindLabel), typeof(string), "");
    public static readonly DependencyProperty FooterLeftProperty = Register(nameof(FooterLeft), typeof(string), "");
    public static readonly DependencyProperty FooterRightProperty = Register(nameof(FooterRight), typeof(string), "");

    private static DependencyProperty Register(string name, Type type, object fallback) =>
        DependencyProperty.Register(name, type, typeof(BrandedWindow), new PropertyMetadata(fallback));

    private NoticeKind _kind;

    public BrandedWindow()
    {
        Resources.MergedDictionaries.Add(new ResourceDictionary { Source = ThemeUri });
        ApplyBrand(BrandInfo.Current);
        Style = (Style)Resources["CutOnce.WindowStyle"];
        Kind = NoticeKind.Info;
        PreviewKeyDown += (s, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            OnCloseRequested();
        };
    }

    public string Headline { get => (string)GetValue(HeadlineProperty); set => SetValue(HeadlineProperty, value); }
    public string BrandName { get => (string)GetValue(BrandNameProperty); set => SetValue(BrandNameProperty, value); }
    public string BrandTagline { get => (string)GetValue(BrandTaglineProperty); set => SetValue(BrandTaglineProperty, value); }
    public ImageSource LogoSource { get => (ImageSource)GetValue(LogoSourceProperty); set => SetValue(LogoSourceProperty, value); }
    public Visibility LogoVisibility { get => (Visibility)GetValue(LogoVisibilityProperty); set => SetValue(LogoVisibilityProperty, value); }
    public Visibility MarkVisibility { get => (Visibility)GetValue(MarkVisibilityProperty); set => SetValue(MarkVisibilityProperty, value); }
    public Brush KindBrush { get => (Brush)GetValue(KindBrushProperty); set => SetValue(KindBrushProperty, value); }
    public Brush KindSoftBrush { get => (Brush)GetValue(KindSoftBrushProperty); set => SetValue(KindSoftBrushProperty, value); }
    public string KindGlyph { get => (string)GetValue(KindGlyphProperty); set => SetValue(KindGlyphProperty, value); }
    public string KindLabel { get => (string)GetValue(KindLabelProperty); set => SetValue(KindLabelProperty, value); }
    public string FooterLeft { get => (string)GetValue(FooterLeftProperty); set => SetValue(FooterLeftProperty, value); }
    public string FooterRight { get => (string)GetValue(FooterRightProperty); set => SetValue(FooterRightProperty, value); }

    /// <summary>Severity: amber warning, red problem, green all clear, brand colour for information.</summary>
    public NoticeKind Kind
    {
        get => _kind;
        set
        {
            _kind = value;
            Color brand = BrandInfo.Current.Color;
            Color strong, soft;
            switch (value)
            {
                case NoticeKind.Warning:
                    strong = Color.FromRgb(0xB2, 0x6A, 0x00); soft = Color.FromRgb(0xFF, 0xF3, 0xD6);
                    KindGlyph = ""; KindLabel = "WARNING"; break;
                case NoticeKind.Error:
                    strong = Color.FromRgb(0xC6, 0x28, 0x28); soft = Color.FromRgb(0xFD, 0xEC, 0xEC);
                    KindGlyph = ""; KindLabel = "STOP AND CHECK"; break;
                case NoticeKind.Ok:
                    strong = Color.FromRgb(0x2E, 0x7D, 0x32); soft = Color.FromRgb(0xE7, 0xF5, 0xE8);
                    KindGlyph = ""; KindLabel = "ALL CLEAR"; break;
                default:
                    strong = brand; soft = BrandInfo.Shade(brand, 1.88);
                    KindGlyph = ""; KindLabel = "INFO"; break;
            }
            KindBrush = Frozen(strong);
            KindSoftBrush = Frozen(soft);
        }
    }

    private static Brush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }

    private void ApplyBrand(BrandInfo b)
    {
        Resources["CutOnce.Brand"] = Frozen(b.Color);
        Resources["CutOnce.BrandDark"] = Frozen(BrandInfo.Shade(b.Color, 0.72));
        Resources["CutOnce.BrandSoft"] = Frozen(BrandInfo.Shade(b.Color, 1.9));
        var gradient = new LinearGradientBrush(b.Color, BrandInfo.Shade(b.Color, 0.68), new Point(0, 0), new Point(1, 1));
        gradient.Freeze();
        Resources["CutOnce.BrandGradient"] = gradient;

        BrandName = b.Name;
        BrandTagline = b.Tagline;
        Title = b.Name;
        LogoSource = b.Logo;
        LogoVisibility = b.Logo != null ? Visibility.Visible : Visibility.Collapsed;
        MarkVisibility = b.Logo != null ? Visibility.Collapsed : Visibility.Visible;
        FooterLeft = string.Equals(b.Name, Product.DefaultName, StringComparison.Ordinal)
            ? $"{Product.DefaultName} {Product.Version}"
            : $"{b.Name}  ·  powered by {Product.DefaultName} {Product.Version}";
        FooterRight = Product.Publisher;
    }

    public override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        if (GetTemplateChild("PART_Header") is UIElement header)
            header.MouseLeftButtonDown += (s, e) =>
            {
                try { DragMove(); } catch (InvalidOperationException) { /* not a left-button drag */ }
            };
        if (GetTemplateChild("PART_Close") is Button close)
            close.Click += (s, e) => OnCloseRequested();
    }

    /// <summary>The close button and ESC: each dialog decides what closing means.</summary>
    protected virtual void OnCloseRequested() => Close();
}
