using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace CutOnce.Core;

/// <summary>
/// "Learn More" links. Every warning has a topic; the topic maps to a section of the
/// "Civil 3D Warnings Explained" page. LearnMoreUrl / LearnMoreAnchors in the config
/// override the defaults; a topic missing from the config uses its default, and ""
/// opens the top of the page.
/// </summary>
public static class KnowledgeBase
{
    public const string DefaultUrl = "https://designtovisualization.com/kb-c3d-and-cutonce-assistant/";

    public static readonly IReadOnlyDictionary<string, string> DefaultAnchors = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        // change-impact warnings
        ["MOVE"] = "move-civil-objects",
        ["STRETCH"] = "stretch-civil-objects",
        ["ROTATE"] = "rotate-civil-objects",
        ["SCALE"] = "scale-civil-objects",
        ["GRIP_ALIGNMENT"] = "grip-edit-alignment",
        ["GRIP_PROFILE"] = "grip-edit-profile",
        ["SURFACE"] = "surface-edits",
        ["GENERAL"] = "dynamic-model",
        // standards check
        ["STANDARDS_OPEN"] = "standards-check",
        ["STD_BYLAYER"] = "objects-not-bylayer",
        ["STD_XREF_STATUS"] = "xrefs-broken-unloaded",
        ["STD_XREF_ORIGIN"] = "xref-not-at-origin",
        // guard
        ["GUARD_EXPLODE"] = "explode-civil-objects",
        ["GUARD_ATTRIB"] = "explode-attributed-blocks",
        ["GUARD_XREF_BIND"] = "xref-bind",
        ["GUARD_XREF_MOVED"] = "xref-moved",
        ["GUARD_REFEDIT"] = "refedit",
        ["GUARD_REFCLOSE"] = "refclose",
        ["GUARD_PROMOTE"] = "promote-reference",
        ["GUARD_TEXT"] = "text-instead-of-labels",
        ["GUARD_GROWTH"] = "drawing-growth",
        ["GUARD_CLEANUP"] = "drawing-cleanup",
        ["STD_COORD_UNITS"] = "coordinate-system-units",
        ["BACKUP"] = "backup-copies",
        // control center
        ["CONTROL_CENTER"] = "control-center",
        ["LINK_MAP"] = "link-map",
    };

    /// <summary>Topics whose section has no "Learn More topic:" line of its own.</summary>
    private static readonly string[] NoTextTopics = { "GUARD_REFCLOSE", "GENERAL" };

    /// <summary>Percent-encoding: letters, digits and _ . ~ stay, everything else becomes %XX.</summary>
    public static string UrlEncode(string s)
    {
        var sb = new StringBuilder();
        foreach (byte b in Encoding.UTF8.GetBytes(s ?? ""))
        {
            char c = (char)b;
            bool keep = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '.' || c == '~';
            sb.Append(keep ? c.ToString() : "%" + b.ToString("X2"));
        }
        return sb.ToString();
    }

    public static string Url(string topic, CutOnceConfig cfg)
    {
        cfg ??= CutOnceConfig.Empty;
        string baseUrl = cfg.GetString("LearnMoreUrl") ?? DefaultUrl;
        int hash = baseUrl.IndexOf('#');
        if (hash >= 0) baseUrl = baseUrl.Substring(0, hash);

        var custom = cfg.GetPairs("LearnMoreAnchors").FirstOrDefault(p => p.Key == topic);
        bool fromConfig = custom.Key != null;
        string anchor = fromConfig ? custom.Value as string : (DefaultAnchors.TryGetValue(topic ?? "", out var a) ? a : null);
        if (string.IsNullOrWhiteSpace(anchor)) return baseUrl;

        // On the built-in page every article lists "Learn More topic: <TOPIC>"; a text
        // fragment makes Edge and Chrome scroll to that line even when the page shifts.
        string text = "";
        if (!fromConfig && cfg.GetBool("LearnMoreHighlight", true) &&
            string.Equals(baseUrl, DefaultUrl, StringComparison.OrdinalIgnoreCase) &&
            Array.IndexOf(NoTextTopics, topic) < 0)
            text = ":~:text=" + UrlEncode("Learn More topic: " + topic);

        return baseUrl + "#" + anchor.TrimStart('#') + text;
    }
}
