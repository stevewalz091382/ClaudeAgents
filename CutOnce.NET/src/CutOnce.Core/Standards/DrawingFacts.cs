using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace CutOnce.Core;

/// <summary>One xref definition as read from the block table.</summary>
public sealed class XrefDefinition
{
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
    /// <summary>"Attach", "Overlay" or "" when unknown.</summary>
    public string Type { get; set; } = "";
    /// <summary>"Loaded", "Unloaded" or "Not Found".</summary>
    public string Status { get; set; } = "";
    public bool Nested => Name.IndexOf('|') >= 0;
    /// <summary>The referenced drawing's INSUNITS, when known.</summary>
    public int? Units { get; set; }
    /// <summary>The referenced drawing's coordinate system, when it can be read.</summary>
    public string CoordinateSystem { get; set; }
}

/// <summary>An xref insert in Model Space.</summary>
public sealed class XrefInsert
{
    public string Name { get; set; } = "";
    public double[] Point { get; set; } = { 0, 0, 0 };
    public double RotationDegrees { get; set; }
    public double Scale { get; set; } = 1;

    public bool AtOrigin => Point.Length >= 3 && Math.Abs(Point[0]) < 1e-6 && Math.Abs(Point[1]) < 1e-6 && Math.Abs(Point[2]) < 1e-6;

    public static string PointText(double[] p) =>
        p == null ? "?" : string.Join(", ", p.Take(3).Select(v => v.ToString("F3", CultureInfo.InvariantCulture)));
}

/// <summary>One Xrefs.csv row: an xref definition and its first Model Space insert.</summary>
public sealed class XrefDetail
{
    public XrefDefinition Definition { get; set; }
    public int Instances { get; set; }
    public XrefInsert FirstInsert { get; set; }
    /// <summary>"" (no inserts), "Yes" or "No".</summary>
    public string AtOrigin { get; set; } = "";
}

/// <summary>What one pass over Model Space and the layouts found.</summary>
public sealed class SpaceScan
{
    /// <summary>ObjectName -> count: AECC* objects and block references (every type when HealthExtraCounts is set).</summary>
    public Dictionary<string, long> ObjectCounts { get; } = new Dictionary<string, long>(StringComparer.Ordinal);
    public long Hatches { get; set; }
    public long TextObjects { get; set; }
    public long ColorNotByLayer { get; set; }
    public long LinetypeNotByLayer { get; set; }
    public long ObjectsNotByLayer { get; set; }
    public List<XrefInsert> XrefInserts { get; } = new List<XrefInsert>();

    public void Bump(string objectName)
    {
        ObjectCounts.TryGetValue(objectName, out long n);
        ObjectCounts[objectName] = n + 1;
    }
}

/// <summary>Everything the standards check and Health.csv need for one drawing.</summary>
public sealed class DrawingFacts
{
    public SpaceScan Spaces { get; set; } = new SpaceScan();
    /// <summary>Null when "Include block definitions" is off (Health.csv: n/a).</summary>
    public long? BlockDefColorNotByLayer { get; set; }
    public long? BlockDefLinetypeNotByLayer { get; set; }
    public List<XrefDetail> Xrefs { get; } = new List<XrefDetail>();
    public int XrefsBroken { get; set; }
    public int XrefsUnloaded { get; set; }
    public List<XrefInsert> OffOrigin { get; } = new List<XrefInsert>();
    /// <summary>"" when none is assigned.</summary>
    public string CoordinateSystem { get; set; } = "";
    public int? InsUnits { get; set; }
    public ProjectStandard Project { get; set; }
    public List<string> CoordIssues { get; } = new List<string>();

    /// <summary>
    /// Pairs xref definitions with their Model Space inserts and works out the
    /// broken / unloaded / off-origin counts and every coordinate system and units problem.
    /// </summary>
    public static DrawingFacts Assemble(SpaceScan spaces, long[] blockDefCounts, IEnumerable<XrefDefinition> xrefs,
                                        string coordinateSystem, int? insUnits, ProjectStandard project, bool coordSysRequired)
    {
        var f = new DrawingFacts
        {
            Spaces = spaces ?? new SpaceScan(),
            BlockDefColorNotByLayer = blockDefCounts?[0],
            BlockDefLinetypeNotByLayer = blockDefCounts?[1],
            CoordinateSystem = coordinateSystem ?? "",
            InsUnits = insUnits,
            Project = project,
        };
        var defs = (xrefs ?? Enumerable.Empty<XrefDefinition>()).ToList();
        foreach (var xd in defs)
        {
            var mine = f.Spaces.XrefInserts.Where(i => string.Equals(i.Name, xd.Name, StringComparison.OrdinalIgnoreCase)).ToList();
            var off = mine.Where(i => !i.AtOrigin).ToList();
            f.OffOrigin.AddRange(off);
            f.Xrefs.Add(new XrefDetail
            {
                Definition = xd,
                Instances = mine.Count,
                FirstInsert = mine.FirstOrDefault(),
                AtOrigin = mine.Count == 0 ? "" : off.Count > 0 ? "No" : "Yes",
            });
            if (xd.Status == "Not Found") f.XrefsBroken++;
            else if (xd.Status == "Unloaded") f.XrefsUnloaded++;
        }
        f.CoordIssues.AddRange(CoordIssueLines(f.CoordinateSystem, insUnits, project, defs, coordSysRequired));
        return f;
    }

