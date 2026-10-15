;;; ============================================================================
;;; CutOnce-ControlCenter.lsp
;;;
;;; CutOnce Control Center: one place where each designer chooses which
;;; CutOnce checks, warnings and logs run for them. Choices are
;;; stored per user (AutoCAD profile) and apply to every drawing at once.
;;; Items the CAD administrator has locked ("LockedSettings" in
;;; CutOnce-Config.lsp) are shown greyed out with the administrator's value.
;;;
;;;   Command warnings         master on/off, every time or once per command
;;;                            per session, then one row per command:
;;;                            MOVE, COPY, STRETCH, ROTATE, SCALE, EXPLODE,
;;;                            XREF/XBIND, REFEDIT/REFCLOSE, promote reference,
;;;                            TEXT, DTEXT, MTEXT, grip edits, surface edits,
;;;                            other watched commands (with instructions
;;;                            for the CAD administrator on adding them)
;;;   Save checks              unusual growth, xrefs not at 0,0,0
;;;   Standards check on open  ByLayer, xref status (broken / unloaded),
;;;                            xrefs not at 0,0,0, always show, block defs
;;;   Logging                  master switch, then Health.csv on save / on
;;;                            open, Xrefs.csv, Events.csv, Opened.csv
;;;
;;; Commands:
;;;   CUTONCE     the dialog
;;;   -CUTONCE    command-line version for scripts and macros, e.g.
;;;                         ^C^C-CUTONCE;LogEnabled;;  toggles logging
;;;
;;; This file loads last. It also runs the open-time work for the drawing
;;; (standards check and Health.csv row) once everything else is loaded.
;;;
;;; Naming: every function and global here starts with cocc: / *cocc:.
;;; Requires all other CutOnce files.
;;; ============================================================================

(vl-load-com)

(defun cocc:log (msg) (cutonce:msg "CutOnce" msg))

