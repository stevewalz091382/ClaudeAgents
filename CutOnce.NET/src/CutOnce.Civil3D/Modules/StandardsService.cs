using System.Linq;
using Autodesk.AutoCAD.ApplicationServices;
using CutOnce.Core;
using CutOnce.Host;

namespace CutOnce.Modules;

/// <summary>
/// The standards check: objects not ByLayer, xrefs broken / unloaded / not at 0,0,0,
/// coordinate system and units. Shown on open when something is wrong (or always, if
/// the designer chose that); CUTONCE-CHECK runs it any time and always shows it.
/// </summary>
internal static class StandardsService
{
    public static void ShowReport(Document doc, DrawingFacts facts, string drawingName, bool manual)
    {
        var settings = CutOnceApp.Settings;
        var report = StandardsReport.Build(facts, drawingName, manual, settings);
        Acad.Write("\n" + report.Headline + "\n" + string.Join("\n", report.Lines) + "\n");
        if (report.HasIssues) CutOnceApp.LogEvent(doc, "STANDARDS-OPEN", report.EventDetail);
        if (!(manual || report.HasIssues || settings.IsOn("StdAlwaysShow"))) return;
        Notices.Show(new NoticeRequest
        {
            Headline = report.Headline,
            Kind = report.HasIssues ? NoticeKind.Warning : NoticeKind.Ok,
            Lines = report.Lines,
            Links = report.Links,
        }, doc);
    }

    public static void CheckNow(Document doc)
    {
        string path = Acad.DocPath(doc);
        var facts = Scanning.DrawingScanner.Scan(doc.Database, path, CutOnceApp.Settings.IsOn("StdScanBlocks"), Civil.DocumentFor(doc.Database));
        ShowReport(doc, facts, Acad.DocName(doc), true);
    }

    public static string[] StatusKeys = { "StdCheckOnOpen", "StdByLayer", "StdXrefStatus", "StdXrefOrigin", "StdCoordUnits", "StdAlwaysShow", "StdScanBlocks" };

    public static string StatusLines() =>
        string.Concat(StatusKeys.Select(k => $"\n  {SettingsCatalog.Label(k)}: {(CutOnceApp.Settings.IsOn(k) ? "on" : "off")}" +
                                              (CutOnceApp.Settings.IsLocked(k) ? "  (set by CAD admin)" : "")));
}
