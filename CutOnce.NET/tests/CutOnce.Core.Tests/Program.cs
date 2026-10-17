using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using CutOnce.Core;

// A dependency-free test runner: each Test(...) prints PASS/FAIL; exit code = failures.
internal static class Program
{
    private static int _failed, _passed;

    private static void Test(string name, Action body)
    {
        try { body(); _passed++; Console.WriteLine("PASS  " + name); }
        catch (Exception ex) { _failed++; Console.WriteLine("FAIL  " + name + "\n      " + ex.Message); }
    }

    private static void Eq<T>(T expected, T actual, string what = "")
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new Exception($"{what} expected <{expected}> but was <{actual}>");
    }

    private static void True(bool cond, string what) { if (!cond) throw new Exception(what); }

    private static string RepoFile(params string[] parts)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "CutOnce.sln"))) dir = dir.Parent;
        if (dir == null) throw new Exception("CutOnce.sln not found above " + AppContext.BaseDirectory);
        return Path.Combine(new[] { dir.FullName }.Concat(parts).ToArray());
    }

    private static int Main()
    {
        // ---------------- LISP config reader ----------------
        Test("reader: dotted pairs, nil, T, numbers, strings, comments", () =>
        {
            var cfg = CutOnceConfig.Parse(@"
                ;; comment
                ;| block
                   comment |;
                (setq *cutonce:config*
                  '(
                    (""LogDir"" . nil)
                    (""BrandColor"" . 150)
                    (""Pct"" . 12.5)
                    (""StdAlwaysShow"" . T)
                    (""Name"" . ""Acme \""Civil\"" C:\\CAD"")
                    (""LockedSettings"" . (""LogEnabled"" ""WarnMOVE""))
                    (""HealthExtraCounts"" . ((""FeatureLines"" . ""AeccDbFeatureLine"") (""Dims"" . ""AcDb*Dimension"")))
                    (""LogDir"" . ""second wins? no, first wins"")
                  ))");
            Eq(null, cfg.Get("LogDir"), "LogDir");
            True(cfg.Has("LogDir"), "LogDir present");
            Eq(150.0, cfg.GetNumber("BrandColor"));
            Eq(12.5, cfg.GetNumber("Pct"));
            Eq(true, cfg.GetBool("StdAlwaysShow", false));
            Eq(false, cfg.GetBool("LogDir", true), "nil is false");
            Eq(true, cfg.GetBool("Missing", true), "missing uses default");
            Eq("Acme \"Civil\" C:\\CAD", cfg.GetString("Name"));
            Eq("LogEnabled,WarnMOVE", string.Join(",", cfg.GetStringList("LockedSettings")));
            var pairs = cfg.GetStringPairs("HealthExtraCounts");
            Eq(2, pairs.Count);
            Eq("AcDb*Dimension", pairs[1].Value);
        });

        Test("reader: the shipped CutOnce-Config.lsp parses with every documented default", () =>
        {
            var cfg = CutOnceConfig.LoadFile(RepoFile("bundle", "CutOnce.bundle", "Contents", "CutOnce-Config.lsp"));
            Eq(null, cfg.LoadError, "LoadError");
            Eq(true, cfg.GetBool("CommandWarnings", false));
            Eq(false, cfg.GetBool("StdAlwaysShow", true));
            Eq("every", cfg.GetString("WarnFrequency"));
            Eq(20.0, cfg.GetNumber("GuardGrowthWarnPct"));
            Eq("CutOnce", cfg.GetString("BrandName"));
            Eq(0, cfg.GetStringList("LockedSettings").Count);
            foreach (var def in SettingsCatalog.All) True(cfg.Has(def.Key), "config lists " + def.Key);
        });

        Test("reader: broken file gives defaults and a LoadError, never throws", () =>
        {
            string tmp = Path.GetTempFileName();
            File.WriteAllText(tmp, "(setq *cutonce:config* '((\"A\" . 1)");
            var cfg = CutOnceConfig.LoadFile(tmp);
            True(cfg.LoadError != null, "LoadError set");
            Eq(true, cfg.GetBool("A", true));
            File.Delete(tmp);
        });

        // ---------------- settings ----------------
        Test("settings: locked > user choice > admin default > built-in", () =>
        {
            var cfg = CutOnceConfig.Parse("(setq *cutonce:config* '((\"WarnMOVE\" . nil) (\"LogXrefs\" . nil) (\"LockedSettings\" . (\"LogXrefs\"))))");
            var store = new MemoryPreferenceStore();
            var s = new SettingsService(cfg, store);
            Eq(false, s.IsOn("WarnMOVE"), "admin default");
            Eq(true, s.IsOn("WarnCOPY"), "built-in default");
            Eq(false, s.IsOn("StdAlwaysShow"), "built-in nil");
            s.SetOn("WarnMOVE", true);
            Eq("1", store.Get("CutOnce.WarnMOVE"));
            Eq(true, s.IsOn("WarnMOVE"));
            s.SetOn("WarnMOVE", false);
            Eq(null, store.Get("CutOnce.WarnMOVE"), "choice equal to default is stored as no choice");
            s.SetOn("LogXrefs", true);
            Eq(null, store.Get("CutOnce.LogXrefs"), "locked keys never written");
            Eq(false, s.IsOn("LogXrefs"));
            True(s.AnyLocked, "AnyLocked");
        });

        Test("settings: master switches gate their children", () =>
        {
            var s = new SettingsService(CutOnceConfig.Empty, new MemoryPreferenceStore());
            Eq(true, s.CommandWarnOn("WarnEXPLODE"));
            s.SetOn("CommandWarnings", false);
            Eq(false, s.CommandWarnOn("WarnEXPLODE"));
            Eq(false, s.OfferStop, "stop needs the master switch");
            s.SetOn("LogEnabled", false);
            Eq(false, s.LogOn("LogEvents"));
        });

        Test("settings: once-per-session frequency", () =>
        {
            var s = new SettingsService(CutOnceConfig.Empty, new MemoryPreferenceStore());
            Eq(WarnMode.Every, s.WarnMode);
            s.MarkWarned("IMPACT:MOVE");
            True(s.IsDue("IMPACT:MOVE"), "every: always due");
            s.SetWarnMode(WarnMode.Once);
            True(s.IsDue("IMPACT:MOVE"), "changing mode forgets what was shown");
            s.MarkWarned("IMPACT:MOVE");
            True(!s.IsDue("IMPACT:MOVE"), "once: not due again");
            True(s.IsDue("IMPACT:SCALE"), "other commands still due");
        });

        // ---------------- wildcards ----------------
        Test("wildcard: wcmatch semantics", () =>
        {
            True(Wildcard.IsMatch("ACDBALIGNEDDIMENSION", "ACDB*DIMENSION"), "*");
            True(Wildcard.IsMatch("AECCDBSURFACEGRID", "AECCDBSURFACETIN,AECCDBSURFACEGRID"), "comma");
            True(!Wildcard.IsMatch("AECCDBSURFACETINX", "AECCDBSURFACETIN"), "anchored");
            True(Wildcard.IsMatch("*U12", "`**"), "backquote");
            True(!Wildcard.IsMatch("A12", "`**"), "backquote literal");
            True(Wildcard.IsMatch("C101", "@###"), "# and @");
            True(Wildcard.IsMatch("ABC", "~XYZ"), "negation");
            True(!Wildcard.IsMatch("XYZ", "~XYZ"), "negation 2");
            True(Wildcard.IsMatch(@"\\SERVER\PROJECTS\1234-ROAD\C.DWG", @"\\SERVER\PROJECTS\1234*"), "path");
        });

        // ---------------- CSV ----------------
        Test("csv: quoting and splitting round-trip", () =>
        {
            string row = Csv.Row("a,b", "say \"hi\"", 3L, 1.5, null, true);
            Eq("\"a,b\",\"say \"\"hi\"\"\",3,1.500000,,True", row);
            var f = Csv.Split(row);
            Eq(6, f.Count);
            Eq("say \"hi\"", f[1]);
        });

        Test("csv: header change archives the old log once", () =>
        {
            string dir = Path.Combine(Path.GetTempPath(), "cutonce-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, "Health.csv");
            File.WriteAllLines(path, new[] { "Old,Header", "1,2" });
            var w = new CsvLogWriter();
            var messages = new List<string>();
            w.Message = messages.Add;
            True(w.AppendLine(path, "New,Header", "3,4"), "append");
            Eq("New,Header", CsvLogWriter.FirstLine(path));
            Eq(2, Directory.GetFiles(dir).Length);
            True(Directory.GetFiles(dir).Any(p => Path.GetFileName(p).StartsWith("Health-archived-")), "archived");
            True(w.AppendLine(path, "New,Header", "5,6"), "second append");
            Eq(3, CsvLogWriter.ReadLines(path).Count);
            Directory.Delete(dir, true);
        });

        // ---------------- folders ----------------
        Test("folders: log folder resolution and per-person subfolder", () =>
        {
            var cfg = CutOnceConfig.Parse("(setq *cutonce:config* '((\"LogDir\" . \"//server/cad/Logs\") (\"LogSubfolder\" . \"user-computer\")))");
            var env = new Dictionary<string, string>();
            var f = new Folders(cfg, n => env.TryGetValue(n, out var v) ? v : null, "j:smith", "PC12", Path.GetTempPath());
            Eq("jsmith-PC12", f.LogSubfolder());
            env["CUTONCE_LOGSUBFOLDER"] = "computer";
            Eq("PC12", f.LogSubfolder(), "environment wins");
            Eq(@"\\server\cad\Backups\", Folders.DirSlash("//server/cad/Backups/"));
            Eq(null, Folders.SafeFolder(" . "));
        });

        Test("backup: unique names with a counter", () =>
        {
            var taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var now = new DateTime(2026, 10, 15, 14, 30, 5, 789);
            string a = BackupNaming.Name(@"\\srv\Backups", @"C:\P\C-Grading.dwg", "jsmith", "CAD-PC12", now, taken.Contains);
            Eq(@"\\srv\Backups\C-Grading__20261015-143005-789_jsmith-CAD-PC12.dwg", a);
            taken.Add(a);
            string b = BackupNaming.Name(@"\\srv\Backups", @"C:\P\C-Grading.dwg", "jsmith", "CAD-PC12", now, taken.Contains);
            Eq(@"\\srv\Backups\C-Grading__20261015-143005-789_jsmith-CAD-PC12-2.dwg", b);
        });

        // ---------------- knowledge base ----------------
        Test("kb: default links highlight the topic line", () =>
        {
            Eq("https://designtovisualization.com/kb-c3d-and-cutonce-assistant/#drawing-growth:~:text=Learn%20More%20topic%3A%20GUARD_GROWTH",
               KnowledgeBase.Url("GUARD_GROWTH", CutOnceConfig.Empty));
            Eq("https://designtovisualization.com/kb-c3d-and-cutonce-assistant/#refclose", KnowledgeBase.Url("GUARD_REFCLOSE", CutOnceConfig.Empty));
            var cfg = CutOnceConfig.Parse("(setq *cutonce:config* '((\"LearnMoreUrl\" . \"https://intra/kb#x\") (\"LearnMoreAnchors\" . ((\"MOVE\" . \"\")))))");
            Eq("https://intra/kb", KnowledgeBase.Url("MOVE", cfg), "empty anchor = top of page");
            Eq("https://intra/kb#rotate-civil-objects", KnowledgeBase.Url("ROTATE", cfg), "custom page: no highlight");
        });

        // ---------------- health / growth ----------------
        Test("growth: RegApps, new-since and percentage rules", () =>
        {
            var prev = new Dictionary<string, object> { ["RegApps"] = 10L, ["Layers"] = 100L, ["Hatches"] = 0L, ["Blocks"] = 50L, ["Styles"] = "n/a" };
            var cur = new Dictionary<string, object> { ["RegApps"] = 11L, ["Layers"] = 120L, ["Hatches"] = 3L, ["Blocks"] = 55L, ["Styles"] = 400L };
            var flags = GrowthCheck.Flags(prev, cur, new List<ExtraCount>(), 20);
            Eq("Layers,RegApps,Hatches", string.Join(",", flags.Select(f => f.Metric)));
            Eq("up 20% since the last check", flags[0].Reason);
        });

        Test("health: previous row parsed only from the current layout", () =>
        {
            var cols = HealthSchema.Columns(new List<ExtraCount>());
            var lines = new List<string> { string.Join(",", cols) };
            var facts = new Dictionary<string, object> { ["Layers"] = 12L, ["Styles"] = "n/a" };
            lines.Add(HealthSchema.Row("2026-01-01 00:00:00", "Save", "me", @"C:\a.dwg", "a.dwg", facts, new List<ExtraCount>()));
            facts["Layers"] = 15L;
            lines.Add(HealthSchema.Row("2026-01-02 00:00:00", "Save", "me", @"C:\a.dwg", "a.dwg", facts, new List<ExtraCount>()));
            var prev = HealthSchema.PreviousRow(lines, cols, @"C:\a.dwg");
            Eq(15L, prev["Layers"]);
            Eq("n/a", prev["Styles"]);
            Eq(null, HealthSchema.PreviousRow(new List<string> { "Other,Header" }, cols, @"C:\a.dwg"));
        });

        Test("health: extra columns are sanitised and never repeat built-ins", () =>
        {
            var cfg = CutOnceConfig.Parse("(setq *cutonce:config* '((\"HealthExtraCounts\" . ((\"Feature Lines!\" . \"AeccDbFeatureLine\") (\"Layers\" . \"x\") (\"Dims\" . \"AcDb*Dimension\")))))");
            var extras = HealthSchema.ExtraCounts(cfg);
            Eq("FeatureLines,Dims", string.Join(",", extras.Select(e => e.Column)));
            var counts = new Dictionary<string, long> { ["AcDbAlignedDimension"] = 3, ["AcDbRotatedDimension"] = 2, ["AcDbLine"] = 9 };
            Eq(5L, HealthSchema.Sum(counts, extras[1].Pattern));
        });

        // ---------------- standards ----------------
        Test("standards: xref pairing, broken/unloaded/off-origin and coordinate issues", () =>
        {
            var scan = new SpaceScan();
            scan.XrefInserts.Add(new XrefInsert { Name = "BASE", Point = new double[] { 0, 0, 0 } });
            scan.XrefInserts.Add(new XrefInsert { Name = "TOPO", Point = new double[] { 10, 5, 0 } });
            var defs = new[]
            {
                new XrefDefinition { Name = "BASE", Status = "Loaded", Units = 2, CoordinateSystem = "CA83-VIF" },
                new XrefDefinition { Name = "TOPO", Status = "Unloaded", Units = 6 },
                new XrefDefinition { Name = "GONE", Status = "Not Found" },
            };
            var project = new ProjectStandard("CA83-VI", 21, "ini");
            var f = DrawingFacts.Assemble(scan, null, defs, "CA83-VIF", 2, project, true);
            Eq(1, f.XrefsBroken); Eq(1, f.XrefsUnloaded); Eq(1, f.OffOrigin.Count);
            Eq("Yes", f.Xrefs[0].AtOrigin); Eq("No", f.Xrefs[1].AtOrigin); Eq("", f.Xrefs[2].AtOrigin);
            True(f.CoordIssues.Any(i => i.Contains("does not match the project's CA83-VI")), "cs mismatch");
            True(f.CoordIssues.Any(i => i.Contains("the project uses US Survey Feet")), "units mismatch");
            True(f.CoordIssues.Any(i => i.Contains("Xref TOPO is in Meters")), "xref units");
            var settings = new SettingsService(CutOnceConfig.Empty, new MemoryPreferenceStore());
            var report = StandardsReport.Build(f, "C-101.dwg", false, settings);
            True(report.HasIssues, "issues");
            Eq("Standards check found problems in C-101.dwg", report.Headline);
            Eq(4, report.Links.Count); // reading + xref status + origin + coords
            var row = new Dictionary<string, object>();
            f.AddHealthColumns(row, new List<ExtraCount>());
            Eq("n/a", row["BlockDefColorNotByLayer"]);
            Eq(3L, row["Xrefs"]);
            Eq(3, f.XrefRows("t", "Save", "me", "p", "n").Count());
        });

        Test("standards: project ini found in a parent folder", () =>
        {
            var files = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
            {
                [@"P:\1234\CutOnce-Project.ini"] = new[] { "; comment", "[Project]", "CoordinateSystem=CA83-VIF", "InsUnits=US Survey Feet" },
            };
            var r = new ProjectStandardsResolver(CutOnceConfig.Empty, files.ContainsKey, p => files[p]);
            var ps = r.Resolve(@"P:\1234\Civil\Base\C-Base.dwg");
            Eq("CA83-VIF", ps.CoordinateSystem); Eq(21, ps.InsUnits); Eq(@"P:\1234\CutOnce-Project.ini", ps.Source);
            Eq(null, r.Resolve(@"Q:\Other\x.dwg"));
        });

        Test("standards: project from config wildcard", () =>
        {
            var cfg = CutOnceConfig.Parse(@"(setq *cutonce:config* '((""ProjectStandards""
                . ((""//server/projects/1234*"" . ((""CoordinateSystem"" . ""CA83-VIF"") (""InsUnits"" . ""US Survey Feet"")))
                   (""P:/Metric/*"" . ((""CoordinateSystem"" . ""UTM83-10"") (""InsUnits"" . ""Meters"")))))))");
            var r = new ProjectStandardsResolver(cfg, _ => false, _ => new List<string>());
            Eq("UTM83-10", r.Resolve(@"P:\Metric\Job\a.dwg").CoordinateSystem);
            Eq(6, r.Resolve(@"P:\Metric\Job\a.dwg").InsUnits);
            Eq("CA83-VIF", r.Resolve(@"\\server\projects\1234-Road\b.dwg").CoordinateSystem);
        });

        Test("units and coordinate system parsing", () =>
        {
            Eq(21, Units.Parse("us survey feet")); Eq(2, Units.Parse("2")); Eq(6, Units.Parse(6L)); Eq(null, Units.Parse("furlongs"));
            Eq("CA83-VIF", CoordinateSystems.CodeFromDefinition("<Dictionary><ProjectedCoordinateSystem id=\"CA83-VIF\" x=\"1\"/>"));
            Eq("NAD83 / California zone 6", CoordinateSystems.CodeFromDefinition("PROJCS[\"NAD83 / California zone 6\",GEOGCS[\"NAD83\"]]"));
            Eq("UTM83-10", CoordinateSystems.CodeFromDefinition("UTM83-10"));
        });

        // ---------------- message text ----------------
        Test("text: headline split and line classification", () =>
        {
            var (head, body) = MessageText.SplitHeadline("CutOnce Guard tip:\n\nPlain TEXT won't update\nmore", "CutOnce");
            Eq("Plain TEXT won't update", head);
            Eq("more", body[0]);
            Eq(BodyLineKind.Heading, MessageText.Classify("OBJECTS NOT BYLAYER (model space and layouts)").Kind);
            Eq(BodyLineKind.Heading, MessageText.Classify("ALIGNMENT: Main St").Kind);
            var d = MessageText.Classify("   Color not ByLayer:      12");
            Eq(BodyLineKind.Detail, d.Kind); Eq("12", d.Value);
            var b = MessageText.Classify("      - Not Found: TOPO  C:\\x.dwg");
            Eq(BodyLineKind.Bullet, b.Kind); Eq(2, b.Indent);
            Eq(BodyLineKind.Paragraph, MessageText.Classify("If this wasn't intentional, undo it now.").Kind);
            Eq(BodyLineKind.Paragraph, MessageText.Classify("Plain TEXT/MTEXT for stations").Kind);
            Eq(BodyLineKind.Heading, MessageText.Classify("PROFILES on this alignment:").Kind);
            Eq(BodyLineKind.Detail, MessageText.Classify("   Layers:  100 -> 120  (up 20% since the last check)").Kind);
            var flowed = MessageText.ClassifyAll(new[] { "Binding copies all of that drawing's layers", "permanently, which causes", "growth.", "", "  (\"Key\" . nil)", "  and replace nil" });
            Eq(4, flowed.Count);
            Eq("Binding copies all of that drawing's layers permanently, which causes growth.", flowed[0].Text);
            Eq(BodyLineKind.Blank, flowed[1].Kind);
        });

        // ---------------- guard ----------------
        Test("guard: explode report and copy rules", () =>
        {
            var before = new Dictionary<string, long> { ["AeccDbAlignment"] = 2, ["AcDbHatch"] = 5, ["AcDbBlockReference"] = 9 };
            var after = new Dictionary<string, long> { ["AeccDbAlignment"] = 1, ["AcDbHatch"] = 5, ["AcDbBlockReference"] = 9 };
            var r = ExplodeReport.Compare(before, after, 4, 3);
            True(r.CivilLost, "civil lost"); Eq("GUARD_EXPLODE", r.WarningKey); Eq(1L, r.AttributedConverted);
            True(r.Lines(4, 3).Any(l => l.Contains("Alignment:  2 -> 1 (down 1)")), "lines");
            Eq(2, r.Links().Count);
            True(!GuardTexts.CopyOffered("GUARD_TEXT:MTEXT"), "no copy on text tip");
            True(GuardTexts.CopyOffered("GUARD_GROWTH|C-101.dwg"), "copy on growth");
            Eq("GUARD_GROWTH", GuardTexts.WarningBase("GUARD_GROWTH|C-101.dwg"));
        });

        Test("command line: abbreviations, prefixes and ambiguity", () =>
        {
            Eq("EXIT", CommandLineSettings.Resolve("x"));
            Eq("LogEnabled", CommandLineSettings.Resolve("logen"));
            Eq("WarnEXPLODE", CommandLineSettings.Resolve("warnexplode"));
            Eq(null, CommandLineSettings.Resolve("Warn"), "ambiguous");
            Eq(null, CommandLineSettings.Resolve("nonsense"));
        });

        Test("summary: rolls up opened, health and events", () =>
        {
            var cols = HealthSchema.Columns(new List<ExtraCount>());
            var opened = new List<string> { EventLog.OpenedHeader, Csv.Row("t", "me", @"C:\a.dwg", "a.dwg"), Csv.Row("t", "me", @"C:\b.dwg", "b.dwg") };
            var health = new List<string> { string.Join(",", cols),
                HealthSchema.Row("2026-01-01 00:00:00", "Save", "me", @"C:\a.dwg", "a.dwg", new Dictionary<string, object> { ["Layers"] = 3L }, new List<ExtraCount>()) };
            var events = new List<string> { EventLog.EventsHeader, Csv.Row("t", "me", @"C:\a.dwg", "a.dwg", "IMPACT", "x") };
            var lines = GuardSummary.Build(opened, health, events, cols);
            Eq("2 drawing(s) tracked:", lines[0]);
            True(lines.Any(l => l.Contains("flagged events: 1")), "events");
            True(lines.Any(l => l.Contains("Layers=3")), "health");
            True(lines.Any(l => l.Contains("(opened, no health row yet)")), "opened only");
        });

        // ---------------- view models ----------------
        Test("control center: masters grey children, reset and apply", () =>
        {
            var store = new MemoryPreferenceStore();
            var s = new SettingsService(CutOnceConfig.Parse("(setq *cutonce:config* '((\"LockedSettings\" . (\"LogXrefs\"))))"), store);
            var vm = new ControlCenterViewModel(s, @"C:\logs\", @"C:\bk\");
            True(vm["WarnMOVE"].IsEditable, "editable");
            vm.CommandWarnings.IsOn = false;
            True(!vm["WarnMOVE"].IsEditable, "greyed by master");
            True(!vm.FrequencyEditable, "frequency greyed");
            True(!vm["LogXrefs"].IsEditable, "locked");
            vm.FrequencyOnce = true;
            vm.Apply();
            Eq("0", store.Get("CutOnce.CommandWarnings"));
            Eq("once", store.Get("CutOnce.WarnFrequency"));
            var vm2 = new ControlCenterViewModel(s, "", "");
            vm2.ResetToDefaults();
            True(vm2.CommandWarnings.IsOn, "reset");
            vm2.Apply();
            Eq(null, store.Get("CutOnce.CommandWarnings"));
            Eq(null, store.Get("CutOnce.WarnFrequency"));
        });

        Test("cleanup: plan, result text and choice", () =>
        {
            var before = new Dictionary<string, object> { ["RegApps"] = 40L, ["Styles"] = 12L, ["AnonBlocks"] = 3L, ["Other"] = 100L, ["Scales"] = 30L, ["CivilStyles"] = "n/a" };
            var after = new Dictionary<string, object> { ["RegApps"] = 10L, ["Styles"] = 12L, ["AnonBlocks"] = 0L, ["Other"] = 90L, ["Scales"] = 12L, ["CivilStyles"] = "n/a" };
            Eq("40 -> 10  (30 removed)", CleanupPlan.ResultText("RegApps", before, after));
            Eq("12 -> 12  (nothing unused to remove)", CleanupPlan.ResultText("Styles", before, after));
            Eq("n/a -> n/a", CleanupPlan.ResultText("CivilStyles", before, after));
            Eq(155L, CleanupPlan.PurgeSum(before));
            var vm = new CleanupViewModel(before, true, true, true, @"C:\bk\", false, true, @"C:\a.dwg");
            True(vm.BackupForced && !vm.BackupEditable, "forced");
            vm.Steps[0].IsChecked = false;
            Eq("backup,styles,regapps,anon,all,scales,audit", string.Join(",", vm.Choice()));
            True(vm.BackupNote.Contains("Required by your CAD administrator"), "note");
        });

        Console.WriteLine();
        Console.WriteLine($"{_passed} passed, {_failed} failed");
        return _failed;
    }
}
