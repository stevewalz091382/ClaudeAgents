using System;
using System.Windows;
using CutOnce.Core;

namespace CutOnce.UI;

/// <summary>The cleanup dialog: what runs, with today's counts, and the backup copy first.</summary>
public partial class CleanupWindow : BrandedWindow
{
    private readonly Action<string> _openTopic;

    public CleanupWindow(CleanupViewModel vm, Action<string> openTopic)
    {
        _openTopic = openTopic;
        InitializeComponent();
        DataContext = vm;
        Kind = NoticeKind.Info;
        Headline = "Clean up this drawing: choose what runs";
    }

    /// <summary>True when the designer clicked Clean up.</summary>
    public bool Accepted { get; private set; }

    private void OnCleanUp(object sender, RoutedEventArgs e)
    {
        Accepted = true;
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();

    private void OnLearnMore(object sender, RoutedEventArgs e) => _openTopic?.Invoke("GUARD_CLEANUP");
}
