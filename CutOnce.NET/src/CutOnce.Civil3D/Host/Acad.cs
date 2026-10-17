using System;
using System.Diagnostics;
using System.IO;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using CutOnce.Core;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

namespace CutOnce.Host;

/// <summary>Small, fail-safe helpers around the AutoCAD application.</summary>
internal static class Acad
{
    public static Document ActiveDoc => AcApp.DocumentManager.MdiActiveDocument;

    /// <summary>"[tag] message" on the command line of the active drawing.</summary>
    public static void Msg(string tag, string msg) => Write($"\n[{tag}] {msg}");

    public static void Write(string text)
    {
        try { ActiveDoc?.Editor?.WriteMessage(text); }
        catch (System.Exception) { /* no editor yet (startup) */ }
    }

    public static object GetVar(string name)
    {
        try { return AcApp.GetSystemVariable(name); }
        catch (System.Exception) { return null; }
    }

    public static void SetVar(string name, object value)
    {
        try { AcApp.SetSystemVariable(name, value); }
        catch (System.Exception) { /* read-only or unknown in this release */ }
    }

    public static int GetInt(string name, int fallback)
    {
        object v = GetVar(name);
        try { return v == null ? fallback : Convert.ToInt32(v); }
        catch (System.Exception) { return fallback; }
    }

    public static string GetString(string name) => GetVar(name) as string ?? "";

    /// <summary>The drawing's full path ("" for a new, unsaved drawing).</summary>
    public static string DocPath(Document doc)
    {
        if (doc == null) return "";
        try { return doc.IsNamedDrawing ? doc.Name : ""; }
        catch (System.Exception) { return ""; }
    }

    public static string DocName(Document doc)
    {
        if (doc == null) return "";
        try { return WinPath.FileName(doc.Name); }
        catch (System.Exception) { return ""; }
    }

    /// <summary>Saved at least once, so there is a file on disk to copy or check.</summary>
    public static bool IsSaved(Document doc)
    {
        string p = DocPath(doc);
        return p.Length > 0 && File.Exists(p);
    }

    /// <summary>Unsaved changes (DBMOD), for the active drawing.</summary>
    public static bool HasUnsavedChanges(Document doc) => doc != null && doc == ActiveDoc && GetInt("DBMOD", 0) != 0;

    public static bool IsActive(Document doc) => doc != null && doc == ActiveDoc;

    /// <summary>The command names running now, e.g. "MOVE" or "EXPLODE'ZOOM".</summary>
    public static string CmdNames => GetString("CMDNAMES").ToUpperInvariant();

    public static bool CommandRunning(string cmd) => CmdNames.IndexOf(cmd, StringComparison.OrdinalIgnoreCase) >= 0;

    public static Document DocumentOf(Database db)
    {
        try { return db == null ? null : AcApp.DocumentManager.GetDocument(db); }
        catch (System.Exception) { return null; }
    }

    /// <summary>Queues input for the drawing; runs once AutoCAD is ready for it.</summary>
    public static void Send(Document doc, string text)
    {
        try { doc?.SendStringToExecute(text, true, false, false); }
        catch (System.Exception) { /* drawing closing */ }
    }

    /// <summary>Cancels the command waiting for input (the same as pressing ESC twice).</summary>
    public static void CancelRunningCommand(Document doc) => Send(doc, "\x03\x03");

    /// <summary>Undoes the last command (the same as typing U).</summary>
    public static void QueueUndo(Document doc) => Send(doc, "_.U ");

    /// <summary>Opens a web page in the default browser; the address is also printed so it can be copied.</summary>
    public static void OpenUrl(string url)
    {
        Write("\nLearn more: " + url);
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (System.Exception ex) { Msg("CutOnce", "Could not open the browser: " + ex.Message); }
    }

    /// <summary>Opens a file in its default application (e.g. a .csv in Excel).</summary>
    public static void OpenFile(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (System.Exception ex) { Msg("CutOnce", "Could not open " + path + ": " + ex.Message); }
    }

    public static void OpenFolder(string dir)
    {
        Folders.EnsureDir(dir);
        try { Process.Start(new ProcessStartInfo("explorer.exe", "\"" + dir.TrimEnd('\\') + "\"") { UseShellExecute = true }); }
        catch (System.Exception ex) { Msg("CutOnce", "Could not open " + dir + ": " + ex.Message); }
    }
}
