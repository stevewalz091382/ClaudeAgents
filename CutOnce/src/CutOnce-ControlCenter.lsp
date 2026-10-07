;;; ============================================================================
;;; CutOnce-ControlCenter.lsp
;;;
;;; CutOnce Control Center: one place where each designer chooses which
;;; CutOnce checks, warnings, interceptions and logs run for them. Choices are
;;; stored per user (AutoCAD profile) and apply to every drawing at once.
;;; Items the CAD administrator has locked ("LockedSettings" in
;;; CutOnce-Config.lsp) are shown greyed out with the administrator's value.
;;;
;;;   Change-impact warnings   on/off, each kind on/off, every time or once
;;;   Command interception     MOVE / STRETCH / ROTATE / SCALE, each separately
;;;   Data-loss guards         EXPLODE/BURST, xref bind, xref move/copy,
;;;                            REFEDIT, PROMOTEREFERENCE, TEXT tip
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
;;;   Older ModelWise / C3DTools / ByLayerCheck command names still work; see the
;;;   "Older command names" section at the end of this file.
;;;
;;; This file loads last. It also runs the open-time work for the drawing
;;; (standards check and Health.csv row) once everything else is loaded.
;;;
;;; Naming: every function and global here starts with mwcc: / *mwcc:.
;;; Requires all other CutOnce files.
;;; ============================================================================

(vl-load-com)

(defun mwcc:log (msg) (mwise:msg "CutOnce" msg))

;; Master switch -> the items it governs (greyed out while it is off).
(setq *mwcc:children*
  '(("ImpactWarnings" "ImpactGrips" "ImpactSurface" "ImpactTransform" "ImpactOther" "every" "once")
    ("StdCheckOnOpen" "StdByLayer" "StdXrefStatus" "StdXrefOrigin" "StdAlwaysShow")
    ("LogEnabled" "LogHealthOnSave" "LogHealthOnOpen" "LogXrefs" "LogEvents" "LogOpened")))

(defun mwcc:icpt-key (cn) (strcat "icpt_" cn))

;; ---------------------------------------------------------------------------
;; Interception defaults (same rules as mwimpact:intercept-wanted-p)
;; ---------------------------------------------------------------------------

(defun mwcc:intercept-default-p (cn / def)
  (setq def (mwise:cfg "ImpactInterceptDefault" nil))
  (cond
    ((not (mwimpact:intercept-allowed-p)) nil)
    ((null def) nil)
    ((listp def) (if (member cn (mapcar 'strcase (vl-remove-if-not 'mwise:nonblank def))) T))
    (T T)
  )
)

;; Turns interception on/off for one command. With reset, a choice equal to
;; the administrator default is stored as "no choice".
(defun mwcc:apply-intercept (cn on reset)
  (if (and reset (eq (if on T nil) (mwcc:intercept-default-p cn)))
    (progn
      (mwise:pref-set (strcat "ImpactIntercept." cn) "")
      (if (mwise:pref-get "ImpactIntercept") (mwise:pref-set "ImpactIntercept" ""))
      (if on (mwimpact:intercept-on cn) (mwimpact:intercept-off cn))
    )
    (mwimpact:set-intercept cn on)
  )
)

(defun mwcc:default-freq ( )
  (if (= (mwise:cfg "ImpactWarnFrequency" "every") "once") "once" "every")
)

;; ---------------------------------------------------------------------------
;; Dialog definition (DCL written to a temp file on first use)
;; ---------------------------------------------------------------------------

