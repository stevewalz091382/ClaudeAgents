using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace CutOnce.Core;

public enum BodyLineKind { Blank, Heading, Paragraph, Bullet, Detail }

/// <summary>One line of a dialog body, classified so the dialog can style it.</summary>
public sealed class BodyLine
{
    public BodyLineKind Kind { get; set; }
    public string Text { get; set; } = "";
    /// <summary>Right-hand value of a "Label:      value" detail row.</summary>
    public string Value { get; set; }
    /// <summary>Indent level (0, 1, 2) from the leading spaces.</summary>
    public int Indent { get; set; }
}

public static class MessageText
{
    private static readonly string[] Prefixes = { "CutOnce Guard tip:", "CutOnce Guard:", "CutOnce:" };
    private static readonly Regex DetailRow = new Regex(@"^(?<label>\S.*?:)\s{2,}(?<value>\S.*)$", RegexOptions.CultureInvariant);
    private static readonly Regex Parens = new Regex(@"\([^)]*\)|""[^""]*""", RegexOptions.CultureInvariant);

    public static List<string> SplitLines(string text) =>
        (text ?? "").Replace("\r\n", "\n").Split('\n').ToList();

    /// <summary>
    /// The first line of a message becomes the dialog headline (without the "CutOnce Guard:"
    /// prefix the header already shows); the rest is the body.
    /// </summary>
    public static (string Headline, List<string> Body) SplitHeadline(string text, string fallback)
    {
        var lines = SplitLines(text);
        int i = 0;
        while (i < lines.Count && string.IsNullOrWhiteSpace(lines[i])) i++;
        string head = i < lines.Count ? lines[i].Trim() : "";
        i++;
        foreach (string pre in Prefixes)
        {
            if (head.StartsWith(pre, StringComparison.OrdinalIgnoreCase))
            {
                head = head.Substring(pre.Length).Trim();
                break;
            }
        }
        while (i < lines.Count && string.IsNullOrWhiteSpace(lines[i])) i++;
        // "CutOnce Guard tip:" alone on its line: the next line is the headline
        if (head.Length == 0 && i < lines.Count)
        {
            head = lines[i].Trim();
            i++;
            while (i < lines.Count && string.IsNullOrWhiteSpace(lines[i])) i++;
        }
        return (head.Length == 0 ? fallback : head, lines.Skip(i).ToList());
    }

    /// <summary>
    /// Headings are lines whose leading words are in capitals, e.g. "XREFS",
    /// "ALIGNMENT: Main St" or "1. UNUSUAL GROWTH SINCE THE LAST CHECK".
    /// </summary>
    public static bool IsHeading(string trimmed)
    {
        string t = Regex.Replace(trimmed, @"^\d+\.\s*", "");
        int colon = t.IndexOf(':');
        string probe = colon > 0 ? t.Substring(0, colon) : Parens.Replace(t, "");
        int upper = probe.Count(char.IsUpper);
        if (upper >= 3 && !probe.Any(char.IsLower)) return true;
        // "PROFILES on this alignment:" - a capitalised lead word introducing a list
        return t.EndsWith(":", StringComparison.Ordinal) && LeadCaps.IsMatch(t);
    }

    private static readonly Regex LeadCaps = new Regex(@"^[A-Z]{4,}(\s|$)", RegexOptions.CultureInvariant);

    public static BodyLine Classify(string line)
    {
        line ??= "";
        if (string.IsNullOrWhiteSpace(line)) return new BodyLine { Kind = BodyLineKind.Blank };
        int lead = line.Length - line.TrimStart(' ').Length;
        int indent = lead >= 5 ? 2 : lead >= 2 ? 1 : 0;
        string t = line.Trim();

        if (t.StartsWith("- ", StringComparison.Ordinal) || t.StartsWith("-> ", StringComparison.Ordinal))
            return new BodyLine { Kind = BodyLineKind.Bullet, Text = t.Substring(t.IndexOf(' ') + 1).Trim(), Indent = Math.Max(indent, 1) };

        var m = DetailRow.Match(t);
        if (m.Success && m.Groups["label"].Value.Length < 40)
            return new BodyLine { Kind = BodyLineKind.Detail, Text = m.Groups["label"].Value, Value = m.Groups["value"].Value, Indent = indent };

        if (indent == 0 && IsHeading(t)) return new BodyLine { Kind = BodyLineKind.Heading, Text = t };

        return new BodyLine { Kind = BodyLineKind.Paragraph, Text = t, Indent = indent };
    }

    /// <summary>
    /// Classifies every line. Consecutive unindented paragraph lines are joined into one
    /// paragraph, so text hard-wrapped for the old fixed-width dialogs reflows to the window.
    /// </summary>
    public static List<BodyLine> ClassifyAll(IEnumerable<string> lines)
    {
        var outList = new List<BodyLine>();
        foreach (var ln in lines)
        {
            var b = Classify(ln);
            BodyLine prev = outList.Count > 0 ? outList[outList.Count - 1] : null;
            // collapse runs of blank lines, and never start or end with one
            if (b.Kind == BodyLineKind.Blank && (prev == null || prev.Kind == BodyLineKind.Blank)) continue;
            if (b.Kind == BodyLineKind.Paragraph && b.Indent == 0 && prev != null && prev.Kind == BodyLineKind.Paragraph &&
                prev.Indent == 0 && !prev.Text.EndsWith(":", StringComparison.Ordinal))
            {
                prev.Text += " " + b.Text;
                continue;
            }
            outList.Add(b);
        }
        while (outList.Count > 0 && outList[outList.Count - 1].Kind == BodyLineKind.Blank) outList.RemoveAt(outList.Count - 1);
        return outList;
    }
}
