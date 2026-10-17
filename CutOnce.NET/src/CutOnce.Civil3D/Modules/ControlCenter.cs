using System.Collections.Generic;
using System.Linq;
using Autodesk.AutoCAD.EditorInput;
using CutOnce.Core;
using CutOnce.Host;
using CutOnce.UI;

namespace CutOnce.Modules;

/// <summary>
/// CUTONCE (dialog) and -CUTONCE (command line): every designer chooses which checks,
/// warnings and logs run for them. Choices are stored in their AutoCAD profile and
/// apply to every open drawing at once; locked items show the administrator's value.
/// </summary>
internal static class ControlCenter
{
    private static SettingsService S => CutOnceApp.Settings;

    public static void ShowDialog()
    {
        var vm = new ControlCenterViewModel(S, CutOnceApp.Folders.LogDir, CutOnceApp.Folders.BackupDir);
        var callbacks = new ControlCenterCallbacks
        {
            OpenLogFolder = () => Acad.OpenFolder(CutOnceApp.Folders.LogDir),
            OpenBackupFolder = () => Acad.OpenFolder(CutOnceApp.Folders.BackupDir),
            OpenTopic = CutOnceApp.OpenTopic,
            ShowOtherHelp = ShowOtherHelp,
        };
        if (!CutOnceApp.Dialogs.ShowControlCenter(vm, callbacks)) return;
        vm.Apply();
        Acad.Msg("CutOnce", "Settings saved. They apply to every open drawing.");
        PrintSummary();
    }

    public static void PrintSummary()
    {
        var off = SettingsCatalog.Keys.Where(k => !S.IsOn(k)).ToList();
        Acad.Write($"\n  Logging: {(S.IsOn("LogEnabled") ? "on" : "OFF")}   Command warnings: {(S.IsOn("CommandWarnings") ? "on" : "OFF")}" +
                   $"   Switched off: {(off.Count > 0 ? off.Count.ToString() : "none")}");
        Acad.Write("\n  Type -CUTONCE then List for the full list.");
    }

    /// <summary>Instructions for the CAD administrator on adding commands to "Other watched commands".</summary>
    public static void ShowOtherHelp()
    {
        var extra = CutOnceApp.Config.GetStringList("ImpactExtraCommands").Select(s => s.ToUpperInvariant()).ToList();
        string cfgPath = CutOnceApp.Config.SourcePath ?? (CutOnceApp.Home + CutOnceConfig.FileName);
        var lines = new List<string>
        {
            "Other watched commands - for CAD administrators",
            "",
            "CutOnce shows the change-impact warning for the commands in this list, in addition to the ones it",
            "watches already. The warning lists what depends on the selected alignment, profile or surface. With",
            "nothing selected, a command whose name contains SURFACE, PROFILE or ALIGNMENT reports on every object",
            "of that type; any other command shows no warning, because there is nothing to analyse.",
            "",
            "1. FIND THE COMMAND'S EXACT NAME",
            "   - Type CUTONCE-GUARD-LOGCOMMANDS to turn command-name echo on.",
            "   - Start the command the way designers do (ribbon, menu or command line).",
            "   - Note the name printed on the command line, e.g. AECCSOMECOMMAND.",
            "   - Type CUTONCE-GUARD-LOGCOMMANDS again to turn the echo off.",
            "",
            "2. OPEN THE CUTONCE CONFIGURATION FILE IN NOTEPAD",
            "   " + cfgPath,
            "   (For a network install, edit the copy in the shared folder.)",
            "",
            "3. FIND THIS LINE",
            "   (\"ImpactExtraCommands\" . nil)",
            "   and replace nil with the names in quotes, separated by spaces:",
            "   (\"ImpactExtraCommands\" . (\"AECCSOMECOMMAND\" \"AECCOTHER\"))",
            "",
            "4. SAVE THE FILE, THEN TYPE CUTONCE-RELOADCONFIG (or restart Civil 3D).",
            "",
            "5. KEEP \"OTHER WATCHED COMMANDS\" SWITCHED ON",
            "   To enforce it for everyone, add \"WarnOTHER\" to LockedSettings in the same file.",
            "",
            "Reinstalling CutOnce keeps your configuration file.",
            "",
            "Watched now:      " + (extra.Count > 0 ? string.Join(", ", extra) : "none"),
        };
        Notices.Show(Notices.FromText(lines, NoticeKind.Info, new[] { new NoticeLink("Learn More...", "CONTROL_CENTER") }));
    }

