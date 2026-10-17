using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace CutOnce.Core;

/// <summary>CSV helpers with RFC 4180 quoting, matching the LISP edition's files exactly.</summary>
public static class Csv
{
    public static string Quote(string s) => "\"" + (s ?? "").Replace("\"", "\"\"") + "\"";

    /// <summary>One value as a CSV field. Strings are always quoted; reals have 6 decimals.</summary>
    public static string Field(object v)
    {
        switch (v)
        {
            case null: return "";
            case string s: return Quote(s);
            case int i: return i.ToString(CultureInfo.InvariantCulture);
            case long l: return l.ToString(CultureInfo.InvariantCulture);
            case double d: return d.ToString("F6", CultureInfo.InvariantCulture);
            case float f: return ((double)f).ToString("F6", CultureInfo.InvariantCulture);
            case bool b: return b ? "True" : "False";
            default: return Quote(Convert.ToString(v, CultureInfo.InvariantCulture));
        }
    }

    public static string Row(IEnumerable<object> values) => string.Join(",", values.Select(Field));

    public static string Row(params object[] values) => Row((IEnumerable<object>)values);

    /// <summary>Quote-aware split on one separator character.</summary>
    public static List<string> Split(string line, char sep = ',')
    {
        var outList = new List<string>();
        var field = new StringBuilder();
        bool inQuotes = false;
        line ??= "";
        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (inQuotes && c == '"' && i + 1 < line.Length && line[i + 1] == '"')
            {
                field.Append('"');
                i++;
            }
            else if (c == '"')
            {
                inQuotes = !inQuotes;
            }
            else if (!inQuotes && c == sep)
            {
                outList.Add(field.ToString());
                field.Clear();
            }
            else
            {
                field.Append(c);
            }
        }
        outList.Add(field.ToString());
        return outList;
    }

    public static string Timestamp(DateTime now) => now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

    public static string Timestamp() => Timestamp(DateTime.Now);
}
