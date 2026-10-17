using System;
using System.Windows;
using CutOnce.Core;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

namespace CutOnce.UI;

/// <summary>Shows the WPF dialogs as Civil 3D modal windows (owned by the main window).</summary>
internal sealed class WpfDialogHost : IDialogHost
{
    private static void ShowModal(Window w) => AcApp.ShowModalWindow(w);

    public NoticeResult ShowNotice(NoticeRequest request, Func<CopyOutcome> saveCopy, Action<string> openTopic)
    {
        var w = new NoticeWindow(request, saveCopy, openTopic);
        ShowModal(w);
        return w.Result;
    }

    public bool ShowControlCenter(ControlCenterViewModel viewModel, ControlCenterCallbacks callbacks)
    {
        var w = new ControlCenterWindow(viewModel, callbacks);
        ShowModal(w);
        return w.Saved;
    }

    public bool ShowCleanup(CleanupViewModel viewModel, Action<string> openTopic)
    {
        var w = new CleanupWindow(viewModel, openTopic);
        ShowModal(w);
        return w.Accepted;
    }
}
