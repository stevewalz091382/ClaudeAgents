// CutOnceLabels: optional .NET helper for CutOnce.
//
// AutoLISP cannot see whether a Civil 3D label's text has been typed over:
// the label exposes no such property to getpropertyvalue or COM. The Civil 3D
// .NET API can (Label.IsTextComponentOverriden), so this helper adds two
// AutoLISP functions that CutOnce uses when the DLL is loaded:
//
//   (cutonce-label-overrides ename)  number of typed-over text components on
//                                    the label (0 = none), or nil when the
//                                    object is not a label or cannot be checked
//   (cutonce-label-api ename)        diagnostic string for CUTONCE-LABEL-PROBE
//
// The Civil 3D methods are found by reflection, so this compiles against the
// AutoCAD assemblies only, works across Civil 3D releases, and answers nil
// (CutOnce then reports "could not be checked") instead of failing if a
// release names a method differently.

using System;
using System.Reflection;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.Runtime;

[assembly: CommandClass(typeof(CutOnce.LabelOverrides))]

namespace CutOnce
{
    public class LabelOverrides
    {
        [LispFunction("CUTONCE-LABEL-OVERRIDES")]
        public static object Count(ResultBuffer args)
        {
            ObjectId id = FirstObjectId(args);
            if (id.IsNull) return null;
            try
            {
                using (Transaction tr = id.Database.TransactionManager.StartOpenCloseTransaction())
                {
                    int? n = CountOverrides(tr.GetObject(id, OpenMode.ForRead), tr);
                    tr.Commit();
                    if (n.HasValue) return n.Value;
                    return null;
                }
            }
            catch (System.Exception)
            {
                return null;
            }
        }

        [LispFunction("CUTONCE-LABEL-API")]
        public static object Describe(ResultBuffer args)
        {
            ObjectId id = FirstObjectId(args);
            if (id.IsNull) return "no object";
            try
            {
                using (Transaction tr = id.Database.TransactionManager.StartOpenCloseTransaction())
                {
                    DBObject obj = tr.GetObject(id, OpenMode.ForRead);
                    Type t = obj.GetType();
                    string fromLabel;
                    ObjectIdCollection comps = TextComponentIds(obj, tr, out fromLabel);
                    int? n = CountOverrides(obj, tr);
                    tr.Commit();
                    return t.FullName
                        + "; IsTextComponentOverriden: " + (OverrideTest(t) != null ? "found" : "NOT FOUND")
                        + "; text components: " + (comps == null ? "NOT FOUND" : comps.Count + " (from " + fromLabel + ")")
                        + "; typed over: " + (n.HasValue ? n.Value.ToString() : "cannot check");
                }
            }
            catch (System.Exception ex)
            {
                return "error: " + ex.Message;
            }
        }

        static ObjectId FirstObjectId(ResultBuffer args)
        {
            if (args == null) return ObjectId.Null;
            foreach (TypedValue tv in args)
                if (tv.Value is ObjectId) return (ObjectId)tv.Value;
            return ObjectId.Null;
        }

        // Autodesk spells it "Overriden"; the corrected spelling is tried too.
        static MethodInfo OverrideTest(Type t)
        {
            return t.GetMethod("IsTextComponentOverriden", new[] { typeof(ObjectId) })
                ?? t.GetMethod("IsTextComponentOverridden", new[] { typeof(ObjectId) });
        }

        static int? CountOverrides(DBObject label, Transaction tr)
        {
            MethodInfo isOverridden = OverrideTest(label.GetType());
            if (isOverridden == null) return null;
            string from;
            ObjectIdCollection comps = TextComponentIds(label, tr, out from);
            if (comps == null) return null;
            int n = 0;
            foreach (ObjectId c in comps)
            {
                try
                {
                    if ((bool)isOverridden.Invoke(label, new object[] { c })) n++;
                }
                catch (TargetInvocationException)
                {
                    // not a text component of this label: skip it
                }
            }
            return n;
        }

        // The label's own list of text components when the release has one,
        // otherwise the text components of the label's style.
        static ObjectIdCollection TextComponentIds(DBObject label, Transaction tr, out string from)
        {
            Type t = label.GetType();
            from = "label";
            MethodInfo own = t.GetMethod("GetTextComponentIds", Type.EmptyTypes);
            if (own != null)
            {
                try
                {
                    ObjectIdCollection ids = own.Invoke(label, null) as ObjectIdCollection;
                    if (ids != null) return ids;
                }
                catch (TargetInvocationException) { }
            }
            from = "label style";
            PropertyInfo styleProp = t.GetProperty("StyleId");
            if (styleProp == null) return null;
            ObjectId styleId = (ObjectId)styleProp.GetValue(label, null);
            if (styleId.IsNull) return null;
            DBObject style = tr.GetObject(styleId, OpenMode.ForRead);
            foreach (MethodInfo m in style.GetType().GetMethods())
            {
                if (m.Name != "GetComponents") continue;
                ParameterInfo[] ps = m.GetParameters();
                if (ps.Length != 1 || !ps[0].ParameterType.IsEnum) continue;
                if (!Enum.IsDefined(ps[0].ParameterType, "Text")) continue;
                try
                {
                    return m.Invoke(style, new[] { Enum.Parse(ps[0].ParameterType, "Text") }) as ObjectIdCollection;
                }
                catch (TargetInvocationException) { }
            }
            return null;
        }
    }
}
