using System;
using System.Collections.Generic;
using System.Linq;

namespace CutOnce.Core;

/// <summary>One switch in the Control Center.</summary>
public sealed class SettingItem : ObservableObject
{
    private bool _isOn;
    private bool _parentOn = true;

    public SettingItem(SettingDefinition def, bool isOn, bool isLocked)
    {
        Definition = def;
        _isOn = isOn;
        IsLocked = isLocked;
    }

    public SettingDefinition Definition { get; }
    public string Key => Definition.Key;
    public string Label => Definition.Label;
    public bool IsLocked { get; }

    /// <summary>Raised when the switch changes, so children of a master switch can update.</summary>
    public event Action<SettingItem> Toggled;

    public bool IsOn
    {
        get => _isOn;
        set { if (Set(ref _isOn, value)) Toggled?.Invoke(this); }
    }

    /// <summary>False while the master switch above it is off.</summary>
    public bool ParentOn
    {
        get => _parentOn;
        set { if (Set(ref _parentOn, value)) Raise(nameof(IsEditable)); }
    }

    public bool IsEditable => !IsLocked && ParentOn;

    public string ToolTip => IsLocked ? "Set by your CAD administrator" : null;

    internal void SetSilently(bool on)
    {
        if (_isOn == on) return;
        _isOn = on;
        Raise(nameof(IsOn));
        Toggled?.Invoke(this);
    }
}

/// <summary>
/// The CutOnce Control Center: every designer chooses which checks, warnings and logs
/// run for them. Nothing is stored until <see cref="Apply"/>.
/// </summary>
public sealed class ControlCenterViewModel : ObservableObject
{
    private readonly SettingsService _settings;
    private readonly Dictionary<string, SettingItem> _items = new Dictionary<string, SettingItem>(StringComparer.OrdinalIgnoreCase);
    private bool _frequencyOnce;
    private bool _resetPressed;
    private string _note;

    public ControlCenterViewModel(SettingsService settings, string logFolder, string backupFolder)
    {
        _settings = settings;
        LogFolder = logFolder;
        BackupFolder = backupFolder;
        foreach (var def in SettingsCatalog.All)
        {
            var item = new SettingItem(def, settings.IsOn(def.Key), settings.IsLocked(def.Key));
            item.Toggled += _ => RefreshParents();
            _items[def.Key] = item;
        }
        _frequencyOnce = settings.WarnMode == WarnMode.Once;
        FrequencyLocked = settings.IsLocked(SettingsCatalog.WarnFrequency);
        _note = settings.AnyLocked ? "Items with a lock are set by your CAD administrator." : "";
        RefreshParents();
    }

    public SettingItem this[string key] => _items[key];

    // Masters, shown as the first switch of each card
    public SettingItem CommandWarnings => _items["CommandWarnings"];
    public SettingItem GuardGrowth => _items["GuardGrowth"];
    public SettingItem StdCheckOnOpen => _items["StdCheckOnOpen"];
    public SettingItem LogEnabled => _items["LogEnabled"];

    public IReadOnlyList<SettingItem> CommandItems => SettingsCatalog.CommandRowKeys.Select(k => _items[k]).ToList();
    public IReadOnlyList<SettingItem> StopItems => Group(SettingGroup.Stop);
    public IReadOnlyList<SettingItem> SaveItems => Group(SettingGroup.Save).Where(i => i.Key != "GuardGrowth").ToList();
    public IReadOnlyList<SettingItem> OpenItems => Group(SettingGroup.Open).Where(i => i.Key != "StdCheckOnOpen").ToList();
    public IReadOnlyList<SettingItem> LogItems => Group(SettingGroup.Log).Where(i => i.Key != "LogEnabled").ToList();

    private IReadOnlyList<SettingItem> Group(SettingGroup g) =>
        SettingsCatalog.All.Where(d => d.Group == g).Select(d => _items[d.Key]).ToList();

    public string LogFolder { get; }
    public string BackupFolder { get; }

    public bool FrequencyLocked { get; }
    public bool FrequencyEditable => !FrequencyLocked && CommandWarnings.IsOn;

    public bool FrequencyEvery
    {
        get => !_frequencyOnce;
        set { if (value && _frequencyOnce) { _frequencyOnce = false; RaiseFrequency(); } }
    }

    public bool FrequencyOnce
    {
        get => _frequencyOnce;
        set { if (value && !_frequencyOnce) { _frequencyOnce = true; RaiseFrequency(); } }
    }

