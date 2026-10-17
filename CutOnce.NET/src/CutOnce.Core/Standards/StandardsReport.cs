using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace CutOnce.Core;

/// <summary>The standards check result, as dialog text, Learn More buttons and an Events.csv line.</summary>
public sealed class StandardsReport
{
    public bool HasIssues { get; private set; }
    public string Headline { get; private set; }
    public List<string> Lines { get; } = new List<string>();
    public List<NoticeLink> Links { get; } = new List<NoticeLink>();
    public string EventDetail { get; private set; }

    private static string N(long v) => v.ToString(CultureInfo.InvariantCulture);
    private static string N(long? v) => v.HasValue ? N(v.Value) : "n/a";

    /// <summary>
    /// manual = CUTONCE-CHECK: every section is shown. Otherwise only the sections the
    /// designer switched on in CUTONCE.
    /// </summary>
    public static StandardsReport Build(DrawingFacts f, string drawingName, bool manual, SettingsService settings)
    {
        bool wantBL = manual || settings.IsOn("StdByLayer");
        bool wantXS = manual || settings.IsOn("StdXrefStatus");
        bool wantXO = manual || settings.IsOn("StdXrefOrigin");
        bool wantCU = manual || settings.IsOn("StdCoordUnits");
        var s = f.Spaces;

        bool issBL = wantBL && (s.ObjectsNotByLayer > 0 ||
                                (f.BlockDefColorNotByLayer.HasValue && f.BlockDefColorNotByLayer + (f.BlockDefLinetypeNotByLayer ?? 0) > 0));
        bool issXS = wantXS && f.XrefsBroken + f.XrefsUnloaded > 0;
        bool issXO = wantXO && f.OffOrigin.Count > 0;
        bool issCU = wantCU && f.CoordIssues.Count > 0;

        var r = new StandardsReport { HasIssues = issBL || issXS || issXO || issCU };
        r.Links.Add(new NoticeLink("Reading this check...", "STANDARDS_OPEN"));
        if (issBL) r.Links.Add(new NoticeLink("Not ByLayer...", "STD_BYLAYER"));
        if (issXS) r.Links.Add(new NoticeLink("Broken / unloaded xrefs...", "STD_XREF_STATUS"));
        if (issXO) r.Links.Add(new NoticeLink("Xrefs not at 0,0,0...", "STD_XREF_ORIGIN"));
        if (issCU) r.Links.Add(new NoticeLink("Coordinates / units...", "STD_COORD_UNITS"));

        r.Headline = (r.HasIssues ? "Standards check found problems in " : "Standards check passed: ") + drawingName;
        var L = r.Lines;

        if (wantBL)
        {
            L.Add("OBJECTS NOT BYLAYER (model space and layouts)");
            L.Add("   Color not ByLayer:      " + N(s.ColorNotByLayer));
            L.Add("   Linetype not ByLayer:   " + N(s.LinetypeNotByLayer));
            L.Add("   Objects with either:    " + N(s.ObjectsNotByLayer));
            if (f.BlockDefColorNotByLayer.HasValue)
            {
                L.Add("");
                L.Add("INSIDE BLOCK DEFINITIONS");
                L.Add("   Color not ByLayer:      " + N(f.BlockDefColorNotByLayer));
                L.Add("   Linetype not ByLayer:   " + N(f.BlockDefLinetypeNotByLayer));
            }
        }
        if (wantXS || wantXO)
        {
            if (L.Count > 0) L.Add("");
            L.Add("XREFS");
            L.Add("   Total xrefs:            " + N(f.Xrefs.Count));
            if (wantXS)
            {
                L.Add("   Broken (not found):     " + N(f.XrefsBroken));
                L.Add("   Unloaded:               " + N(f.XrefsUnloaded));
                foreach (var x in f.Xrefs.Where(x => x.Definition.Status != "Loaded"))
                    L.Add("      - " + x.Definition.Status + ": " + x.Definition.Name + "  " + x.Definition.Path);
            }
            if (wantXO)
            {
                L.Add("   Inserts not at 0,0,0:   " + N(f.OffOrigin.Count));
                foreach (var p in f.OffOrigin)
                    L.Add("      - " + p.Name + " at " + XrefInsert.PointText(p.Point));
            }
        }
        if (wantCU)
        {
            if (L.Count > 0) L.Add("");
            L.Add("COORDINATE SYSTEM AND UNITS");
            L.Add("   Coordinate system:      " + (CutOnceConfig.NonBlank(f.CoordinateSystem) ?? "(none)"));
            L.Add("   Insertion units:        " + Units.Name(f.InsUnits));
            if (f.Project?.Source != null) L.Add("   Project standard from:  " + f.Project.Source);
            foreach (string issue in f.CoordIssues) L.Add("      - " + issue);
        }
        L.Add("");
        L.Add("Choose what is checked in the CutOnce Control Center (type CUTONCE).");

        if (r.HasIssues)
            r.EventDetail = "not ByLayer " + N(s.ObjectsNotByLayer) +
                            "  broken xrefs " + N(f.XrefsBroken) +
                            "  unloaded xrefs " + N(f.XrefsUnloaded) +
                            "  xrefs off 0,0,0 " + N(f.OffOrigin.Count) +
                            "  coordinate/unit issues " + N(f.CoordIssues.Count);
        return r;
    }
}
