using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace CutOnce.Core;

/// <summary>
/// The CAD administrator's settings from CutOnce-Config.lsp. The file keeps its
/// AutoLISP shape, (setq *cutonce:config* '(("Key" . value) ...)), so an existing
/// config from the LISP edition works as-is. It is read as data, never run.
/// A key missing from the file falls back to the default given by the caller.
/// </summary>
public sealed class CutOnceConfig
{
    public const string FileName = "CutOnce-Config.lsp";

    private readonly Dictionary<string, object> _values = new Dictionary<string, object>(StringComparer.Ordinal);

    public static CutOnceConfig Empty => new CutOnceConfig();

    /// <summary>The file the settings came from; null for built-in defaults.</summary>
    public string SourcePath { get; private set; }

    /// <summary>Why the file could not be read, or null.</summary>
    public string LoadError { get; private set; }

    /// <summary>Never throws: a missing or broken file gives built-in defaults and a LoadError.</summary>
    public static CutOnceConfig LoadFile(string path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
            return new CutOnceConfig { LoadError = path == null ? null : "Not found: " + path };
        try
        {
            var cfg = Parse(File.ReadAllText(path));
            cfg.SourcePath = path;
            return cfg;
        }
        catch (Exception ex)
        {
            return new CutOnceConfig { SourcePath = path, LoadError = ex.Message };
        }
    }

    public static CutOnceConfig Parse(string text)
    {
        var cfg = new CutOnceConfig();
        foreach (object datum in LispReader.ReadAll(text))
        {
            if (!(datum is LispList form) || !(form.Car is LispSymbol head) || !head.Is("setq")) continue;
            for (int i = 1; i + 1 < form.Items.Count; i += 2)
            {
                if (form.Items[i] is LispSymbol name && name.Is("*cutonce:config*"))
                    cfg.Load(Unquote(form.Items[i + 1]));
            }
        }
        return cfg;
    }

    private static object Unquote(object v)
    {
        if (v is LispList l && l.Items.Count == 2 && l.Car is LispSymbol s && s.Is("quote")) return l.Items[1];
        return v;
    }

    private void Load(object alist)
    {
        if (!(alist is LispList list)) return;
        foreach (object entry in list.Items)
        {
            // assoc finds the first match, so the first entry for a key wins
            if (entry is LispList pair && pair.Car is string key && !_values.ContainsKey(key))
                _values[key] = pair.Cdr;
        }
    }

    public bool Has(string key) => _values.ContainsKey(key);

    public object Get(string key) => _values.TryGetValue(key, out object v) ? v : null;

    /// <summary>LISP truth: present and not nil is true; missing gives the default.</summary>
    public bool GetBool(string key, bool fallback) => _values.TryGetValue(key, out object v) ? v != null : fallback;

    /// <summary>A non-blank string, or null.</summary>
    public string GetString(string key) => NonBlank(Get(key) as string);

    public double? GetNumber(string key)
    {
        object v = Get(key);
        if (v is long l) return l;
        if (v is double d) return d;
        return null;
    }

    /// <summary>The non-blank strings of a list value, e.g. LockedSettings.</summary>
    public IReadOnlyList<string> GetStringList(string key)
    {
        if (!(Get(key) is LispList l)) return Array.Empty<string>();
        return l.Items.OfType<string>().Select(NonBlank).Where(s => s != null).ToList();
    }

    /// <summary>The ("name" . value) entries of a list value, e.g. HealthExtraCounts.</summary>
    public IReadOnlyList<KeyValuePair<string, object>> GetPairs(string key)
    {
        var outList = new List<KeyValuePair<string, object>>();
        if (Get(key) is LispList l)
        {
            foreach (object item in l.Items)
                if (item is LispList p && p.Car is string name)
                    outList.Add(new KeyValuePair<string, object>(name, p.Cdr));
        }
        return outList;
    }

    /// <summary>("name" . "text") entries only.</summary>
    public IReadOnlyList<KeyValuePair<string, string>> GetStringPairs(string key) =>
        GetPairs(key).Where(p => p.Value is string)
                     .Select(p => new KeyValuePair<string, string>(p.Key, (string)p.Value))
                     .ToList();

    public static string NonBlank(string s) => string.IsNullOrWhiteSpace(s) ? null : s;
}
