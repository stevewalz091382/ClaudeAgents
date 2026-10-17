using System;
using System.Collections.Generic;
using System.Linq;

namespace CutOnce.Core;

/// <summary>What an EXPLODE (or a batch of them, e.g. BURST) removed or converted.</summary>
public sealed class ExplodeReport
{
    public sealed class Loss
    {
        public string ObjectName { get; set; }
        public long Before { get; set; }
        public long After { get; set; }
        public string Friendly => GuardTexts.FriendlyName(ObjectName);
    }

    public List<Loss> Lost { get; } = new List<Loss>();
    public long AttributedConverted { get; private set; }
    public bool CivilLost => Lost.Any(x => x.ObjectName.StartsWith("AECC", StringComparison.OrdinalIgnoreCase));
    public bool HatchLost => Lost.Any(x => x.ObjectName == "AcDbHatch");
    public bool Any => Lost.Count > 0 || AttributedConverted > 0;

    /// <summary>GUARD_EXPLODE when Civil 3D objects were lost (offers Save a copy), else GUARD_EXPLODE_BLOCKS.</summary>
    public string WarningKey => CivilLost ? "GUARD_EXPLODE" : "GUARD_EXPLODE_BLOCKS";

    public static ExplodeReport Compare(IReadOnlyDictionary<string, long> before, IReadOnlyDictionary<string, long> after,
                                        long attribBefore, long attribAfter)
    {
        var r = new ExplodeReport();
        foreach (var kv in before)
        {
            after.TryGetValue(kv.Key, out long a);
            if (a < kv.Value) r.Lost.Add(new Loss { ObjectName = kv.Key, Before = kv.Value, After = a });
        }
        r.AttributedConverted = attribAfter < attribBefore ? attribBefore - attribAfter : 0;
        return r;
    }

    public string LossEvent => string.Concat(Lost.Select(x => $"{x.Friendly} {x.Before}->{x.After}  "));

    /// <summary>The warning shown after the command (type U / Undo to reverse it).</summary>
    public List<string> Lines(long attribBefore, long attribAfter)
    {
        var L = new List<string> { "CutOnce Guard: EXPLODE just removed or converted objects.", "" };
        foreach (var x in Lost) L.Add($"  {x.Friendly}:  {x.Before} -> {x.After} (down {x.Before - x.After})");
        if (AttributedConverted > 0) L.Add($"  Attributed blocks:  {AttributedConverted} converted to plain text");
        L.Add("");
        if (Lost.Count > 0) { L.Add("Exploded objects are now plain geometry and have lost their design intent."); L.Add(""); }
        if (HatchLost)
        {
            L.Add("An exploded hatch becomes many separate lines: it loses its boundary");
            L.Add("association and area, can no longer be edited as a pattern, and");
            L.Add("adds to file size.");
            L.Add("");
        }
        if (AttributedConverted > 0)
        {
            L.Add("The attribute data used for tags, schedules and data extraction is gone;");
            L.Add("only the displayed text remains.");
            L.Add("");
        }
        L.Add("If this wasn't intentional, undo it now.");
        return L;
    }

    public List<NoticeLink> Links()
    {
        var links = new List<NoticeLink>();
        if (Lost.Count > 0) links.Add(new NoticeLink("Learn More...", "GUARD_EXPLODE"));
        if (AttributedConverted > 0) links.Add(new NoticeLink(Lost.Count > 0 ? "Attributes..." : "Learn More...", "GUARD_ATTRIB"));
        return links;
    }
}

/// <summary>The words of every Guard warning, kept in one place.</summary>
public static class GuardTexts
{
    public static string FriendlyName(string raw)
    {
        switch (raw)
        {
            case "AcDbBlockReference": return "Block";
            case "AcDbHatch": return "Hatch";
            case "AeccDbAlignment": return "Alignment";
            case "AeccDbVAlignment": return "Profile";
            case "AeccDbGraphProfile": return "Profile View";
            case "AeccDbSurfaceTin": return "Surface (TIN)";
            case "AeccDbSurfaceGrid": return "Surface (Grid)";
            case "AeccDbSurfaceVolume": return "Surface (Volume)";
            case "AeccDbCorridor": return "Corridor";
            case "AeccDbNetwork": return "Gravity Pipe Network";
            case "AeccDbPipe": return "Gravity Pipe";
            case "AeccDbStructure": return "Gravity Structure";
            case "AeccDbPressurePipeNetwork": return "Pressure Pipe Network";
            case "AeccDbPressurePipe": return "Pressure Pipe";
            case "AeccDbPressureFitting": return "Pressure Fitting";
            case "AeccDbPressureAppurtenance": return "Pressure Appurtenance";
            case "AeccDbParcel": return "Parcel";
            case "AeccDbSampleLine": return "Sample Line";
            case "AeccDbSampleLineGroup": return "Sample Line Group";
            case "AeccDbSectionView": return "Section View";
            case "AeccDbAssembly": return "Assembly";
            case "AeccDbFeatureLine": return "Feature Line";
            default: return raw;
        }
    }

