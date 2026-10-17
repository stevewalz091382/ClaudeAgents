using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.Runtime;
using CutOnce.Core;
using CutOnce.Host;
using CutOnce.Modules;
using CutOnce.Scanning;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

namespace CutOnce.Commands;

/// <summary>
/// Every CutOnce command. The names are the same as the LISP edition, so toolbar
/// buttons, scripts and muscle memory keep working.
/// </summary>
public sealed class CutOnceCommands
{
    private const string Group = "CUTONCE";

    private static Document Doc => AcApp.DocumentManager.MdiActiveDocument;

    private static void Run(string what, Action body)
    {
        try { body(); }
        catch (System.Exception ex) { Acad.Msg("CutOnce", what + " failed: " + ex.Message); }
    }

    // ---------------- Control Center ----------------

    [CommandMethod(Group, "CUTONCE", CommandFlags.Modal)]
    public void ControlCenterDialog() => Run("Control Center", ControlCenter.ShowDialog);

    [CommandMethod(Group, "-CUTONCE", CommandFlags.Modal)]
    public void ControlCenterCommandLine() => Run("-CUTONCE", () => ControlCenter.CommandLine(Doc.Editor));

    [CommandMethod(Group, "CUTONCE-STATUS", CommandFlags.Modal)]
    public void Status() => Run("Status", () =>
    {
        var f = CutOnceApp.Folders;
        var s = CutOnceApp.Settings;
        Acad.Msg("CutOnce", $"Version {Product.Version} (.NET edition) - published by {Product.Publisher}");
        Acad.Write("\n  Install folder:  " + CutOnceApp.Home);
        Acad.Write("\n  Configuration:   " + (CutOnceApp.Config.SourcePath ?? "(not found - built-in defaults)") +
                   (CutOnceApp.Config.LoadError != null && CutOnceApp.Config.SourcePath != null ? "  ERROR: " + CutOnceApp.Config.LoadError : ""));
        Acad.Write("\n  Plugin:          " + typeof(CutOnceCommands).Assembly.Location);
        Acad.Write("\n  Log folder:      " + f.LogDir);
        Acad.Write("\n  Backup folder:   " + f.BackupDir + (f.BackupDirConfigured != null ? "" : "  (personal default - set BackupDir for a shared folder)"));
        Acad.Write("\n  Civil 3D API:    " + (Civil.Available ? "connected" : "not found (plain AutoCAD?)"));
        Acad.Write("\n  Logging:         " + (s.IsOn("LogEnabled") ? "on" : "OFF"));
        Acad.Write("\n  Stop / Undo:     " + (s.OfferStop ? "offered on command warnings" : "off"));
        Acad.Write("\n  Settings:        CUTONCE (dialog), -CUTONCE List (command line)");
        Acad.Write("\n  Tool status:     CUTONCE-GUARD-STATUS, CUTONCE-IMPACT-STATUS, CUTONCE-CHECK-STATUS");
    });

    [CommandMethod(Group, "CUTONCE-RELOADCONFIG", CommandFlags.Modal)]
    public void ReloadConfig() => Run("Reload", () =>
    {
        CutOnceApp.LoadConfig();
        Acad.Msg("CutOnce", "Configuration reloaded from " + (CutOnceApp.Config.SourcePath ?? "(built-in defaults)"));
    });

    /// <summary>Kept for old toolbar buttons: the .NET edition talks to Civil 3D directly.</summary>
    [CommandMethod(Group, "CUTONCE-FINDCIVIL", CommandFlags.Modal)]
    public void FindCivil() => Acad.Msg("CutOnce",
        Civil.Available ? "Civil 3D API connected. (The .NET edition no longer needs a COM ProgID.)" : "Civil 3D API not found - is this plain AutoCAD?");

