using System;
using System.Windows;
using CutOnce.Core;

namespace CutOnce.UI;

/// <summary>The CutOnce Control Center (CUTONCE). Bound to <see cref="ControlCenterViewModel"/>.</summary>
public partial class ControlCenterWindow : BrandedWindow
{
    private readonly ControlCenterViewModel _vm;
    private readonly ControlCenterCallbacks _callbacks;

    internal ControlCenterWindow(ControlCenterViewModel vm, ControlCenterCallbacks callbacks)
    {
        _vm = vm;
        _callbacks = callbacks;
        InitializeComponent();
        Scroller.MaxHeight = Math.Max(320, Math.Min(640, ScreenHeight - 270));
        DataContext = vm;
        Kind = NoticeKind.Info;
        Headline = "Control Center: choose which checks, warnings and logs run for you. Changes apply to every open drawing.";
    }

    /// <summary>True when the designer clicked Save.</summary>
    public bool Saved { get; private set; }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        Saved = true;
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Close();

    private void OnDefaults(object sender, RoutedEventArgs e) => _vm.ResetToDefaults();

    private void OnLearnMore(object sender, RoutedEventArgs e) => _callbacks.OpenTopic?.Invoke("CONTROL_CENTER");

    private void OnOtherHelp(object sender, RoutedEventArgs e) => _callbacks.ShowOtherHelp?.Invoke();

    private void OnOpenLogs(object sender, RoutedEventArgs e) => _callbacks.OpenLogFolder?.Invoke();

    private void OnOpenBackups(object sender, RoutedEventArgs e) => _callbacks.OpenBackupFolder?.Invoke();
}
