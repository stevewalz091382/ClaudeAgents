;;; ============================================================================
;;; CutOnce-ControlCenter.lsp  (TRIAL)
;;;
;;; Copyright (c) 2026 Stephen Walz. All rights reserved.
;;;
;;; CutOnce Control Center for the trial: the EXPLODE / BURST warning switch
;;; and how often it shows. Choices are stored per user (AutoCAD profile) and
;;; apply to every drawing at once.
;;;
;;; To unlock the full version, reach out to stevewalz@hotmail.com
;;; (The dialog says so too, with a button that starts an email.)
;;;
;;; Commands:
;;;   CUTONCE     the dialog
;;;   -CUTONCE    command-line version for scripts and macros, e.g.
;;;                         ^C^C-CUTONCE;WarnEXPLODE;;  toggles the EXPLODE warning
;;;
;;; Naming: every function and global here starts with cocc: / *cocc:.
;;; Requires CutOnce-Core.lsp and CutOnce-Guard.lsp.
;;; ============================================================================

(vl-load-com)

(defun cocc:log (msg) (cutonce:msg "CutOnce" msg))

(defun cocc:default-freq ( ) (cutonce:default-warn-mode))

;; ---------------------------------------------------------------------------
;; Dialog definition (DCL written to a temp file on first use)
;; ---------------------------------------------------------------------------

(if (not (boundp '*cocc:dcl-path*)) (setq *cocc:dcl-path* nil))

(defun cocc:dcl-lines ( )
  (list
    "cocc_dialog : dialog {"
    "  label = \"CutOnce Control Center - Trial\";"
    "  : text { label = \"Choose whether the EXPLODE warning runs for you. Changes apply to every open drawing.\"; }"
    "  : boxed_column {"
    "    label = \"Command warnings\";"
    (strcat "    : toggle { key = \"WarnEXPLODE\"; label = \"" (cutonce:setting-label "WarnEXPLODE") "\"; }")
    "    : radio_column {"
    "      key = \"freq\";"
    "      : radio_button { key = \"every\"; label = \"Every time the command runs\"; }"
    "      : radio_button { key = \"once\"; label = \"Once per command, per Civil 3D session\"; }"
    "    }"
    "  }"
    "  : boxed_column {"
    "    label = \"Trial version\";"
    "    : text { label = \"This trial includes the EXPLODE / BURST warning only.\"; }"
    "    : text { label = \"The full version adds standards checks, health logs, impact warnings and xref guards.\"; }"
    (strcat "    : text { label = \"To unlock the full version, reach out to " *cutonce:contact* "\"; }")
    "    : button { key = \"email\"; label = \"Email about the full version...\"; fixed_width = true; }"
    "  }"
    "  : text { key = \"note\"; width = 90; }"
    "  : row {"
    "    alignment = centered; fixed_width = true;"
    "    : button { key = \"accept\"; label = \"OK\"; is_default = true; width = 12; }"
    "    : button { key = \"cancel\"; label = \"Cancel\"; is_cancel = true; width = 12; }"
    "    : button { key = \"defaults\"; label = \"Reset to defaults\"; width = 18; }"
    "    : button { key = \"learn_more\"; label = \"Learn More...\"; width = 16; }"
    "  }"
    "}"
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

;; The frequency choice is greyed out while the warning is off.
(defun cocc:refresh-modes ( )
  (mode_tile "freq" (if (= (get_tile "WarnEXPLODE") "1") 0 1))
)

(defun cocc:fill-tiles (useDefaults)
  (foreach key (cutonce:setting-keys)
    (set_tile key (if (if useDefaults (cutonce:setting-default key) (cutonce:on-p key)) "1" "0"))
  )
  (set_tile "freq" (if useDefaults (cocc:default-freq) (cutonce:warn-mode)))
  (cocc:refresh-modes)
)

(defun cocc:press-defaults ( )
  (setq *cocc:reset* T)
  (cocc:fill-tiles T)
  (set_tile "note" "Defaults restored in the dialog. Click OK to keep them.")
)

(defun cocc:capture ( )
  (setq *cocc:values*
    (append
      (mapcar (function (lambda (k) (cons k (get_tile k)))) (cutonce:setting-keys))
      (list (cons "freq" (get_tile "freq")))))
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
          (set_tile "note" "")
          (action_tile "WarnEXPLODE" "(cocc:refresh-modes)")
          (action_tile "email" "(cutonce:email-unlock)")
          (action_tile "defaults" "(cocc:press-defaults)")
          (action_tile "learn_more" "(cutonce:open-kb \"GUARD_EXPLODE\")")
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

(defun cocc:print-all ( )
  (cocc:log "Current settings (type a name to toggle it):")
  (foreach e *cutonce:settings*
    (princ (strcat "\n    " (if (cutonce:on-p (car e)) "[on]  " "[off] ") (car e) "  - " (caddr e)))
  )
  (princ (strcat "\n    Frequency: " (if (= (cutonce:warn-mode) "once") "once per command per session" "every time")))
  (princ (strcat "\n  " *cutonce:unlock-note*))
  (princ)
)

(defun cocc:print-summary ( )
  (princ (strcat "\n  EXPLODE warning: " (if (cutonce:on-p "WarnEXPLODE") "on" "OFF")
                 "   Frequency: " (if (= (cutonce:warn-mode) "once") "once per command per session" "every time")))
  (princ (strcat "\n  " *cutonce:unlock-note*))
  (princ)
)

;; ---------------------------------------------------------------------------
;; -CUTONCE (command line)
;;   Type a setting name (or enough of it to be unique) to toggle it, or:
;;     List  Frequency  Defaults  eXit
;;   e.g. ^C^C-CUTONCE;WarnEXPLODE;;     toggles the EXPLODE warning
;; ---------------------------------------------------------------------------

(setq *cocc:keywords* '("LIST" "FREQUENCY" "DEFAULTS" "EXIT"))

;; Resolves typed input to a keyword or setting key; nil if unknown/ambiguous.
(setq *cocc:abbrev*
  '(("X" . "EXIT") ("L" . "LIST") ("F" . "FREQUENCY") ("D" . "DEFAULTS")))

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
  (setq on (not (cutonce:on-p key)))
  (cutonce:set-on key on)
  (cocc:log (strcat (cutonce:setting-label key) ": " (if on "ON" "OFF")))
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
      (setq in (getstring "\nSetting to toggle, or [List/Frequency/Defaults/eXit] <eXit>: "))
      (and in (/= in "") (/= (setq kw (cocc:resolve in)) "EXIT"))
    )
    (cond
      ((null kw) (cocc:log (strcat "\"" in "\" is not a setting name (or matches more than one). Type List to see them.")))
      ((= kw "LIST") (cocc:print-all))
      ((= kw "FREQUENCY")
       (cutonce:set-warn-mode (if (= (cutonce:warn-mode) "once") "every" "once"))
       (cocc:log (strcat "EXPLODE warning: " (if (= (cutonce:warn-mode) "once") "once per command per session" "every time"))))
      ((= kw "DEFAULTS") (cocc:reset-all))
      (T (cocc:toggle-key (cocc:key-from-upper kw)))
    )
  )
  (princ)
)

(defun c:-CUTONCE ( ) (cocc:command-line))

(princ)