(if (not (boundp '*mwcc:dcl-path*)) (setq *mwcc:dcl-path* nil))

(defun mwcc:toggle-line (key)
  (strcat "      : toggle { key = \"" key "\"; label = \"" (mwise:setting-label key) "\"; }")
)

(defun mwcc:group-lines (title keys extra)
  (append
    (list "    : boxed_column {" (strcat "      label = \"" title "\";"))
    (mapcar 'mwcc:toggle-line keys)
    extra
    (list "    }"))
)

(defun mwcc:dcl-lines ( )
  (append
    (list
      "mwcc_dialog : dialog {"
      "  label = \"CutOnce Control Center\";"
      "  : text { label = \"Choose which checks, warnings and logs run for you. Changes apply to every open drawing.\"; }"
      "  : row {"
      "   : column {")
    (mwcc:group-lines "Change-impact warnings"
      '("ImpactWarnings" "ImpactGrips" "ImpactSurface" "ImpactTransform" "ImpactOther")
      (list
        "      : radio_column {"
        "        key = \"freq\";"
        "        : radio_button { key = \"every\"; label = \"Every time the command runs\"; }"
        "        : radio_button { key = \"once\"; label = \"Once per command, per Civil 3D session\"; }"
        "      }"))
    (list
      "    : boxed_column {"
      "      label = \"Command interception (each ticked command is undefined while on)\";"
      "      : row {"
      "        : toggle { key = \"icpt_MOVE\"; label = \"MOVE\"; }"
      "        : toggle { key = \"icpt_STRETCH\"; label = \"STRETCH\"; }"
      "        : toggle { key = \"icpt_ROTATE\"; label = \"ROTATE\"; }"
      "        : toggle { key = \"icpt_SCALE\"; label = \"SCALE\"; }"
      "      }"
      "      : button { key = \"icpt_about\"; label = \"What interception does...\"; fixed_width = true; }"
      "    }")
    (mwcc:group-lines "Data-loss guards"
      '("GuardExplode" "GuardXrefBind" "GuardXrefMove" "GuardRefEdit" "GuardPromote" "GuardTextTip")
      nil)
    (list
      "   }"
      "   : column {")
    (mwcc:group-lines "Checks on save"
      '("GuardGrowth" "GuardXrefOrigin")
      nil)
    (mwcc:group-lines "Standards check when a drawing opens"
      '("StdCheckOnOpen" "StdByLayer" "StdXrefStatus" "StdXrefOrigin" "StdAlwaysShow" "StdScanBlocks")
      nil)
    (mwcc:group-lines "Logging"
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

(defun mwcc:ensure-dcl ( / path f)
  (if (not (and *mwcc:dcl-path* (findfile *mwcc:dcl-path*)))
    (progn
      (setq path (vl-filename-mktemp "mwcc" nil ".dcl"))
      (if (setq f (open path "w"))
        (progn
          (foreach ln (mwcc:dcl-lines) (write-line ln f))
          (close f)
          (setq *mwcc:dcl-path* path)
        )
      )
    )
  )
  *mwcc:dcl-path*
)

;; ---------------------------------------------------------------------------
;; Dialog behaviour (these run while the dialog is open)
;; ---------------------------------------------------------------------------

(setq *mwcc:reset* nil)
(setq *mwcc:values* nil)

(defun mwcc:tile-on (key) (= (get_tile key) "1"))

;; Greys out locked items, and children of a master switch that is off.
(defun mwcc:refresh-modes ( / allowed parentOff)
  (foreach key (mwise:setting-keys)
    (mode_tile key (if (mwise:locked-p key) 1 0))
  )
  (foreach k '("every" "once")
    (mode_tile k (if (mwise:locked-p "ImpactWarnFrequency") 1 0))
  )
  (foreach grp *mwcc:children*
    (setq parentOff (not (mwcc:tile-on (car grp))))
    (foreach child (cdr grp)
      (if (or parentOff
              (mwise:locked-p child)
              (and (member child '("every" "once")) (mwise:locked-p "ImpactWarnFrequency")))
        (mode_tile child 1)
        (mode_tile child 0)
      )
    )
  )
  (setq allowed (mwimpact:intercept-allowed-p))
  (foreach cn *mwimpact:native-commands*
    (mode_tile (mwcc:icpt-key cn) (if (or (not allowed) (member cn *mwimpact:foreign*)) 1 0))
  )
)

(defun mwcc:fill-tiles (useDefaults)
  (foreach key (mwise:setting-keys)
    (if (not (and useDefaults (mwise:locked-p key)))
      (set_tile key (if (if useDefaults (mwise:setting-default key) (mwise:on-p key)) "1" "0")))
  )
  (if (not (and useDefaults (mwise:locked-p "ImpactWarnFrequency")))
    (set_tile "freq" (if useDefaults (mwcc:default-freq) (mwimpact:warn-mode))))
  (foreach cn *mwimpact:native-commands*
    (set_tile (mwcc:icpt-key cn)
      (if (if useDefaults (mwcc:intercept-default-p cn) (mwimpact:intercept-active-p cn)) "1" "0"))
  )
  (mwcc:refresh-modes)
)

(defun mwcc:press-defaults ( )
  (setq *mwcc:reset* T)
  (mwcc:fill-tiles T)
  (set_tile "locknote" "Defaults restored in the dialog. Click OK to keep them.")
)

(defun mwcc:capture ( )
  (setq *mwcc:values*
    (append
      (mapcar (function (lambda (k) (cons k (get_tile k)))) (mwise:setting-keys))
      (list (cons "freq" (get_tile "freq")))
      (mapcar (function (lambda (cn) (cons cn (get_tile (mwcc:icpt-key cn))))) *mwimpact:native-commands*)))
)

(defun mwcc:about-intercept ( )
  (alert (mwise:join
           (if (mwimpact:intercept-allowed-p)
             (append *mwimpact:intercept-text*
                     (list "" "Interception only shows a warning when change-impact warnings"
                              "and \"MOVE / STRETCH / ROTATE / SCALE\" are switched on."))
             (list "Command interception has been disabled by your CAD administrator."))
           "\n"))
)

;; Opens a folder in Windows Explorer.
(defun mwcc:open-folder (dir / sh)
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

(defun mwcc:any-locked-p ( )
  (or (vl-some 'mwise:locked-p (mwise:setting-keys))
      (mwise:locked-p "ImpactWarnFrequency")
      (not (mwimpact:intercept-allowed-p)))
)

;; ---------------------------------------------------------------------------
;; Applying the captured choices
;; ---------------------------------------------------------------------------

(defun mwcc:apply (values reset / on freq)
  (foreach key (mwise:setting-keys)
    (setq on (= (cdr (assoc key values)) "1"))
    (if (or reset (not (eq on (mwise:on-p key))))
      (mwise:set-on key on))
  )
  (setq freq (cdr (assoc "freq" values)))
  (if (and (member freq '("every" "once"))
           (not (mwise:locked-p "ImpactWarnFrequency"))
           (or reset (/= freq (mwimpact:warn-mode))))
    (mwimpact:set-warn-mode freq))
  (if (mwimpact:intercept-allowed-p)
    (foreach cn *mwimpact:native-commands*
      (if (not (member cn *mwimpact:foreign*))
        (progn
          (setq on (= (cdr (assoc cn values)) "1"))
          (if (or reset (not (eq on (if (mwimpact:intercept-active-p cn) T nil))))
            (mwcc:apply-intercept cn on reset))
        )
      )
    )
  )
)

;; ---------------------------------------------------------------------------
;; CUTONCE (dialog)
;; ---------------------------------------------------------------------------

(defun mwcc:dialog ( / path dcl_id result)
  (setq path (mwcc:ensure-dcl) *mwcc:reset* nil *mwcc:values* nil result 0)
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog "mwcc_dialog" dcl_id)
        (progn
          (mwcc:fill-tiles nil)
          (set_tile "logdir" (strcat "Log folder: " (mwise:log-dir)))
          (set_tile "locknote"
            (if (mwcc:any-locked-p) "Greyed-out items are set by your CAD administrator." ""))
          (foreach grp *mwcc:children*
            (action_tile (car grp) "(mwcc:refresh-modes)"))
          (action_tile "icpt_about" "(mwcc:about-intercept)")
          (action_tile "openlogs" "(mwcc:open-folder (mwise:log-dir))")
          (action_tile "defaults" "(mwcc:press-defaults)")
          (action_tile "learn_more" "(mwise:open-kb \"CONTROL_CENTER\")")
          (action_tile "accept" "(mwcc:capture)(done_dialog 1)")
          (action_tile "cancel" "(done_dialog 0)")
          (setq result (start_dialog))
        )
      )
      (unload_dialog dcl_id)
    )
    (mwcc:log "Dialog unavailable - use -CUTONCE instead.")
  )
  (if (and (= result 1) *mwcc:values*)
    (progn
      (mwcc:apply *mwcc:values* *mwcc:reset*)
      (mwcc:log "Settings saved. They apply to every open drawing.")
      (mwcc:print-summary)
    )
  )
  (princ)
)

(defun c:CUTONCE ( ) (mwcc:dialog))

;; ---------------------------------------------------------------------------
;; Listing
;; ---------------------------------------------------------------------------

(setq *mwcc:group-titles*
  '(("Impact" . "Change-impact warnings")
    ("Guard"  . "Data-loss guards")
    ("Save"   . "Checks on save")
    ("Open"   . "Standards check when a drawing opens")
    ("Log"    . "Logging")))

(defun mwcc:print-all ( / grp)
  (mwcc:log "Current settings (type a name to toggle it):")
  (foreach g *mwcc:group-titles*
    (princ (strcat "\n  " (cdr g)))
    (foreach e *mwise:settings*
      (if (= (cadr e) (car g))
        (princ (strcat "\n    " (if (mwise:on-p (car e)) "[on]  " "[off] ") (car e)
                       "  - " (caddr e) (if (mwise:locked-p (car e)) "  (set by CAD admin)" ""))))
    )
    (if (= (car g) "Impact")
      (progn
        (princ (strcat "\n    Frequency: " (if (= (mwimpact:warn-mode) "once") "once per command per session" "every time")))
        (princ "\n    Interception: ")
        (if (not (mwimpact:intercept-allowed-p))
          (princ "disabled by your CAD administrator")
          (foreach cn *mwimpact:native-commands*
            (princ (strcat cn " " (if (mwimpact:intercept-active-p cn) "ON" "off") "  "))))
      )
    )
  )
  (princ (strcat "\n  Log folder: " (mwise:log-dir)))
  (princ)
)

(defun mwcc:print-summary ( / off)
  (setq off (vl-remove-if 'mwise:on-p (mwise:setting-keys)))
  (princ (strcat "\n  Logging: " (if (mwise:on-p "LogEnabled") "on" "OFF")
                 "   Impact warnings: " (if (mwise:on-p "ImpactWarnings") "on" "OFF")
                 "   Switched off: " (if off (itoa (length off)) "none")))
  (princ "\n  Type -CUTONCE then List for the full list.")
  (princ)
)

;; ---------------------------------------------------------------------------
;; -CUTONCE (command line)
;;   Type a setting name (or enough of it to be unique) to toggle it, or:
;;     List  Frequency  Move  Stretch  Rotate  Scale  Warnings  Defaults  eXit
;;   e.g. ^C^C-CUTONCE;LogEnabled;;
;;        ^C^C-CUTONCE;Move;X;
;; ---------------------------------------------------------------------------

(setq *mwcc:keywords* '("LIST" "FREQUENCY" "MOVE" "STRETCH" "ROTATE" "SCALE" "WARNINGS" "DEFAULTS" "EXIT"))

;; Resolves typed input to a keyword or setting key; nil if unknown/ambiguous.
(setq *mwcc:abbrev*
  '(("X" . "EXIT") ("L" . "LIST") ("F" . "FREQUENCY") ("M" . "MOVE") ("ST" . "STRETCH")
    ("R" . "ROTATE") ("SC" . "SCALE") ("W" . "WARNINGS") ("D" . "DEFAULTS")))

(defun mwcc:resolve (in / up names exact pre)
  (setq up (strcase in))
  (setq names (append *mwcc:keywords* (mapcar 'strcase (mwise:setting-keys))))
  (cond
    ((assoc up *mwcc:abbrev*) (cdr (assoc up *mwcc:abbrev*)))
    ((setq exact (car (vl-member-if (function (lambda (n) (= n up))) names))) exact)
    (T
     (setq pre (vl-remove-if-not (function (lambda (n) (wcmatch n (strcat up "*")))) names))
     (if (= (length pre) 1) (car pre))
    )
  )
)

(defun mwcc:key-from-upper (up)
  (car (vl-member-if (function (lambda (k) (= (strcase k) up))) (mwise:setting-keys)))
)

(defun mwcc:toggle-key (key / on)
  (cond
    ((mwise:locked-p key) (mwcc:log (strcat key " is set by your CAD administrator.")))
    (T
     (setq on (not (mwise:on-p key)))
     (mwise:set-on key on)
     (mwcc:log (strcat (mwise:setting-label key) ": " (if on "ON" "OFF")))
    )
  )
)

(defun mwcc:reset-all ( / vals)
  (setq vals
    (append
      (mapcar (function (lambda (k) (cons k (if (mwise:setting-default k) "1" "0")))) (mwise:setting-keys))
      (list (cons "freq" (mwcc:default-freq)))
      (mapcar (function (lambda (cn) (cons cn (if (mwcc:intercept-default-p cn) "1" "0")))) *mwimpact:native-commands*)))
  (mwcc:apply vals T)
  (mwcc:log "All settings restored to the defaults.")
)

(defun mwcc:command-line ( / in kw cn on)
  (mwcc:print-summary)
  (while
    (progn
      (setq in (getstring "\nSetting to toggle, or [List/Frequency/Move/Stretch/Rotate/Scale/Warnings/Defaults/eXit] <eXit>: "))
      (and in (/= in "") (/= (setq kw (mwcc:resolve in)) "EXIT"))
    )
    (cond
      ((null kw) (mwcc:log (strcat "\"" in "\" is not a setting name (or matches more than one). Type List to see them.")))
      ((= kw "LIST") (mwcc:print-all))
      ((= kw "WARNINGS") (mwcc:toggle-key "ImpactWarnings"))
      ((= kw "FREQUENCY")
       (if (mwise:locked-p "ImpactWarnFrequency")
         (mwcc:log "Warning frequency is set by your CAD administrator.")
         (progn
           (mwimpact:set-warn-mode (if (= (mwimpact:warn-mode) "once") "every" "once"))
           (mwcc:log (strcat "Impact warnings: " (if (= (mwimpact:warn-mode) "once") "once per command per session" "every time"))))))
      ((= kw "DEFAULTS") (mwcc:reset-all))
      ((member kw *mwimpact:native-commands*)
       (setq cn kw)
       (cond
         ((not (mwimpact:intercept-allowed-p))
          (mwcc:log "Command interception has been disabled by your CAD administrator."))
         ((member cn *mwimpact:foreign*)
          (mwcc:log (strcat "Another add-on already defines C:" cn " - it cannot be intercepted.")))
         (T
          (setq on (not (mwimpact:intercept-active-p cn)))
          (if on
            (princ (strcat "\nNote: " cn " is now UNDEFINED for this session and replaced by the CutOnce"
                           " version; LISP or macros calling " cn " without \"_.\" get it too.")))
          (mwimpact:set-intercept cn on)
          (mwcc:log (strcat cn " interception " (if on "ON" "OFF"))))
       ))
      (T (mwcc:toggle-key (mwcc:key-from-upper kw)))
    )
  )
  (princ)
)

(defun c:-CUTONCE ( ) (mwcc:command-line))

;; ---------------------------------------------------------------------------
;; Older command names (ModelWise, C3DTools 1.x / 2.0 and ByLayerCheck). Each one runs
;; the CutOnce command, so existing toolbar buttons, macros and habits keep
;; working. A name another add-on already defines is left alone.
;; ---------------------------------------------------------------------------

(setq *mwcc:legacy-commands*
  '(("C3DTOOLS-STATUS"       . "CUTONCE-STATUS")
    ("C3DTOOLS-FINDCIVIL"    . "CUTONCE-FINDCIVIL")
    ("C3D-MODEL-MANAGER"     . "CUTONCE")
    ("-C3D-MODEL-MANAGER"    . "-CUTONCE")
    ("C3DMM"                 . "CUTONCE")
    ("C3D-IMPACT-SETTINGS"   . "CUTONCE")
    ("C3D-IMPACT-INTERCEPT"  . "CUTONCE")
    ("-C3D-IMPACT-SETTINGS"  . "-CUTONCE")
    ("C3D-IMPACT-ON"         . "CUTONCE-IMPACT-ON")
    ("C3D-IMPACT-OFF"        . "CUTONCE-IMPACT-OFF")
    ("C3D-IMPACT-RESTORE"    . "CUTONCE-IMPACT-RESTORE")
    ("C3D-IMPACT-STATUS"     . "CUTONCE-IMPACT-STATUS")
    ("C3D-IMPACT-DEBUG"      . "CUTONCE-IMPACT-DEBUG")
    ("C3DCHECK"              . "CUTONCE-CHECK")
    ("C3DCHECK-STATUS"       . "CUTONCE-CHECK-STATUS")
    ("BLCHECK"               . "CUTONCE-CHECK")
    ("BLCHECK-STATUS"        . "CUTONCE-CHECK-STATUS")
    ("C3DAUDIT"              . "CUTONCE-AUDIT")
    ("C3DAUDIT-FOLDER"       . "CUTONCE-AUDIT-FOLDER")
    ("C3DGUARD-STATUS"       . "CUTONCE-GUARD-STATUS")
    ("C3DGUARD-CHECKNOW"     . "CUTONCE-GUARD-CHECKNOW")
    ("C3DGUARD-DUMPOBJECTS"  . "CUTONCE-GUARD-DUMPOBJECTS")
    ("C3DGUARD-LOG"          . "CUTONCE-GUARD-LOG")
    ("C3DGUARD-SUMMARY"      . "CUTONCE-GUARD-SUMMARY")
    ("C3DGUARD-LOGCOMMANDS"  . "CUTONCE-GUARD-LOGCOMMANDS")
    ;; ModelWise 2.0 names
    ("MODELWISE"             . "CUTONCE")
    ("-MODELWISE"            . "-CUTONCE")
    ("MW"                    . "CUTONCE")
    ("MW-STATUS"             . "CUTONCE-STATUS")
    ("MW-FINDCIVIL"          . "CUTONCE-FINDCIVIL")
    ("MW-CHECK"              . "CUTONCE-CHECK")
    ("MW-CHECK-STATUS"       . "CUTONCE-CHECK-STATUS")
    ("MW-AUDIT"              . "CUTONCE-AUDIT")
    ("MW-AUDIT-FOLDER"       . "CUTONCE-AUDIT-FOLDER")
    ("MW-GUARD-STATUS"       . "CUTONCE-GUARD-STATUS")
    ("MW-GUARD-CHECKNOW"     . "CUTONCE-GUARD-CHECKNOW")
    ("MW-GUARD-DUMPOBJECTS"  . "CUTONCE-GUARD-DUMPOBJECTS")
    ("MW-GUARD-LOG"          . "CUTONCE-GUARD-LOG")
    ("MW-GUARD-SUMMARY"      . "CUTONCE-GUARD-SUMMARY")
    ("MW-GUARD-LOGCOMMANDS"  . "CUTONCE-GUARD-LOGCOMMANDS")
    ("MW-IMPACT-ON"          . "CUTONCE-IMPACT-ON")
    ("MW-IMPACT-OFF"         . "CUTONCE-IMPACT-OFF")
    ("MW-IMPACT-RESTORE"     . "CUTONCE-IMPACT-RESTORE")
    ("MW-IMPACT-STATUS"      . "CUTONCE-IMPACT-STATUS")
    ("MW-IMPACT-DEBUG"       . "CUTONCE-IMPACT-DEBUG")))

(defun mwcc:install-legacy-commands ( / old new)
  (foreach pair *mwcc:legacy-commands*
    (setq old (read (strcat "C:" (car pair))) new (read (strcat "C:" (cdr pair))))
    (if (and (or (not (boundp old)) (member (car pair) *mwcc:legacy-defined*))
             (boundp new))
      (progn
        (eval (list 'defun old nil (list new)))
        (if (not (member (car pair) *mwcc:legacy-defined*))
          (setq *mwcc:legacy-defined* (cons (car pair) *mwcc:legacy-defined*)))
      )
    )
  )
)

(if (not (boundp '*mwcc:legacy-defined*)) (setq *mwcc:legacy-defined* nil))
(mwcc:install-legacy-commands)

;; ---------------------------------------------------------------------------
;; Open-time work for this drawing, now that every file is loaded.
;; ---------------------------------------------------------------------------

(defun mwcc:on-open ( / r)
  (setq r (vl-catch-all-apply 'mwhealth:on-open nil))
  (if (vl-catch-all-error-p r)
    (mwcc:log (strcat "Open-time check failed: " (vl-catch-all-error-message r)))
  )
  (princ)
)

(mwcc:on-open)
(princ)
