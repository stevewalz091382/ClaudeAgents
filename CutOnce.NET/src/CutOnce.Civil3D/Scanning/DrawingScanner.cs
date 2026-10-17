using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Autodesk.AutoCAD.DatabaseServices;
using CutOnce.Core;
using CutOnce.Host;

namespace CutOnce.Scanning;

/// <summary>
/// One pass over Model Space and every layout (plus the block definitions when asked)
/// that feeds both the standards check and the Health.csv row, so a drawing is only
/// read once per check.
/// </summary>
internal static class DrawingScanner
{
    /// <param name="db">The drawing's database (any open drawing, not only the active one).</param>
    /// <param name="drawingPath">The drawing's file path ("" if never saved).</param>
    /// <param name="civDoc">The Civil 3D document, or null (coordinate system then from CGEOCS / geo data).</param>
    public static DrawingFacts Scan(Database db, string drawingPath, bool scanBlocks, object civDoc)
    {
        var extras = HealthSchema.ExtraCounts(CutOnceApp.Config);
        bool countAll = extras.Count > 0;
        SpaceScan spaces;
        long[] blockDefs = null;
        List<XrefDefinition> xrefs;

        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            var bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
            var records = new List<BlockTableRecord>();
            foreach (ObjectId id in bt) records.Add((BlockTableRecord)tr.GetObject(id, OpenMode.ForRead));

            var xrefDefIds = new HashSet<ObjectId>(records.Where(r => r.IsFromExternalReference).Select(r => r.ObjectId));
            spaces = new SpaceScan();
            foreach (var btr in records.Where(r => r.IsLayout))
            {
                bool isModel = string.Equals(btr.Name, BlockTableRecord.ModelSpace, StringComparison.OrdinalIgnoreCase);
                foreach (ObjectId id in btr) Tally(tr, id, isModel, countAll, xrefDefIds, spaces);
            }

            if (scanBlocks)
            {
                long col = 0, lt = 0;
                foreach (var btr in records)
                {
                    if (btr.Name.StartsWith("*", StringComparison.Ordinal) || btr.Name.IndexOf('|') >= 0 ||
                        btr.IsLayout || btr.IsFromExternalReference || btr.IsDependent) continue;
                    foreach (ObjectId id in btr)
                    {
                        if (!(SafeOpen(tr, id) is Entity ent)) continue;
                        if (BadColor(ent)) col++;
                        if (BadLinetype(ent)) lt++;
                    }
                }
                blockDefs = new[] { col, lt };
            }

            string prefix = WinPath.Directory(drawingPath);
            xrefs = records.Where(r => r.IsFromExternalReference).Select(r => XrefDef(r, prefix, db)).ToList();
            tr.Commit();
        }

