using System;
using System.Linq;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;
using CutOnce.Core;
using CutOnce.Host;

namespace CutOnce.Modules;

/// <summary>
/// Stopping a command from its warning: the feature AutoLISP could not provide.
///
/// Civil 3D raises DocumentLockModeChanged as a command takes the drawing, before it
/// changes anything, and lets that handler Veto() the command. CutOnce shows the
/// warning there; "Stop MOVE" vetoes the command, so nothing changes at all.
///
/// Whichever order Civil 3D raises CommandWillStart and DocumentLockModeChanged in,
/// each command's pre-start warning is shown once. If no lock event arrives (a
/// command that never locks the drawing), the warning is shown from Application.Idle
/// while the command waits for input, and "Stop" cancels it with ESC instead.
/// ("StopOnLock" . nil) in the config skips the lock event altogether: the warning
/// then shows from CommandWillStart, as in the LISP edition, and Stop sends ESC.
///
/// Later layers: SelectionAdded (ImpactService) warns while objects are picked after
/// the command started, and warnings raised once a command has run offer "Undo".
/// </summary>
internal static class CommandGate
{
    private static readonly string[] Advisories = { "REFEDIT", "REFCLOSE", "-REFCLOSE", "TEXT", "DTEXT", "MTEXT" };

    /// <summary>Commands that can show a warning before they run.</summary>
    public static bool IsGated(string cmd) =>
        ImpactService.IsTransform(cmd) || ImpactService.IsWatched(cmd) || cmd == "EXPLODE" ||
        Advisories.Contains(cmd) || cmd.IndexOf("PROMOTE", StringComparison.Ordinal) >= 0;

    /// <summary>"MOVE" for a command taking the drawing; null for "#MOVE" (releasing it) or no command.</summary>
    private static string Normalize(string globalName)
    {
        if (string.IsNullOrWhiteSpace(globalName) || globalName[0] == '#') return null;
        return globalName.Trim().ToUpperInvariant();
    }

    public static void OnLockModeChanged(object sender, DocumentLockModeChangedEventArgs e)
    {
        // ("StopOnLock" . nil) in the config: warn from CommandWillStart instead (Stop then cancels with ESC)
        if (!CutOnceApp.Config.GetBool("StopOnLock", true)) return;
        string cmd = Normalize(e.GlobalCommandName);
        if (cmd == null || !IsGated(cmd)) return;
        var st = DocMonitor.Get(e.Document);
        if (st == null || st.PreStartDone == cmd) return;
        DocMonitor.Safe("command gate", () =>
        {
            st.PreStartDone = cmd;
            st.AwaitingPreStart = null;
            if (PreStart(st, cmd, Pickfirst(st)))
            {
                e.Veto();
                st.PreStartDone = null;   // a vetoed command never ends, so forget it now
                Stopped(st.Doc, cmd, "before it started");
            }
        });
    }

    /// <summary>Called from CommandWillStart: wait for the lock event, or fall back to idle.</summary>
    public static void OnCommandWillStart(DocState st, string cmd)
    {
        if (st.PreStartDone == cmd || !IsGated(cmd)) return;
        if (CutOnceApp.Config.GetBool("StopOnLock", true))
        {
            st.AwaitingPreStart = cmd;
            return;
        }
        // lock-event warnings switched off: warn now; Stop queues ESC for the command's first prompt
        st.PreStartDone = cmd;
        if (PreStart(st, cmd, st.PickfirstAtStart))
        {
            Acad.CancelRunningCommand(st.Doc);
            Stopped(st.Doc, cmd, "as it started");
        }
    }

    /// <summary>No lock event came: warn while the command waits for input; Stop cancels it.</summary>
    public static void OnIdle(DocState st)
    {
        string cmd = st.AwaitingPreStart;
        st.AwaitingPreStart = null;
        if (cmd == null || st.PreStartDone == cmd || !Acad.CommandRunning(cmd)) return;
        st.PreStartDone = cmd;
        if (PreStart(st, cmd, st.PickfirstAtStart))
        {
            Acad.CancelRunningCommand(st.Doc);
            Stopped(st.Doc, cmd, "while it waited for input");
        }
    }

    private static void Stopped(Document doc, string cmd, string when)
    {
        CutOnceApp.LogEvent(doc, "COMMAND-STOPPED", cmd + " stopped from its warning, " + when);
        Acad.Msg("CutOnce", cmd + " stopped - nothing was changed.");
    }

    /// <summary>The pre-start warning for one command. True = the designer chose Stop.</summary>
    private static bool PreStart(DocState st, string cmd, ObjectId[] ids)
    {
        if (ImpactService.IsTransform(cmd)) return ImpactService.TransformPreStart(st, cmd, ids);
        if (ImpactService.IsWatched(cmd)) return ImpactService.WatchedPreStart(st, cmd, ids);
        if (cmd == "EXPLODE") return GuardService.ExplodePreStart(st, ids);
        return GuardService.AdvisoryPreStart(st, cmd);
    }

    /// <summary>
    /// The pickfirst selection: read now, else the last value seen. A selection cleared
    /// a moment ago was most likely cleared by the command that is starting.
    /// </summary>
    public static ObjectId[] Pickfirst(DocState st)
    {
        try
        {
            PromptSelectionResult r = st.Doc.Editor.SelectImplied();
            if (r.Status == PromptStatus.OK && r.Value != null && r.Value.Count > 0) return r.Value.GetObjectIds();
        }
        catch (Exception)
        {
            // fall back to the cache
        }
        if (st.Implied.Length > 0) return st.Implied;
        if (st.SinceImpliedCleared.IsRunning && st.SinceImpliedCleared.ElapsedMilliseconds < 1000) return st.LastNonEmptyImplied;
        return new ObjectId[0];
    }
}