    /// <summary>Shows sample dialogs, to check branding after editing the config.</summary>
    [CommandMethod(Group, "CUTONCE-PREVIEW", CommandFlags.Modal)]
    public void Preview() => Run("Preview", () =>
    {
        var req = Notices.FromText(new[]
        {
            "CutOnce Guard: EXPLODE is about to convert the selected objects.",
            "",
            "  Alignment:  1",
            "  Block:  3",
            "",
            "Exploded Civil 3D objects become plain geometry: labels, styles, design",
            "data and every object that depends on them are lost.",
        }, NoticeKind.Error, new[] { new NoticeLink("Learn More...", "GUARD_EXPLODE") });
        req.OfferCopy = true;
        req.Footnote = "Preview only - nothing is stopped or changed.";
        Notices.ApplyStop(req, StopOffer.StopCommand, "EXPLODE", null);
        Notices.Show(req, Doc, "Preview");
    });

    // ---------------- Standards and health ----------------

    [CommandMethod(Group, "CUTONCE-CHECK", CommandFlags.Modal)]
    public void Check() => Run("Check", () => StandardsService.CheckNow(Doc));

    [CommandMethod(Group, "CUTONCE-CHECK-STATUS", CommandFlags.Modal)]
    public void CheckStatus() => Run("Check status", () =>
    {
        Acad.Msg("CutOnce Standards", "Standards check settings (change in the Control Center: CUTONCE):");
        Acad.Write(StandardsService.StatusLines());
    });

    [CommandMethod(Group, "CUTONCE-AUDIT", CommandFlags.Session)]
    public void Audit() => Run("Audit", () =>
    {
        int n = 0;
        foreach (Document d in AcApp.DocumentManager)
        {
            try { if (HealthService.AuditDocument(d)) n++; }
            catch (System.Exception ex) { Acad.Write($"\nFailed: {Acad.DocName(d)} - {ex.Message}"); }
        }
        Acad.Write($"\n{n} drawing(s) recorded in {HealthService.HealthPath}");
        if (n > 0) HealthService.OpenInExcel(HealthService.HealthPath);
    });