;; Command warning rows (every "Cmd" setting except the master switch).
(defun cocc:cmd-keys ( )
  (vl-remove "CommandWarnings"
    (mapcar 'car (vl-remove-if-not (function (lambda (e) (= (cadr e) "Cmd"))) *cutonce:settings*)))
)

;; Master switch -> the items it governs (greyed out while it is off).
(setq *cocc:children*
  (list
    (append '("CommandWarnings" "every" "once") (cocc:cmd-keys))
    '("StdCheckOnOpen" "StdByLayer" "StdXrefStatus" "StdXrefOrigin" "StdAlwaysShow")
    '("LogEnabled" "LogHealthOnSave" "LogHealthOnOpen" "LogXrefs" "LogEvents" "LogOpened")))

(defun cocc:default-freq ( ) (cutonce:default-warn-mode))

;; ---------------------------------------------------------------------------
;; Dialog definition (DCL written to a temp file on first use)
;; ---------------------------------------------------------------------------

(if (not (boundp '*cocc:dcl-path*)) (setq *cocc:dcl-path* nil))

(defun cocc:toggle-line (key)
  (strcat "      : toggle { key = \"" key "\"; label = \"" (cutonce:setting-label key) "\"; }")
)

(defun cocc:group-lines (title keys extra)
  (append
    (list "    : boxed_column {" (strcat "      label = \"" title "\";"))
    (mapcar 'cocc:toggle-line keys)
    extra
    (list "    }"))
)

(defun cocc:dcl-lines ( )
  (append
    (list
      "cocc_dialog : dialog {"
      "  label = \"CutOnce Control Center\";"
      "  : text { label = \"Choose which checks, warnings and logs run for you. Changes apply to every open drawing.\"; }"
      "  : row {"
      "   : column {")
    (list
      "    : boxed_column {"
      "      label = \"Command warnings\";"
      "      : toggle { key = \"CommandWarnings\"; label = \"Show command warnings\"; }"
      "      : radio_column {"
      "        key = \"freq\";"
      "        : radio_button { key = \"every\"; label = \"Every time the command runs\"; }"
      "        : radio_button { key = \"once\"; label = \"Once per command, per Civil 3D session\"; }"
      "      }"
      "      : text { label = \"Show the warning for:\"; }")
    (mapcar 'cocc:toggle-line (cocc:cmd-keys))
    (list
      "      : button { key = \"other_help\"; label = \"How to add other watched commands...\"; fixed_width = true; }"
      "    }")
    (list
      "   }"
      "   : column {")
    (cocc:group-lines "Checks on save"
      '("GuardGrowth" "GuardXrefOrigin")
      nil)
    (cocc:group-lines "Standards check when a drawing opens"
      '("StdCheckOnOpen" "StdByLayer" "StdXrefStatus" "StdXrefOrigin" "StdAlwaysShow" "StdScanBlocks")
      nil)
    (cocc:group-lines "Logging"
      '("LogEnabled" "LogHealthOnSave" "LogHealthOnOpen" "LogXrefs" "LogEvents" "LogOpened")
      (list
        "      : text { key = \"logdir\"; width = 60; }"
        "      : button { key = \"openlogs\"; label = \"Open log folder\"; fixed_width = true; }"))
    (list
      "   }"
      "  }"
      "  : text { key = \"locknote\"; width = 100; }"
      "  : row {"
      "    alignment = centered; fixed_width = true;"
      "    : button { key = \"accept\"; label = \"OK\"; is_default = true; width = 12; }"
      "    : button { key = \"cancel\"; label = \"Cancel\"; is_cancel = true; width = 12; }"
      "    : button { key = \"defaults\"; label = \"Reset to defaults\"; width = 18; }"
      "    : button { key = \"learn_more\"; label = \"Learn More...\"; width = 16; }"
      "  }"
      "}")
  )
)

(defun cocc:ensure-dcl ( / path f)
  (if (not (and *cocc:dcl-path* (findfile *cocc:dcl-path*)))
    (progn
      (setq path (vl-filename-mktemp "cocc" nil ".dcl"))
      (if (setq f (open path "w"))
        (progn
          (foreach ln (cocc:dcl-lines) (write-line ln f))
          (close f)
          (setq *cocc:dcl-path* path)
        )
      )
    )
  )
  *cocc:dcl-path*
)

;; ---------------------------------------------------------------------------
;; Dialog behaviour (these run while the dialog is open)
;; ---------------------------------------------------------------------------

(setq *cocc:reset* nil)
(setq *cocc:values* nil)

(defun cocc:tile-on (key) (= (get_tile key) "1"))

;; Greys out locked items, and children of a master switch that is off.
(defun cocc:refresh-modes ( / parentOff freqLocked)
  (setq freqLocked (cutonce:locked-p "WarnFrequency"))
  (foreach key (cutonce:setting-keys)
    (mode_tile key (if (cutonce:locked-p key) 1 0))
  )
  (foreach grp *cocc:children*
    (setq parentOff (not (cocc:tile-on (car grp))))
    (foreach child (cdr grp)
      (if (or parentOff
              (cutonce:locked-p child)
              (and (member child '("every" "once")) freqLocked))
        (mode_tile child 1)
        (mode_tile child 0)
      )
    )
  )
)

(defun cocc:fill-tiles (useDefaults)
  (foreach key (cutonce:setting-keys)
    (if (not (and useDefaults (cutonce:locked-p key)))
      (set_tile key (if (if useDefaults (cutonce:setting-default key) (cutonce:on-p key)) "1" "0")))
  )
  (if (not (and useDefaults (cutonce:locked-p "WarnFrequency")))
    (set_tile "freq" (if useDefaults (cocc:default-freq) (cutonce:warn-mode))))
  (cocc:refresh-modes)
)

(defun cocc:press-defaults ( )
  (setq *cocc:reset* T)
  (cocc:fill-tiles T)
  (set_tile "locknote" "Defaults restored in the dialog. Click OK to keep them.")
)

(defun cocc:capture ( )
  (setq *cocc:values*
    (append
      (mapcar (function (lambda (k) (cons k (get_tile k)))) (cutonce:setting-keys))
      (list (cons "freq" (get_tile "freq")))))
)

;; Instructions for the CAD administrator on adding commands to the
;; "Other watched commands" row (ImpactExtraCommands in CutOnce-Config.lsp).
(defun cocc:other-help ( / extra cfgpath)
  (setq extra (cutonce:cfg "ImpactExtraCommands" nil)
        extra (if (listp extra) (vl-remove-if-not 'cutonce:nonblank extra))
        cfgpath (strcat (cutonce:home) "CutOnce-Config.lsp"))
  (cutonce:notice-links
    (cutonce:join
      (list
        "OTHER WATCHED COMMANDS - for CAD administrators"
        ""
        "CutOnce shows the change-impact warning for the commands in this list,"
        "in addition to the ones it watches already. The warning lists what"
        "depends on the selected alignment, profile or surface. With nothing"
        "selected, a command whose name contains SURFACE, PROFILE or ALIGNMENT"
        "reports on every object of that type; any other command shows no"
        "warning, because there is nothing to analyse."
        ""
        "1. Find the command's exact name"
        "   - Type CUTONCE-GUARD-LOGCOMMANDS to turn command-name echo on."
        "   - Start the command the way designers do (ribbon, menu or"
        "     command line)."
        "   - Note the name printed on the command line, e.g. AECCSOMECOMMAND."
        "   - Type CUTONCE-GUARD-LOGCOMMANDS again to turn the echo off."
        ""
        "2. Open the CutOnce configuration file in Notepad:"
        (strcat "   " cfgpath)
        "   (For a network install, edit the copy in the shared folder.)"
        ""
        "3. Find this line:"
        "     (\"ImpactExtraCommands\" . nil)"
        "   and replace nil with the names in quotes, separated by spaces:"
        "     (\"ImpactExtraCommands\" . (\"AECCSOMECOMMAND\" \"AECCOTHER\"))"
        ""
        "4. Save the file, then restart Civil 3D (or open a new drawing)."
        ""
        "5. Keep \"Other watched commands\" ticked in this Control Center. To"
        "   enforce it for everyone, add \"WarnOTHER\" to LockedSettings in"
        "   the same file."
        ""
        "Reinstalling CutOnce keeps your configuration file."
        ""
        (strcat "Watched now: " (if extra (cutonce:join (mapcar 'strcase extra) ", ") "none")))
      "\n")
    nil)
)

;; Opens a folder in Windows Explorer.
(defun cocc:open-folder (dir / sh)
  (setq sh (vl-catch-all-apply 'vlax-get-or-create-object (list "Shell.Application")))
  (if (and sh (not (vl-catch-all-error-p sh)))
    (progn
      (vl-catch-all-apply 'vlax-invoke-method (list sh 'Open dir))
      (vl-catch-all-apply 'vlax-release-object (list sh))
    )
    (vl-catch-all-apply 'startapp (list "explorer.exe" dir))
  )
  (princ)
)

(defun cocc:any-locked-p ( )
  (or (vl-some 'cutonce:locked-p (cutonce:setting-keys))
      (cutonce:locked-p "WarnFrequency"))
)

;; ---------------------------------------------------------------------------
;; Applying the captured choices
;; ---------------------------------------------------------------------------

(defun cocc:apply (values reset / on freq)
  (foreach key (cutonce:setting-keys)
    (setq on (= (cdr (assoc key values)) "1"))
    (if (or reset (not (eq on (cutonce:on-p key))))
      (cutonce:set-on key on))
  )
  (setq freq (cdr (assoc "freq" values)))
  (if (and (member freq '("every" "once"))
           (not (cutonce:locked-p "WarnFrequency"))
           (or reset (/= freq (cutonce:warn-mode))))
    (cutonce:set-warn-mode freq))
)

;; ---------------------------------------------------------------------------
;; CUTONCE (dialog)
;; ---------------------------------------------------------------------------

(defun cocc:dialog ( / path dcl_id result)
  (setq path (cocc:ensure-dcl) *cocc:reset* nil *cocc:values* nil result 0)
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog "cocc_dialog" dcl_id)
        (progn
          (cocc:fill-tiles nil)
          (set_tile "logdir" (strcat "Log folder: " (cutonce:log-dir)))
          (set_tile "locknote"
            (if (cocc:any-locked-p) "Greyed-out items are set by your CAD administrator." ""))
          (foreach grp *cocc:children*
            (action_tile (car grp) "(cocc:refresh-modes)"))
          (action_tile "other_help" "(cocc:other-help)")
          (action_tile "openlogs" "(cocc:open-folder (cutonce:log-dir))")
          (action_tile "defaults" "(cocc:press-defaults)")
          (action_tile "learn_more" "(cutonce:open-kb \"CONTROL_CENTER\")")
          (action_tile "accept" "(cocc:capture)(done_dialog 1)")
          (action_tile "cancel" "(done_dialog 0)")
          (setq result (start_dialog))
        )
      )
      (unload_dialog dcl_id)
    )
    (cocc:log "Dialog unavailable - use -CUTONCE instead.")
  )
  (if (and (= result 1) *cocc:values*)
    (progn
      (cocc:apply *cocc:values* *cocc:reset*)
      (cocc:log "Settings saved. They apply to every open drawing.")
      (cocc:print-summary)
    )
  )
  (princ)
)

(defun c:CUTONCE ( ) (cocc:dialog))

;; ---------------------------------------------------------------------------
;; Listing
;; ---------------------------------------------------------------------------

(setq *cocc:group-titles*
  '(("Cmd"    . "Command warnings")
    ("Save"   . "Checks on save")
    ("Open"   . "Standards check when a drawing opens")
    ("Log"    . "Logging")))

(defun cocc:print-all ( / grp)
  (cocc:log "Current settings (type a name to toggle it):")
  (foreach g *cocc:group-titles*
    (princ (strcat "\n  " (cdr g)))
    (foreach e *cutonce:settings*
      (if (= (cadr e) (car g))
        (princ (strcat "\n    " (if (cutonce:on-p (car e)) "[on]  " "[off] ") (car e)
                       "  - " (caddr e) (if (cutonce:locked-p (car e)) "  (set by CAD admin)" ""))))
    )
    (if (= (car g) "Cmd")
      (progn
        (princ (strcat "\n    Frequency: " (if (= (cutonce:warn-mode) "once") "once per command per session" "every time")))
      )
    )
  )
  (princ (strcat "\n  Log folder: " (cutonce:log-dir)))
  (princ)
)

(defun cocc:print-summary ( / off)
  (setq off (vl-remove-if 'cutonce:on-p (cutonce:setting-keys)))
  (princ (strcat "\n  Logging: " (if (cutonce:on-p "LogEnabled") "on" "OFF")
                 "   Command warnings: " (if (cutonce:on-p "CommandWarnings") "on" "OFF")
                 "   Switched off: " (if off (itoa (length off)) "none")))
  (princ "\n  Type -CUTONCE then List for the full list.")
  (princ)
)

;; ---------------------------------------------------------------------------
;; -CUTONCE (command line)
;;   Type a setting name (or enough of it to be unique) to toggle it, or:
;;     List  Frequency  Warnings  Defaults  eXit
;;   e.g. ^C^C-CUTONCE;LogEnabled;;      toggles logging
;;        ^C^C-CUTONCE;WarnEXPLODE;;     toggles the EXPLODE warning
;; ---------------------------------------------------------------------------

(setq *cocc:keywords* '("LIST" "FREQUENCY" "WARNINGS" "DEFAULTS" "EXIT"))

;; Resolves typed input to a keyword or setting key; nil if unknown/ambiguous.
(setq *cocc:abbrev*
  '(("X" . "EXIT") ("L" . "LIST") ("F" . "FREQUENCY") ("W" . "WARNINGS") ("D" . "DEFAULTS")))

(defun cocc:resolve (in / up names exact pre)
  (setq up (strcase in))
  (setq names (append *cocc:keywords* (mapcar 'strcase (cutonce:setting-keys))))
  (cond
    ((assoc up *cocc:abbrev*) (cdr (assoc up *cocc:abbrev*)))
    ((setq exact (car (vl-member-if (function (lambda (n) (= n up))) names))) exact)
    (T
     (setq pre (vl-remove-if-not (function (lambda (n) (wcmatch n (strcat up "*")))) names))
     (if (= (length pre) 1) (car pre))
    )
  )
)

(defun cocc:key-from-upper (up)
  (car (vl-member-if (function (lambda (k) (= (strcase k) up))) (cutonce:setting-keys)))
)

(defun cocc:toggle-key (key / on)
  (cond
    ((cutonce:locked-p key) (cocc:log (strcat key " is set by your CAD administrator.")))
    (T
     (setq on (not (cutonce:on-p key)))
     (cutonce:set-on key on)
     (cocc:log (strcat (cutonce:setting-label key) ": " (if on "ON" "OFF")))
    )
  )
)

(defun cocc:reset-all ( / vals)
  (setq vals
    (append
      (mapcar (function (lambda (k) (cons k (if (cutonce:setting-default k) "1" "0")))) (cutonce:setting-keys))
      (list (cons "freq" (cocc:default-freq)))))
  (cocc:apply vals T)
  (cocc:log "All settings restored to the defaults.")
)

(defun cocc:command-line ( / in kw)
  (cocc:print-summary)
  (while
    (progn
      (setq in (getstring "\nSetting to toggle, or [List/Frequency/Warnings/Defaults/eXit] <eXit>: "))
      (and in (/= in "") (/= (setq kw (cocc:resolve in)) "EXIT"))
    )
    (cond
      ((null kw) (cocc:log (strcat "\"" in "\" is not a setting name (or matches more than one). Type List to see them.")))
      ((= kw "LIST") (cocc:print-all))
      ((= kw "WARNINGS") (cocc:toggle-key "CommandWarnings"))
      ((= kw "FREQUENCY")
       (if (cutonce:locked-p "WarnFrequency")
         (cocc:log "Warning frequency is set by your CAD administrator.")
         (progn
           (cutonce:set-warn-mode (if (= (cutonce:warn-mode) "once") "every" "once"))
           (cocc:log (strcat "Command warnings: " (if (= (cutonce:warn-mode) "once") "once per command per session" "every time"))))))
      ((= kw "DEFAULTS") (cocc:reset-all))
      (T (cocc:toggle-key (cocc:key-from-upper kw)))
    )
  )
  (princ)
)

(defun c:-CUTONCE ( ) (cocc:command-line))

;; ---------------------------------------------------------------------------
;; Open-time work for this drawing, now that every file is loaded.
;; ---------------------------------------------------------------------------

(defun cocc:on-open ( / r)
  (setq r (vl-catch-all-apply 'cohealth:on-open nil))
  (if (vl-catch-all-error-p r)
    (cocc:log (strcat "Open-time check failed: " (vl-catch-all-error-message r)))
  )
  (princ)
)

(cocc:on-open)
(princ)
