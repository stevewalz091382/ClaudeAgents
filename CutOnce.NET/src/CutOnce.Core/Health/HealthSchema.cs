using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace CutOnce.Core;

/// <summary>An administrator-defined Health.csv column ("HealthExtraCounts").</summary>
public sealed class ExtraCount
{
    public ExtraCount(string column, string pattern) { Column = column; Pattern = pattern; }
    public string Column { get; }
    /// <summary>Upper-case ObjectName wildcard, e.g. "ACDB*DIMENSION".</summary>
    public string Pattern { get; }
}

/// <summary>Health.csv and Xrefs.csv columns. Same names and order as the LISP edition.</summary>
public static class HealthSchema
{
    public static readonly string[] IdColumns = { "Timestamp", "Trigger", "User", "DrawingPath", "DrawingName" };

    public static readonly string[] MetricColumns =
    {
        "Layers", "Linetypes", "Blocks", "Layouts", "RegApps", "Styles",
        "Alignments", "Profiles", "ProfileViews", "Surfaces", "Corridors", "Assemblies",
        "PipeNetworks", "GravityPipes", "GravityStructures", "PressurePipeNetworks",
        "SectionViews", "Sections", "Hatches", "TextObjects",
        "ColorNotByLayer", "LinetypeNotByLayer", "ObjectsNotByLayer",
        "BlockDefColorNotByLayer", "BlockDefLinetypeNotByLayer",
        "Xrefs", "XrefsBroken", "XrefsUnloaded", "XrefsOffOrigin",
    };

    public static readonly string[] SettingColumns =
    {
        "AngularUnits", "InsUnits", "DrawingScale", "CoordinateSystem", "ProjectCoordinateSystem", "CoordUnitIssues",
    };

    /// <summary>Metrics compared with the previous check for unusual growth.</summary>
    public static readonly string[] GrowthWatch =
    {
        "Layers", "Linetypes", "Blocks", "Layouts", "Xrefs", "RegApps", "Styles",
        "Alignments", "Profiles", "ProfileViews", "Surfaces", "Corridors", "Assemblies",
        "PipeNetworks", "PressurePipeNetworks", "SectionViews", "Sections", "Hatches", "TextObjects",
    };

    /// <summary>Civil 3D object counts: column -> ObjectName wildcard (upper case).</summary>
    public static readonly IReadOnlyList<KeyValuePair<string, string>> CivilCounts = new List<KeyValuePair<string, string>>
    {
        new KeyValuePair<string, string>("Alignments", "AECCDBALIGNMENT"),
        new KeyValuePair<string, string>("Profiles", "AECCDBVALIGNMENT"),
        new KeyValuePair<string, string>("ProfileViews", "AECCDBGRAPHPROFILE"),
        new KeyValuePair<string, string>("Surfaces", "AECCDBSURFACETIN,AECCDBSURFACEGRID,AECCDBSURFACEVOLUME"),
        new KeyValuePair<string, string>("Corridors", "AECCDBCORRIDOR"),
        new KeyValuePair<string, string>("Assemblies", "AECCDBASSEMBLY"),
        new KeyValuePair<string, string>("PipeNetworks", "AECCDBNETWORK"),
        new KeyValuePair<string, string>("GravityPipes", "AECCDBPIPE"),
        new KeyValuePair<string, string>("GravityStructures", "AECCDBSTRUCTURE"),
        new KeyValuePair<string, string>("PressurePipeNetworks", "AECCDBPRESSUREPIPENETWORK,AECCDBPRESSURENETWORK"),
        new KeyValuePair<string, string>("SectionViews", "AECCDBSECTIONVIEW"),
        // surface sections are AeccDbSection, corridor sections AeccDbSectionCorridor
        new KeyValuePair<string, string>("Sections", "AECCDBSECTION,AECCDBSECTIONCORRIDOR"),
    };

