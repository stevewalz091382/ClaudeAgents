using System;
using System.IO;
using System.Linq;

namespace CutOnce.Core;

/// <summary>
/// Install, log and backup folders, resolved in the same order as the LISP edition.
///   Log folder:    CUTONCE_LOGDIR, then "LogDir", then %LOCALAPPDATA%\CutOnce\Logs\,
///                  plus a per-person subfolder (CUTONCE_LOGSUBFOLDER, then "LogSubfolder")
///   Backup folder: CUTONCE_BACKUPDIR, then "BackupDir", then Documents\CutOnce Backups
/// </summary>
public sealed class Folders
{
    private readonly CutOnceConfig _cfg;
    private readonly Func<string, string> _getEnv;
    private readonly string _tempDir;
    private string _logDir;

    /// <param name="getEnv">Environment lookup (Windows environment, then the AutoCAD profile).</param>
    public Folders(CutOnceConfig cfg, Func<string, string> getEnv, string userName, string computerName, string tempDir)
    {
        _cfg = cfg ?? CutOnceConfig.Empty;
        _getEnv = getEnv ?? (_ => null);
        UserName = userName ?? "";
        ComputerName = computerName ?? "";
        _tempDir = tempDir ?? Path.GetTempPath();
    }

    public string UserName { get; }
    public string ComputerName { get; }

    private string Env(string name) => CutOnceConfig.NonBlank(_getEnv(name));

    /// <summary>A folder name with the characters Windows does not allow removed; null if nothing is left.</summary>
    public static string SafeFolder(string s)
    {
        if (s == null) return null;
        var bad = new[] { '\\', '/', ':', '*', '?', '"', '<', '>', '|' };
        string kept = new string(s.Where(c => Array.IndexOf(bad, c) < 0).ToArray()).Trim(' ', '.');
        return CutOnceConfig.NonBlank(kept);
    }

    /// <summary>Backslashes, exactly one trailing backslash.</summary>
    public static string DirSlash(string d) => (d ?? "").Replace('/', '\\').TrimEnd('\\') + "\\";

    /// <summary>Creates the folder and every missing parent; false when it cannot.</summary>
    public static bool EnsureDir(string dir)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(dir)) return false;
            Directory.CreateDirectory(dir.TrimEnd('\\', '/'));
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// "user", "computer" or "user-computer": each person (or PC) writes to its own
    /// subfolder of a shared log folder, so nobody appends to someone else's file.
    /// </summary>
    public string LogSubfolder()
    {
        string mode = (Env("CUTONCE_LOGSUBFOLDER") ?? _cfg.GetString("LogSubfolder") ?? "").Trim().ToUpperInvariant();
        string user = SafeFolder(UserName), pc = SafeFolder(ComputerName);
        switch (mode)
        {
            case "USER": return user;
            case "COMPUTER": return pc;
            case "USER-COMPUTER": return user != null && pc != null ? user + "-" + pc : user ?? pc;
            default: return null;
        }
    }

    /// <summary>The log folder with a trailing backslash; resolved once and cached.</summary>
    public string LogDir
    {
        get
        {
            if (_logDir != null) return _logDir;
            string d = Env("CUTONCE_LOGDIR") ?? _cfg.GetString("LogDir");
            if (d == null)
            {
                string la = Env("LOCALAPPDATA");
                d = la != null ? Path.Combine(la, "CutOnce", "Logs") : Path.Combine(_tempDir, "CutOnce", "Logs");
            }
            string sub = LogSubfolder();
            if (sub != null) d = DirSlash(d) + sub;
            d = DirSlash(d);
            EnsureDir(d);
            _logDir = d;
            return _logDir;
        }
    }

    public string LogFile(string name) => LogDir + name;

    /// <summary>The backup folder an administrator set, or null for the personal default.</summary>
    public string BackupDirConfigured => Env("CUTONCE_BACKUPDIR") ?? _cfg.GetString("BackupDir");

    public string BackupDir
    {
        get
        {
            string d = BackupDirConfigured;
            if (d == null)
            {
                string up = Env("USERPROFILE");
                d = up != null ? Path.Combine(up, "Documents", "CutOnce Backups") : Path.Combine(_tempDir, "CutOnce Backups");
            }
            return DirSlash(d);
        }
    }
}
