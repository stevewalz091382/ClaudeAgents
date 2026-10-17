using System;
using System.Collections.Generic;
using System.Linq;

namespace CutOnce.Core;

/// <summary>Where a designer's own choices are kept (the AutoCAD profile in Civil 3D).</summary>
public interface IPreferenceStore
{
    /// <summary>The stored value, or null when there is none.</summary>
    string Get(string name);

    /// <summary>Stores a value; an empty value removes it ("no choice").</summary>
    void Set(string name, string value);
}

/// <summary>An in-memory store, for tests and when the profile cannot be reached.</summary>
public sealed class MemoryPreferenceStore : IPreferenceStore
{
    private readonly Dictionary<string, string> _values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    public string Get(string name) => _values.TryGetValue(name, out string v) && !string.IsNullOrWhiteSpace(v) ? v : null;
    public void Set(string name, string value)
    {
        if (string.IsNullOrEmpty(value)) _values.Remove(name); else _values[name] = value;
    }
}

public enum WarnMode { Every, Once }

/// <summary>
/// The effective value of every Control Center setting. For each key:
///   1. the administrator's value, if the key is listed in LockedSettings
///   2. otherwise the designer's own choice (profile value CutOnce.&lt;key&gt; = "1" / "0")
///   3. otherwise the administrator's default, ("&lt;key&gt;" . T/nil) in the config
///   4. otherwise the built-in default
/// </summary>
public sealed class SettingsService
{
    public const string PrefPrefix = "CutOnce.";

    private readonly IPreferenceStore _store;
    private readonly HashSet<string> _warned;

    /// <param name="warnedThisSession">
    /// Warnings already shown this Civil 3D session. Share one set across drawings
    /// so "once per command per session" means once for the whole session.
    /// </param>
    public SettingsService(CutOnceConfig config, IPreferenceStore store, HashSet<string> warnedThisSession = null)
    {
        Config = config ?? CutOnceConfig.Empty;
        _store = store ?? new MemoryPreferenceStore();
        _warned = warnedThisSession ?? new HashSet<string>(StringComparer.Ordinal);
    }

    public CutOnceConfig Config { get; }

    public string GetPref(string name) => CutOnceConfig.NonBlank(_store.Get(PrefPrefix + name));

    public void SetPref(string name, string value)
    {
        try { _store.Set(PrefPrefix + name, value ?? ""); }
        catch { /* a profile write failure must never stop a warning */ }
    }

    public bool IsLocked(string key) =>
        key != null && Config.GetStringList("LockedSettings").Any(k => string.Equals(k, key, StringComparison.OrdinalIgnoreCase));

    public bool AnyLocked => SettingsCatalog.Keys.Any(IsLocked) || IsLocked(SettingsCatalog.WarnFrequency);

    /// <summary>Administrator default, falling back to the built-in default.</summary>
    public bool Default(string key)
    {
        var def = SettingsCatalog.Find(key);
        return Config.GetBool(key, def?.BuiltInDefault ?? true);
    }

    public bool IsOn(string key)
    {
        if (IsLocked(key)) return Default(key);
        string p = GetPref(key);
        if (p == "1") return true;
        if (p == "0") return false;
        return Default(key);
    }

    /// <summary>
    /// Stores the designer's choice. A choice equal to the administrator default is
    /// stored as "no choice", so a later change to the default still reaches this
    /// designer. Locked keys are never written.
    /// </summary>
    public void SetOn(string key, bool on)
    {
        if (IsLocked(key)) return;
        if (on == Default(key))
        {
            if (GetPref(key) != null) SetPref(key, "");
        }
        else
        {
            SetPref(key, on ? "1" : "0");
        }
    }

    /// <summary>Logging gate: the master switch and the specific log.</summary>
    public bool LogOn(string key) => IsOn("LogEnabled") && IsOn(key);

    /// <summary>A command warning shows only when the master switch and its own row are on.</summary>
    public bool CommandWarnOn(string key) => IsOn(SettingsCatalog.CommandWarnings) && IsOn(key);

    /// <summary>Stop / Undo buttons on command warnings.</summary>
    public bool OfferStop => CommandWarnOn("WarnOfferStop");

    // ------------------------------------------------------------------
    // Warning frequency: every time, or once per command per session.
    // ------------------------------------------------------------------

    public WarnMode DefaultWarnMode =>
        string.Equals(Config.GetString(SettingsCatalog.WarnFrequency), "once", StringComparison.OrdinalIgnoreCase)
            ? WarnMode.Once : WarnMode.Every;

    public WarnMode WarnMode
    {
        get
        {
            string p = IsLocked(SettingsCatalog.WarnFrequency) ? null : GetPref(SettingsCatalog.WarnFrequency);
            if (p == "every") return WarnMode.Every;
            if (p == "once") return WarnMode.Once;
            return DefaultWarnMode;
        }
    }

    public void SetWarnMode(WarnMode mode)
    {
        if (IsLocked(SettingsCatalog.WarnFrequency)) return;
        if (mode != WarnMode) _warned.Clear();
        if (mode == DefaultWarnMode)
        {
            if (GetPref(SettingsCatalog.WarnFrequency) != null) SetPref(SettingsCatalog.WarnFrequency, "");
        }
        else
        {
            SetPref(SettingsCatalog.WarnFrequency, ModeName(mode));
        }
    }

    public static string ModeName(WarnMode mode) => mode == WarnMode.Once ? "once" : "every";

    /// <summary>key identifies one warning, e.g. "IMPACT:MOVE" or "GUARD_EXPLODE".</summary>
    public bool IsDue(string key) => WarnMode == WarnMode.Every || !_warned.Contains(key);

    public void MarkWarned(string key) => _warned.Add(key);

    public string FrequencyNote() =>
        WarnMode == WarnMode.Once
            ? "Shown once per command each session. To change, type CUTONCE."
            : "Shown every time. To change, type CUTONCE (Control Center).";
}
