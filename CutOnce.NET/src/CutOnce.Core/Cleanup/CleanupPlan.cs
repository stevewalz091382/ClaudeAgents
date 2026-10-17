using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace CutOnce.Core;

public sealed class CleanupStep
{
    public CleanupStep(string key, string label, string countName) { Key = key; Label = label; CountName = countName; }
    public string Key { get; }
    public string Label { get; }
    /// <summary>The count this step lowers, or null (AUDIT).</summary>
    public string CountName { get; }
}

/// <summary>The cleanup steps, in the order they run, and the result text.</summary>
public static class CleanupPlan
{
    public static readonly IReadOnlyList<CleanupStep> Steps = new List<CleanupStep>
    {
        new CleanupStep("civil",   "Unused Civil 3D styles (_PURGESTYLES, runs first)", "CivilStyles"),
        new CleanupStep("styles",  "Unused text, dimension, multileader, table, multiline styles", "Styles"),
        new CleanupStep("regapps", "Unused registered applications (RegApps)", "RegApps"),
        new CleanupStep("anon",    "Unused anonymous blocks", "AnonBlocks"),
        new CleanupStep("all",     "Everything else unused: layers, linetypes, named blocks... (PURGE All)", "Other"),
        new CleanupStep("scales",  "Reset the annotation scale list to the default", "Scales"),
        new CleanupStep("audit",   "AUDIT the drawing and fix errors (runs last)", null),
    };

    public static readonly string[] PurgeKeys = { "styles", "anon", "regapps", "all" };
    public static readonly string[] PurgeCounts = { "RegApps", "Styles", "AnonBlocks", "Other" };
    public static readonly string[] EventCounts = { "CivilStyles", "Styles", "RegApps", "AnonBlocks", "Other", "Scales" };

    public static string CountText(object v) =>
        v is long l ? l.ToString(CultureInfo.InvariantCulture) : v is int i ? i.ToString(CultureInfo.InvariantCulture) : (v?.ToString() ?? "");

    /// <summary>Sum of the counts the PURGE passes can lower.</summary>
    public static long PurgeSum(IReadOnlyDictionary<string, object> counts) =>
        PurgeCounts.Sum(k => counts.TryGetValue(k, out object v) && v is long l ? l : 0);

    public static string ResultText(string key, IReadOnlyDictionary<string, object> before, IReadOnlyDictionary<string, object> after)
    {
        before.TryGetValue(key, out object b);
        after.TryGetValue(key, out object a);
        if (!(b is long bl) || !(a is long al)) return CountText(b) + " -> " + CountText(a);
        if (bl == al) return $"{al} -> {al}  (nothing unused to remove)";
        return $"{bl} -> {al}  ({bl - al} removed)";
    }

    public static List<string> ResultLines(ICollection<string> choice, IReadOnlyDictionary<string, object> before,
                                           IReadOnlyDictionary<string, object> after, IEnumerable<string> commandsRun, string backupPath)
    {
        var L = new List<string> { "Cleanup finished", "" };
        foreach (var st in Steps)
        {
            string result = !choice.Contains(st.Key) ? "not run"
                          : st.CountName != null ? ResultText(st.CountName, before, after)
                          : "done (see the command line)";
            L.Add("   " + st.Label + ":  " + result);
        }
        L.Add("");
        L.Add("COMMANDS RUN");
        L.AddRange(commandsRun.Select(c => "  - " + c));
        L.Add("");
        L.Add("PURGE only removes items nothing uses, so an unchanged count means everything");
        L.Add("of that kind is still in use. Its messages are on the command line (F2).");
        L.Add("");
        L.Add(backupPath != null ? "Backup copy (before cleanup): " + backupPath : "No backup copy was made.");
        L.Add("");
        L.Add("Undo now reverses the whole cleanup (one undo step).");
        L.Add("Save the drawing to keep the result.");
        return L;
    }

    public static string EventDetail(IReadOnlyDictionary<string, object> before, IReadOnlyDictionary<string, object> after) =>
        string.Join("  ", EventCounts.Select(k =>
            k + " " + CountText(before.TryGetValue(k, out var b) ? b : null) + "->" + CountText(after.TryGetValue(k, out var a) ? a : null)));
}
