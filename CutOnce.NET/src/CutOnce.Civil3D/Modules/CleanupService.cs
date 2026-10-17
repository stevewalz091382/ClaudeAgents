using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;
using CutOnce.Core;
using CutOnce.Host;
using CutOnce.Scanning;

namespace CutOnce.Modules;

/// <summary>
/// One-click bloat cleanup (CUTONCE-CLEANUP, also offered by the growth warning):
/// _PURGESTYLES first, then -PURGE passes repeated while counts keep falling, the scale
/// list reset and AUDIT, all as one undo step, after an optional backup copy.
/// </summary>
internal static class CleanupService
{
    private static readonly List<string> Ran = new List<string>();

    /// <summary>What each step can lower, for this drawing.</summary>
    public static Dictionary<string, object> Counts(Database db)
    {
        var c = new Dictionary<string, object>(StringComparer.Ordinal);
        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            c["RegApps"] = DrawingScanner.CountTable(tr, db.RegAppTableId);
            c["Scales"] = DrawingScanner.CountNamedDictionary(tr, db, "ACAD_SCALELIST");
            c["Styles"] = DrawingScanner.CountTable(tr, db.TextStyleTableId) + DrawingScanner.CountTable(tr, db.DimStyleTableId) +
                          DrawingScanner.CountDictionary(tr, db.MLeaderStyleDictionaryId) +
                          DrawingScanner.CountDictionary(tr, db.TableStyleDictionaryId) +
                          DrawingScanner.CountDictionary(tr, db.MLStyleDictionaryId);
            long anon = 0, other = DrawingScanner.CountTable(tr, db.LayerTableId) + DrawingScanner.CountTable(tr, db.LinetypeTableId);
            var bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
            foreach (ObjectId id in bt)
            {
                var btr = (BlockTableRecord)tr.GetObject(id, OpenMode.ForRead);
                string name = btr.Name.ToUpperInvariant();
                if (btr.IsFromExternalReference) continue;
                if (name.StartsWith("*", StringComparison.Ordinal))
                {
                    if (name != "*MODEL_SPACE" && !name.StartsWith("*PAPER_SPACE", StringComparison.Ordinal)) anon++;
                }
                else if (name.IndexOf('|') < 0 && !btr.IsLayout)
                {
                    other++;
                }
            }
            c["AnonBlocks"] = anon;
            c["Other"] = other;
            tr.Commit();
        }
        long? civil = Civil.CountStyles(Civil.DocumentFor(db));
        c["CivilStyles"] = civil.HasValue ? (object)civil.Value : "n/a";
        return c;
    }

    /// <summary>CUTONCE-CLEANUP: the dialog, then the run.</summary>
    public static void Run(Document doc)
    {
        var settings = CutOnceApp.Settings;
        var before = Counts(doc.Database);
        bool forced = settings.IsLocked("BackupBeforeCleanup") && settings.IsOn("BackupBeforeCleanup");
        var vm = new CleanupViewModel(before, Acad.IsSaved(doc), settings.IsOn("BackupBeforeCleanup"), forced,
                                      CutOnceApp.Folders.BackupDir, CutOnceApp.Folders.BackupDirConfigured != null,
                                      Acad.HasUnsavedChanges(doc), Acad.DocPath(doc).Length > 0 ? Acad.DocPath(doc) : Acad.DocName(doc));
        if (!CutOnceApp.Dialogs.ShowCleanup(vm, CutOnceApp.OpenTopic))
        {
            Acad.Msg("CutOnce Cleanup", "Cancelled - nothing was changed.");
            return;
        }
        var choice = vm.Choice();
        if (!CleanupPlan.Steps.Any(s => choice.Contains(s.Key)))
        {
            Acad.Msg("CutOnce Cleanup", "Nothing ticked - nothing was changed.");
            return;
        }
        Execute(doc, choice, before, forced);
    }

    private static void Note(Editor ed, string text)
    {
        Ran.Add(text);
        ed.WriteMessage("\n[CutOnce Cleanup] " + text);
    }

    private static int CmdActive => Acad.GetInt("CMDACTIVE", 0);

    /// <summary>Cancels a command left waiting for input (an option a release lacks), never this command itself.</summary>
    private static void CancelActive(Editor ed)
    {
        for (int n = 0; n < 4 && (CmdActive & 1) == 1 && Acad.CmdNames.Length > 0 && !Acad.CmdNames.Contains("CUTONCE"); n++)
        {
            try { ed.Command(); } catch (Exception) { break; }
        }
    }

    private static void Purge(Editor ed, string keyword, string names)
    {
        Note(ed, $"-PURGE {keyword.TrimStart('_')} {names} No");
        try { ed.Command("_.-PURGE", keyword, names, "_No"); }
        catch (Exception ex) { Note(ed, "  stopped: " + ex.Message); }
        CancelActive(ed);
    }

    private static void PurgePass(Editor ed, ICollection<string> choice)
    {
        if (choice.Contains("styles"))
            foreach (string kw in new[] { "_Dimstyles", "_textSTyles", "_MUltileaderstyles", "_Tablestyles", "_Mlinestyles" })
                Purge(ed, kw, "*");
        // anonymous blocks only: ` makes the first * literal
        if (choice.Contains("anon")) Purge(ed, "_Blocks", "`**");
        if (choice.Contains("regapps")) Purge(ed, "_Regapps", "*");
        if (choice.Contains("all")) Purge(ed, "_All", "*");
    }

    private static void Execute(Document doc, List<string> choice, Dictionary<string, object> before, bool forced)
    {
        Editor ed = doc.Editor;
        Ran.Clear();
        string backup = null;

        // 1. backup copy, when ticked
        if (choice.Contains("backup"))
        {
            backup = BackupService.Backup(doc, "Before cleanup");
            if (backup == null)
            {
                string folder = CutOnceApp.Folders.BackupDir;
                if (forced)
                {
                    Notices.Info(new[]
                    {
                        "The backup copy could not be saved",
                        "",
                        "Your CAD administrator requires a backup copy before cleanup, so nothing was changed.",
                        "",
                        "Backup folder: " + folder,
                    }, "BACKUP", NoticeKind.Error);
                    return;
                }
                if (!Notices.Confirm(new[]
                    {
                        "The backup copy could not be saved",
                        "",
                        "The reason is on the command line.",
                        "",
                        "Backup folder: " + folder,
                        "",
                        "Clean up anyway, without a backup?",
                    }, "Clean up without a backup", "Cancel"))
                {
                    Acad.Msg("CutOnce Cleanup", "Cancelled - nothing was changed.");
                    return;
                }
            }
        }

        // 2. Civil 3D styles, PURGE passes, scale list, AUDIT - as one undo step
        object echo = Acad.GetVar("CMDECHO");
        Acad.SetVar("CMDECHO", 1);
        Acad.Msg("CutOnce Cleanup", "Cleaning up - each command and its result is shown below.");
        try
        {
            ed.Command("_.UNDO", "_Begin");
            // Civil 3D styles first: they hold on to text styles, blocks, layers and
            // registered apps, which PURGE can only remove once the styles are gone
            if (choice.Contains("civil"))
            {
                Note(ed, "_PURGESTYLES (unused Civil 3D styles)");
                try
                {
                    ed.Command("_.PURGESTYLES");
                    for (int n = 0; n < 20 && (CmdActive & 1) == 1 && Acad.CmdNames.Contains("PURGESTYLES"); n++)
                        ed.Command(Editor.PauseToken);
                }
                catch (Exception ex) { Note(ed, "  stopped: " + ex.Message); }
            }
            // purging one item can free another (a style using a regapp, a block in a
            // block), so repeat while any count is still falling, at most 5 times
            if (choice.Any(k => CleanupPlan.PurgeKeys.Contains(k)))
            {
                long current = CleanupPlan.PurgeSum(Counts(doc.Database));
                long? previous = null;
                for (int pass = 0; pass < 5 && current != previous; pass++)
                {
                    previous = current;
                    PurgePass(ed, choice);
                    current = CleanupPlan.PurgeSum(Counts(doc.Database));
                }
            }
            if (choice.Contains("scales"))
            {
                Note(ed, "-SCALELISTEDIT Reset Yes Exit");
                try { ed.Command("_.-SCALELISTEDIT", "_Reset", "_Yes", "_Exit"); }
                catch (Exception ex) { Note(ed, "  stopped: " + ex.Message); }
                CancelActive(ed);
            }
            if (choice.Contains("audit"))
            {
                Note(ed, "AUDIT Yes (fix errors)");
                try { ed.Command("_.AUDIT", "_Yes"); }
                catch (Exception ex) { Note(ed, "  stopped: " + ex.Message); }
                CancelActive(ed);
            }
        }
        finally
        {
            try { ed.Command("_.UNDO", "_End"); } catch (Exception) { /* already ended */ }
            if (echo != null) Acad.SetVar("CMDECHO", echo);
        }

        // 3. result
        var after = Counts(doc.Database);
        CutOnceApp.LogEvent(doc, "CLEANUP", CleanupPlan.EventDetail(before, after));
        var req = new NoticeRequest
        {
            Headline = "Cleanup finished",
            Kind = NoticeKind.Ok,
            Lines = CleanupPlan.ResultLines(choice, before, after, Ran, backup).Skip(2).ToList(),
            Links = new List<NoticeLink> { new NoticeLink("Learn More...", "GUARD_CLEANUP") },
            OkLabel = "Close",
        };
        req.Actions.Add("Save now");
        req.Stop = StopOffer.UndoCommand;
        req.CommandName = "cleanup";
        req.StopHint = "Undo cleanup reverses every step above in one go (the same as typing U now).";
        var r = Notices.Show(req, doc);
        if (r.IsStop)
        {
            Acad.QueueUndo(doc);
            CutOnceApp.LogEvent(doc, "COMMAND-UNDONE", "cleanup undone from its result");
        }
        else if (r.IsAction(0))
        {
            try { ed.Command("_.QSAVE"); } catch (Exception ex) { Acad.Msg("CutOnce Cleanup", "Save failed: " + ex.Message); }
        }
    }
}
