using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using CutOnce.Core;
using CutOnce.Host;
using CutOnce.Scanning;

namespace CutOnce.Modules;

/// <summary>
/// Health.csv (one row per check, kept as history) and Xrefs.csv, the save-time
/// growth check with its one-click cleanup, and the open-time standards check.
///   Save    every save, plus the growth check
///   Open    when a saved drawing opens
///   Audit   CUTONCE-AUDIT / CUTONCE-AUDIT-FOLDER
///   Manual  CUTONCE-GUARD-CHECKNOW
/// </summary>
internal static class HealthService
{
    private static string _lastPath;
    private static Dictionary<string, object> _lastRow;

    private static SettingsService S => CutOnceApp.Settings;

    public static string HealthPath => CutOnceApp.Folders.LogFile("Health.csv");
    public static string XrefsPath => CutOnceApp.Folders.LogFile("Xrefs.csv");

    public static List<ExtraCount> Extras => HealthSchema.ExtraCounts(CutOnceApp.Config);
    public static List<string> Columns => HealthSchema.Columns(Extras);

    /// <summary>Every Health.csv value for one drawing. civDoc may be null (Styles and settings read n/a).</summary>
    public static Dictionary<string, object> Collect(Database db, string drawingPath, object civDoc, out DrawingFacts facts)
    {
        facts = DrawingScanner.Scan(db, drawingPath, S.IsOn("StdScanBlocks"), civDoc);
        var row = new Dictionary<string, object>(StringComparer.Ordinal);
        DrawingScanner.AddTableCounts(db, row);
        long? styles = civDoc != null ? Civil.CountStyles(civDoc) : null;
        row["Styles"] = styles.HasValue ? (object)styles.Value : "n/a";
        facts.AddHealthColumns(row, Extras);
        row["AngularUnits"] = (civDoc != null ? Civil.AngularUnits(civDoc) : null) ?? "n/a";
        row["InsUnits"] = facts.InsUnits.HasValue ? (object)(long)facts.InsUnits.Value : "n/a";
        try { row["DrawingScale"] = db.Dimscale; } catch (Exception) { row["DrawingScale"] = "n/a"; }
        return row;
    }

    /// <summary>The Health.csv row, and Xrefs.csv rows when that log is on (always when forced).</summary>
    public static void Write(string drawingPath, string drawingName, Dictionary<string, object> row, DrawingFacts facts, string trigger, bool force)
    {
        string ts = Csv.Timestamp(), user = CutOnceApp.Folders.UserName;
        var extras = Extras;
        CutOnceApp.Writer.AppendLine(HealthPath, HealthSchema.Header(extras),
            HealthSchema.Row(ts, trigger, user, drawingPath, drawingName, row, extras));
        if (force || S.LogOn("LogXrefs"))
            CutOnceApp.Writer.AppendLines(XrefsPath, HealthSchema.XrefHeader, facts.XrefRows(ts, trigger, user, drawingPath, drawingName));
    }

    private static void Remember(string path, Dictionary<string, object> row)
    {
        _lastPath = path;
        _lastRow = row;
    }

    /// <summary>The drawing's previous check: from memory, else its last Health.csv row.</summary>
    private static IReadOnlyDictionary<string, object> Previous(string path)
    {
        if (_lastRow != null && string.Equals(_lastPath, path, StringComparison.OrdinalIgnoreCase)) return _lastRow;
        return HealthSchema.PreviousRow(CsvLogWriter.ReadLines(HealthPath), Columns, path);
    }

    // ------------------------------------------------------------------
    // Save
    // ------------------------------------------------------------------

    public static void OnBeginSave(Document doc, string fileName)
    {
        // autosave writes .sv$ files: not a designer's save
        if (fileName != null && fileName.EndsWith(".sv$", StringComparison.OrdinalIgnoreCase)) return;
        Check(doc, "Save");
    }

    /// <summary>trigger "Save" (every save) or "Manual" (CUTONCE-GUARD-CHECKNOW: shows and writes whatever the settings say).</summary>
    public static void Check(Document doc, string trigger)
    {
        bool manual = trigger == "Manual";
        bool wantLog = manual || S.LogOn("LogHealthOnSave");
        bool wantGrowth = manual || S.IsOn("GuardGrowth");
        if (!wantLog && !wantGrowth) return;
        string path = Acad.DocPath(doc), name = Acad.DocName(doc);
        if (path.Length == 0)
        {
            Acad.Msg("CutOnce Health", "This drawing has not been saved yet - health check skipped.");
            return;
        }
        var row = Collect(doc.Database, path, Civil.DocumentFor(doc.Database), out var facts);
        IReadOnlyDictionary<string, object> prev = null;
        if (wantGrowth)
        {
            try { prev = Previous(path); } catch (Exception) { prev = null; }
        }
        if (wantLog)
        {
            try { Write(path, name, row, facts, trigger, manual); }
            catch (Exception ex) { Acad.Msg("CutOnce Health", "Could not write the log: " + ex.Message); }
        }
        Remember(path, row);
        if (!wantGrowth) return;
        var flags = GrowthCheck.Flags(prev, row, Extras, GrowthCheck.Threshold(CutOnceApp.Config));
        if (flags.Count > 0) ShowGrowth(doc, name, flags, manual);
    }

