using System;
using System.Collections.Generic;
using System.Linq;
using CutOnce.Core;
using CutOnce.Host;
using CutOnce.Scanning;

namespace CutOnce.Modules;

/// <summary>
/// Data-loss guards: EXPLODE / BURST, xref bind, xref moved or copied, and the
/// REFEDIT / REFCLOSE / promote / TEXT advisories. Each command can be switched off
/// in the Control Center; a guard that is off takes no snapshot.
/// </summary>
internal static class GuardService
{
    /// <summary>CUTONCE-GUARD-LOGCOMMANDS: print every command name as it starts.</summary>
    public static bool LogAllCommands;

    private static readonly string[] XrefCommands = { "XREF", "-XREF", "XBIND", "-XBIND" };

    private static SettingsService S => CutOnceApp.Settings;

    /// <summary>"(C:BURST)" -> "BURST"; null when it is not a command.</summary>
    public static string LispCommandName(string firstLine)
    {
        string t = (firstLine ?? "").Trim().TrimStart('(').Trim();
        if (!t.StartsWith("C:", StringComparison.OrdinalIgnoreCase)) return null;
        string name = new string(t.Substring(2).TakeWhile(c => !char.IsWhiteSpace(c) && c != ')').ToArray());
        return name.Length == 0 ? null : name.ToUpperInvariant();
    }

    // ------------------------------------------------------------------
    // Command events
    // ------------------------------------------------------------------

    public static void CommandWillStart(DocState st, string cmd)
    {
        var db = st.Doc.Database;
        if (cmd == "EXPLODE")
        {
            // inside a batch (BURST, a LISP loop) keep the first EXPLODE's snapshot
            if (S.CommandWarnOn("WarnEXPLODE") && !st.ExplodePending)
            {
                st.ExplodeSnapshot = ObjectCounter.SpaceCounts(db, false);
                st.ExplodeAttribSnapshot = ObjectCounter.AttributedBlockCount(db);
            }
        }
        else if (XrefCommands.Contains(cmd))
        {
            if (S.CommandWarnOn("WarnXREFBIND")) st.XrefSnapshot = ObjectCounter.XrefNames(db);
        }
        else if (cmd == "MOVE" || cmd == "COPY")
        {
            if (S.CommandWarnOn("Warn" + cmd))
            {
                // MOVE/COPY are frequent: with a pickfirst selection only check it; otherwise snapshot every xref
                var ids = st.PickfirstAtStart;
                st.CheckXrefMove = ids.Length == 0 || ObjectCounter.AnyXref(db, ids);
                st.XrefPointsSnapshot = st.CheckXrefMove ? ObjectCounter.XrefInsertPoints(db) : null;
            }
        }
    }

    public static void CommandEnded(DocState st, string cmd)
    {
        if (cmd == "EXPLODE")
        {
            if (st.InLisp) { if (st.ExplodeSnapshot != null) st.ExplodePending = true; }
            else ExplodeFlush(st, "EXPLODE");
        }
        else if (XrefCommands.Contains(cmd))
        {
            if (st.XrefSnapshot != null) ReportBinds(st, cmd, ObjectCounter.BoundXrefs(st.Doc.Database, st.XrefSnapshot));
            st.XrefSnapshot = null;
        }
        else if ((cmd == "MOVE" || cmd == "COPY") && st.CheckXrefMove)
        {
            var before = st.XrefPointsSnapshot;
            st.XrefPointsSnapshot = null;
            st.CheckXrefMove = false;
            if (before != null && !ObjectCounter.SamePositions(before, ObjectCounter.XrefInsertPoints(st.Doc.Database)))
            {
                CutOnceApp.LogEvent(st.Doc, "XREF-MOVED", "an xref insertion point changed position");
                var r = Notices.Once(st.Doc, "GUARD_XREF_MOVED", GuardTexts.XrefMoved,
                    new[] { new NoticeLink("Learn More...", "GUARD_XREF_MOVED") },
                    stop: StopOffer.UndoCommand, commandName: cmd);
                Notices.HandleUndo(st.Doc, r, cmd);
            }
        }
    }

    public static void CommandCancelled(DocState st)
    {
        // a cancelled step inside an EXPLODE batch keeps the batch's snapshot
        if (!st.ExplodePending)
        {
            st.ExplodeSnapshot = null;
            st.ExplodePreWarned = false;
        }
        st.XrefSnapshot = null;
        st.XrefPointsSnapshot = null;
        st.CheckXrefMove = false;
    }

    /// <summary>The LISP routine (BURST, a script) has finished: one warning for its EXPLODEs.</summary>
    public static void LispEnded(DocState st)
    {
        if (st.ExplodePending) ExplodeFlush(st, st.LispName ?? "EXPLODE");
    }

    // ------------------------------------------------------------------
    // EXPLODE
    // ------------------------------------------------------------------

    /// <summary>Before EXPLODE runs, when the objects were selected first. True = Stop.</summary>
    public static bool ExplodePreStart(DocState st, Autodesk.AutoCAD.DatabaseServices.ObjectId[] ids)
    {
        if (st.InLisp || ids.Length == 0 || !S.CommandWarnOn("WarnEXPLODE")) return false;
        var risk = ObjectCounter.AtRisk(st.Doc.Database, ids, out long attributed);
        if (risk.Count == 0) return false;
        bool civil = risk.Keys.Any(k => k.StartsWith("AECC", StringComparison.OrdinalIgnoreCase));
        string key = civil ? "GUARD_EXPLODE" : "GUARD_EXPLODE_BLOCKS";
        var links = new List<NoticeLink> { new NoticeLink("Learn More...", "GUARD_EXPLODE") };
        if (attributed > 0) links.Add(new NoticeLink("Attributes...", "GUARD_ATTRIB"));
        var r = Notices.Once(st.Doc, key, GuardTexts.ExplodeBefore(risk, attributed), links,
                             civil ? NoticeKind.Error : NoticeKind.Warning,
                             stop: StopOffer.StopCommand, commandName: "EXPLODE");
        if (r == null) return false;
        if (r.IsStop) return true;
        st.ExplodePreWarned = true;
        return false;
    }

