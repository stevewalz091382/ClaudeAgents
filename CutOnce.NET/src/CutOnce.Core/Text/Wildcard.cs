using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace CutOnce.Core;

/// <summary>
/// AutoLISP wcmatch patterns, so admins can keep the patterns they already use
/// ("AcDb*Dimension", "AECCDBSURFACETIN,AECCDBSURFACEGRID", "//server/projects/1234*").
///   *  any sequence      ?  any one character     #  a digit
///   @  a letter          .  a non-alphanumeric    ~  (first) not
///   [...] / [~...]       one of / none of          `  next character is literal
///   ,  separates alternatives
/// </summary>
public static class Wildcard
{
    private static readonly Dictionary<string, Regex> Cache = new Dictionary<string, Regex>(StringComparer.Ordinal);

    public static bool IsMatch(string text, string pattern, bool ignoreCase = false)
    {
        if (text == null || pattern == null) return false;
        string cacheKey = (ignoreCase ? "i:" : "c:") + pattern;
        Regex re;
        lock (Cache)
        {
            if (!Cache.TryGetValue(cacheKey, out re))
            {
                var options = RegexOptions.CultureInvariant | (ignoreCase ? RegexOptions.IgnoreCase : RegexOptions.None);
                re = new Regex(ToRegex(pattern), options);
                Cache[cacheKey] = re;
            }
        }
        return re.IsMatch(text);
    }

    public static string ToRegex(string pattern)
    {
        var alternatives = new List<string>();
        var current = new StringBuilder();
        bool negate = false;
        bool atStart = true;

        void Finish()
        {
            alternatives.Add(negate ? "^(?!(?:" + current + ")$)[\\s\\S]*$" : "^(?:" + current + ")$");
            current.Clear();
            negate = false;
            atStart = true;
        }

        for (int i = 0; i < pattern.Length; i++)
        {
            char c = pattern[i];
            if (c == '`' && i + 1 < pattern.Length)
            {
                current.Append(Regex.Escape(pattern[++i].ToString()));
                atStart = false;
                continue;
            }
            switch (c)
            {
                case ',': Finish(); continue;
                case '~' when atStart: negate = true; atStart = false; continue;
                case '*': current.Append("[\\s\\S]*"); break;
                case '?': current.Append("[\\s\\S]"); break;
                case '#': current.Append("[0-9]"); break;
                case '@': current.Append("[A-Za-z]"); break;
                case '.': current.Append("[^A-Za-z0-9]"); break;
                case '[':
                    int close = pattern.IndexOf(']', i + 1);
                    if (close < 0) { current.Append(Regex.Escape("[")); break; }
                    string set = pattern.Substring(i + 1, close - i - 1);
                    bool not = set.StartsWith("~", StringComparison.Ordinal);
                    if (not) set = set.Substring(1);
                    var cls = new StringBuilder();
                    foreach (char sc in set)
                        cls.Append(sc == '-' ? "-" : Regex.Escape(sc.ToString()).Replace("]", "\\]"));
                    current.Append(not ? "[^" : "[").Append(cls).Append(']');
                    i = close;
                    break;
                default: current.Append(Regex.Escape(c.ToString())); break;
            }
            atStart = false;
        }
        Finish();
        return alternatives.Count == 1 ? alternatives[0] : "(?:" + string.Join("|", alternatives) + ")";
    }
}
