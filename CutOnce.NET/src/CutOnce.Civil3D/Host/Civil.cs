using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using Autodesk.AutoCAD.DatabaseServices;

namespace CutOnce.Host;

/// <summary>
/// Civil 3D access by reflection. CutOnce never compiles against AeccDbMgd.dll, so
/// one source tree runs on every Civil 3D release (and builds on a PC without
/// Civil 3D). Each member here returns null / empty when Civil 3D is not loaded or a
/// member does not exist in the running release.
/// </summary>
internal static class Civil
{
    private static Type _appType;
    private static Type _docType;
    private static bool _searched;

    private static void Find()
    {
        if (_searched && _appType != null) return;
        _searched = true;
        try
        {
            Assembly asm = AppDomain.CurrentDomain.GetAssemblies()
                .FirstOrDefault(a => string.Equals(a.GetName().Name, "AeccDbMgd", StringComparison.OrdinalIgnoreCase));
            if (asm == null)
            {
                try { asm = Assembly.Load("AeccDbMgd"); }
                catch (Exception) { asm = null; }
            }
            _appType = asm?.GetType("Autodesk.Civil.ApplicationServices.CivilApplication");
            _docType = asm?.GetType("Autodesk.Civil.ApplicationServices.CivilDocument");
        }
        catch (Exception)
        {
            _appType = null;
        }
    }

    /// <summary>True inside Civil 3D (the Civil 3D .NET API is loaded).</summary>
    public static bool Available
    {
        get { Find(); return _appType != null; }
    }

    /// <summary>The CivilDocument of the active drawing, or null.</summary>
    public static object ActiveDocument()
    {
        Find();
        try { return _appType?.GetProperty("ActiveDocument", BindingFlags.Public | BindingFlags.Static)?.GetValue(null, null); }
        catch (Exception) { return null; }
    }

    /// <summary>The CivilDocument of any open drawing's database, or null.</summary>
    public static object DocumentFor(Database db)
    {
        Find();
        if (_docType == null || db == null) return null;
        try
        {
            MethodInfo m = _docType.GetMethod("GetCivilDocument", BindingFlags.Public | BindingFlags.Static, null, new[] { typeof(Database) }, null);
            if (m != null) return m.Invoke(null, new object[] { db });
        }
        catch (Exception)
        {
            // fall through to the active drawing
        }
        return Acad.ActiveDoc?.Database == db ? ActiveDocument() : null;
    }

    public static string Name(object civilObject) => CutOnce.Core.CutOnceConfig.NonBlank(SafeProps.GetString(civilObject, "Name"));

    /// <summary>Every alignment: siteless ones, then those in each site.</summary>
    public static List<ObjectId> AlignmentIds(object civDoc, Transaction tr)
    {
        var ids = SafeProps.Ids(SafeProps.Call(civDoc, "GetAlignmentIds"));
        foreach (ObjectId siteId in SiteIds(civDoc))
        {
            object site = Open(siteId, tr);
            foreach (ObjectId id in SafeProps.Ids(SafeProps.Call(site, "GetAlignmentIds")))
                if (!ids.Contains(id)) ids.Add(id);
        }
        return ids;
    }

    public static List<ObjectId> SiteIds(object civDoc) => SafeProps.Ids(SafeProps.Call(civDoc, "GetSiteIds"));

    public static List<ObjectId> SurfaceIds(object civDoc) => SafeProps.Ids(SafeProps.Call(civDoc, "GetSurfaceIds"));

    public static List<ObjectId> CorridorIds(object civDoc) => SafeProps.Ids(SafeProps.Get(civDoc, "CorridorCollection"));

    /// <summary>Opens an object for read in the caller's transaction; null when it cannot be opened.</summary>
    public static DBObject Open(ObjectId id, Transaction tr)
    {
        if (tr == null || id.IsNull || id.IsErased || !id.IsValid) return null;
        try { return tr.GetObject(id, OpenMode.ForRead, false); }
        catch (Exception) { return null; }
    }

    private static object UnitZone(object civDoc) =>
        SafeProps.Get(SafeProps.Get(SafeProps.Get(civDoc, "Settings"), "DrawingSettings"), "UnitZoneSettings");

    /// <summary>Drawing Settings > Units and Zone > coordinate system code, or null.</summary>
    public static string CoordinateSystemCode(object civDoc) =>
        CutOnce.Core.CutOnceConfig.NonBlank(SafeProps.GetString(UnitZone(civDoc), "CoordinateSystemCode"));

    public static string AngularUnits(object civDoc) => SafeProps.Get(UnitZone(civDoc), "AngularUnits")?.ToString();

    /// <summary>
    /// Every Civil 3D style in the drawing: the Count of each style collection under
    /// CivilDocument.Styles, following nested roots (label styles) a few levels down.
    /// Null when the styles cannot be read.
    /// </summary>
    public static long? CountStyles(object civDoc)
    {
        object root = SafeProps.Get(civDoc, "Styles");
        if (root == null) return null;
        long total = 0;
        var seen = new HashSet<object>(ReferenceComparer.Instance);
        CountStylesIn(root, 0, seen, ref total);
        return total;
    }

    private static void CountStylesIn(object node, int depth, HashSet<object> seen, ref long total)
    {
        if (node == null || depth > 4 || !seen.Add(node)) return;
        PropertyInfo[] props;
        try { props = node.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance); }
        catch (Exception) { return; }
        foreach (PropertyInfo p in props)
        {
            if (p.GetIndexParameters().Length > 0) continue;
            Type t = p.PropertyType;
            if (t.IsValueType || t == typeof(string) || t.Namespace == null || !t.Namespace.StartsWith("Autodesk.Civil", StringComparison.Ordinal)) continue;
            object v;
            try { v = p.GetValue(node, null); }
            catch (Exception) { continue; }
            if (v == null) continue;
            if (v is IEnumerable && SafeProps.Get(v, "Count") is int n)
                total += n;
            else if (t.Name.EndsWith("Root", StringComparison.Ordinal) || t.Name.EndsWith("Styles", StringComparison.Ordinal))
                CountStylesIn(v, depth + 1, seen, ref total);
        }
    }

    private sealed class ReferenceComparer : IEqualityComparer<object>
    {
        public static readonly ReferenceComparer Instance = new ReferenceComparer();
        public new bool Equals(object x, object y) => ReferenceEquals(x, y);
        public int GetHashCode(object obj) => RuntimeHelpers.GetHashCode(obj);
    }
}