    private void RaiseFrequency()
    {
        Raise(nameof(FrequencyEvery));
        Raise(nameof(FrequencyOnce));
    }

    public string Note
    {
        get => _note;
        private set => Set(ref _note, value);
    }

    public IReadOnlyList<string> WatchedExtraCommands =>
        _settings.Config.GetStringList("ImpactExtraCommands").Select(s => s.ToUpperInvariant()).ToList();

    private void RefreshParents()
    {
        foreach (var kv in SettingsCatalog.Children)
        {
            bool on = _items[kv.Key].IsOn;
            foreach (string child in kv.Value)
                if (_items.TryGetValue(child, out var item)) item.ParentOn = on;
        }
        Raise(nameof(FrequencyEditable));
    }

    /// <summary>Restores the firm's defaults in the dialog; OK keeps them.</summary>
    public void ResetToDefaults()
    {
        _resetPressed = true;
        foreach (var item in _items.Values)
            if (!item.IsLocked) item.SetSilently(_settings.Default(item.Key));
        if (!FrequencyLocked)
        {
            _frequencyOnce = _settings.DefaultWarnMode == WarnMode.Once;
            RaiseFrequency();
        }
        RefreshParents();
        Note = "Defaults restored in the dialog. Click Save to keep them.";
    }

    /// <summary>Stores the choices. Returns the keys that ended up off.</summary>
    public IReadOnlyList<string> Apply()
    {
        foreach (var item in _items.Values)
            if (_resetPressed || item.IsOn != _settings.IsOn(item.Key))
                _settings.SetOn(item.Key, item.IsOn);
        var mode = _frequencyOnce ? WarnMode.Once : WarnMode.Every;
        if (!FrequencyLocked && (_resetPressed || mode != _settings.WarnMode)) _settings.SetWarnMode(mode);
        return SettingsCatalog.Keys.Where(k => !_settings.IsOn(k)).ToList();
    }
}

/// <summary>One tick box of the cleanup dialog.</summary>
public sealed class CleanupStepItem : ObservableObject
{
    private bool _isChecked = true;
    public CleanupStepItem(CleanupStep step, string countText) { Step = step; CountText = countText; }
    public CleanupStep Step { get; }
    public string Label => Step.Label;
    /// <summary>"now 42", or null for AUDIT.</summary>
    public string CountText { get; }
    public bool HasCount => CountText != null;
    public bool IsChecked { get => _isChecked; set => Set(ref _isChecked, value); }
}

/// <summary>The cleanup dialog: what runs, with today's counts, and the backup copy.</summary>
public sealed class CleanupViewModel : ObservableObject
{
    private bool _backup;

    public CleanupViewModel(IReadOnlyDictionary<string, object> counts, bool canBackup, bool backupDefault, bool backupForced,
                            string backupFolder, bool backupFolderConfigured, bool hasUnsavedChanges, string drawingPath)
    {
        Steps = CleanupPlan.Steps.Select(st => new CleanupStepItem(st,
            st.CountName != null && counts.TryGetValue(st.CountName, out object v) ? "now " + CleanupPlan.CountText(v) : null)).ToList();
        CanBackup = canBackup;
        BackupForced = canBackup && backupForced;
        _backup = canBackup && backupDefault;
        BackupFolder = backupFolder + (backupFolderConfigured ? "" : "   (personal - your CAD admin can set BackupDir)");
        DrawingPath = drawingPath;
        BackupNote = !canBackup
            ? "No backup possible: this drawing has never been saved."
            : (hasUnsavedChanges
                ? "The copy is the last saved version; unsaved changes are not in it."
                : "The copy is the drawing as last saved, before any cleanup.")
              + (BackupForced ? "  Required by your CAD administrator." : "");
    }

    public IReadOnlyList<CleanupStepItem> Steps { get; }
    public bool CanBackup { get; }
    public bool BackupForced { get; }
    public bool BackupEditable => CanBackup && !BackupForced;
    public bool Backup { get => _backup; set => Set(ref _backup, value); }
    public string BackupFolder { get; }
    public string BackupNote { get; }
    public string DrawingPath { get; }

    /// <summary>The ticked keys, "backup" first when ticked.</summary>
    public List<string> Choice()
    {
        var c = new List<string>();
        if (Backup) c.Add("backup");
        c.AddRange(Steps.Where(s => s.IsChecked).Select(s => s.Step.Key));
        return c;
    }
}
