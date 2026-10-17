using System;
using System.Globalization;
using System.IO;

namespace CutOnce.Core;

/// <summary>Events.csv (one row per warning) and Opened.csv (one row per drawing opened).</summary>
public sealed class EventLog
{
    public const string EventsHeader = "Timestamp,User,DrawingPath,DrawingName,EventType,Detail";
    public const string OpenedHeader = "Timestamp,User,DrawingPath,DrawingName";

    private readonly SettingsService _settings;
    private readonly Folders _folders;
    private readonly CsvLogWriter _writer;

    public EventLog(SettingsService settings, Folders folders, CsvLogWriter writer)
    {
        _settings = settings; _folders = folders; _writer = writer;
    }

    public string EventsPath => _folders.LogFile("Events.csv");
    public string OpenedPath => _folders.LogFile("Opened.csv");

    /// <summary>Never throws: a logging failure must not suppress the warning that follows it.</summary>
    public void Write(string drawingPath, string drawingName, string kind, string detail)
    {
        try
        {
            if (!_settings.LogOn("LogEvents")) return;
            _writer.AppendLine(EventsPath, EventsHeader,
                Csv.Row(Csv.Timestamp(), _folders.UserName, drawingPath ?? "", drawingName ?? "", kind, detail ?? ""));
        }
        catch (Exception)
        {
            // logging must never interrupt the designer
        }
    }

    public void WriteOpened(string drawingPath, string drawingName)
    {
        try
        {
            if (!_settings.LogOn("LogOpened")) return;
            _writer.AppendLine(OpenedPath, OpenedHeader, Csv.Row(Csv.Timestamp(), _folders.UserName, drawingPath, drawingName ?? ""));
        }
        catch (Exception)
        {
            // logging must never interrupt the designer
        }
    }
}

/// <summary>Backup copy names and Backups.csv.</summary>
public static class BackupNaming
{
    public const string LogHeader = "Timestamp,User,Computer,DrawingPath,BackupPath,Reason,UnsavedChangesNotInCopy";

    /// <summary>
    /// A name nobody else will produce: drawing, time to the millisecond, user and
    /// computer, and a -2, -3... counter if that name still exists.
    ///   &lt;drawing&gt;__&lt;YYYYMMDD-HHMMSS-mmm&gt;_&lt;user&gt;-&lt;computer&gt;.dwg
    /// </summary>
    public static string Name(string dir, string drawingPath, string user, string computer, DateTime now, Func<string, bool> exists)
    {
        string baseName = WinPath.FileNameWithoutExtension(drawingPath);
        string ext = WinPath.Extension(drawingPath);
        if (string.IsNullOrEmpty(ext)) ext = ".dwg";
        string who = Folders.SafeFolder((user ?? "") + "-" + (computer ?? "")) ?? "unknown";
        string stamp = now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) + "-" +
                       now.Millisecond.ToString("000", CultureInfo.InvariantCulture);
        dir = Folders.DirSlash(dir);
        string name = dir + baseName + "__" + stamp + "_" + who + ext;
        for (int n = 2; exists(name); n++)
            name = dir + baseName + "__" + stamp + "_" + who + "-" + n.ToString(CultureInfo.InvariantCulture) + ext;
        return name;
    }
}