    // ------------------------------------------------------------------
    // -CUTONCE: type a setting name (or enough of it) to toggle it, or
    // List / Frequency / Warnings / Defaults / eXit. For scripts and buttons:
    //   ^C^C-CUTONCE;LogEnabled;;
    // ------------------------------------------------------------------

    public static void CommandLine(Editor ed)
    {
        PrintSummary();
        while (true)
        {
            var opts = new PromptStringOptions("\nSetting to toggle, or [List/Frequency/Warnings/Defaults/eXit] <eXit>: ")
            {
                AllowSpaces = false,
            };
            PromptResult r = ed.GetString(opts);
            if (r.Status != PromptStatus.OK || string.IsNullOrWhiteSpace(r.StringResult)) break;
            string kw = CommandLineSettings.Resolve(r.StringResult);
            if (kw == "EXIT") break;
            switch (kw)
            {
                case null:
                    Acad.Msg("CutOnce", $"\"{r.StringResult}\" is not a setting name (or matches more than one). Type List to see them.");
                    break;
                case "LIST": PrintAll(); break;
                case "WARNINGS": Toggle("CommandWarnings"); break;
                case "FREQUENCY":
                    if (S.IsLocked(SettingsCatalog.WarnFrequency))
                        Acad.Msg("CutOnce", "Warning frequency is set by your CAD administrator.");
                    else
                    {
                        S.SetWarnMode(S.WarnMode == WarnMode.Once ? WarnMode.Every : WarnMode.Once);
                        Acad.Msg("CutOnce", "Command warnings: " + (S.WarnMode == WarnMode.Once ? "once per command per session" : "every time"));
                    }
                    break;
                case "DEFAULTS":
                    var vm = new ControlCenterViewModel(S, "", "");
                    vm.ResetToDefaults();
                    vm.Apply();
                    Acad.Msg("CutOnce", "All settings restored to the defaults.");
                    break;
                default: Toggle(kw); break;
            }
        }
    }

    private static void Toggle(string key)
    {
        if (S.IsLocked(key))
        {
            Acad.Msg("CutOnce", key + " is set by your CAD administrator.");
            return;
        }
        bool on = !S.IsOn(key);
        S.SetOn(key, on);
        Acad.Msg("CutOnce", $"{SettingsCatalog.Label(key)}: {(on ? "ON" : "OFF")}");
    }

    public static void PrintAll()
    {
        Acad.Msg("CutOnce", "Current settings (type a name to toggle it):");
        foreach (var g in SettingsCatalog.GroupTitles)
        {
            Acad.Write("\n  " + g.Value);
            foreach (var d in SettingsCatalog.All.Where(d => d.Group == g.Key))
                Acad.Write($"\n    {(S.IsOn(d.Key) ? "[on]  " : "[off] ")}{d.Key}  - {d.Label}{(S.IsLocked(d.Key) ? "  (set by CAD admin)" : "")}");
            if (g.Key == SettingGroup.Cmd)
                Acad.Write("\n    Frequency: " + (S.WarnMode == WarnMode.Once ? "once per command per session" : "every time"));
        }
        Acad.Write("\n  Log folder: " + CutOnceApp.Folders.LogDir);
        Acad.Write("\n  Backup folder: " + CutOnceApp.Folders.BackupDir);
    }
}
