using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.AutoCAD.DatabaseServices;
using CutOnce.Core;

namespace CutOnce.Scanning;

/// <summary>
/// Quick counts for the Guard: object types in Model Space and every layout, read from
/// each ObjectId's class without opening the objects.
/// </summary>
internal static class ObjectCounter
{
    /// <summary>
    /// ObjectName -> count over Model Space and every paper-space layout: Civil 3D objects,
    /// block references and hatches, or every type when all = true (DUMPOBJECTS).
    /// </summary>
    public static Dictionary<string, long> SpaceCounts(Database db, bool all)
    {
        var counts = new Dictionary<string, long>(StringComparer.Ordinal);
        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            var bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
            foreach (ObjectId btrId in bt)
            {
                var btr = (BlockTableRecord)tr.GetObject(btrId, OpenMode.ForRead);
                if (!btr.IsLayout) continue;
                foreach (ObjectId id in btr)
                {
                    string name = id.ObjectClass?.Name ?? "";
                    if (all || GuardTexts.AtRiskOfExplode(name))
                    {
                        counts.TryGetValue(name, out long n);
                        counts[name] = n + 1;
                    }
                }
            }
            tr.Commit();
        }
        return counts;
    }

    /// <summary>Block references in Model Space that carry attributes.</summary>
    public static long AttributedBlockCount(Database db)
    {
        long n = 0;
        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            var ms = (BlockTableRecord)tr.GetObject(SymbolUtilityServices.GetBlockModelSpaceId(db), OpenMode.ForRead);
            foreach (ObjectId id in ms)
            {
                if (id.ObjectClass?.Name != "AcDbBlockReference") continue;
                if (tr.GetObject(id, OpenMode.ForRead) is BlockReference br && br.AttributeCollection.Count > 0) n++;
            }
            tr.Commit();
        }
        return n;
    }

    /// <summary>Counts by ObjectName of the given objects that EXPLODE would convert, plus attributed blocks.</summary>
    public static Dictionary<string, long> AtRisk(Database db, IEnumerable<ObjectId> ids, out long attributed)
    {
        var counts = new Dictionary<string, long>(StringComparer.Ordinal);
        attributed = 0;
        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            foreach (ObjectId id in ids)
            {
                if (id.IsNull || id.IsErased) continue;
                string name = id.ObjectClass?.Name ?? "";
                if (!GuardTexts.AtRiskOfExplode(name)) continue;
                counts.TryGetValue(name, out long n);
                counts[name] = n + 1;
                if (name == "AcDbBlockReference" && tr.GetObject(id, OpenMode.ForRead) is BlockReference br && br.AttributeCollection.Count > 0)
                    attributed++;
            }
            tr.Commit();
        }
        return counts;
    }

    /// <summary>Names of every xref definition.</summary>
    public static List<string> XrefNames(Database db)
    {
        var names = new List<string>();
        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            var bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
            foreach (ObjectId id in bt)
            {
                var btr = (BlockTableRecord)tr.GetObject(id, OpenMode.ForRead);
                if (btr.IsFromExternalReference) names.Add(btr.Name);
            }
            tr.Commit();
        }
        return names;
    }

    /// <summary>
    /// The xrefs that became ordinary blocks (bound). An xref that is simply gone was
    /// detached, which loses nothing, so it is not reported.
    /// </summary>
    public static List<string> BoundXrefs(Database db, IEnumerable<string> xrefsBefore)
    {
        var bound = new List<string>();
        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            var bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
            foreach (string name in xrefsBefore)
            {
                if (!bt.Has(name)) continue;
                var btr = (BlockTableRecord)tr.GetObject(bt[name], OpenMode.ForRead);
                if (!btr.IsFromExternalReference) bound.Add(name);
            }
            tr.Commit();
        }
        return bound;
    }

    /// <summary>Insertion points of the xref inserts in Model Space.</summary>
    public static List<KeyValuePair<string, double[]>> XrefInsertPoints(Database db)
    {
        var pts = new List<KeyValuePair<string, double[]>>();
        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            var ms = (BlockTableRecord)tr.GetObject(SymbolUtilityServices.GetBlockModelSpaceId(db), OpenMode.ForRead);
            foreach (ObjectId id in ms)
            {
                if (id.ObjectClass?.Name != "AcDbBlockReference") continue;
                if (!(tr.GetObject(id, OpenMode.ForRead) is BlockReference br)) continue;
                var def = (BlockTableRecord)tr.GetObject(br.BlockTableRecord, OpenMode.ForRead);
                if (def.IsFromExternalReference)
                    pts.Add(new KeyValuePair<string, double[]>(def.Name, new[] { br.Position.X, br.Position.Y, br.Position.Z }));
            }
            tr.Commit();
        }
        return pts;
    }

    /// <summary>True when any of the objects is an xref insert.</summary>
    public static bool AnyXref(Database db, IEnumerable<ObjectId> ids)
    {
        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            foreach (ObjectId id in ids)
            {
                if (id.IsNull || id.IsErased || id.ObjectClass?.Name != "AcDbBlockReference") continue;
                if (tr.GetObject(id, OpenMode.ForRead) is BlockReference br &&
                    tr.GetObject(br.BlockTableRecord, OpenMode.ForRead) is BlockTableRecord def && def.IsFromExternalReference)
                    return true;
            }
            tr.Commit();
        }
        return false;
    }

    /// <summary>True when every xref insert is where it was (same names, same points).</summary>
    public static bool SamePositions(List<KeyValuePair<string, double[]>> before, List<KeyValuePair<string, double[]>> after)
    {
        if (before.Count != after.Count) return false;
        foreach (var b in before)
        {
            bool match = after.Any(a => a.Key == b.Key && Math.Abs(a.Value[0] - b.Value[0]) < 1e-6 &&
                                        Math.Abs(a.Value[1] - b.Value[1]) < 1e-6 && Math.Abs(a.Value[2] - b.Value[2]) < 1e-6);
            if (!match) return false;
        }
        return true;
    }
}
