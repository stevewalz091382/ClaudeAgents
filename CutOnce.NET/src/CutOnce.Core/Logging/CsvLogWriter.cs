using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace CutOnce.Core;

/// <summary>
/// Appends rows to the CutOnce logs. A log written by an older version with different
/// columns is renamed to &lt;name&gt;-archived-&lt;date&gt;.csv once, so new rows start a clean
/// file and nothing is lost. Never throws: a log that cannot be written (open in Excel,
/// share offline) is skipped and the reason goes to <see cref="Message"/>.
/// </summary>
public sealed class CsvLogWriter
{
    private static readonly Encoding Utf8Bom = new UTF8Encoding(true);
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

    private readonly HashSet<string> _headerOk = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    /// <summary>Receives a line for the command line, e.g. "Could not archive ...".</summary>
    public Action<string> Message { get; set; }

    /// <summary>Clock, replaceable in tests.</summary>
    public Func<DateTime> Now { get; set; } = () => DateTime.Now;

    public bool AppendLine(string path, string header, string line) => AppendLines(path, header, new[] { line });

    public bool AppendLines(string path, string header, IEnumerable<string> lines)
    {
        var list = new List<string>(lines ?? Array.Empty<string>());
        if (list.Count == 0 || string.IsNullOrEmpty(path)) return false;
        try
        {
            if (!EnsureHeader(path, header)) return false;
            bool isNew = !File.Exists(path);
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            using (var fs = new FileStream(path, isNew ? FileMode.CreateNew : FileMode.Append, FileAccess.Write, FileShare.Read))
            using (var w = new StreamWriter(fs, isNew ? Utf8Bom : Utf8NoBom))
            {
                if (isNew && header != null) w.WriteLine(header);
                foreach (var ln in list) w.WriteLine(ln);
            }
            return true;
        }
        catch (Exception ex)
        {
            Message?.Invoke($"Could not write {path} ({ex.Message}). Not logged this time.");
            return false;
        }
    }

    /// <summary>True when the file is safe to append to under this header.</summary>
    public bool EnsureHeader(string path, string header)
    {
        if (header == null || _headerOk.Contains(path)) return true;
        string first = FirstLine(path);
        if (first == null || first == header)
        {
            _headerOk.Add(path);
            return true;
        }
        string archived = Path.Combine(
            Path.GetDirectoryName(path) ?? "",
            Path.GetFileNameWithoutExtension(path) + "-archived-" +
            Now().ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture) +
            (string.IsNullOrEmpty(Path.GetExtension(path)) ? ".csv" : Path.GetExtension(path)));
        try
        {
            File.Move(path, archived);
            Message?.Invoke("Log columns changed in this version. Previous log kept as " + archived);
            _headerOk.Add(path);
            return true;
        }
        catch (Exception)
        {
            Message?.Invoke($"Could not archive {path} (open in Excel?). Not logged this time.");
            return false;
        }
    }

    /// <summary>Every line of a text file, read even while Excel has it open; empty on failure.</summary>
    public static List<string> ReadLines(string path)
    {
        var outList = new List<string>();
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return outList;
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var r = new StreamReader(fs, Utf8NoBom, true);
            string line;
            while ((line = r.ReadLine()) != null) outList.Add(line);
        }
        catch (Exception)
        {
            // unreadable: treated as empty, the same as a missing log
        }
        return outList;
    }

    public static string FirstLine(string path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var r = new StreamReader(fs, Utf8NoBom, true);
            return r.ReadLine();
        }
        catch (Exception)
        {
            return null;
        }
    }
}
