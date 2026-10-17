using System;
using System.Collections.Generic;
using System.Linq;

namespace CutOnce.Core;

public enum SettingGroup { Cmd, Stop, Save, Open, Log }

public sealed class SettingDefinition
{
    public SettingDefinition(string key, SettingGroup group, string label, bool builtInDefault)
    {
        Key = key; Group = group; Label = label; BuiltInDefault = builtInDefault;
    }
    public string Key { get; }
    public SettingGroup Group { get; }
    public string Label { get; }
    public bool BuiltInDefault { get; }
}

/// <summary>
/// Every on/off choice a designer can make in the Control Center (CUTONCE).
/// The keys are the same as the LISP edition, so existing choices and
/// CutOnce-Config.lsp defaults carry over.
/// </summary>
public static class SettingsCatalog
{
    public const string CommandWarnings = "CommandWarnings";
    public const string WarnFrequency = "WarnFrequency";

    public static readonly IReadOnlyList<SettingDefinition> All = new List<SettingDefinition>
    {
        // Command warnings: a master switch, then one row per command
        new SettingDefinition("CommandWarnings",  SettingGroup.Cmd, "Show command warnings", true),
        new SettingDefinition("WarnMOVE",         SettingGroup.Cmd, "MOVE - Civil 3D objects and xrefs", true),
        new SettingDefinition("WarnCOPY",         SettingGroup.Cmd, "COPY - xrefs", true),
        new SettingDefinition("WarnSTRETCH",      SettingGroup.Cmd, "STRETCH - Civil 3D objects", true),
        new SettingDefinition("WarnROTATE",       SettingGroup.Cmd, "ROTATE - Civil 3D objects", true),
        new SettingDefinition("WarnSCALE",        SettingGroup.Cmd, "SCALE - Civil 3D objects", true),
        new SettingDefinition("WarnEXPLODE",      SettingGroup.Cmd, "EXPLODE / BURST - Civil 3D objects, blocks, hatches", true),
        new SettingDefinition("WarnXREFBIND",     SettingGroup.Cmd, "XREF / XBIND - binding an xref", true),
        new SettingDefinition("WarnREFEDIT",      SettingGroup.Cmd, "REFEDIT / REFCLOSE", true),
        new SettingDefinition("WarnPROMOTE",      SettingGroup.Cmd, "Promoting a data shortcut reference", true),
        new SettingDefinition("WarnTEXT",         SettingGroup.Cmd, "TEXT - label style tip", true),
        new SettingDefinition("WarnDTEXT",        SettingGroup.Cmd, "DTEXT - label style tip", true),
        new SettingDefinition("WarnMTEXT",        SettingGroup.Cmd, "MTEXT - label style tip", true),
        new SettingDefinition("WarnGRIPS",        SettingGroup.Cmd, "Grip edits of alignments, profiles, surfaces", true),
        new SettingDefinition("WarnSURFACE",      SettingGroup.Cmd, "Surface edit commands", true),
        new SettingDefinition("WarnOTHER",        SettingGroup.Cmd, "Other watched commands (added by CAD admin)", true),
        // Stopping a command from a warning (new in the .NET edition)
        new SettingDefinition("WarnOfferStop",      SettingGroup.Stop, "Offer Stop / Undo on command warnings", true),
        new SettingDefinition("WarnWhileSelecting", SettingGroup.Stop, "Warn while selecting (MOVE, STRETCH, ROTATE, SCALE), before anything changes", true),
        // Save checks
        new SettingDefinition("GuardGrowth",         SettingGroup.Save, "Unusual growth since the last check", true),
        new SettingDefinition("GuardCleanup",        SettingGroup.Save, "Offer one-click cleanup when growth is flagged", true),
        new SettingDefinition("BackupBeforeCleanup", SettingGroup.Save, "Save a backup copy to the shared folder before cleanup", true),
        // Standards check when a drawing opens
        new SettingDefinition("StdCheckOnOpen", SettingGroup.Open, "Run the standards check when a drawing opens", true),
        new SettingDefinition("StdByLayer",     SettingGroup.Open, "Objects whose color or linetype is not ByLayer", true),
        new SettingDefinition("StdXrefStatus",  SettingGroup.Open, "Xrefs that are broken (not found) or unloaded", true),
        new SettingDefinition("StdXrefOrigin",  SettingGroup.Open, "Xrefs not inserted at 0,0,0", true),
        new SettingDefinition("StdCoordUnits",  SettingGroup.Open, "Coordinate system and insertion units", true),
        new SettingDefinition("StdAlwaysShow",  SettingGroup.Open, "Show the result even when nothing is wrong", false),
        new SettingDefinition("StdScanBlocks",  SettingGroup.Open, "Include block definitions in ByLayer counts (slower)", true),
        // Logging
        new SettingDefinition("LogEnabled",      SettingGroup.Log, "Write logs", true),
        new SettingDefinition("LogHealthOnSave", SettingGroup.Log, "Health.csv row on every save", true),
        new SettingDefinition("LogHealthOnOpen", SettingGroup.Log, "Health.csv row when a drawing opens", true),
        new SettingDefinition("LogXrefs",        SettingGroup.Log, "Xrefs.csv detail with every Health.csv row", true),
        new SettingDefinition("LogEvents",       SettingGroup.Log, "Events.csv row for every warning", true),
        new SettingDefinition("LogOpened",       SettingGroup.Log, "Opened.csv row for every drawing opened", true),
    };

