using System.Collections.Generic;

namespace CutOnce.Core;

/// <summary>Severity of a dialog: sets its colour strip, badge and icon.</summary>
public enum NoticeKind { Info, Warning, Error, Ok }

/// <summary>What the dialog offers for stopping the command it warns about.</summary>
public enum StopOffer
{
    /// <summary>No stop button (advisories on save, reports, help).</summary>
    None,
    /// <summary>The command has not run yet: "Stop MOVE" cancels it before anything changes.</summary>
    StopCommand,
    /// <summary>The command has already run: "Undo EXPLODE" reverses it (same as typing U).</summary>
    UndoCommand,
}

public sealed class NoticeLink
{
    public NoticeLink(string label, string topic) { Label = label; Topic = topic; }
    public string Label { get; }
    public string Topic { get; }
}

/// <summary>Everything a CutOnce dialog shows. The UI layer only renders it.</summary>
public sealed class NoticeRequest
{
    public string Headline { get; set; } = "";
    public NoticeKind Kind { get; set; } = NoticeKind.Info;
    public List<string> Lines { get; set; } = new List<string>();
    public List<NoticeLink> Links { get; set; } = new List<NoticeLink>();

    /// <summary>Extra buttons; the result's ActionIndex says which was clicked.</summary>
    public List<string> Actions { get; set; } = new List<string>();

    /// <summary>The main button: "OK", "Continue", "Close".</summary>
    public string OkLabel { get; set; } = "OK";

    public StopOffer Stop { get; set; } = StopOffer.None;
    /// <summary>The command a Stop / Undo button acts on, e.g. "MOVE".</summary>
    public string CommandName { get; set; }
    /// <summary>One line under the body explaining Stop / Undo.</summary>
    public string StopHint { get; set; }

    /// <summary>Small print at the bottom, e.g. the frequency note.</summary>
    public string Footnote { get; set; }

    /// <summary>Offer "Save a copy" (a backup of the drawing as last saved).</summary>
    public bool OfferCopy { get; set; }
    public bool CopyAvailable { get; set; }
    public string CopyIntro { get; set; }
    public string CopyFolder { get; set; }

    public string StopLabel => Stop == StopOffer.UndoCommand
        ? "Undo " + (CommandName ?? "it")
        : "Stop " + (CommandName ?? "command");
}

public enum NoticeButton { Ok, Stop, Action }

public sealed class NoticeResult
{
    public NoticeResult(NoticeButton button, int actionIndex = -1) { Button = button; ActionIndex = actionIndex; }
    public NoticeButton Button { get; }
    public int ActionIndex { get; }

    public static readonly NoticeResult Ok = new NoticeResult(NoticeButton.Ok);
    public bool IsStop => Button == NoticeButton.Stop;
    public bool IsAction(int index) => Button == NoticeButton.Action && ActionIndex == index;
}

/// <summary>Outcome of the "Save a copy" button.</summary>
public sealed class CopyOutcome
{
    public CopyOutcome(bool success, string path, string message) { Success = success; Path = path; Message = message; }
    public bool Success { get; }
    public string Path { get; }
    public string Message { get; }
}