    /// <summary>Every coordinate system / units problem, as display lines.</summary>
    public static List<string> CoordIssueLines(string cs, int? insUnits, ProjectStandard project,
                                               IEnumerable<XrefDefinition> xrefs, bool coordSysRequired)
    {
        var outList = new List<string>();
        cs ??= "";
        string pcs = CutOnceConfig.NonBlank(project?.CoordinateSystem);
        int? pins = project?.InsUnits;
        if (cs.Length == 0 && coordSysRequired) outList.Add("No coordinate system is assigned to this drawing.");
        if (pcs != null && cs.Length > 0 && !string.Equals(cs, pcs, StringComparison.OrdinalIgnoreCase))
            outList.Add($"Coordinate system {cs} does not match the project's {pcs}.");
        if (pcs != null && cs.Length == 0) outList.Add($"The project uses {pcs}; this drawing has none.");
        if (insUnits == 0) outList.Add("Insertion units (INSUNITS) are Unitless.");
        if (pins != null && insUnits != null && pins != insUnits)
            outList.Add($"Insertion units are {Units.Name(insUnits)}; the project uses {Units.Name(pins)}.");
        foreach (var x in xrefs)
        {
            if (!string.IsNullOrWhiteSpace(x.CoordinateSystem) && !string.Equals(x.CoordinateSystem, cs, StringComparison.OrdinalIgnoreCase))
                outList.Add($"Xref {x.Name} uses {x.CoordinateSystem}; this drawing uses {(cs.Length == 0 ? "none" : cs)}.");
            if (x.Units > 0 && insUnits > 0 && x.Units != insUnits)
                outList.Add($"Xref {x.Name} is in {Units.Name(x.Units)}; this drawing is in {Units.Name(insUnits)}.");
        }
        return outList;
    }

    /// <summary>The standards and Civil 3D count columns of Health.csv.</summary>
    public void AddHealthColumns(IDictionary<string, object> row, IEnumerable<ExtraCount> extras)
    {
        foreach (var kv in HealthSchema.CivilCounts) row[kv.Key] = HealthSchema.Sum(Spaces.ObjectCounts, kv.Value);
        row["Hatches"] = Spaces.Hatches;
        row["TextObjects"] = Spaces.TextObjects;
        row["ColorNotByLayer"] = Spaces.ColorNotByLayer;
        row["LinetypeNotByLayer"] = Spaces.LinetypeNotByLayer;
        row["ObjectsNotByLayer"] = Spaces.ObjectsNotByLayer;
        row["BlockDefColorNotByLayer"] = BlockDefColorNotByLayer.HasValue ? (object)BlockDefColorNotByLayer.Value : "n/a";
        row["BlockDefLinetypeNotByLayer"] = BlockDefLinetypeNotByLayer.HasValue ? (object)BlockDefLinetypeNotByLayer.Value : "n/a";
        row["Xrefs"] = (long)Xrefs.Count;
        row["XrefsBroken"] = (long)XrefsBroken;
        row["XrefsUnloaded"] = (long)XrefsUnloaded;
        row["XrefsOffOrigin"] = (long)OffOrigin.Count;
        row["CoordinateSystem"] = CoordinateSystem;
        row["ProjectCoordinateSystem"] = Project?.CoordinateSystem ?? "";
        row["CoordUnitIssues"] = (long)CoordIssues.Count;
        foreach (var e in extras) row[e.Column] = HealthSchema.Sum(Spaces.ObjectCounts, e.Pattern);
    }

    /// <summary>The Xrefs.csv rows for one Health.csv row.</summary>
    public IEnumerable<string> XrefRows(string timestamp, string trigger, string user, string drawingPath, string drawingName)
    {
        foreach (var x in Xrefs)
        {
            var d = x.Definition;
            var p = x.FirstInsert?.Point;
            yield return Csv.Row(timestamp, trigger, user, drawingPath, drawingName,
                d.Name, d.Path, d.Type, d.Status, d.Nested ? "Yes" : "No", (long)x.Instances,
                p != null ? (object)p[0] : null, p != null ? (object)p[1] : null, p != null ? (object)p[2] : null,
                x.FirstInsert != null ? (object)x.FirstInsert.RotationDegrees : null,
                x.FirstInsert != null ? (object)x.FirstInsert.Scale : null,
                x.AtOrigin,
                d.Units.HasValue ? Units.Name(d.Units) : "",
                d.CoordinateSystem ?? "");
        }
    }
}
