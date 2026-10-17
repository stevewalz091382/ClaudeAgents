using System;
using CutOnce.Core;

namespace CutOnce.UI;

/// <summary>Actions the Control Center's buttons trigger.</summary>
internal sealed class ControlCenterCallbacks
{
    public Action OpenLogFolder { get; set; }
    public Action OpenBackupFolder { get; set; }
    public Action<string> OpenTopic { get; set; }
    public Action ShowOtherHelp { get; set; }
}

/// <summary>
/// The dialogs, kept behind an interface so every module stays UI-agnostic: the
/// modules build a request or a view model, the WPF host renders it.
/// </summary>
internal interface IDialogHost
{
    /// <param name="saveCopy">Runs the "Save a copy" button.</param>
    /// <param name="openTopic">Runs a Learn More button (a knowledge-base topic).</param>
    NoticeResult ShowNotice(NoticeRequest request, Func<CopyOutcome> saveCopy, Action<string> openTopic);

    /// <summary>True when the designer clicked Save.</summary>
    bool ShowControlCenter(ControlCenterViewModel viewModel, ControlCenterCallbacks callbacks);

    /// <summary>True when the designer clicked Clean up.</summary>
    bool ShowCleanup(CleanupViewModel viewModel, Action<string> openTopic);
}