    /// <summary>Cleanup is queued to run after the save, so not while the drawing is closing.</summary>
    private static bool Closing()
    {
        string names = Acad.CmdNames;
        return names.Contains("CLOSE") || names.Contains("QUIT") || names.Contains("EXIT");
    }

    private static void ShowGrowth(Document doc, string drawingName, List<GrowthFlag> flags, bool manual)
    {
        string key = "GUARD_GROWTH|" + drawingName;
        CutOnceApp.LogEvent(doc, "SAVE-FLAG", string.Concat(flags.Select(f => f.EventText)));
        if (!manual && !S.IsDue(key)) return;

        bool offer = S.IsOn("GuardCleanup") && !Closing();
        var lines = new List<string> { "UNUSUAL GROWTH SINCE THE LAST CHECK" };
        lines.AddRange(flags.Select(f => "   " + f.DisplayLine));
        lines.Add("");
        lines.Add("Full history: " + HealthPath);
        lines.Add("");
        if (offer)
        {
            lines.Add("Clean up now... runs once this save finishes. It can remove unused registered");
            lines.Add("applications, scales, styles and anonymous blocks (PURGE, AUDIT); you choose");
            lines.Add("what runs first. (If it does not start, type CUTONCE-CLEANUP.)");
            lines.Add("");
        }
        lines.Add("Save a copy keeps the drawing as last saved in the backup folder before you go on.");

        var req = new NoticeRequest
        {
            Headline = "Unusual growth since the last check of " + drawingName,
            Kind = NoticeKind.Warning,
            Lines = lines,
            Links = new List<NoticeLink> { new NoticeLink("Learn More...", "GUARD_GROWTH") },
            OfferCopy = true,
            Footnote = manual
                ? "Turn any of these checks off in the CutOnce Control Center (type CUTONCE)."
                : S.FrequencyNote() + " Each check can be turned off there.",
        };
        if (offer) req.Actions.Add("Clean up now...");
        var r = Notices.Show(req, doc, "Before going ahead: save checks");
        if (!manual) S.MarkWarned(key);
        if (offer && r.IsAction(0)) Acad.Send(doc, "CUTONCE-CLEANUP ");
    }

    // ------------------------------------------------------------------
    // Open: one scan feeds both the standards check and the Health.csv row
    // ------------------------------------------------------------------

    public static void OnOpen(Document doc)
    {
        string path = Acad.DocPath(doc);
        if (path.Length == 0) return;
        CutOnceApp.Events.WriteOpened(path, Acad.DocName(doc));
        bool wantCheck = S.IsOn("StdCheckOnOpen");
        bool wantLog = S.LogOn("LogHealthOnOpen");
        if (!wantCheck && !wantLog) return;
        var row = Collect(doc.Database, path, Civil.DocumentFor(doc.Database), out var facts);
        if (wantLog) Write(path, Acad.DocName(doc), row, facts, "Open", false);
        // the state at open is the baseline for this session's first save
        Remember(path, row);
        if (wantCheck) StandardsService.ShowReport(doc, facts, Acad.DocName(doc), false);
    }

    // ------------------------------------------------------------------
    // Audit (other open drawings and whole folders)
    // ------------------------------------------------------------------

    /// <summary>Records one drawing with Trigger = Audit, even with logging off. False when never saved.</summary>
    public static bool AuditDocument(Document doc)
    {
        string path = Acad.DocPath(doc);
        if (path.Length == 0)
        {
            Acad.Write("\nSkipped (never saved): " + Acad.DocName(doc));
            return false;
        }
        using (doc.LockDocument())
        {
            var row = Collect(doc.Database, path, Civil.DocumentFor(doc.Database), out var facts);
            Write(path, Acad.DocName(doc), row, facts, "Audit", true);
        }
        return true;
    }

    /// <summary>Opens Health.csv in Excel with a bold, filtered, frozen header row; else in the default app.</summary>
    public static void OpenInExcel(string csvPath)
    {
        try
        {
            Type t = Type.GetTypeFromProgID("Excel.Application");
            if (t == null) throw new InvalidOperationException("Excel is not installed");
            object xl = Activator.CreateInstance(t);
            SafeSet(xl, "Visible", true);
            object wb = Invoke(SafeProps.Get(xl, "Workbooks"), "Open", csvPath);
            object ws = SafeProps.Get(wb, "ActiveSheet");
            object used = SafeProps.Get(ws, "UsedRange");
            object firstRow = Invoke(SafeProps.Get(ws, "Rows"), "Item", 1);
            SafeSet(SafeProps.Get(firstRow, "Font"), "Bold", true);
            Invoke(used, "AutoFilter");
            Invoke(SafeProps.Get(used, "Columns"), "AutoFit");
            object win = SafeProps.Get(xl, "ActiveWindow");
            SafeSet(win, "SplitRow", 1);
            SafeSet(win, "FreezePanes", true);
        }
        catch (Exception)
        {
            Acad.OpenFile(csvPath);
        }
    }

    private static object Invoke(object com, string method, params object[] args)
    {
        if (com == null) return null;
        try { return com.GetType().InvokeMember(method, System.Reflection.BindingFlags.InvokeMethod, null, com, args); }
        catch (Exception) { return null; }
    }

    private static void SafeSet(object com, string prop, object value)
    {
        if (com == null) return;
        try { com.GetType().InvokeMember(prop, System.Reflection.BindingFlags.SetProperty, null, com, new[] { value }); }
        catch (Exception) { /* cosmetic only */ }
    }
}
