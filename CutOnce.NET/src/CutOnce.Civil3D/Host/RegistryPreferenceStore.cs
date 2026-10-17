using System;
using Autodesk.AutoCAD.DatabaseServices;
using CutOnce.Core;
using Microsoft.Win32;

namespace CutOnce.Host;

/// <summary>
/// The designer's own choices, in the AutoCAD profile:
/// HKCU\&lt;product key&gt;\FixedProfile\General, the same values the LISP edition wrote
/// with (setenv "CutOnce.WarnMOVE" "0"). Existing choices therefore carry over, and
/// Uninstall.ps1 removes them the same way.
/// </summary>
internal sealed class RegistryPreferenceStore : IPreferenceStore
{
    private readonly string _keyPath;

    public RegistryPreferenceStore()
    {
        string root;
        try { root = HostApplicationServices.Current.UserRegistryProductRootKey; }
        catch (System.Exception) { root = null; }
        _keyPath = string.IsNullOrEmpty(root) ? @"Software\CutOnce" : root + @"\FixedProfile\General";
    }

    public string Get(string name)
    {
        try
        {
            using RegistryKey k = Registry.CurrentUser.OpenSubKey(_keyPath);
            return k?.GetValue(name) as string;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public void Set(string name, string value)
    {
        using RegistryKey k = Registry.CurrentUser.CreateSubKey(_keyPath);
        if (k == null) return;
        if (string.IsNullOrEmpty(value)) k.DeleteValue(name, false);
        else k.SetValue(name, value, RegistryValueKind.String);
    }
}
