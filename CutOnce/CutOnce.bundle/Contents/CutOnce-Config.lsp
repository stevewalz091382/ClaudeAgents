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

    ;; Where Health.csv, Xrefs.csv, Events.csv and Opened.csv go.
    ;; nil = %LOCALAPPDATA%\CutOnce\Logs\ (per user, per machine).
    ;; Use forward slashes, e.g. "D:/CAD/CutOnce/Logs" or a shared
    ;; folder "//server/cad/CutOnce/Logs".
    ;; The CUTONCE_LOGDIR environment variable, if set, overrides this.
    ("LogDir" . nil)

    ;; ---- Control Center defaults -------------------------------------------
    ;; Change-impact warnings
    ("ImpactWarnings"   . T)    ; master switch for all impact warnings
    ("ImpactGrips"      . T)    ; grip edits of alignments and profiles
    ("ImpactSurface"    . T)    ; surface edit commands
    ("ImpactTransform"  . T)    ; MOVE / STRETCH / ROTATE / SCALE of Civil 3D objects
    ("ImpactOther"      . T)    ; commands listed in ImpactExtraCommands

    ;; How often an impact warning appears:
    ;;   "every"  every time the command runs
    ;;   "once"   the first time each command runs in a Civil 3D session
    ("ImpactWarnFrequency" . "every")

    ;; Data-loss guards
    ("GuardExplode"     . T)    ; EXPLODE / BURST of Civil 3D objects and attributed blocks
    ("GuardXrefBind"    . T)    ; xref bound into the drawing
    ("GuardXrefMove"    . T)    ; xref moved or copied
    ("GuardRefEdit"     . T)    ; REFEDIT / REFCLOSE advisory
    ("GuardPromote"     . T)    ; PROMOTEREFERENCE advisory
    ("GuardTextTip"     . T)    ; TEXT / MTEXT tip, once per session

    ;; Checks on save
    ("GuardGrowth"      . T)    ; unusual growth since the last check
    ("GuardXrefOrigin"  . T)    ; xref not inserted at 0,0,0

    ;; Standards check when a drawing opens
    ("StdCheckOnOpen"   . T)    ; run the check on open (CUTONCE-CHECK runs it any time)
    ("StdByLayer"       . T)    ; objects whose color or linetype is not ByLayer
    ("StdXrefStatus"    . T)    ; xrefs broken (not found) or unloaded
    ("StdXrefOrigin"    . T)    ; xrefs not inserted at 0,0,0
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
    ;; "ImpactWarnFrequency". Example, to require logging firm-wide:
    ;;   ("LockedSettings" . ("LogEnabled" "LogHealthOnSave" "LogXrefs"))
    ("LockedSettings" . nil)

    ;; ---- Health checks -----------------------------------------------------

    ;; Percentage growth between checks that triggers the growth warning.
    ("GuardGrowthWarnPct" . 20)

    ;; ---- Command interception ----------------------------------------------

    ;; Whether users may turn on interception of MOVE, STRETCH, ROTATE and
    ;; SCALE in the Control Center. Each intercepted command is UNDEFINED for
    ;; the session. Set to nil to prohibit it.
    ("ImpactInterceptAllowed" . T)

    ;; Interception for users who have not made their own choice:
    ;;   nil                     none (recommended)
    ;;   T                       all four commands
    ;;   ("MOVE" "ROTATE")       just the commands listed
    ;; Leave nil unless your firm has agreed to it.
    ("ImpactInterceptDefault" . nil)

    ;; Extra Civil 3D command names that should show the impact warning
    ;; (switched by "ImpactOther"). Only add names you have confirmed: run
    ;; CUTONCE-GUARD-LOGCOMMANDS, start the command from the ribbon, and copy the
    ;; name printed on the command line.
    ;; Example:  ("ImpactExtraCommands" . ("AECCSOMECOMMAND" "AECCOTHER"))
    ("ImpactExtraCommands" . nil)

    ;; ---- Learn More links --------------------------------------------------

    ;; Page opened by the Learn More buttons: "Civil 3D Warnings Explained".
    ("LearnMoreUrl" . "https://designtovisualization.com/kb-c3d-and-modelwise-assistant/")

    ;; Section of that page for each warning (the part after "#"), matching
    ;; the page's "Linking warnings to articles" table (#link-map). Set an
    ;; entry to "" to open the top of the page. A topic left out uses the
    ;; built-in section.
    ("LearnMoreAnchors"
      . (;; Change-impact warnings
         ("MOVE"              . "move-civil-objects")
         ("STRETCH"           . "stretch-civil-objects")
         ("ROTATE"            . "rotate-civil-objects")
         ("SCALE"             . "scale-civil-objects")
         ("GRIP_ALIGNMENT"    . "grip-edit-alignment")       ; grip edit, alignment selected
         ("GRIP_PROFILE"      . "grip-edit-profile")         ; grip edit, profile selected
         ("SURFACE"           . "surface-edits")             ; any surface-edit command
         ("GENERAL"           . "dynamic-model")             ; anything else
         ;; Standards check (on open, or CUTONCE-CHECK)
         ("STANDARDS_OPEN"    . "standards-check")           ; reading the check
         ("STD_BYLAYER"       . "objects-not-bylayer")
         ("STD_XREF_STATUS"   . "xrefs-broken-unloaded")
         ("STD_XREF_ORIGIN"   . "xref-not-at-origin")
         ;; Guard
         ("GUARD_EXPLODE"     . "explode-civil-objects")
         ("GUARD_ATTRIB"      . "explode-attributed-blocks")
         ("GUARD_XREF_BIND"   . "xref-bind")
         ("GUARD_XREF_MOVED"  . "xref-moved")
         ("GUARD_XREF_ORIGIN" . "xref-not-at-origin")        ; save check
         ("GUARD_REFEDIT"     . "refedit")                   ; REFEDIT and REFCLOSE
         ("GUARD_PROMOTE"     . "promote-reference")
         ("GUARD_TEXT"        . "text-instead-of-labels")
         ("GUARD_GROWTH"      . "drawing-growth")
         ;; Control Center
         ("CONTROL_CENTER"    . "control-center")))
  )
)

(princ)