    public const string XrefHeader =
        "Timestamp,Trigger,User,DrawingPath,DrawingName,XrefName,XrefPath,Type,Status," +
        "Nested,Instances,InsertX,InsertY,InsertZ,Rotation,Scale,AtOrigin,XrefInsUnits,XrefCoordinateSystem";

    /// <summary>Letters, digits and _ only.</summary>
    public static string ColumnName(string s) =>
        new string((s ?? "").Where(c => (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_').ToArray());

    /// <summary>The usable HealthExtraCounts entries, minus any that repeat a built-in column.</summary>
    public static List<ExtraCount> ExtraCounts(CutOnceConfig cfg)
    {
        var builtin = new HashSet<string>(IdColumns.Concat(MetricColumns).Concat(SettingColumns), StringComparer.OrdinalIgnoreCase);
        var outList = new List<ExtraCount>();
        foreach (var p in (cfg ?? CutOnceConfig.Empty).GetStringPairs("HealthExtraCounts"))
        {
            string name = ColumnName(p.Key);
            if (name.Length == 0 || string.IsNullOrWhiteSpace(p.Value) || builtin.Contains(name)) continue;
            if (outList.Any(e => e.Column == name)) continue;
            outList.Add(new ExtraCount(name, p.Value.ToUpperInvariant()));
        }
        return outList;
    }

    public static List<string> Columns(IEnumerable<ExtraCount> extras) =>
        IdColumns.Concat(MetricColumns).Concat(extras.Select(e => e.Column)).Concat(SettingColumns).ToList();

    public static string Header(IEnumerable<ExtraCount> extras) => string.Join(",", Columns(extras));

    /// <summary>Sum of ObjectName counts matching an upper-case wildcard.</summary>
    public static long Sum(IReadOnlyDictionary<string, long> objectCounts, string wildcard)
    {
        long total = 0;
        foreach (var kv in objectCounts)
            if (Wildcard.IsMatch(kv.Key.ToUpperInvariant(), wildcard.ToUpperInvariant())) total += kv.Value;
        return total;
    }

    /// <summary>One Health.csv row.</summary>
    public static string Row(string timestamp, string trigger, string user, string drawingPath, string drawingName,
                             IReadOnlyDictionary<string, object> facts, IEnumerable<ExtraCount> extras)
    {
        var values = new List<object> { timestamp, trigger, user, drawingPath, drawingName };
        foreach (string c in MetricColumns.Concat(extras.Select(e => e.Column)).Concat(SettingColumns))
            values.Add(facts.TryGetValue(c, out object v) ? v : null);
        return Csv.Row(values);
    }

    /// <summary>
    /// The last Health.csv row for a drawing, as column -> value (numbers as long),
    /// or null when the log has a different layout or no row for it.
    /// </summary>
    public static Dictionary<string, object> PreviousRow(IList<string> lines, IList<string> columns, string drawingPath)
    {
        if (lines == null || lines.Count == 0 || lines[0] != string.Join(",", columns)) return null;
        int pidx = columns.IndexOf("DrawingPath");
        List<string> last = null;
        for (int i = 1; i < lines.Count; i++)
        {
            var fields = Csv.Split(lines[i]);
            if (fields.Count > pidx && fields[pidx] == drawingPath) last = fields;
        }
        if (last == null) return null;
        var row = new Dictionary<string, object>(StringComparer.Ordinal);
        for (int i = 0; i < columns.Count && i < last.Count; i++)
            row[columns[i]] = LeadingNumber(last[i]);
        return row;
    }

    /// <summary>Like atoi on a field starting with a digit: "12" -> 12L, "n/a" stays text.</summary>
    private static object LeadingNumber(string v)
    {
        if (string.IsNullOrEmpty(v) || !char.IsDigit(v[0])) return v;
        int end = 0;
        while (end < v.Length && char.IsDigit(v[end])) end++;
        return long.TryParse(v.Substring(0, end), NumberStyles.None, CultureInfo.InvariantCulture, out long n) ? (object)n : v;
    }
}