    /// <summary>Reports the gathered EXPLODE batch (if any) and clears it.</summary>
    private static void ExplodeFlush(DocState st, string commandName)
    {
        var before = st.ExplodeSnapshot;
        long attribBefore = st.ExplodeAttribSnapshot;
        bool preWarned = st.ExplodePreWarned;
        st.ExplodeSnapshot = null;
        st.ExplodePending = false;
        st.ExplodePreWarned = false;
        if (before == null) return;

        var db = st.Doc.Database;
        long attribAfter = ObjectCounter.AttributedBlockCount(db);
        var report = ExplodeReport.Compare(before, ObjectCounter.SpaceCounts(db, false), attribBefore, attribAfter);
        if (report.Lost.Count > 0) CutOnceApp.LogEvent(st.Doc, "EXPLODE-LOSS", report.LossEvent);
        if (report.AttributedConverted > 0)
            CutOnceApp.LogEvent(st.Doc, "ATTRIB-LOSS", $"attributed blocks {attribBefore}->{attribAfter}");
        // the designer already saw (and accepted) this before EXPLODE ran
        if (!report.Any || preWarned) return;

        var r = Notices.Once(st.Doc, report.WarningKey, report.Lines(attribBefore, attribAfter), report.Links(),
                             report.CivilLost ? NoticeKind.Error : NoticeKind.Warning,
                             stop: StopOffer.UndoCommand, commandName: commandName);
        Notices.HandleUndo(st.Doc, r, commandName);
    }

    // ------------------------------------------------------------------
    // XREF / XBIND bind
    // ------------------------------------------------------------------

    private static void ReportBinds(DocState st, string cmd, List<string> bound)
    {
        if (bound.Count == 0) return;
        CutOnceApp.LogEvent(st.Doc, "XREF-BIND", string.Concat(bound.Select(n => n + "  ")));
        var r = Notices.Once(st.Doc, "GUARD_XREF_BIND", GuardTexts.XrefBind(bound),
            new[] { new NoticeLink("Learn More...", "GUARD_XREF_BIND") },
            stop: StopOffer.UndoCommand, commandName: cmd);
        Notices.HandleUndo(st.Doc, r, cmd);
    }

    // ------------------------------------------------------------------
    // Advisories: shown as the command starts, so each offers Stop
    // ------------------------------------------------------------------

    public static bool AdvisoryPreStart(DocState st, string cmd)
    {
        var doc = st.Doc;
        NoticeResult r = null;
        if (cmd == "REFEDIT")
        {
            if (!S.CommandWarnOn("WarnREFEDIT")) return false;
            CutOnceApp.LogEvent(doc, "ADVISORY-REFEDIT", "REFEDIT started");
            r = Notices.Once(doc, "GUARD_REFEDIT", GuardTexts.RefEdit, new[] { new NoticeLink("Learn More...", "GUARD_REFEDIT") },
                             stop: StopOffer.StopCommand, commandName: cmd);
        }
        else if (cmd == "REFCLOSE" || cmd == "-REFCLOSE")
        {
            if (!S.CommandWarnOn("WarnREFEDIT")) return false;
            CutOnceApp.LogEvent(doc, "ADVISORY-REFCLOSE", "REFCLOSE started");
            r = Notices.Once(doc, "GUARD_REFCLOSE", GuardTexts.RefClose, new[] { new NoticeLink("Learn More...", "GUARD_REFCLOSE") },
                             stop: StopOffer.StopCommand, commandName: "REFCLOSE");
        }
        else if (cmd.IndexOf("PROMOTE", StringComparison.Ordinal) >= 0)
        {
            if (!S.CommandWarnOn("WarnPROMOTE")) return false;
            CutOnceApp.LogEvent(doc, "ADVISORY-PROMOTE", cmd + " started");
            r = Notices.Once(doc, "GUARD_PROMOTE", GuardTexts.Promote, new[] { new NoticeLink("Learn More...", "GUARD_PROMOTE") },
                             stop: StopOffer.StopCommand, commandName: cmd);
        }
        else if (cmd == "TEXT" || cmd == "DTEXT" || cmd == "MTEXT")
        {
            if (!S.CommandWarnOn("Warn" + cmd)) return false;
            // every start is logged, so plain-text habits can be measured
            string key = "GUARD_TEXT:" + cmd;
            if (!S.IsDue(key))
            {
                CutOnceApp.LogEvent(doc, "TEXT-USED", cmd + " started (tip already shown this session)");
                return false;
            }
            CutOnceApp.LogEvent(doc, "TEXT-TIP", cmd + " started, tip shown");
            r = Notices.Once(doc, key, GuardTexts.TextTip, new[] { new NoticeLink("Learn More...", "GUARD_TEXT") },
                             NoticeKind.Info, stop: StopOffer.StopCommand, commandName: cmd,
                             stopHint: $"Stop {cmd} if a Civil 3D label would do the job; nothing is added to the drawing.");
        }
        return r != null && r.IsStop;
    }
}
