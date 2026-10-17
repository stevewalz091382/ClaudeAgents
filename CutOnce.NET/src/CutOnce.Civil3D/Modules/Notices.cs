using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.AutoCAD.ApplicationServices;
using CutOnce.Core;
using CutOnce.Host;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

namespace CutOnce.Modules;

/// <summary>
/// Every CutOnce dialog goes through here: severity, Learn More links, extra buttons,
/// "Save a copy", Stop / Undo and the frequency rule. The WPF windows only render the
/// request; if they cannot be shown, a plain alert with the links written out is used.
/// </summary>
internal static class Notices
{
    /// <summary>Shows a request. Never throws.</summary>
    public static NoticeResult Show(NoticeRequest req, Document doc = null, string copyReason = null)
    {
        doc ??= Acad.ActiveDoc;
        if (req.OfferCopy)
        {
            req.CopyAvailable = BackupService.Available(doc);
            req.CopyIntro = BackupService.Intro(doc);
            req.CopyFolder = req.CopyAvailable ? CutOnceApp.Folders.BackupDir : "";
        }
        try
        {
            var r = CutOnceApp.Dialogs.ShowNotice(req,
                () => BackupService.CopyNow(doc, copyReason ?? "Before going ahead with a warning"),
                CutOnceApp.OpenTopic);
            return r ?? NoticeResult.Ok;
        }
        catch (Exception ex)
        {
            if (ImpactService.Debug) Acad.Msg("CutOnce", "Dialog failed: " + ex.Message);
            var text = new List<string> { req.Headline, "" };
            text.AddRange(req.Lines);
            foreach (var lk in req.Links) text.Add("\n" + lk.Label + " " + CutOnceApp.KbUrl(lk.Topic));
            try { AcApp.ShowAlertDialog(string.Join("\n", text)); } catch (Exception) { /* nothing more to try */ }
            return NoticeResult.Ok;
        }
    }

    /// <summary>A message whose first line is the headline (as in the LISP edition).</summary>
    public static NoticeRequest FromText(IEnumerable<string> lines, NoticeKind kind, IEnumerable<NoticeLink> links)
    {
        var (head, body) = MessageText.SplitHeadline(string.Join("\n", lines), BrandName);
        return new NoticeRequest
        {
            Headline = head,
            Lines = body,
            Kind = kind,
            Links = (links ?? Enumerable.Empty<NoticeLink>()).Where(l => l?.Topic != null).ToList(),
        };
    }

    public static string BrandName => CutOnceApp.Config.GetString("BrandName") ?? Product.DefaultName;

    /// <summary>An information or result notice with one Learn More button.</summary>
    public static void Info(IEnumerable<string> lines, string topic, NoticeKind kind = NoticeKind.Info)
    {
        var req = FromText(lines, kind, topic == null ? null : new[] { new NoticeLink("Learn More...", topic) });
        Show(req);
    }

    /// <summary>Yes / no question. The safe answer is the main (default) button.</summary>
    public static bool Confirm(IEnumerable<string> lines, string yesLabel, string noLabel)
    {
        var req = FromText(lines, NoticeKind.Error, null);
        req.Actions.Add(yesLabel);
        req.OkLabel = noLabel;
        return Show(req).IsAction(0);
    }

    /// <summary>
    /// A command or save-check warning: shown only when due under the designer's frequency
    /// choice, then remembered. Returns null when the frequency choice hid it.
    /// </summary>
    /// <param name="key">Identifies the warning, e.g. "GUARD_XREF_BIND" or "IMPACT:MOVE".</param>
    /// <param name="stop">Offer Stop (command not run yet) or Undo (already run); needs WarnOfferStop.</param>
    public static NoticeResult Once(Document doc, string key, IEnumerable<string> lines, IEnumerable<NoticeLink> links,
                                    NoticeKind kind = NoticeKind.Warning, IEnumerable<string> actions = null,
                                    StopOffer stop = StopOffer.None, string commandName = null, string stopHint = null)
    {
        var settings = CutOnceApp.Settings;
        if (!settings.IsDue(key)) return null;
        var req = FromText(lines, kind, links);
        if (actions != null) req.Actions.AddRange(actions);
        req.Footnote = settings.FrequencyNote();
        req.OfferCopy = GuardTexts.CopyOffered(key);
        ApplyStop(req, stop, commandName, stopHint);
        var r = Show(req, doc, "Before going ahead: " + GuardTexts.WarningName(key));
        settings.MarkWarned(key);
        return r;
    }

    /// <summary>Adds Stop / Undo when the designer allows it, with the matching hint.</summary>
    public static void ApplyStop(NoticeRequest req, StopOffer stop, string cmd, string hint)
    {
        if (stop == StopOffer.None) return;
        req.CommandName = cmd;
        if (CutOnceApp.Settings.OfferStop)
        {
            req.Stop = stop;
            req.OkLabel = stop == StopOffer.StopCommand ? "Continue" : "Keep it";
            req.StopHint = hint ?? (stop == StopOffer.StopCommand
                ? $"Stop {cmd} cancels it before anything changes."
                : $"{cmd} has already run. Undo {cmd} reverses it (the same as typing U).");
        }
        else
        {
            req.StopHint = stop == StopOffer.StopCommand
                ? "Click OK, then press ESC if you want to stop this command."
                : $"{cmd} has already run. Type U to undo it.";
        }
    }

    /// <summary>Acts on an Undo answer: queues U for after the command, and logs it.</summary>
    public static void HandleUndo(Document doc, NoticeResult r, string cmd)
    {
        if (r == null || !r.IsStop) return;
        Acad.QueueUndo(doc);
        CutOnceApp.LogEvent(doc, "COMMAND-UNDONE", cmd + " undone from its warning");
    }
}
