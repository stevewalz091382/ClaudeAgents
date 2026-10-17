using System;
using System.Collections.Generic;
using System.Diagnostics;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;
using CutOnce.Modules;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

namespace CutOnce.Host;

/// <summary>Everything CutOnce remembers about one open drawing between events.</summary>
internal sealed class DocState
{
    public DocState(Document doc) { Doc = doc; }
    public Document Doc { get; }

    /// <summary>The open-time check (standards, Health.csv, Opened.csv) has not run yet.</summary>
    public bool OpenPending;

    // ---- command gate (stop before a command runs) ----
    /// <summary>The command whose pre-start warning has already been handled.</summary>
    public string PreStartDone;
    /// <summary>CommandWillStart fired; waiting for the lock event, else the idle fallback.</summary>
    public string AwaitingPreStart;
    /// <summary>The pickfirst selection when the current command started.</summary>
    public ObjectId[] PickfirstAtStart = new ObjectId[0];

    // ---- pickfirst cache (ImpliedSelectionChanged) ----
    public ObjectId[] Implied = new ObjectId[0];
    public ObjectId[] LastNonEmptyImplied = new ObjectId[0];
    public readonly Stopwatch SinceImpliedCleared = new Stopwatch();

    // ---- guard ----
    public Dictionary<string, long> ExplodeSnapshot;
    public long ExplodeAttribSnapshot;
    public bool ExplodePending;
    public bool ExplodePreWarned;
    public bool InLisp;
    public string LispName;
    public List<string> XrefSnapshot;
    public bool CheckXrefMove;
    public List<KeyValuePair<string, double[]>> XrefPointsSnapshot;

    // ---- impact ----
    /// <summary>MOVE/STRETCH/ROTATE/SCALE started with nothing selected: analyse when it ends.</summary>
    public string TransformPending;
    /// <summary>The command whose selection is being watched (SelectionAdded).</summary>
    public string SelectionWatch;
    public bool SelectionWarned;
    /// <summary>The designer chose "Leave them out": keep removing Civil 3D objects from this selection.</summary>
    public bool FilterCivil;

    /// <summary>Forgets the per-command state of a command that has finished (transparent commands leave it alone).</summary>
    public void ClearCommand(string cmd)
    {
        if (PreStartDone == cmd) PreStartDone = null;
        if (AwaitingPreStart == cmd) AwaitingPreStart = null;
        if (TransformPending == cmd) TransformPending = null;
        if (SelectionWatch == cmd)
        {
            SelectionWatch = null;
            SelectionWarned = false;
            FilterCivil = false;
        }
    }
}

/// <summary>
/// Attaches CutOnce to every drawing (command, LISP, selection and save events) and
/// runs the open-time check once each drawing is open and idle. This replaces the
/// LISP edition's vlr-command / vlr-lisp / vlr-editor reactors.
/// </summary>
internal static class DocMonitor
{
    private static readonly Dictionary<Document, DocState> States = new Dictionary<Document, DocState>();
    private static bool _started;

    public static bool Running => _started;

    public static void Start()
    {
        if (_started) return;
        _started = true;
        DocumentCollection dm = AcApp.DocumentManager;
        dm.DocumentCreated += OnDocumentCreated;
        dm.DocumentToBeDestroyed += OnDocumentToBeDestroyed;
        dm.DocumentLockModeChanged += CommandGate.OnLockModeChanged;
        foreach (Document doc in dm) Attach(doc, true);
        AcApp.Idle += OnIdle;
    }

    public static void Stop()
    {
        if (!_started) return;
        _started = false;
        DocumentCollection dm = AcApp.DocumentManager;
        dm.DocumentCreated -= OnDocumentCreated;
        dm.DocumentToBeDestroyed -= OnDocumentToBeDestroyed;
        dm.DocumentLockModeChanged -= CommandGate.OnLockModeChanged;
        AcApp.Idle -= OnIdle;
        foreach (var doc in new List<Document>(States.Keys)) Detach(doc);
    }

    public static DocState Get(Document doc)
    {
        if (doc == null) return null;
        return States.TryGetValue(doc, out var st) ? st : null;
    }

    private static void OnDocumentCreated(object sender, DocumentCollectionEventArgs e) => Attach(e.Document, true);

    private static void OnDocumentToBeDestroyed(object sender, DocumentCollectionEventArgs e) => Detach(e.Document);

    private static void Attach(Document doc, bool openPending)
    {
        if (doc == null || States.ContainsKey(doc)) return;
        States[doc] = new DocState(doc) { OpenPending = openPending };
        doc.CommandWillStart += OnCommandWillStart;
        doc.CommandEnded += OnCommandEnded;
        doc.CommandCancelled += OnCommandCancelled;
        doc.CommandFailed += OnCommandCancelled;
        doc.LispWillStart += OnLispWillStart;
        doc.LispEnded += OnLispEnded;
        doc.LispCancelled += OnLispEnded;
        doc.ImpliedSelectionChanged += OnImpliedSelectionChanged;
        doc.Database.BeginSave += OnBeginSave;
        doc.Editor.SelectionAdded += OnSelectionAdded;
    }

