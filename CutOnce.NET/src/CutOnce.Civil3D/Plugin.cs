using System;
using Autodesk.AutoCAD.Runtime;
using CutOnce.Host;

[assembly: ExtensionApplication(typeof(CutOnce.Plugin))]
[assembly: CommandClass(typeof(CutOnce.Commands.CutOnceCommands))]

namespace CutOnce;

/// <summary>
/// Entry point. Civil 3D loads this DLL at startup (CutOnce.bundle,
/// LoadOnAutoCADStartup) and calls Initialize once per session; from then on
/// every drawing is watched through document and database events.
/// </summary>
public sealed class Plugin : IExtensionApplication
{
    public void Initialize()
    {
        try
        {
            CutOnceApp.Start();
        }
        catch (System.Exception ex)
        {
            Acad.Msg("CutOnce", "Could not start: " + ex.Message);
        }
    }

    public void Terminate()
    {
        try { CutOnceApp.Stop(); }
        catch (System.Exception) { /* Civil 3D is closing */ }
    }
}
