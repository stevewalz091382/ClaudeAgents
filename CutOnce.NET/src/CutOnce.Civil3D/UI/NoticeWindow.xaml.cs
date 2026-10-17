using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using CutOnce.Core;

namespace CutOnce.UI;

/// <summary>
/// Every CutOnce warning and notice: the message (headings, details and bullets styled
/// from plain text), Learn More links, Save a copy, and the decision buttons:
/// Stop / Undo (red), extra actions, and Continue / OK.
/// </summary>
public partial class NoticeWindow : BrandedWindow
{
    private readonly NoticeRequest _request;
    private readonly Func<CopyOutcome> _saveCopy;
    private readonly Action<string> _openTopic;

    public NoticeWindow(NoticeRequest request, Func<CopyOutcome> saveCopy, Action<string> openTopic)
    {
        _request = request;
        _saveCopy = saveCopy;
        _openTopic = openTopic;
        InitializeComponent();
        BodyScroll.MaxHeight = Math.Max(200, Math.Min(400, ScreenHeight - 420));

        Kind = request.Kind;
        Headline = request.Headline;
        BuildBody();
        BuildLinks();
        BuildButtons();

        if (!string.IsNullOrWhiteSpace(request.Footnote))
        {
            Footnote.Text = request.Footnote;
            Footnote.Visibility = Visibility.Visible;
        }
        if (!string.IsNullOrWhiteSpace(request.StopHint))
        {
            StopHint.Text = request.StopHint;
            StopCard.Visibility = Visibility.Visible;
            if (request.Stop == StopOffer.UndoCommand) StopIcon.Text = "";
            if (request.Stop == StopOffer.None)
            {
                // the hint without a button: plain ESC / U instructions
                StopCard.Background = (Brush)FindResource("CutOnce.Canvas");
                StopCard.BorderBrush = (Brush)FindResource("CutOnce.Line");
                StopIcon.Text = "";
                StopIcon.Foreground = (Brush)FindResource("CutOnce.Muted");
            }
        }
        if (request.OfferCopy)
        {
            CopyCard.Visibility = Visibility.Visible;
            CopyIntro.Text = request.CopyIntro ?? "";
            CopyFolder.Text = request.CopyFolder ?? "";
            CopyFolder.Visibility = string.IsNullOrEmpty(request.CopyFolder) ? Visibility.Collapsed : Visibility.Visible;
            CopyButton.IsEnabled = request.CopyAvailable && _saveCopy != null;
        }
    }

    /// <summary>The button the designer chose; OK when the window was closed.</summary>
    public NoticeResult Result { get; private set; } = NoticeResult.Ok;

    protected override void OnCloseRequested()
    {
        Result = NoticeResult.Ok;
        Close();
    }

    private void Finish(NoticeResult result)
    {
        Result = result;
        Close();
    }

    // ------------------------------------------------------------------
    // Body: plain lines, styled by kind
    // ------------------------------------------------------------------

