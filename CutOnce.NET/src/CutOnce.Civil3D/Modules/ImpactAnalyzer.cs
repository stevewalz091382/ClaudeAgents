using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.AutoCAD.DatabaseServices;
using CutOnce.Core;
using CutOnce.Host;

namespace CutOnce.Modules;

/// <summary>
/// What depends on an alignment, surface or profile: profiles, sample line groups,
/// corridors, view frames, profile views, nearby pipe network parts and grading groups.
/// Reads Civil 3D objects by reflection (see <see cref="Civil"/>), inside one read-only
/// transaction for the whole analysis; Model Space scans are cached per analysis.
/// </summary>
internal sealed class ImpactAnalyzer : IDisposable
{
    private readonly Database _db;
    private readonly Transaction _tr;
    private readonly object _civDoc;
    private readonly Dictionary<string, List<ObjectId>> _scanCache = new Dictionary<string, List<ObjectId>>(StringComparer.Ordinal);

    public ImpactAnalyzer(Database db)
    {
        _db = db;
        _tr = db.TransactionManager.StartOpenCloseTransaction();
        _civDoc = Civil.DocumentFor(db);
    }

    public void Dispose()
    {
        try { _tr.Commit(); } catch (Exception) { /* read-only */ }
        _tr.Dispose();
    }

    public bool CivilConnected => _civDoc != null;

    /// <summary>"alignment", "profile", "surface" or null, from the object's class.</summary>
    public static string KindOf(ObjectId id)
    {
        string c = id.IsNull ? "" : id.ObjectClass?.Name ?? "";
        if (c == "AeccDbVAlignment") return "profile";
        if (c == "AeccDbAlignment") return "alignment";
        if (c.StartsWith("AeccDbSurface", StringComparison.Ordinal)) return "surface";
        return null;
    }

    private DBObject Open(ObjectId id) => Civil.Open(id, _tr);

    private string NameOf(ObjectId id) => Civil.Name(Open(id)) ?? "<unnamed>";

    private string NameOf(object obj) => Civil.Name(obj) ?? "<unnamed>";

    private List<ObjectId> ScanModelSpace(string classWildcard)
    {
        if (_scanCache.TryGetValue(classWildcard, out var hit)) return hit;
        var outList = new List<ObjectId>();
        try
        {
            var ms = (BlockTableRecord)_tr.GetObject(SymbolUtilityServices.GetBlockModelSpaceId(_db), OpenMode.ForRead);
            foreach (ObjectId id in ms)
                if (Wildcard.IsMatch(id.ObjectClass?.Name ?? "", classWildcard, true)) outList.Add(id);
        }
        catch (Exception)
        {
            // keep what was found
        }
        _scanCache[classWildcard] = outList;
        return outList;
    }

    private static List<string> Section(string title, IEnumerable<string> names)
    {
        var list = names.ToList();
        if (list.Count == 0) return new List<string>();
        var lines = new List<string> { "", title };
        lines.AddRange(list.Select(n => "  - " + n));
        return lines;
    }

    // ------------------------------------------------------------------
    // Relationships
    // ------------------------------------------------------------------

    private IEnumerable<ObjectId> CorridorsWhereBaseline(Func<object, bool> test)
    {
        foreach (ObjectId cid in Civil.CorridorIds(_civDoc))
        {
            object corridor = Open(cid);
            if (SafeProps.Items(SafeProps.Get(corridor, "Baselines")).Any(test)) yield return cid;
        }
    }

    private bool ProfileUsesSurface(object profile, ObjectId surfaceId)
    {
        ObjectId sid = SafeProps.GetId(profile, "SurfaceId");
        if (!sid.IsNull) return sid == surfaceId;
        // older releases: through the COM object, compared by handle
        object com = SafeProps.Get(profile, "AcadObject");
        object surf = SafeProps.Get(com, "Surface") ?? SafeProps.Get(com, "SurfaceEntity");
        string handle = SafeProps.GetString(surf, "Handle");
        return handle != null && string.Equals(handle, surfaceId.Handle.ToString(), StringComparison.OrdinalIgnoreCase);
    }

    private static bool Overlaps(Extents3d a, Extents3d b) =>
        !(a.MinPoint.X > b.MaxPoint.X || b.MinPoint.X > a.MaxPoint.X ||
          a.MinPoint.Y > b.MaxPoint.Y || b.MinPoint.Y > a.MaxPoint.Y);

    private Extents3d? Bounds(ObjectId id)
    {
        try { return Open(id) is Entity e ? e.GeometricExtents : (Extents3d?)null; }
        catch (Exception) { return null; }
    }

    // ------------------------------------------------------------------
    // Analysis
    // ------------------------------------------------------------------

