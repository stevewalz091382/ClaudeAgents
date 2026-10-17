namespace CutOnce.Core;

/// <summary>
/// Windows path pieces that treat both \ and / as separators on every platform, so
/// drawing paths behave the same in Civil 3D and in the tests.
/// </summary>
public static class WinPath
{
    private static int LastSeparator(string p) => System.Math.Max(p.LastIndexOf('\\'), p.LastIndexOf('/'));

    public static string FileName(string p)
    {
        p ??= "";
        return p.Substring(LastSeparator(p) + 1);
    }

    /// <summary>The folder part without a trailing separator; "" when there is none.</summary>
    public static string Directory(string p)
    {
        p ??= "";
        int i = LastSeparator(p);
        return i <= 0 ? "" : p.Substring(0, i);
    }

    public static string Extension(string p)
    {
        string name = FileName(p);
        int dot = name.LastIndexOf('.');
        return dot <= 0 ? "" : name.Substring(dot);
    }

    public static string FileNameWithoutExtension(string p)
    {
        string name = FileName(p);
        int dot = name.LastIndexOf('.');
        return dot <= 0 ? name : name.Substring(0, dot);
    }
}