    private static readonly Dictionary<string, SettingDefinition> ByKey =
        All.ToDictionary(d => d.Key, StringComparer.OrdinalIgnoreCase);

    public static IEnumerable<string> Keys => All.Select(d => d.Key);

    public static SettingDefinition Find(string key) =>
        key != null && ByKey.TryGetValue(key, out var d) ? d : null;

    public static string Label(string key) => Find(key)?.Label ?? key;

    /// <summary>Command warning rows: every Cmd setting except the master switch.</summary>
    public static IEnumerable<string> CommandRowKeys =>
        All.Where(d => d.Group == SettingGroup.Cmd && d.Key != CommandWarnings).Select(d => d.Key);

    /// <summary>
    /// Master switch -> the items it governs (greyed out in the Control Center while it is off).
    /// "every" and "once" are the frequency radio buttons.
    /// </summary>
    public static readonly IReadOnlyList<KeyValuePair<string, string[]>> Children = new List<KeyValuePair<string, string[]>>
    {
        new KeyValuePair<string, string[]>(CommandWarnings,
            new[] { "every", "once" }
                .Concat(CommandRowKeys)
                .Concat(All.Where(d => d.Group == SettingGroup.Stop).Select(d => d.Key)).ToArray()),
        new KeyValuePair<string, string[]>("GuardGrowth", new[] { "GuardCleanup" }),
        new KeyValuePair<string, string[]>("StdCheckOnOpen",
            new[] { "StdByLayer", "StdXrefStatus", "StdXrefOrigin", "StdCoordUnits", "StdAlwaysShow" }),
        new KeyValuePair<string, string[]>("LogEnabled",
            new[] { "LogHealthOnSave", "LogHealthOnOpen", "LogXrefs", "LogEvents", "LogOpened" }),
    };

    public static string ParentOf(string key)
    {
        foreach (var kv in Children)
            if (kv.Value.Contains(key, StringComparer.OrdinalIgnoreCase)) return kv.Key;
        return null;
    }

    public static readonly IReadOnlyList<KeyValuePair<SettingGroup, string>> GroupTitles = new List<KeyValuePair<SettingGroup, string>>
    {
        new KeyValuePair<SettingGroup, string>(SettingGroup.Cmd,  "Command warnings"),
        new KeyValuePair<SettingGroup, string>(SettingGroup.Stop, "Stopping commands"),
        new KeyValuePair<SettingGroup, string>(SettingGroup.Save, "Checks on save"),
        new KeyValuePair<SettingGroup, string>(SettingGroup.Open, "Standards check when a drawing opens"),
        new KeyValuePair<SettingGroup, string>(SettingGroup.Log,  "Logging"),
    };
}
