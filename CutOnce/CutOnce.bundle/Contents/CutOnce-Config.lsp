;;; ============================================================================
;;; CutOnce-Config.lsp  -  settings for CutOnce
;;;
;;; Edit the values below, save, and restart Civil 3D (or open a new drawing).
;;; This file is plain text on purpose so CAD administrators can change it
;;; without rebuilding the application. Keep the ("Key" . value) shape.
;;;
;;;   T    means yes / on
;;;   nil  means no / off (or "use the default" for LogDir)
;;;
;;; HOW DESIGNER CHOICES AND THIS FILE FIT TOGETHER
;;; Each designer can switch every check, warning and log on or off for
;;; themselves in the CutOnce Control Center (CUTONCE). The
;;; values in the "Control Center defaults" section below are what a designer
;;; gets until they make their own choice. To enforce a value for everyone,
;;; also list its key in "LockedSettings": it then shows greyed out in the
;;; Control Center and the value here always applies.
;;; ============================================================================

(setq *cutonce:config*
  '(
    ;; ---- Folders -----------------------------------------------------------

    ;; Where Health.csv, Xrefs.csv, Events.csv, Opened.csv and Backups.csv go.
    ;; nil = %LOCALAPPDATA%\CutOnce\Logs\ (per user, per machine).
    ;; Use forward slashes, e.g. "D:/CAD/CutOnce/Logs" or a shared
    ;; folder "//server/cad/CutOnce/Logs".
    ;; The CUTONCE_LOGDIR environment variable, if set, overrides this.
    ;; For a team: point this at one shared folder every office can reach
    ;; (a network share, or a folder each PC syncs), e.g.
    ;;   ("LogDir" . "//server/cad/CutOnce/Logs")
    ("LogDir" . nil)

    ;; With a shared LogDir, give each person (or PC) its own subfolder so
    ;; nobody writes to someone else's file and synced folders never make
    ;; conflict copies. Excel (Data > Get Data > From Folder) combines them.
    ;;   nil              no subfolder: everyone writes the same files
    ;;   "user"           <LogDir>/<Windows user name>/
    ;;   "computer"       <LogDir>/<computer name>/
    ;;   "user-computer"  <LogDir>/<user>-<computer>/   (recommended for teams)
    ;; The CUTONCE_LOGSUBFOLDER environment variable, if set, overrides this.
    ("LogSubfolder" . nil)

    ;; The shared "master" backup folder. CUTONCE-BACKUP, and the cleanup
    ;; offered when a drawing grows unusually, copy the drawing here before
    ;; anything changes, so an earlier version can always be recovered.
    ;; Every copy gets a unique name, so nobody overwrites anyone's copy:
    ;;   <drawing>__<YYYYMMDD-HHMMSS-mmm>_<user>-<computer>.dwg
    ;; nil = Documents\CutOnce Backups (per user - set a shared folder here).
    ;; Use forward slashes, e.g. "//server/cad/CutOnce/Backups".
    ;; The CUTONCE_BACKUPDIR environment variable, if set, overrides this.
    ("BackupDir" . nil)

    ;; ---- Control Center defaults -------------------------------------------
    ;; Command warnings: master switch, then one switch per command
    ("CommandWarnings"  . T)    ; master switch for every command warning below
    ("WarnMOVE"         . T)    ; MOVE of Civil 3D objects and xrefs
    ("WarnCOPY"         . T)    ; COPY of xrefs
    ("WarnSTRETCH"      . T)    ; STRETCH of Civil 3D objects
    ("WarnROTATE"       . T)    ; ROTATE of Civil 3D objects
    ("WarnSCALE"        . T)    ; SCALE of Civil 3D objects
    ("WarnEXPLODE"      . T)    ; EXPLODE / BURST of Civil 3D objects, blocks, hatches, attributes
    ("WarnXREFBIND"     . T)    ; XREF / XBIND binding an xref into the drawing
    ("WarnREFEDIT"      . T)    ; REFEDIT / REFCLOSE advisory
    ("WarnPROMOTE"      . T)    ; promoting a data shortcut reference (any *PROMOTE* command)
    ("WarnTEXT"         . T)    ; TEXT: label style tip
    ("WarnDTEXT"        . T)    ; DTEXT: label style tip
    ("WarnMTEXT"        . T)    ; MTEXT: label style tip
    ("WarnGRIPS"        . T)    ; grip edits of alignments, profiles and surfaces
    ("WarnSURFACE"      . T)    ; surface edit commands
    ("WarnOTHER"        . T)    ; commands listed in ImpactExtraCommands

    ;; How often a command or save-check warning appears:
    ;;   "every"  every time
    ;;   "once"   the first time each command warns in a Civil 3D session
    ;; Events.csv is written every time either way.
    ("WarnFrequency" . "every")

    ;; Checks on save
    ("GuardGrowth"      . T)    ; unusual growth since the last check
    ("GuardCleanup"     . T)    ; the growth warning offers one-click cleanup
    ("BackupBeforeCleanup" . T) ; cleanup copies the drawing to BackupDir first
                                ; (lock it to require a backup before every cleanup)

    ;; Standards check when a drawing opens
    ("StdCheckOnOpen"   . T)    ; run the check on open (CUTONCE-CHECK runs it any time)
    ("StdByLayer"       . T)    ; objects whose color or linetype is not ByLayer
    ("StdXrefStatus"    . T)    ; xrefs broken (not found) or unloaded
    ("StdXrefOrigin"    . T)    ; xrefs not inserted at 0,0,0
    ("StdCoordUnits"    . T)    ; coordinate system and insertion units
    ("StdAlwaysShow"    . nil)  ; show the result even when nothing is wrong
    ("StdScanBlocks"    . T)    ; include named block definitions (slower on big drawings)

    ;; Logging
    ("LogEnabled"       . T)    ; master switch: nil writes no logs at all
    ("LogHealthOnSave"  . T)    ; Health.csv row on every save
    ("LogHealthOnOpen"  . T)    ; Health.csv row when a drawing opens
    ("LogXrefs"         . T)    ; Xrefs.csv detail with every Health.csv row
    ("LogEvents"        . T)    ; Events.csv row for every warning
    ("LogOpened"        . T)    ; Opened.csv row for every drawing opened

    ;; Keys designers may NOT change; the value above always applies.
    ;; Any key from the section above can be listed, plus
    ;; "WarnFrequency". Example, to require logging firm-wide:
    ;;   ("LockedSettings" . ("LogEnabled" "LogHealthOnSave" "LogXrefs"))
    ("LockedSettings" . nil)

    ;; ---- Health checks -----------------------------------------------------

    ;; Percentage growth between checks that triggers the growth warning.
    ("GuardGrowthWarnPct" . 20)

    ;; ---- Coordinate system and units ---------------------------------------

    ;; Flag a drawing that has no coordinate system at all. Set nil if many
    ;; of your drawings (details, sheets) legitimately have none; mismatches
    ;; with the project and with xrefs are still flagged.
    ("CoordSysRequired" . T)

    ;; The coordinate system and insertion units each project should use.
    ;; Easiest: put a text file named CutOnce-Project.ini in the project's
    ;; top folder (CutOnce looks in the drawing's folder and the folders above):
    ;;     CoordinateSystem=CA83-VIF
    ;;     InsUnits=US Survey Feet
    ;; Or list projects here by folder (wildcards * ?; the first match wins;
    ;; a CutOnce-Project.ini, when found, takes precedence). InsUnits is a
    ;; name (Feet, US Survey Feet, Meters...) or the INSUNITS number.
    ;; Example:
    ;;   ("ProjectStandards"
    ;;     . (("//server/projects/1234*" . (("CoordinateSystem" . "CA83-VIF")
    ;;                                      ("InsUnits" . "US Survey Feet")))
    ;;        ("P:/Metric/*"             . (("CoordinateSystem" . "UTM83-10")
    ;;                                      ("InsUnits" . "Meters")))))
    ("ProjectStandards" . nil)

    ;; ---- Other watched commands ------------------------------------------

    ;; Extra Civil 3D command names that should show the impact warning
    ;; (the "Other watched commands" row, switched by "WarnOTHER"). Only add
    ;; names you have confirmed: run CUTONCE-GUARD-LOGCOMMANDS, start the
    ;; command from the ribbon, and copy the name printed on the command line.
    ;; The Control Center's "How to add other watched commands..." button
    ;; shows these steps too.
    ;; Example:  ("ImpactExtraCommands" . ("AECCSOMECOMMAND" "AECCOTHER"))
    ("ImpactExtraCommands" . nil)

    ;; ---- Extra Health.csv data points --------------------------------------

    ;; More object counts to record in Health.csv (one column each) and to
    ;; include in the save-time growth check. Each entry is
    ;;   ("ColumnName" . "ObjectName")
    ;; where ObjectName may use wildcards (* ?) and commas for several types.
    ;; Counts cover Model Space and every layout. To find an object's exact
    ;; name, open a drawing that has one and run CUTONCE-GUARD-DUMPOBJECTS.
    ;; Example:
    ;;   ("HealthExtraCounts" . (("FeatureLines" . "AeccDbFeatureLine")
    ;;                           ("Polylines"    . "AcDbPolyline,AcDb2dPolyline,AcDb3dPolyline")
    ;;                           ("Dimensions"   . "AcDb*Dimension")))
    ;; Changing this list changes the Health.csv columns; the old file is kept
    ;; as Health-archived-<date>.csv and a new one is started.
    ("HealthExtraCounts" . nil)

    ;; ---- Branding ----------------------------------------------------------

    ;; Every CutOnce dialog opens with a header band: a logo tile, the name and
    ;; tagline, the dialog's headline, and a colour strip (amber = warning,
    ;; red = problem, green = all clear, brand colour = information).
    ("BrandName"    . "CutOnce")
    ("BrandTagline" . "Healthy Civil 3D models, one save at a time")
    ;; Logo tile background, an AutoCAD Color Index number (1-255), e.g.
    ;; 150 blue, 5 pure blue, 1 red, 30 orange, 94 green, 250 dark grey.
    ("BrandColor"   . 150)
    ;; Your own logo instead of the built-in check mark: draw it in AutoCAD
    ;; (white or light lines read best on BrandColor), zoom so it fills the
    ;; screen, run MSLIDE, and point this at the .sld file. A file named
    ;; CutOnce-Logo.sld in the install folder is used automatically.
    ;; Example:  ("BrandLogoSlide" . "//server/cad/CutOnce/FirmLogo.sld")
    ("BrandLogoSlide" . nil)

    ;; ---- Learn More links --------------------------------------------------

    ;; The Learn More buttons open "Civil 3D Warnings Explained"
    ;; (https://designtovisualization.com/kb-c3d-and-cutonce-assistant/) at the
    ;; section for each warning. That address and its sections are built in, so
    ;; they stay current with each CutOnce update. Only uncomment the lines
    ;; below to send designers to your own copy of the page instead.
    ;;
    ;; ("LearnMoreUrl" . "https://designtovisualization.com/kb-c3d-and-cutonce-assistant/")
    ;;
    ;; Section of that page for each warning (the part after "#"), matching
    ;; the page's "Linking warnings to articles" table (#link-map). Set an
    ;; entry to "" to open the top of the page. A topic left out uses the
    ;; built-in section.
    ;; ("LearnMoreAnchors"
    ;;   . (;; Change-impact warnings
    ;;      ("MOVE"              . "move-civil-objects")
    ;;      ("STRETCH"           . "stretch-civil-objects")
    ;;      ("ROTATE"            . "rotate-civil-objects")
    ;;      ("SCALE"             . "scale-civil-objects")
    ;;      ("GRIP_ALIGNMENT"    . "grip-edit-alignment")       ; grip edit, alignment selected
    ;;      ("GRIP_PROFILE"      . "grip-edit-profile")         ; grip edit, profile selected
    ;;      ("SURFACE"           . "surface-edits")             ; any surface-edit command
    ;;      ("GENERAL"           . "dynamic-model")             ; anything else
    ;;      ;; Standards check (on open, or CUTONCE-CHECK)
    ;;      ("STANDARDS_OPEN"    . "standards-check")           ; reading the check
    ;;      ("STD_BYLAYER"       . "objects-not-bylayer")
    ;;      ("STD_XREF_STATUS"   . "xrefs-broken-unloaded")
    ;;      ("STD_XREF_ORIGIN"   . "xref-not-at-origin")
    ;;      ;; Guard
    ;;      ("GUARD_EXPLODE"     . "explode-civil-objects")
    ;;      ("GUARD_ATTRIB"      . "explode-attributed-blocks")
    ;;      ("GUARD_XREF_BIND"   . "xref-bind")
    ;;      ("GUARD_XREF_MOVED"  . "xref-moved")
    ;;      ("GUARD_XREF_ORIGIN" . "xref-not-at-origin")
    ;;      ("GUARD_REFEDIT"     . "refedit")                   ; REFEDIT and REFCLOSE
    ;;      ("GUARD_PROMOTE"     . "promote-reference")
    ;;      ("GUARD_TEXT"        . "text-instead-of-labels")
    ;;      ("GUARD_GROWTH"      . "drawing-growth")
    ;;      ("GUARD_CLEANUP"     . "drawing-cleanup")           ; cleanup offered on save
    ;;      ("STD_COORD_UNITS"   . "coordinate-system-units")
    ;;      ("BACKUP"            . "backup-copies")
    ;;      ;; Control Center
    ;;      ("CONTROL_CENTER"    . "control-center")))
  )
)

(princ)