    private static void Detach(Document doc)
    {
        if (doc == null || !States.Remove(doc)) return;
        try
        {
            doc.CommandWillStart -= OnCommandWillStart;
            doc.CommandEnded -= OnCommandEnded;
            doc.CommandCancelled -= OnCommandCancelled;
            doc.CommandFailed -= OnCommandCancelled;
            doc.LispWillStart -= OnLispWillStart;
            doc.LispEnded -= OnLispEnded;
            doc.LispCancelled -= OnLispEnded;
            doc.ImpliedSelectionChanged -= OnImpliedSelectionChanged;
            doc.Database.BeginSave -= OnBeginSave;
            doc.Editor.SelectionAdded -= OnSelectionAdded;
        }
        catch (Exception)
        {
            // the drawing is already going away
        }
    }

    /// <summary>Runs an event body so that no CutOnce failure ever reaches Civil 3D.</summary>
    public static void Safe(string what, Action body)
    {
        try { body(); }
        catch (Exception ex)
        {
            if (ImpactService.Debug) Acad.Msg("CutOnce", what + " failed: " + ex.Message);
        }
    }

    private static string Cmd(CommandEventArgs e) => (e.GlobalCommandName ?? "").ToUpperInvariant();

    private static void OnCommandWillStart(object sender, CommandEventArgs e)
    {
        var st = Get(sender as Document);
        if (st == null) return;
        string cmd = Cmd(e);
        Safe("command start", () =>
        {
            if (GuardService.LogAllCommands) Acad.Msg("CutOnce Guard", "command: " + cmd);
            st.PickfirstAtStart = CommandGate.Pickfirst(st);
            GuardService.CommandWillStart(st, cmd);
            CommandGate.OnCommandWillStart(st, cmd);
        });
    }

    private static void OnCommandEnded(object sender, CommandEventArgs e)
    {
        var st = Get(sender as Document);
        if (st == null) return;
        string cmd = Cmd(e);
        Safe("command end", () =>
        {
            GuardService.CommandEnded(st, cmd);
            ImpactService.CommandEnded(st, cmd);
        });
        st.ClearCommand(cmd);
    }

    private static void OnCommandCancelled(object sender, CommandEventArgs e)
    {
        var st = Get(sender as Document);
        if (st == null) return;
        Safe("command cancel", () => GuardService.CommandCancelled(st));
        st.ClearCommand(Cmd(e));
    }

    private static void OnLispWillStart(object sender, LispWillStartEventArgs e)
    {
        var st = Get(sender as Document);
        if (st == null) return;
        st.InLisp = true;
        st.LispName = GuardService.LispCommandName(e.FirstLine);
    }

    private static void OnLispEnded(object sender, EventArgs e)
    {
        var st = Get(sender as Document);
        if (st == null) return;
        st.InLisp = false;
        Safe("LISP end", () => GuardService.LispEnded(st));
        st.LispName = null;
    }

    private static void OnImpliedSelectionChanged(object sender, EventArgs e)
    {
        var st = Get(sender as Document);
        if (st == null) return;
        try
        {
            PromptSelectionResult r = st.Doc.Editor.SelectImplied();
            ObjectId[] ids = r.Status == PromptStatus.OK && r.Value != null ? r.Value.GetObjectIds() : new ObjectId[0];
            if (ids.Length > 0)
            {
                st.LastNonEmptyImplied = ids;
                st.SinceImpliedCleared.Reset();
            }
            else if (st.Implied.Length > 0)
            {
                st.SinceImpliedCleared.Restart();
            }
            st.Implied = ids;
        }
        catch (Exception)
        {
            // pickfirst not readable now; keep the last value
        }
    }

    private static void OnSelectionAdded(object sender, SelectionAddedEventArgs e)
    {
        var ed = sender as Editor;
        var st = Get(ed?.Document);
        if (st?.SelectionWatch == null) return;
        Safe("selection", () => ImpactService.SelectionAdded(st, e));
    }

    private static void OnBeginSave(object sender, DatabaseIOEventArgs e)
    {
        var doc = Acad.DocumentOf(sender as Database);
        if (doc == null) return;
        Safe("save check", () => HealthService.OnBeginSave(doc, e.FileName));
    }

    /// <summary>
    /// Idle: the open-time check for a drawing that has finished opening, and the
    /// fallback for a command whose start could not be intercepted.
    /// </summary>
    private static void OnIdle(object sender, EventArgs e)
    {
        Document doc = Acad.ActiveDoc;
        var st = Get(doc);
        if (st == null) return;
        if (st.AwaitingPreStart != null) Safe("command gate", () => CommandGate.OnIdle(st));
        if (st.OpenPending)
        {
            bool quiet;
            try { quiet = doc.Editor.IsQuiescent; } catch (Exception) { quiet = false; }
            if (!quiet) return;
            st.OpenPending = false;
            Safe("open check", () => HealthService.OnOpen(doc));
        }
    }
}
