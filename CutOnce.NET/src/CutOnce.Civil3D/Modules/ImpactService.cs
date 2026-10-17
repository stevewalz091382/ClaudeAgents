using System;
using System.Collections.Generic;
using System.Linq;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;
using CutOnce.Core;
using CutOnce.Host;

namespace CutOnce.Modules;

/// <summary>
/// Change-impact warnings: before an alignment, surface or profile is edited, list what
/// depends on it. Three moments, each with a way to stop:
///   - objects selected first: warned as the command starts; Stop vetoes it
///   - picked after the command started: warned as they are selected; Stop cancels the
///     command, or "Leave them out" removes them from the selection
///   - otherwise: warned when the command ends; Undo reverses it
/// </summary>
internal static class ImpactService
{
    /// <summary>CUTONCE-IMPACT-DEBUG: report failures inside event handlers.</summary>
    public static bool Debug;

    private static readonly string[] Transform = { "MOVE", "STRETCH", "ROTATE", "SCALE" };

    /// <summary>Civil 3D command names observed firing at command start in a live session.</summary>
    public static readonly string[] Verified =
    {
        "AECCRAISELOWERSURFACE", "AECCADDSURFACELINE", "AECCDELETESURFACELINE", "AECCADDSURFACEPOINT",
        "AECCDELETESURFACEPOINT", "AECCEDITSURFACEPOINT", "AECCMOVESURFACEPOINT", "AECCEDITSURFACESWAPEDGE",
    };

    private static SettingsService S => CutOnceApp.Settings;

    public static bool IsTransform(string cmd) => Transform.Contains(cmd);

    public static bool IsWatched(string cmd) =>
        Verified.Contains(cmd) || cmd.StartsWith("GRIP_", StringComparison.Ordinal) ||
        CutOnceApp.Config.GetStringList("ImpactExtraCommands").Any(c => string.Equals(c, cmd, StringComparison.OrdinalIgnoreCase));

    /// <summary>The Control Center row that governs a command's warning.</summary>
    public static string Category(string cmd)
    {
        if (IsTransform(cmd)) return "Warn" + cmd;
        if (cmd.StartsWith("GRIP_", StringComparison.Ordinal)) return "WarnGRIPS";
        if (Verified.Contains(cmd)) return "WarnSURFACE";
        return "WarnOTHER";
    }

    /// <summary>All grip edits (GRIP_STRETCH, GRIP_MOVE...) count as one command, "GRIP".</summary>
    public static string WarnKey(string cmd) => "IMPACT:" + (cmd.StartsWith("GRIP_", StringComparison.Ordinal) ? "GRIP" : cmd);

    public static bool ShouldWarn(string cmd) => S.CommandWarnOn(Category(cmd)) && S.IsDue(WarnKey(cmd));

    /// <summary>The Learn More topic of a warning.</summary>
    public static string Topic(string cmd, IEnumerable<ObjectId> ids)
    {
        if (IsTransform(cmd)) return cmd;
        if (cmd.IndexOf("SURFACE", StringComparison.Ordinal) >= 0) return "SURFACE";
        if (cmd.StartsWith("GRIP_", StringComparison.Ordinal))
        {
            var kinds = ids.Select(ImpactAnalyzer.KindOf).ToList();
            if (kinds.Contains("alignment")) return "GRIP_ALIGNMENT";
            if (kinds.Contains("profile")) return "GRIP_PROFILE";
            if (kinds.Contains("surface")) return "SURFACE";
        }
        return "GENERAL";
    }

    private enum Moment { Before, WhileSelecting, After }

    /// <summary>Every impact warning goes through here: logged, then shown.</summary>
    private static NoticeResult Warn(DocState st, string cmd, string topic, List<string> lines, Moment when)
    {
        CutOnceApp.LogEvent(st.Doc, "IMPACT",
            $"{cmd} ({topic}){(when == Moment.After ? " after the edit" : when == Moment.WhileSelecting ? " while selecting" : "")}" +
            $"  {lines.Count(l => l.Length > 0)} report line(s)");

        var body = new List<string> { "Command: " + cmd, "" };
        body.AddRange(lines.Count > 0 ? lines : new List<string> { "No dependent objects were found by the automated scan." });
        var req = new NoticeRequest
        {
            Headline = when == Moment.After
                ? $"{cmd} changed objects that other objects depend on"
                : $"{cmd}: these objects depend on what you are about to edit",
            Kind = NoticeKind.Warning,
            Lines = body,
            Links = new List<NoticeLink> { new NoticeLink("Learn More...", topic) },
            Footnote = S.FrequencyNote(),
            OfferCopy = true,
        };
        if (when == Moment.WhileSelecting)
        {
            Notices.ApplyStop(req, StopOffer.StopCommand, cmd,
                $"Nothing has changed yet. Stop {cmd} cancels the command; Leave them out removes these objects from the selection and carries on.");
            req.Actions.Add("Leave them out");
        }
        else
        {
            Notices.ApplyStop(req, when == Moment.After ? StopOffer.UndoCommand : StopOffer.StopCommand, cmd, null);
        }
        var r = Notices.Show(req, st.Doc, "Before going ahead: " + cmd);
        S.MarkWarned(WarnKey(cmd));
        return r;
    }

    // ------------------------------------------------------------------
    // MOVE / STRETCH / ROTATE / SCALE
    // ------------------------------------------------------------------

