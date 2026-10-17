using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace CutOnce.Core;

public sealed class ProjectStandard
{
    public ProjectStandard(string coordinateSystem, int? insUnits, string source)
    {
        CoordinateSystem = coordinateSystem ?? ""; InsUnits = insUnits; Source = source;
    }
    /// <summary>"" when the project does not set one.</summary>
    public string CoordinateSystem { get; }
    public int? InsUnits { get; }
    /// <summary>The CutOnce-Project.ini path, or "CutOnce-Config.lsp ProjectStandards".</summary>
    public string Source { get; }
}

/// <summary>
/// The coordinate system and units a project should use: the nearest
/// CutOnce-Project.ini in the drawing's folder or a folder above it, else the first
/// "ProjectStandards" entry whose path wildcard matches the drawing. Cached per folder.
/// </summary>
public sealed class ProjectStandardsResolver
{
    public const string IniName = "CutOnce-Project.ini";

    private readonly CutOnceConfig _cfg;
    private readonly Func<string, bool> _fileExists;
    private readonly Func<string, IList<string>> _readLines;
    private readonly Dictionary<string, ProjectStandard> _cache = new Dictionary<string, ProjectStandard>(StringComparer.OrdinalIgnoreCase);

    public ProjectStandardsResolver(CutOnceConfig cfg, Func<string, bool> fileExists = null, Func<string, IList<string>> readLines = null)
    {
        _cfg = cfg ?? CutOnceConfig.Empty;
        _fileExists = fileExists ?? File.Exists;
        _readLines = readLines ?? (p => CsvLogWriter.ReadLines(p));
    }

    /// <summary>KEY=value lines; keys upper-cased; ; # and [ start comment / section lines. First key wins.</summary>
    public static Dictionary<string, string> ReadIni(IEnumerable<string> lines)
    {
        var outDict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string raw in lines)
        {
            string ln = raw.Trim(' ', '\t');
            if (ln.Length == 0 || ln[0] == ';' || ln[0] == '#' || ln[0] == '[') continue;
            int i = ln.IndexOf('=');
            if (i < 0) continue;
            string key = ln.Substring(0, i).Trim(' ', '\t').ToUpperInvariant();
            if (!outDict.ContainsKey(key)) outDict[key] = ln.Substring(i + 1).Trim(' ', '\t', '"');
        }
        return outDict;
    }

    public string FindIni(string dir)
    {
        string d = (dir ?? "").Replace('/', '\\').TrimEnd('\\');
        for (int n = 0; d.Length > 0 && n < 12; n++)
        {
            string candidate = d + "\\" + IniName;
            if (_fileExists(candidate)) return candidate;
            int cut = d.LastIndexOf('\\');
            if (cut <= 0) break;
            string parent = d.Substring(0, cut);
            if (parent == d || parent.EndsWith("\\", StringComparison.Ordinal) || parent.Length == 0) break;
            d = parent;
        }
        return null;
    }

    public ProjectStandard FromConfig(string drawingPath)
    {
        string up = (drawingPath ?? "").Replace('/', '\\').ToUpperInvariant();
        foreach (var entry in _cfg.GetPairs("ProjectStandards"))
        {
            if (string.IsNullOrWhiteSpace(entry.Key) || !(entry.Value is LispList values)) continue;
            if (!Wildcard.IsMatch(up, entry.Key.Replace('/', '\\').ToUpperInvariant())) continue;
            string cs = null; object units = null;
            foreach (object item in values.Items)
            {
                if (!(item is LispList kv) || !(kv.Car is string k)) continue;
                if (k == "CoordinateSystem" && cs == null) cs = kv.Cdr as string;
                if (k == "InsUnits" && units == null) units = kv.Cdr;
            }
            return new ProjectStandard(CutOnceConfig.NonBlank(cs) ?? "", Units.Parse(units), "CutOnce-Config.lsp ProjectStandards");
        }
        return null;
    }

    /// <summary>The project's standard for a drawing, or null when none is defined.</summary>
    public ProjectStandard Resolve(string drawingPath)
    {
        string dir = WinPath.Directory(drawingPath);
        if (_cache.TryGetValue(dir, out var cached)) return cached;

        ProjectStandard result = null;
        string ini = dir.Length > 0 ? FindIni(dir) : null;
        if (ini != null)
        {
            var kv = ReadIni(_readLines(ini));
            kv.TryGetValue("COORDINATESYSTEM", out string cs);
            kv.TryGetValue("INSUNITS", out string units);
            result = new ProjectStandard(CutOnceConfig.NonBlank(cs) ?? "", Units.Parse(units), ini);
        }
        else
        {
            result = FromConfig(drawingPath);
        }
        _cache[dir] = result;
        return result;
    }
}