    [CommandMethod(Group, "CUTONCE-AUDIT-FOLDER", CommandFlags.Session)]
    public void AuditFolder() => Run("Audit folder", () =>
    {
        var opts = new PromptOpenFileOptions("Pick any .dwg in the folder to audit (every .dwg in it will be processed)")
        {
            Filter = "Drawing (*.dwg)|*.dwg",
        };
        PromptFileNameResult picked = Doc.Editor.GetFileNameForOpen(opts);
        if (picked.Status != PromptStatus.OK)
        {
            Acad.Write("\nCancelled.");
            return;
        }
        string folder = Path.GetDirectoryName(picked.StringResult) ?? "";
        int n = 0;
        foreach (string file in Directory.GetFiles(folder, "*.dwg").OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
        {
            // opened visibly: Civil 3D objects are not reliably readable from a side database
            Document d = AcApp.DocumentManager.Cast<Document>()
                .FirstOrDefault(x => string.Equals(Acad.DocPath(x), file, StringComparison.OrdinalIgnoreCase));
            bool openedHere = d == null;
            try
            {
                if (openedHere) d = AcApp.DocumentManager.Open(file, true);
                if (HealthService.AuditDocument(d)) n++;
            }
            catch (System.Exception ex)
            {
                Acad.Write($"\nSkipped (could not open): {Path.GetFileName(file)} - {ex.Message}");
            }
            finally
            {
                if (openedHere && d != null) { try { d.CloseAndDiscard(); } catch (System.Exception) { /* already closed */ } }
            }
        }
        Acad.Write($"\n{n} drawing(s) recorded in {HealthService.HealthPath}");
        if (n > 0) HealthService.OpenInExcel(HealthService.HealthPath);
    });

    // ---------------- Cleanup and backups ----------------

    [CommandMethod(Group, "CUTONCE-CLEANUP", CommandFlags.Modal)]
    public void Cleanup() => Run("Cleanup", () => CleanupService.Run(Doc));

    [CommandMethod(Group, "CUTONCE-BACKUP", CommandFlags.Modal)]
    public void Backup() => Run("Backup", () =>
    {
        Document doc = Doc;
        if (!Acad.IsSaved(doc))
        {
            Acad.Msg("CutOnce Cleanup", "Save the drawing first - there is no file to copy yet.");
            return;
        }
        string kw = "Save";
        if (Acad.HasUnsavedChanges(doc))
        {
            var opts = new PromptKeywordOptions("\nThis drawing has unsaved changes. [Save first/Copy last saved version/Cancel] <Save first>: ", "Save Copy Cancel")
            {
                AllowNone = true,
            };
            PromptResult r = doc.Editor.GetKeywords(opts);
            if (r.Status == PromptStatus.Cancel) return;
            if (r.Status == PromptStatus.OK && !string.IsNullOrEmpty(r.StringResult)) kw = r.StringResult;
            if (kw == "Cancel") return;
            if (kw == "Save") doc.Editor.Command("_.QSAVE");
        }
        string bk = BackupService.Backup(doc, kw == "Copy" ? "Manual (last saved version)" : "Manual");
        if (bk != null) Acad.Write("\n  Recorded in " + BackupService.LogPath);
    });

    [CommandMethod(Group, "CUTONCE-BACKUP-FOLDER", CommandFlags.Modal)]
    public void BackupFolder() => Run("Backup folder", () =>
    {
        string dir = CutOnceApp.Folders.BackupDir;
        Acad.Msg("CutOnce Cleanup", "Backup folder: " + dir);
        Acad.OpenFolder(dir);
    });

    // ---------------- Guard ----------------

    private static readonly string[] GuardSwitches =
    {
        "CommandWarnings", "WarnMOVE", "WarnCOPY", "WarnEXPLODE", "WarnXREFBIND", "WarnREFEDIT", "WarnPROMOTE",
        "WarnTEXT", "WarnDTEXT", "WarnMTEXT", "WarnOfferStop", "GuardGrowth", "GuardCleanup", "BackupBeforeCleanup",
    };

    [CommandMethod(Group, "CUTONCE-GUARD-STATUS", CommandFlags.Modal)]
    public void GuardStatus() => Run("Guard status", () =>
    {
        var s = CutOnceApp.Settings;
        Acad.Msg("CutOnce Guard", "Command and save events: " + (DocMonitor.Running ? "active" : "not running"));
        Acad.Msg("CutOnce Guard", "Growth threshold: " + GrowthCheck.Threshold(CutOnceApp.Config) + "%");
        Acad.Msg("CutOnce Guard", "Log folder:       " + CutOnceApp.Folders.LogDir);
        Acad.Msg("CutOnce Guard", "Frequency:        " + (s.WarnMode == WarnMode.Once ? "once per command per session" : "every time"));
        foreach (string k in GuardSwitches)
            Acad.Write($"\n  {SettingsCatalog.Label(k)}: {(s.IsOn(k) ? "on" : "off")}{(s.IsLocked(k) ? "  (set by CAD admin)" : "")}");
        Acad.Write("\n  Change these in the CutOnce Control Center (type CUTONCE).");
    });

    [CommandMethod(Group, "CUTONCE-GUARD-CHECKNOW", CommandFlags.Modal)]
    public void GuardCheckNow() => Run("Check now", () => HealthService.Check(Doc, "Manual"));

    [CommandMethod(Group, "CUTONCE-GUARD-DUMPOBJECTS", CommandFlags.Modal)]
    public void DumpObjects() => Run("Dump objects", () =>
    {
        var counts = ObjectCounter.SpaceCounts(Doc.Database, true);
        if (counts.Count == 0)
        {
            Acad.Msg("CutOnce Guard", "No objects in Model Space or any layout.");
            return;
        }
        Acad.Msg("CutOnce Guard", "ObjectName counts (Model Space + all layouts). Use these names in HealthExtraCounts:");
        foreach (var kv in counts.OrderBy(k => k.Key, StringComparer.Ordinal)) Acad.Write($"\n  {kv.Key} = {kv.Value}");
    });

    [CommandMethod(Group, "CUTONCE-GUARD-LOG", CommandFlags.Modal)]
    public void GuardLog() => Run("Log paths", () =>
    {
        var f = CutOnceApp.Folders;
        Acad.Msg("CutOnce Guard", "Health history: " + HealthService.HealthPath);
        Acad.Msg("CutOnce Guard", "Xref detail:    " + HealthService.XrefsPath);
        Acad.Msg("CutOnce Guard", $"Backup copies:  {BackupService.LogPath}  (copies in {f.BackupDir})");
        Acad.Msg("CutOnce Guard", "Event log:      " + CutOnceApp.Events.EventsPath);
        Acad.Msg("CutOnce Guard", "Opened log:     " + CutOnceApp.Events.OpenedPath);
        Acad.Msg("CutOnce Guard", "Logging is " + (CutOnceApp.Settings.IsOn("LogEnabled") ? "on." : "OFF (turn it on in the Control Center: CUTONCE)."));
    });

    [CommandMethod(Group, "CUTONCE-GUARD-SUMMARY", CommandFlags.Modal)]
    public void GuardSummaryCommand() => Run("Summary", () =>
    {
        var lines = GuardSummary.Build(
            CsvLogWriter.ReadLines(CutOnceApp.Events.OpenedPath),
            CsvLogWriter.ReadLines(HealthService.HealthPath),
            CsvLogWriter.ReadLines(CutOnceApp.Events.EventsPath),
            HealthService.Columns);
        Acad.Msg("CutOnce Guard", lines[0]);
        foreach (string ln in lines.Skip(1)) Acad.Write("\n" + ln);
    });

    [CommandMethod(Group, "CUTONCE-GUARD-LOGCOMMANDS", CommandFlags.Modal)]
    public void LogCommands()
    {
        GuardService.LogAllCommands = !GuardService.LogAllCommands;
        Acad.Msg("CutOnce Guard", GuardService.LogAllCommands
            ? "Command echo ON - every command name prints as it starts. Run CUTONCE-GUARD-LOGCOMMANDS again to stop."
            : "Command echo OFF.");
    }

    // ---------------- Impact ----------------

    [CommandMethod(Group, "CUTONCE-IMPACT-ON", CommandFlags.Modal)]
    public void ImpactOn() => SetWarnings(true);

    [CommandMethod(Group, "CUTONCE-IMPACT-OFF", CommandFlags.Modal)]
    public void ImpactOff() => SetWarnings(false);

    private static void SetWarnings(bool on)
    {
        var s = CutOnceApp.Settings;
        if (s.IsLocked("CommandWarnings"))
        {
            Acad.Msg("CutOnce Impact", "Command warnings are set by your CAD administrator.");
            return;
        }
        s.SetOn("CommandWarnings", on);
        Acad.Msg("CutOnce Impact", on
            ? "Command warnings ON."
            : "Command warnings OFF. Turn them back on with CUTONCE-IMPACT-ON or in the Control Center (CUTONCE).");
    }

    [CommandMethod(Group, "CUTONCE-IMPACT-STATUS", CommandFlags.Modal)]
    public void ImpactStatus() => Run("Impact status", () =>
    {
        var lines = ImpactService.StatusLines().ToList();
        Acad.Msg("CutOnce Impact", lines[0]);
        foreach (string ln in lines.Skip(1)) Acad.Write("\n" + ln);
        Acad.Write("\n  Civil 3D API: " + (Civil.Available ? "connected" : "not found"));
        Acad.Write("\n  Debug tracing: " + (ImpactService.Debug ? "ON" : "off"));
        Acad.Write("\n  Change any of these in the CutOnce Control Center (type CUTONCE).");
    });

    [CommandMethod(Group, "CUTONCE-IMPACT-DEBUG", CommandFlags.Modal)]
    public void ImpactDebug()
    {
        ImpactService.Debug = !ImpactService.Debug;
        Acad.Msg("CutOnce Impact", "Debug tracing " + (ImpactService.Debug ? "ON" : "OFF"));
    }
}
