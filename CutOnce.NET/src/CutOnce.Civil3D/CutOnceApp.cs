using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using Autodesk.AutoCAD.ApplicationServices;
using CutOnce.Core;
using CutOnce.Host;
using CutOnce.Modules;
using CutOnce.UI;

namespace CutOnce;

/// <summary>
/// The CutOnce session: configuration, settings, folders, logs and the dialog host,
/// shared by every drawing. Started once by <see cref="Plugin.Initialize"/>.
/// </summary>
internal static class CutOnceApp
{
    /// <summary>Warnings shown this session (for "once per command per session").</summary>
    private static readonly HashSet<string> WarnedThisSession = new HashSet<string>(StringComparer.Ordinal);

    public static string Home { get; private set; } = "";
    public static CutOnceConfig Config { get; private set; } = CutOnceConfig.Empty;
    public static IPreferenceStore Store { get; private set; } = new MemoryPreferenceStore();
    public static SettingsService Settings { get; private set; }
    public static Folders Folders { get; private set; }
    public static CsvLogWriter Writer { get; } = new CsvLogWriter();
    public static EventLog Events { get; private set; }
    public static ProjectStandardsResolver Projects { get; private set; }
    public static IDialogHost Dialogs { get; private set; }

    public static void Start()
    {
        Writer.Message = m => Acad.Msg("CutOnce", m);
        try { Store = new RegistryPreferenceStore(); }
        catch (Exception) { Store = new MemoryPreferenceStore(); }
        Home = FindHome();
        LoadConfig();
        Dialogs = new WpfDialogHost();
        DocMonitor.Start();
        Acad.Msg("CutOnce", $"{Product.Version} loaded. Type CUTONCE for settings, CUTONCE-STATUS for details.");
    }

    public static void Stop() => DocMonitor.Stop();

    /// <summary>Reads CutOnce-Config.lsp again (CUTONCE-RELOADCONFIG, or at start).</summary>
    public static void LoadConfig()
    {
        Config = CutOnceConfig.LoadFile(Path.Combine(Home, CutOnceConfig.FileName));
        if (Config.LoadError != null && Config.SourcePath != null)
            Acad.Msg("CutOnce", $"Could not read {Config.SourcePath} ({Config.LoadError}). Using built-in defaults.");
        Settings = new SettingsService(Config, Store, WarnedThisSession);
        Folders = new Folders(Config, GetEnv, Environment.UserName, Environment.MachineName, Path.GetTempPath());
        Events = new EventLog(Settings, Folders, Writer);
        Projects = new ProjectStandardsResolver(Config);
        BrandInfo.Reset();
    }

    /// <summary>A Windows environment variable, else the same name in the AutoCAD profile (LISP setenv).</summary>
    public static string GetEnv(string name)
    {
        string v = Environment.GetEnvironmentVariable(name);
        if (!string.IsNullOrWhiteSpace(v)) return v;
        try { return Store.Get(name); }
        catch (Exception) { return null; }
    }

    /// <summary>
    /// The install folder holding CutOnce-Config.lsp: CUTONCE_HOME, then the bundle's
    /// Contents folder above this DLL, then the standard ApplicationPlugins folders.
    /// </summary>
    private static string FindHome()
    {
        var candidates = new List<string>();
        string env = Environment.GetEnvironmentVariable("CUTONCE_HOME");
        if (!string.IsNullOrWhiteSpace(env)) candidates.Add(env);
        try
        {
            var dir = new DirectoryInfo(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location) ?? "");
            for (int i = 0; dir != null && i < 4; i++, dir = dir.Parent) candidates.Add(dir.FullName);
        }
        catch (Exception) { /* dynamic load */ }
        foreach (string root in new[] { Environment.GetEnvironmentVariable("APPDATA"), Environment.GetEnvironmentVariable("ProgramData") })
            if (!string.IsNullOrEmpty(root)) candidates.Add(Path.Combine(root, "Autodesk", "ApplicationPlugins", "CutOnce.bundle", "Contents"));

        foreach (string c in candidates)
            if (File.Exists(Path.Combine(c, CutOnceConfig.FileName))) return Folders.DirSlash(c);
        return candidates.Count > 0 ? Folders.DirSlash(candidates[0]) : "";
    }

    // ------------------------------------------------------------------
    // Shortcuts used everywhere
    // ------------------------------------------------------------------

    public static void LogEvent(Document doc, string kind, string detail) =>
        Events?.Write(Acad.DocPath(doc), Acad.DocName(doc), kind, detail);

    public static string KbUrl(string topic) => KnowledgeBase.Url(topic, Config);

    public static void OpenTopic(string topic) => Acad.OpenUrl(KbUrl(topic));
}
