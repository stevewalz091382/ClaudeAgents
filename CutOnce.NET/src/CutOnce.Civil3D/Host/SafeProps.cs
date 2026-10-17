using System;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using Autodesk.AutoCAD.DatabaseServices;

namespace CutOnce.Host;

/// <summary>
/// Fail-safe property and method access by name, for .NET objects (reflection) and
/// COM objects (IDispatch). Nothing here ever throws: a missing or renamed member
/// returns null, the same way the LISP edition's cutonce:prop did. This is how
/// CutOnce reads Civil 3D objects without compiling against a particular release.
/// </summary>
internal static class SafeProps
{
    public static object Get(object target, string name)
    {
        if (target == null) return null;
        try
        {
            if (Marshal.IsComObject(target))
                return target.GetType().InvokeMember(name, BindingFlags.GetProperty, null, target, null);
            PropertyInfo p = target.GetType().GetProperty(name, BindingFlags.Public | BindingFlags.Instance);
            if (p == null || p.GetIndexParameters().Length > 0) return null;
            return p.GetValue(target, null);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Calls a public method that takes no arguments.</summary>
    public static object Call(object target, string method)
    {
        if (target == null) return null;
        try
        {
            if (Marshal.IsComObject(target))
                return target.GetType().InvokeMember(method, BindingFlags.InvokeMethod, null, target, null);
            MethodInfo m = target.GetType().GetMethod(method, BindingFlags.Public | BindingFlags.Instance, null, Type.EmptyTypes, null);
            return m?.Invoke(target, null);
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static string GetString(object target, string name) => Get(target, name) as string;

    public static ObjectId GetId(object target, string name) => Get(target, name) is ObjectId id ? id : ObjectId.Null;

    /// <summary>The ObjectIds in an ObjectIdCollection, an ObjectId[] or any IEnumerable of them.</summary>
    public static List<ObjectId> Ids(object collection)
    {
        var list = new List<ObjectId>();
        if (collection is IEnumerable e)
        {
            try
            {
                foreach (object o in e)
                    if (o is ObjectId id && !id.IsNull) list.Add(id);
            }
            catch (Exception)
            {
                // a collection that fails part way: keep what was read
            }
        }
        return list;
    }

    /// <summary>The items of any IEnumerable, e.g. a corridor's Baselines.</summary>
    public static List<object> Items(object collection)
    {
        var list = new List<object>();
        if (collection is IEnumerable e)
        {
            try { foreach (object o in e) if (o != null) list.Add(o); }
            catch (Exception) { /* keep what was read */ }
        }
        return list;
    }
}
