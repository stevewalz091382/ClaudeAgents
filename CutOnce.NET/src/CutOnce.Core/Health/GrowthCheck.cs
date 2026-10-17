using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace CutOnce.Core;

public sealed class GrowthFlag
{
    public GrowthFlag(string metric, long oldValue, long newValue, string reason)
    {
        Metric = metric; Old = oldValue; New = newValue; Reason = reason;
    }
    public string Metric { get; }
    public long Old { get; }
    public long New { get; }
    public string Reason { get; }

    public string DisplayLine => $"{Metric}:  {Old} -> {New}  ({Reason})";
    public string EventText => $"{Metric} {Old}->{New}  ";
}

/// <summary>The save-time check for unusual growth since the drawing's last check.</summary>
public static class GrowthCheck
{
    public static double Threshold(CutOnceConfig cfg) => (cfg ?? CutOnceConfig.Empty).GetNumber("GuardGrowthWarnPct") ?? 20;

    public static List<GrowthFlag> Flags(IReadOnlyDictionary<string, object> previous, IReadOnlyDictionary<string, object> current,
                                         IEnumerable<ExtraCount> extras, double thresholdPct)
    {
        var flags = new List<GrowthFlag>();
        if (previous == null) return flags;
        foreach (string metric in HealthSchema.GrowthWatch.Concat(extras.Select(e => e.Column)))
        {
            if (!TryNumber(previous, metric, out long oldv) || !TryNumber(current, metric, out long newv)) continue;
            if (metric == "RegApps" && newv > oldv)
            {
                flags.Add(new GrowthFlag(metric, oldv, newv, "new registered app(s), often left by a bind or a foreign block"));
            }
            else if (oldv == 0 && newv > 0)
            {
                flags.Add(new GrowthFlag(metric, oldv, newv, "new since the last check"));
            }
            else if (oldv > 0)
            {
                double pct = 100.0 * (newv - oldv) / oldv;
                if (pct >= thresholdPct)
                    flags.Add(new GrowthFlag(metric, oldv, newv,
                        "up " + Math.Round(pct, MidpointRounding.AwayFromZero).ToString(CultureInfo.InvariantCulture) + "% since the last check"));
            }
        }
        return flags;
    }

    private static bool TryNumber(IReadOnlyDictionary<string, object> d, string key, out long value)
    {
        value = 0;
        if (d == null || !d.TryGetValue(key, out object v)) return false;
        switch (v)
        {
            case long l: value = l; return true;
            case int i: value = i; return true;
            case double x: value = (long)x; return true;
            default: return false;
        }
    }
}
