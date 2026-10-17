using System;
using System.IO;
using Autodesk.AutoCAD.ApplicationServices;
using CutOnce.Core;
using CutOnce.Host;

namespace CutOnce.Modules;

/// <summary>
/// "Save a copy": copies the drawing as last saved to the shared backup folder with a
/// name nobody else can produce, and records it in Backups.csv (always, even with
/// logging off) and Events.csv (BACKUP-COPY). A plain file copy, so it also works
/// while a command or a save is in progress.
/// </summary>
internal static class BackupService
{
    public static string LogPath => CutOnceApp.Folders.LogFile("Backups.csv");

    public static bool Available(Document doc) => Acad.IsSaved(doc);

    public static string Intro(Document doc)
    {
        if (!Available(doc)) return "Save a copy is available once this drawing has been saved.";
        return Acad.HasUnsavedChanges(doc)
            ? "Save a copy puts the drawing as last saved (unsaved changes not included) in:"
            : "Save a copy puts the drawing, as it is now, in:";
    }

    /// <summary>The copy's path, or null (with the reason on the command line).</summary>
    public static string Backup(Document doc, string reason)
    {
        string src = Acad.DocPath(doc);
        string dir = CutOnceApp.Folders.BackupDir;
        Folders.EnsureDir(dir);
        if (src.Length == 0 || !File.Exists(src))
        {
            Acad.Msg("CutOnce", "This drawing has not been saved yet, so there is no file to copy.");
            return null;
        }
        if (!Directory.Exists(dir.TrimEnd('\\')))
        {
            Acad.Msg("CutOnce", "Backup folder not reachable: " + dir);
            return null;
        }
        string dest = BackupNaming.Name(dir, src, CutOnceApp.Folders.UserName, CutOnceApp.Folders.ComputerName, DateTime.Now, File.Exists);
        try
        {
            File.Copy(src, dest, false);
            if (new FileInfo(dest).Length != new FileInfo(src).Length) throw new IOException("the copy is incomplete");
        }
        catch (Exception ex)
        {
            try { if (File.Exists(dest)) File.Delete(dest); } catch (Exception) { /* leave it */ }
            Acad.Msg("CutOnce", $"Could not copy {src} to {dest} ({ex.Message})");
            return null;
        }
        CutOnceApp.Writer.AppendLine(LogPath, BackupNaming.LogHeader,
            Csv.Row(Csv.Timestamp(), CutOnceApp.Folders.UserName, CutOnceApp.Folders.ComputerName, src, dest, reason,
                    Acad.HasUnsavedChanges(doc) ? "Yes" : "No"));
        CutOnceApp.LogEvent(doc, "BACKUP-COPY", reason + ": " + dest);
        Acad.Msg("CutOnce", "Backup copy saved: " + dest);
        return dest;
    }

    /// <summary>The "Save a copy" button.</summary>
    public static CopyOutcome CopyNow(Document doc, string reason)
    {
        string bk;
        try { bk = Backup(doc, reason); }
        catch (Exception) { bk = null; }
        return bk != null
            ? new CopyOutcome(true, bk, "Copy saved:")
            : new CopyOutcome(false, CutOnceApp.Folders.BackupDir, "Copy failed - is this folder reachable? Details are on the command line.");
    }
}