    /// <summary>Objects EXPLODE converts: Civil 3D objects, block references and hatches.</summary>
    public static bool AtRiskOfExplode(string objectName) =>
        objectName == "AcDbBlockReference" || objectName == "AcDbHatch" ||
        objectName.StartsWith("AECC", StringComparison.OrdinalIgnoreCase);

    /// <summary>Shown before EXPLODE runs, when the objects were selected first.</summary>
    public static List<string> ExplodeBefore(IReadOnlyDictionary<string, long> selected, long attributed)
    {
        var L = new List<string> { "CutOnce Guard: EXPLODE is about to convert the selected objects.", "" };
        foreach (var kv in selected.OrderBy(k => GuardTexts.FriendlyName(k.Key)))
            L.Add($"  {FriendlyName(kv.Key)}:  {kv.Value}");
        if (attributed > 0) L.Add($"  Attributed blocks:  {attributed} (attribute data is lost)");
        L.Add("");
        if (selected.Keys.Any(k => k.StartsWith("AECC", StringComparison.OrdinalIgnoreCase)))
        {
            L.Add("Exploded Civil 3D objects become plain geometry: labels, styles, design");
            L.Add("data and every object that depends on them are lost.");
            L.Add("");
        }
        if (selected.ContainsKey("AcDbHatch"))
        {
            L.Add("An exploded hatch becomes many separate lines and adds to file size.");
            L.Add("");
        }
        L.Add("Stop EXPLODE now if this isn't what you meant.");
        return L;
    }

    public static List<string> XrefBind(IEnumerable<string> bound)
    {
        var L = new List<string> { "CutOnce Guard: an xref was just bound into this drawing:", "" };
        L.AddRange(bound.Select(n => "  - " + n));
        L.Add("");
        L.Add("Binding copies all of that drawing's layers, styles and blocks in");
        L.Add("permanently (usually with a $0$ suffix), which commonly causes duplicate");
        L.Add("styles and file-size growth.");
        L.Add("");
        L.Add("To keep it live, Overlay/Attach with a Data Shortcut is usually the better choice.");
        return L;
    }

    public static readonly string[] XrefMoved =
    {
        "CutOnce Guard: an xref's position just changed (moved or copied).",
        "",
        "Moving or copying an xref shifts everything in it out of alignment",
        "with shared coordinates and data shortcuts.",
        "",
        "If this wasn't intentional, undo it now.",
    };

    public static readonly string[] RefEdit =
    {
        "CutOnce Guard: starting REFEDIT (in-place reference edit).",
        "",
        "Changes made now can be saved straight back into the referenced drawing",
        "when you close the edit, which affects every drawing that references it.",
        "",
        "Only choose \"Save back to reference\" (on REFCLOSE) if that is intended.",
    };

    public static readonly string[] RefClose =
    {
        "CutOnce Guard: closing the in-place reference edit.",
        "",
        "Choosing Save writes your changes into the external drawing now, for",
        "everyone who references it. Choose Discard if you were only looking.",
    };

    public static readonly string[] Promote =
    {
        "CutOnce Guard: you are promoting a data shortcut reference.",
        "",
        "Promoting a data-shortcut reference makes an independent copy in this",
        "drawing and breaks its link to the source; later changes to the source",
        "will no longer reach this copy.",
    };

    public static readonly string[] TextTip =
    {
        "CutOnce Guard tip:",
        "",
        "Plain TEXT/MTEXT for stations, elevations or offsets won't update if",
        "the design changes, and won't feed label-based schedules or QA/QC.",
        "",
        "If a Civil 3D label style covers what you're about to type, it stays",
        "live and matches your drawing standard.",
    };

    public static readonly string[] SurfaceEditWarning =
    {
        "MANUAL SURFACE EDITS",
        "Manual surface edits (like Delete Line or Add Point) force a",
        "permanent deviation from the source design data. Because Civil 3D",
        "rebuilds surfaces from their definition in order, these manual changes",
        "can shift or disappear when new data is added. Where possible, change",
        "the source data (feature lines, breaklines, boundaries) instead.",
        "",
    };

    /// <summary>Warnings without "Save a copy": advisories and edits that are quick to undo.</summary>
    public static readonly string[] NoCopyWarnings =
    {
        "GUARD_TEXT", "GUARD_XREF_MOVED", "GUARD_EXPLODE_BLOCKS", "GUARD_ATTRIB", "GUARD_REFEDIT", "GUARD_REFCLOSE",
    };

    /// <summary>"GUARD_GROWTH|C-101.dwg" -> "GUARD_GROWTH"</summary>
    public static string WarningName(string key)
    {
        int i = key.IndexOf('|');
        return i >= 0 ? key.Substring(0, i) : key;
    }

    /// <summary>"GUARD_TEXT:MTEXT" / "GUARD_GROWTH|A.dwg" -> "GUARD_TEXT" / "GUARD_GROWTH"</summary>
    public static string WarningBase(string key)
    {
        string name = WarningName(key);
        int i = name.IndexOf(':');
        return i >= 0 ? name.Substring(0, i) : name;
    }

    public static bool CopyOffered(string key) => Array.IndexOf(NoCopyWarnings, WarningBase(key)) < 0;
}