    public List<string> AnalyzeAlignment(ObjectId algId)
    {
        object alg = Open(algId);
        var report = new List<string> { "ALIGNMENT: " + NameOf(alg) };
        report.AddRange(Section("PROFILES on this alignment:",
            SafeProps.Ids(SafeProps.Call(alg, "GetProfileIds")).Select(NameOf)));

        var groups = SafeProps.Ids(SafeProps.Call(alg, "GetSampleLineGroupIds"));
        if (groups.Count > 0)
        {
            report.Add("");
            report.Add("SAMPLE LINE GROUPS on this alignment:");
            foreach (ObjectId g in groups)
            {
                object grp = Open(g);
                int lines = SafeProps.Ids(SafeProps.Call(grp, "GetSampleLineIds")).Count;
                report.Add($"  - {NameOf(grp)} ({lines} sample line(s))");
            }
        }

        report.AddRange(Section("CORRIDORS using this alignment as a baseline:",
            CorridorsWhereBaseline(b => SafeProps.GetId(b, "AlignmentId") == algId).Select(NameOf)));

        report.AddRange(Section("SHEETS: view frames based on this alignment:",
            ScanModelSpace("*ViewFrame*").Where(v => SafeProps.GetId(Open(v), "AlignmentId") == algId).Select(NameOf)));

        Extents3d? box = Bounds(algId);
        if (box.HasValue)
        {
            var near = ScanModelSpace("*Pipe*").Concat(ScanModelSpace("*Structure*"))
                .Where(p => Bounds(p) is Extents3d pb && Overlaps(box.Value, pb)).Select(NameOf).ToList();
            if (near.Count > 0)
            {
                report.Add("");
                report.Add("PIPE NETWORK PARTS near this alignment (bounding-box check only, verify):");
                report.AddRange(near.Select(n => "  - " + n));
            }
        }
        return report;
    }

    public List<string> AnalyzeSurface(ObjectId surfaceId)
    {
        var report = new List<string> { "SURFACE: " + NameOf(surfaceId) };
        foreach (ObjectId a in Civil.AlignmentIds(_civDoc, _tr))
        {
            foreach (ObjectId p in SafeProps.Ids(SafeProps.Call(Open(a), "GetProfileIds")))
            {
                if (!ProfileUsesSurface(Open(p), surfaceId)) continue;
                report.Add("");
                report.Add($"PROFILE \"{NameOf(p)}\" on alignment \"{NameOf(a)}\" is derived from this surface.");
                foreach (ObjectId c in CorridorsWhereBaseline(b => SafeProps.GetId(b, "ProfileId") == p))
                    report.Add($"  -> CORRIDOR \"{NameOf(c)}\" uses that profile as a baseline profile.");
            }
        }
        foreach (ObjectId site in Civil.SiteIds(_civDoc))
        {
            foreach (ObjectId gg in SafeProps.Ids(SafeProps.Call(Open(site), "GetGradingGroupIds")))
            {
                object group = Open(gg);
                ObjectId gs = SafeProps.GetId(group, "SurfaceId");
                if (gs.IsNull) gs = SafeProps.GetId(group, "BaseSurfaceId");
                if (gs == surfaceId)
                {
                    report.Add("");
                    report.Add($"GRADING GROUP \"{NameOf(group)}\" references this surface.");
                }
            }
        }
        return report;
    }

    public List<string> AnalyzeProfile(ObjectId profileId)
    {
        object prof = Open(profileId);
        ObjectId parent = SafeProps.GetId(prof, "AlignmentId");
        var report = new List<string>
        {
            "PROFILE: " + NameOf(prof) + (parent.IsNull ? "" : $" (on alignment \"{NameOf(parent)}\")"),
        };
        report.AddRange(Section("CORRIDORS using this profile as a baseline:",
            CorridorsWhereBaseline(b => SafeProps.GetId(b, "ProfileId") == profileId).Select(NameOf)));
        if (!parent.IsNull)
            report.AddRange(Section("PROFILE VIEWS on the same alignment (likely display this profile):",
                ScanModelSpace("AeccDbGraphProfile").Where(v => SafeProps.GetId(Open(v), "AlignmentId") == parent).Select(NameOf)));
        return report;
    }

    public List<string> AnalyzeAny(ObjectId id)
    {
        switch (KindOf(id))
        {
            case "alignment": return AnalyzeAlignment(id);
            case "surface": return AnalyzeSurface(id);
            case "profile": return AnalyzeProfile(id);
            default: return new List<string>();
        }
    }

    /// <summary>Every alignment, profile or surface among the objects.</summary>
    public List<string> AnalyzeIds(IEnumerable<ObjectId> ids)
    {
        var lines = new List<string>();
        foreach (ObjectId id in ids.Where(i => !i.IsNull && !i.IsErased && KindOf(i) != null))
        {
            if (lines.Count > 0) lines.Add("");
            lines.AddRange(AnalyzeAny(id));
        }
        return lines;
    }

    /// <summary>Profile commands are usually started with the parent alignment selected: report its profiles.</summary>
    public List<string> AnalyzeForProfileCommand(IEnumerable<ObjectId> ids)
    {
        var lines = new List<string>();
        foreach (ObjectId id in ids)
        {
            string kind = KindOf(id);
            if (kind == "profile") lines.AddRange(AnalyzeProfile(id));
            else if (kind == "alignment")
                foreach (ObjectId p in SafeProps.Ids(SafeProps.Call(Open(id), "GetProfileIds")))
                {
                    lines.AddRange(AnalyzeProfile(p));
                    lines.Add("");
                }
        }
        return lines;
    }

    /// <summary>Whole-drawing fallback for a command that picks its target after it starts.</summary>
    public List<string> AnalyzeAll(string kind)
    {
        var lines = new List<string>();
        if (kind == "surface")
            foreach (ObjectId s in Civil.SurfaceIds(_civDoc)) { lines.AddRange(AnalyzeSurface(s)); lines.Add(""); }
        else if (kind == "alignment")
            foreach (ObjectId a in Civil.AlignmentIds(_civDoc, _tr)) { lines.AddRange(AnalyzeAlignment(a)); lines.Add(""); }
        else if (kind == "profile")
            foreach (ObjectId a in Civil.AlignmentIds(_civDoc, _tr))
                foreach (ObjectId p in SafeProps.Ids(SafeProps.Call(Open(a), "GetProfileIds"))) { lines.AddRange(AnalyzeProfile(p)); lines.Add(""); }
        return lines;
    }
}
