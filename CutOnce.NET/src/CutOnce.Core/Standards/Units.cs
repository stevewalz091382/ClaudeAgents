using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace CutOnce.Core;

/// <summary>INSUNITS values and names.</summary>
public static class Units
{
    public static readonly IReadOnlyDictionary<int, string> Names = new Dictionary<int, string>
    {
        [0] = "Unitless", [1] = "Inches", [2] = "Feet", [3] = "Miles", [4] = "Millimeters",
        [5] = "Centimeters", [6] = "Meters", [7] = "Kilometers", [8] = "Microinches",
        [9] = "Mils", [10] = "Yards", [11] = "Angstroms", [12] = "Nanometers",
        [13] = "Microns", [14] = "Decimeters", [15] = "Decameters", [16] = "Hectometers",
        [17] = "Gigameters", [18] = "Astronomical units", [19] = "Light years",
        [20] = "Parsecs", [21] = "US Survey Feet", [22] = "US Survey Inches",
        [23] = "US Survey Yards", [24] = "US Survey Miles",
    };

    public static string Name(int? n)
    {
        if (n == null) return "?";
        return Names.TryGetValue(n.Value, out var s) ? s : n.Value.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>"Feet", "us survey feet", "2" or 2 -> 2; null when not recognised.</summary>
    public static int? Parse(object v)
    {
        switch (v)
        {
            case int i: return i;
            case long l: return (int)l;
            case double d: return (int)d;
            case string s:
                s = s.Trim();
                if (s.Length == 0) return null;
                if (s.Length <= 2 && s.All(char.IsDigit)) return int.Parse(s, CultureInfo.InvariantCulture);
                foreach (var kv in Names)
                    if (string.Equals(kv.Value, s, StringComparison.OrdinalIgnoreCase)) return kv.Key;
                return null;
            default: return null;
        }
    }
}

/// <summary>Coordinate system codes from a geographic-location definition.</summary>
public static class CoordinateSystems
{
    private static string Between(string s, string open, string close)
    {
        int i = s.IndexOf(open, StringComparison.Ordinal);
        if (i < 0) return null;
        i += open.Length;
        int j = s.IndexOf(close, i, StringComparison.Ordinal);
        return j < 0 ? null : s.Substring(i, j - i);
    }

    /// <summary>
    /// The code from XML (&lt;ProjectedCoordinateSystem id="CA83-VIF" ...&gt;), WKT
    /// (PROJCS["..."]) or a bare code; null when there is none.
    /// </summary>
    public static string CodeFromDefinition(string s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        return CutOnceConfig.NonBlank(Between(s, "CoordinateSystem id=\"", "\""))
            ?? CutOnceConfig.NonBlank(Between(s, "id=\"", "\""))
            ?? CutOnceConfig.NonBlank(Between(s, "PROJCS[\"", "\""))
            ?? CutOnceConfig.NonBlank(Between(s, "GEOGCS[\"", "\""))
            ?? (s.Length < 64 && s.IndexOf('<') < 0 && s.IndexOf(' ') < 0 ? s : null);
    }
}