    private void BuildBody()
    {
        var muted = (Brush)FindResource("CutOnce.Muted");
        var brandDark = (Brush)FindResource("CutOnce.BrandDark");
        var mono = (FontFamily)FindResource("CutOnce.MonoFont");
        foreach (BodyLine line in MessageText.ClassifyAll(_request.Lines))
        {
            double indent = line.Indent * 18;
            switch (line.Kind)
            {
                case BodyLineKind.Blank:
                    Body.Children.Add(new Border { Height = 8 });
                    break;

                case BodyLineKind.Heading:
                    Body.Children.Add(new TextBlock
                    {
                        Text = line.Text,
                        FontWeight = FontWeights.SemiBold,
                        FontSize = 12,
                        Foreground = brandDark,
                        Margin = new Thickness(0, 4, 0, 4),
                        TextWrapping = TextWrapping.Wrap,
                    });
                    break;

                case BodyLineKind.Detail:
                    var row = new Grid { Margin = new Thickness(indent, 1, 0, 1) };
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(230) });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    row.Children.Add(new TextBlock { Text = line.Text, Foreground = muted, TextWrapping = TextWrapping.Wrap });
                    var value = new TextBlock { Text = line.Value, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
                    Grid.SetColumn(value, 1);
                    row.Children.Add(value);
                    Body.Children.Add(row);
                    break;

                case BodyLineKind.Bullet:
                    var bullet = new DockPanel { Margin = new Thickness(indent, 1, 0, 1) };
                    var dot = new TextBlock { Text = "•", Foreground = brandDark, Margin = new Thickness(0, 0, 8, 0), FontWeight = FontWeights.Bold };
                    DockPanel.SetDock(dot, Dock.Left);
                    bullet.Children.Add(dot);
                    bool looksLikePath = line.Text.IndexOf(":\\", StringComparison.Ordinal) >= 0 || line.Text.StartsWith("\\\\", StringComparison.Ordinal);
                    bullet.Children.Add(new TextBlock
                    {
                        Text = line.Text,
                        TextWrapping = TextWrapping.Wrap,
                        FontFamily = looksLikePath ? mono : FontFamily,
                        FontSize = looksLikePath ? 12 : FontSize,
                    });
                    Body.Children.Add(bullet);
                    break;

                default:
                    Body.Children.Add(new TextBlock
                    {
                        Text = line.Text,
                        TextWrapping = TextWrapping.Wrap,
                        Margin = new Thickness(indent, 1, 0, 1),
                        LineHeight = 19,
                    });
                    break;
            }
        }
    }

    // ------------------------------------------------------------------
    // Buttons
    // ------------------------------------------------------------------

    private static StackPanel IconLabel(string glyph, string text, Brush iconBrush = null)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = new TextBlock
        {
            Text = glyph,
            FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
            Margin = new Thickness(0, 1, 8, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (iconBrush != null) icon.Foreground = iconBrush;
        p.Children.Add(icon);
        p.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        return p;
    }

    private void BuildLinks()
    {
        foreach (NoticeLink link in _request.Links)
        {
            var b = new Button
            {
                Style = (Style)FindResource("CutOnce.LinkButton"),
                Content = IconLabel("", link.Label),
                ToolTip = "Opens the explanation in your browser; this window stays open.",
            };
            string topic = link.Topic;
            b.Click += (s, e) => _openTopic?.Invoke(topic);
            LinksPanel.Children.Add(b);
        }
    }

    private void BuildButtons()
    {
        bool hasStop = _request.Stop != StopOffer.None;
        if (hasStop)
        {
            var stop = new Button
            {
                Style = (Style)FindResource("CutOnce.DangerButton"),
                Content = IconLabel(_request.Stop == StopOffer.UndoCommand ? "" : "", _request.StopLabel),
                Margin = new Thickness(8, 0, 0, 0),
            };
            stop.Click += (s, e) => Finish(new NoticeResult(NoticeButton.Stop));
            ButtonsPanel.Children.Add(stop);
        }
        for (int i = 0; i < _request.Actions.Count; i++)
        {
            int index = i;
            var b = new Button
            {
                Style = (Style)FindResource("CutOnce.Button"),
                Content = _request.Actions[i],
                Margin = new Thickness(8, 0, 0, 0),
            };
            b.Click += (s, e) => Finish(new NoticeResult(NoticeButton.Action, index));
            ButtonsPanel.Children.Add(b);
        }
        // with a red Stop beside it, Continue is the quieter (outlined) button; it is still the default
        var ok = new Button
        {
            Style = (Style)FindResource(hasStop ? "CutOnce.Button" : "CutOnce.PrimaryButton"),
            Content = string.IsNullOrWhiteSpace(_request.OkLabel) ? "OK" : _request.OkLabel,
            Margin = new Thickness(8, 0, 0, 0),
            IsDefault = true,
        };
        ok.Click += (s, e) => Finish(NoticeResult.Ok);
        ButtonsPanel.Children.Add(ok);
        Loaded += (s, e) => ok.Focus();
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        CopyOutcome outcome;
        try { outcome = _saveCopy?.Invoke(); }
        catch (Exception ex) { outcome = new CopyOutcome(false, null, "Copy failed: " + ex.Message); }
        if (outcome == null) return;
        CopyIntro.Text = outcome.Message;
        CopyFolder.Text = outcome.Path ?? "";
        CopyFolder.Visibility = Visibility.Visible;
        if (outcome.Success)
        {
            CopyButton.IsEnabled = false;
            CopyIcon.Text = "";
            CopyIcon.Foreground = (Brush)FindResource("CutOnce.Success");
        }
        else
        {
            CopyIcon.Text = "";
            CopyIcon.Foreground = (Brush)FindResource("CutOnce.Danger");
        }
    }

    private void OnCopyText(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(Headline + Environment.NewLine + Environment.NewLine +
                              string.Join(Environment.NewLine, _request.Lines));
        }
        catch (Exception)
        {
            // the clipboard is busy; nothing to do
        }
    }
}
