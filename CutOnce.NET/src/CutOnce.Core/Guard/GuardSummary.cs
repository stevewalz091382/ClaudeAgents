using System;
using System.Collections.Generic;
using System.Linq;

namespace CutOnce.Core;

/// <summary>
/// CUTONCE-GUARD-SUMMARY: every drawing seen in Opened.csv or Health.csv, its latest
/// health row and its flagged-event count, whether or not it is open now.
/// </summary>
public static class GuardSummary
{
    private sealed class Drawing
    {
        public string Name;
        public List<string> LastRow;
    }

    public static List<string> Build(IList<string> opened, IList<string> health, IList<string> events, IList<string> healthColumns)
    {
        var byDraw = new Dictionary<string, Drawing>(StringComparer.Ordinal);
        var order = new List<string>();

        void Touch(string path, string name, List<string> row)
        {
            if (!byDraw.TryGetValue(path, out var d))
            {
                d = new Drawing();
                byDraw[path] = d;
                order.Add(path);
            }
            d.Name = name;
            if (row != null) d.LastRow = row;
        }

        if (opened.Count > 0)
        {
            var hdr = Csv.Split(opened[0]);
            int ip = hdr.IndexOf("DrawingPath"), iname = hdr.IndexOf("DrawingName");
            if (ip >= 0 && iname >= 0)
                foreach (var line in opened.Skip(1))
                {
                    var f = Csv.Split(line);
                    if (f.Count > Math.Max(ip, iname) && !byDraw.ContainsKey(f[ip])) Touch(f[ip], f[iname], null);
                }
        }

        // the current layout only; archived files are not read
        if (health.Count > 0 && health[0] == string.Join(",", healthColumns))
        {
            int ip = healthColumns.IndexOf("DrawingPath"), iname = healthColumns.IndexOf("DrawingName");
            foreach (var line in health.Skip(1))
            {
                var f = Csv.Split(line);
                if (f.Count > Math.Max(ip, iname)) Touch(f[ip], f[iname], f);
            }
        }

        var evCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        if (events.Count > 0)
        {
            int ip = Csv.Split(events[0]).IndexOf("DrawingPath");
            if (ip >= 0)
                foreach (var line in events.Skip(1))
                {
                    var f = Csv.Split(line);
                    if (f.Count > ip) { evCounts.TryGetValue(f[ip], out int n); evCounts[f[ip]] = n + 1; }
                }
        }

        var L = new List<string>();
        if (order.Count == 0)
        {
            L.Add("Nothing tracked yet - open or save a drawing first.");
            return L;
        }
        L.Add(order.Count + " drawing(s) tracked:");
        foreach (string path in order)
        {
            var d = byDraw[path];
            L.Add($"  {d.Name}  ({path})");
            L.Add("    flagged events: " + (evCounts.TryGetValue(path, out int n) ? n : 0));
            if (d.LastRow != null)
            {
                L.Add($"    last check: {d.LastRow[0]} ({(d.LastRow.Count > 1 ? d.LastRow[1] : "")})");
                var parts = new List<string>();
                for (int i = 0; i < healthColumns.Count && i < d.LastRow.Count; i++)
                    if (Array.IndexOf(HealthSchema.IdColumns, healthColumns[i]) < 0)
                        parts.Add(healthColumns[i] + "=" + d.LastRow[i]);
                L.Add("    " + string.Join("  ", parts));
            }
            else
            {
                L.Add("    (opened, no health row yet)");
            }
        }
        return L;
    }
}

/// <summary>-CUTONCE: resolves typed input to a keyword or a setting key.</summary>
public static class CommandLineSettings
{
    public static readonly string[] Keywords = { "LIST", "FREQUENCY", "WARNINGS", "DEFAULTS", "EXIT" };

    private static readonly Dictionary<string, string> Abbrev = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["X"] = "EXIT", ["L"] = "LIST", ["F"] = "FREQUENCY", ["W"] = "WARNINGS", ["D"] = "DEFAULTS",
    };

    /// <summary>A keyword (upper case) or a setting key (its own case); null if unknown or ambiguous.</summary>
    public static string Resolve(string input)
    {
        string up = (input ?? "").Trim().ToUpperInvariant();
        if (up.Length == 0) return null;
        if (Abbrev.TryGetValue(up, out string kw)) return kw;
        var names = Keywords.Concat(SettingsCatalog.Keys).ToList();
        string exact = names.FirstOrDefault(n => n.ToUpperInvariant() == up);
        if (exact != null) return exact;
        var prefixed = names.Where(n => n.ToUpperInvariant().StartsWith(up, StringComparison.Ordinal)).ToList();
        return prefixed.Count == 1 ? prefixed[0] : null;
    }
}