        string cs = DrawingCoordinateSystem(db, civDoc);
        int? insUnits = null;
        try { insUnits = (int)db.Insunits; } catch (Exception) { /* unreadable */ }
        var project = CutOnceApp.Projects.Resolve(drawingPath);
        return DrawingFacts.Assemble(spaces, blockDefs, xrefs, cs, insUnits, project, CutOnceApp.Config.GetBool("CoordSysRequired", true));
    }

    private static DBObject SafeOpen(Transaction tr, ObjectId id)
    {
        try { return tr.GetObject(id, OpenMode.ForRead, false); }
        catch (Exception) { return null; }
    }

    /// <summary>ByBlock, a colour number or a true colour all count as not ByLayer.</summary>
    private static bool BadColor(Entity ent)
    {
        try { return !ent.Color.IsByLayer; } catch (Exception) { return false; }
    }

    private static bool BadLinetype(Entity ent)
    {
        try { return !string.Equals(ent.Linetype, "ByLayer", StringComparison.OrdinalIgnoreCase); }
        catch (Exception) { return false; }
    }

    private static void Tally(Transaction tr, ObjectId id, bool isModel, bool countAll, HashSet<ObjectId> xrefDefIds, SpaceScan s)
    {
        string name = id.ObjectClass?.Name ?? "";
        if (countAll || name == "AcDbBlockReference" || name.StartsWith("AECC", StringComparison.OrdinalIgnoreCase)) s.Bump(name);
        if (!(SafeOpen(tr, id) is Entity ent)) return;
        bool col = BadColor(ent), lt = BadLinetype(ent);
        if (col) s.ColorNotByLayer++;
        if (lt) s.LinetypeNotByLayer++;
        if (col || lt) s.ObjectsNotByLayer++;
        if (!isModel) return;
        if (name == "AcDbHatch") s.Hatches++;
        else if (name == "AcDbText" || name == "AcDbMText") s.TextObjects++;
        else if (ent is BlockReference br && xrefDefIds.Contains(br.BlockTableRecord))
        {
            s.XrefInserts.Add(new XrefInsert
            {
                Name = br.Name,
                Point = new[] { br.Position.X, br.Position.Y, br.Position.Z },
                RotationDegrees = br.Rotation * 180.0 / Math.PI,
                Scale = br.ScaleFactors.X,
            });
        }
    }

    /// <summary>One xref definition: path, attach/overlay, loaded/unloaded/not found, units, coordinate system.</summary>
    private static XrefDefinition XrefDef(BlockTableRecord btr, string drawingFolder, Database host)
    {
        var x = new XrefDefinition
        {
            Name = btr.Name,
            Path = btr.PathName ?? "",
            Type = btr.IsFromOverlayReference ? "Overlay" : "Attach",
        };
        bool loaded = false;
        try { loaded = btr.XrefStatus == XrefStatus.Resolved; } catch (Exception) { /* unknown */ }
        x.Status = loaded ? "Loaded" : FileFound(x.Path, drawingFolder, host) ? "Unloaded" : "Not Found";
        try { x.Units = (int)btr.Units; } catch (Exception) { /* unknown */ }
        if (loaded)
        {
            try
            {
                Database xdb = btr.GetXrefDatabase(false);
                if (xdb != null) x.CoordinateSystem = GeoCoordinateSystem(xdb);
            }
            catch (Exception) { /* not readable: not compared */ }
        }
        return x;
    }

    /// <summary>At its saved path, relative to the drawing, by name in the drawing's folder, or on the support path.</summary>
    private static bool FileFound(string path, string folder, Database host)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        try
        {
            if (Path.IsPathRooted(path) && File.Exists(path)) return true;
            if (folder.Length > 0)
            {
                if (File.Exists(Path.GetFullPath(Path.Combine(folder, path)))) return true;
                string ext = WinPath.Extension(path);
                if (File.Exists(Path.Combine(folder, WinPath.FileNameWithoutExtension(path) + (ext.Length > 0 ? ext : ".dwg")))) return true;
            }
        }
        catch (Exception) { /* invalid path characters */ }
        try { return !string.IsNullOrEmpty(HostApplicationServices.Current.FindFile(path, host, FindFileHint.XRefDrawing)); }
        catch (Exception) { return false; }
    }

    /// <summary>
    /// The drawing's coordinate system: Civil 3D Drawing Settings, then CGEOCS (active
    /// drawing), then the geographic location. "" when none is assigned.
    /// </summary>
    public static string DrawingCoordinateSystem(Database db, object civDoc)
    {
        string cs = civDoc != null ? Civil.CoordinateSystemCode(civDoc) : null;
        if (cs != null) return cs;
        if (Acad.ActiveDoc?.Database == db)
        {
            string v = CutOnceConfig.NonBlank(Acad.GetVar("CGEOCS") as string);
            if (v != null) return v;
        }
        return GeoCoordinateSystem(db) ?? "";
    }

    /// <summary>The coordinate system stored with a database's geographic location, or null.</summary>
    public static string GeoCoordinateSystem(Database db)
    {
        try
        {
            ObjectId geoId = db.GeoDataObject;
            if (geoId.IsNull) return null;
            using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
            {
                var geo = tr.GetObject(geoId, OpenMode.ForRead) as GeoLocationData;
                string code = CoordinateSystems.CodeFromDefinition(geo?.CoordinateSystem);
                tr.Commit();
                return code;
            }
        }
        catch (Exception)
        {
            return null;
        }
    }

    // ------------------------------------------------------------------
    // Table counts for Health.csv and the cleanup
    // ------------------------------------------------------------------

    public static long CountTable(Transaction tr, ObjectId tableId)
    {
        long n = 0;
        if (tr.GetObject(tableId, OpenMode.ForRead) is SymbolTable t)
            foreach (ObjectId _ in t) n++;
        return n;
    }

    public static long CountDictionary(Transaction tr, ObjectId dictId)
    {
        if (dictId.IsNull) return 0;
        try { return tr.GetObject(dictId, OpenMode.ForRead) is DBDictionary d ? d.Count : 0; }
        catch (Exception) { return 0; }
    }

    /// <summary>An entry of the named-object dictionary, e.g. ACAD_SCALELIST; 0 when missing.</summary>
    public static long CountNamedDictionary(Transaction tr, Database db, string name)
    {
        var nod = (DBDictionary)tr.GetObject(db.NamedObjectsDictionaryId, OpenMode.ForRead);
        return nod.Contains(name) ? CountDictionary(tr, nod.GetAt(name)) : 0;
    }

    /// <summary>Layers, linetypes, blocks, layouts and registered apps for Health.csv.</summary>
    public static void AddTableCounts(Database db, IDictionary<string, object> row)
    {
        using (Transaction tr = db.TransactionManager.StartOpenCloseTransaction())
        {
            row["Layers"] = CountTable(tr, db.LayerTableId);
            row["Linetypes"] = CountTable(tr, db.LinetypeTableId);
            row["Blocks"] = CountTable(tr, db.BlockTableId);
            row["Layouts"] = CountDictionary(tr, db.LayoutDictionaryId);
            row["RegApps"] = CountTable(tr, db.RegAppTableId);
            tr.Commit();
        }
    }
}