    /// <summary>As the command starts. True = Stop.</summary>
    public static bool TransformPreStart(DocState st, string cmd, ObjectId[] ids)
    {
        if (!ShouldWarn(cmd)) return false;
        List<string> lines;
        using (var a = new ImpactAnalyzer(st.Doc.Database)) lines = a.AnalyzeIds(ids);
        if (lines.Count > 0) return Warn(st, cmd, cmd, lines, Moment.Before).IsStop;
        if (ids.Length == 0)
        {
            // nothing pre-selected: watch the selection, and check again at the end
            st.TransformPending = cmd;
            if (S.CommandWarnOn("WarnWhileSelecting"))
            {
                st.SelectionWatch = cmd;
                st.SelectionWarned = false;
                st.FilterCivil = false;
            }
        }
        return false;
    }

    /// <summary>Objects were just added to the selection of a watched command.</summary>
    public static void SelectionAdded(DocState st, SelectionAddedEventArgs e)
    {
        string cmd = st.SelectionWatch;
        ObjectId[] added = e.AddedObjects?.GetObjectIds() ?? new ObjectId[0];
        var civilIdx = Enumerable.Range(0, added.Length).Where(i => ImpactAnalyzer.KindOf(added[i]) != null).ToList();
        if (civilIdx.Count == 0) return;

        if (st.FilterCivil)
        {
            for (int k = civilIdx.Count - 1; k >= 0; k--) e.Remove(civilIdx[k]);
            return;
        }
        if (st.SelectionWarned) return;

        List<string> lines;
        using (var a = new ImpactAnalyzer(st.Doc.Database)) lines = a.AnalyzeIds(civilIdx.Select(i => added[i]));
        if (lines.Count == 0) return;
        st.SelectionWarned = true;
        st.TransformPending = null;   // warned now; no second warning at the end

        var r = Warn(st, cmd, cmd, lines, Moment.WhileSelecting);
        if (r.IsStop)
        {
            for (int i = added.Length - 1; i >= 0; i--) e.Remove(i);
            st.SelectionWatch = null;
            Acad.CancelRunningCommand(st.Doc);
            CutOnceApp.LogEvent(st.Doc, "COMMAND-STOPPED", cmd + " stopped from its warning while selecting");
            Acad.Msg("CutOnce", cmd + " stopped - nothing was changed.");
        }
        else if (r.IsAction(0))
        {
            for (int k = civilIdx.Count - 1; k >= 0; k--) e.Remove(civilIdx[k]);
            st.FilterCivil = true;
            CutOnceApp.LogEvent(st.Doc, "SELECTION-FILTERED", cmd + ": Civil 3D objects left out of the selection");
            Acad.Msg("CutOnce", "Civil 3D objects with dependents were left out of the selection.");
        }
    }

    /// <summary>When the command ends: the objects picked after it started, if not warned already.</summary>
    public static void CommandEnded(DocState st, string cmd)
    {
        if (st.TransformPending != cmd) return;
        st.TransformPending = null;
        if (!ShouldWarn(cmd)) return;
        ObjectId[] ids;
        try
        {
            PromptSelectionResult prev = st.Doc.Editor.SelectPrevious();
            ids = prev.Status == PromptStatus.OK && prev.Value != null ? prev.Value.GetObjectIds() : new ObjectId[0];
        }
        catch (Exception)
        {
            return;
        }
        List<string> lines;
        using (var a = new ImpactAnalyzer(st.Doc.Database)) lines = a.AnalyzeIds(ids);
        if (lines.Count == 0) return;
        var r = Warn(st, cmd, cmd, lines, Moment.After);
        Notices.HandleUndo(st.Doc, r, cmd);
    }

    // ------------------------------------------------------------------
    // Grip edits, surface edits and other watched commands
    // ------------------------------------------------------------------

    /// <summary>As the command starts. True = Stop.</summary>
    public static bool WatchedPreStart(DocState st, string cmd, ObjectId[] ids)
    {
        if (!ShouldWarn(cmd)) return false;
        List<string> lines;
        using (var a = new ImpactAnalyzer(st.Doc.Database))
        {
            lines = a.AnalyzeIds(ids);
            if (cmd.IndexOf("PROFILE", StringComparison.Ordinal) >= 0 && ids.Length > 0) lines = a.AnalyzeForProfileCommand(ids);
            // nothing pre-selected: infer the object type from the command name and report on all of them
            string kind = cmd.IndexOf("SURFACE", StringComparison.Ordinal) >= 0 ? "surface"
                        : cmd.IndexOf("PROFILE", StringComparison.Ordinal) >= 0 ? "profile"
                        : cmd.IndexOf("ALIGNMENT", StringComparison.Ordinal) >= 0 ? "alignment" : null;
            if (lines.Count == 0 && kind != null)
            {
                var all = a.AnalyzeAll(kind);
                if (all.Count > 0)
                {
                    lines = kind == "surface"
                        ? GuardTexts.SurfaceEditWarning.ToList()
                        : new List<string> { $"Could not tell which {kind} this command targets.", $"Showing potential impacts for ALL {kind}s in the drawing:", "" };
                    lines.AddRange(all);
                }
            }
        }
        if (lines.Count == 0) return false;
        return Warn(st, cmd, Topic(cmd, ids), lines, Moment.Before).IsStop;
    }

    public static IEnumerable<string> StatusLines()
    {
        yield return $"Warnings: {(S.IsOn("CommandWarnings") ? "ON" : "OFF")} ({(S.WarnMode == WarnMode.Once ? "once per command per session" : "every time")})";
        foreach (string k in new[] { "WarnMOVE", "WarnSTRETCH", "WarnROTATE", "WarnSCALE", "WarnGRIPS", "WarnSURFACE", "WarnOTHER", "WarnOfferStop", "WarnWhileSelecting" })
            yield return $"  {SettingsCatalog.Label(k)}: {(S.IsOn(k) ? "ON" : "OFF")}{(S.IsLocked(k) ? "  (set by CAD admin)" : "")}";
    }
}
