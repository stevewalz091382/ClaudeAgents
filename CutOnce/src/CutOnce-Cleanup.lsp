;;; ============================================================================
;;; CutOnce-Cleanup.lsp
;;;
;;; Bloat cleanup and backup copies.
;;;
;;; CLEANUP
;;;   When the save-time growth check fires, its warning offers "Clean up
;;;   now..." [GuardCleanup]. That queues CUTONCE-CLEANUP to run as soon as the
;;;   save finishes, so the copy on disk is the drawing before cleanup. The
;;;   cleanup dialog shows what it can remove, with the current counts, and the
;;;   designer ticks what runs:
;;;     - unused registered applications      -PURGE Regapps
;;;     - the annotation scale list           -SCALELISTEDIT Reset
;;;     - unused text, dimension, multileader, table and multiline styles
;;;                                           -PURGE (one per style type)
;;;     - unused anonymous blocks             -PURGE Blocks `**
;;;     - unused Civil 3D styles              _PURGESTYLES (Civil 3D's dialog)
;;;     - AUDIT, fixing errors
;;;   PURGE only removes items nothing uses. Everything runs as one undo step,
;;;   so U straight afterwards undoes it. The result lists each count before
;;;   and after and is logged to Events.csv (CLEANUP).
;;;
;;; BACKUP COPIES ("accept the risk, keep a way back")
;;;   Before cleanup changes anything, the dialog offers to copy the drawing
;;;   as last saved into the shared backup folder [BackupBeforeCleanup]. Lock
;;;   that setting on to require a backup. CUTONCE-BACKUP makes a copy at any
;;;   time. Every copy gets a unique name, so nobody overwrites their own or
;;;   anyone else's copy in the shared folder:
;;;       <drawing>__<YYYYMMDD-HHMMSS-mmm>_<user>-<computer>.dwg
;;;   Each copy is recorded in Backups.csv in the log folder (always, even
;;;   with logging off) and in Events.csv (BACKUP-COPY).
;;;   Backup folder: CUTONCE_BACKUPDIR, then "BackupDir" in CutOnce-Config.lsp,
;;;   then Documents\CutOnce Backups.
;;;
;;; Commands:
;;;   CUTONCE-CLEANUP         the cleanup dialog, any time
;;;   CUTONCE-BACKUP          copy this drawing to the backup folder now (every
;;;                           CutOnce warning also has a "Save a copy" button)
;;;   CUTONCE-BACKUP-FOLDER   open the backup folder
;;;
;;; Naming: every function and global here starts with coclean: / *coclean:.
;;; Requires CutOnce-Core.lsp and CutOnce-Health.lsp.
;;; ============================================================================

(vl-load-com)

(defun coclean:log (msg) (cutonce:msg "CutOnce Cleanup" msg))

;; ---------------------------------------------------------------------------
;; Counts (this drawing only: the dictionaries are read with namedobjdict)
;; ---------------------------------------------------------------------------

;; Entries in a named-object dictionary such as ACAD_SCALELIST.
(defun coclean:dict-count (name / d n)
  (setq n 0)
  (if (setq d (dictsearch (namedobjdict) name))
    (foreach g d (if (= (car g) 350) (setq n (1+ n))))
  )
  n
)

;; Anonymous block definitions (*U, *D, *X, *T, *A ...), not layouts or xrefs.
(defun coclean:anon-count (doc / n name)
  (setq n 0)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for blk (vla-get-Blocks doc)
        (setq name (strcase (cond ((cutonce:str-prop blk 'Name)) (""))))
        (if (and (wcmatch name "`**")
                 (not (wcmatch name "`*MODEL_SPACE,`*PAPER_SPACE*"))
                 (not (eq (cutonce:prop blk 'IsXRef) :vlax-true)))
          (setq n (1+ n)))))))
  n
)

(defun coclean:style-count (doc)
  (+ (cutonce:count (vla-get-TextStyles doc))
     (cutonce:count (vla-get-DimStyles doc))
     (coclean:dict-count "ACAD_MLEADERSTYLE")
     (coclean:dict-count "ACAD_TABLESTYLE")
     (coclean:dict-count "ACAD_MLINESTYLE"))
)

(defun coclean:counts (doc / civ)
  (setq civ (cutonce:civil-doc))
  (list (cons "RegApps"     (cutonce:count (vla-get-RegisteredApplications doc)))
        (cons "Scales"      (coclean:dict-count "ACAD_SCALELIST"))
        (cons "Styles"      (coclean:style-count doc))
        (cons "AnonBlocks"  (coclean:anon-count doc))
        (cons "CivilStyles" (if civ (cohealth:count-styles civ) "n/a")))
)

;; ---------------------------------------------------------------------------
;; Steps: (key label count-name)
;; ---------------------------------------------------------------------------

(setq *coclean:steps*
  '(("regapps" "Unused registered applications (RegApps)"                    "RegApps")
    ("scales"  "Reset the annotation scale list to the default"              "Scales")
    ("styles"  "Unused text, dimension, multileader, table, multiline styles" "Styles")
    ("anon"    "Unused anonymous blocks"                                     "AnonBlocks")
    ("civil"   "Unused Civil 3D styles (opens Civil 3D Purge Styles)"         "CivilStyles")
    ("audit"   "AUDIT the drawing and fix errors"                            nil)))

(defun coclean:count-text (v) (if (numberp v) (itoa v) (vl-princ-to-string v)))

;; ---------------------------------------------------------------------------
;; Dialog
;; ---------------------------------------------------------------------------

(setq *coclean:choice* nil)

(defun coclean:write-dcl (counts / path f)
  (setq path (vl-filename-mktemp "coclean" nil ".dcl"))
  (if (setq f (open path "w"))
    (progn
      (foreach ln
        (append
          (list "co_cleanup : dialog {"
                "  label = \"CutOnce - clean up this drawing\";"
                "  : list_box { key = \"info\"; height = 7; width = 84; }"
                "  : boxed_column {"
                "    label = \"Remove (only items nothing uses)\";")
          (mapcar (function (lambda (st / n)
                    (setq n (if (caddr st) (cdr (assoc (caddr st) counts))))
                    (strcat "    : toggle { key = \"cl_" (car st) "\"; label = \""
                            (cutonce:dcl-str (strcat (cadr st) (if n (strcat "  (now " (coclean:count-text n) ")") "")))
                            "\"; }")))
                  *coclean:steps*)
          (list "  }"
                "  : boxed_column {"
                "    label = \"Backup copy\";"
                "    : toggle { key = \"cl_backup\"; label = \"Save a backup copy to the shared backup folder first (recommended)\"; }"
                "    : text { key = \"bk_dir\"; width = 84; }"
                "    : text { key = \"bk_note\"; width = 84; }"
                "  }"
                "  : row {"
                "    alignment = centered; fixed_width = true;"
                "    : button { key = \"accept\"; label = \"Clean up\"; is_default = true; width = 14; }"
                "    : button { key = \"cancel\"; label = \"Cancel\"; is_cancel = true; width = 12; }"
                "    : button { key = \"learn\"; label = \"Learn More...\"; width = 16; }"
                "  }"
                "}"))
        (write-line ln f)
      )
      (close f)
      path
    )
  )
)

(defun coclean:capture ( )
  (setq *coclean:choice*
    (vl-remove nil
      (mapcar (function (lambda (k) (if (= (get_tile (strcat "cl_" k)) "1") k)))
              (cons "backup" (mapcar 'car *coclean:steps*)))))
)

;; Returns the ticked keys ("backup" "regapps" ...), or nil when cancelled.
(defun coclean:dialog (doc counts / path dcl_id result canbackup forced)
  (setq canbackup (and (= 1 (getvar "DWGTITLED")) (cutonce:nonblank (cutonce:str-prop doc 'FullName)))
        forced (and (cutonce:locked-p "BackupBeforeCleanup") (cutonce:on-p "BackupBeforeCleanup"))
        *coclean:choice* nil result 0)
  (setq path (coclean:write-dcl counts))
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog "co_cleanup" dcl_id)
        (progn
          (start_list "info")
          (foreach ln (list
                        "Cleanup changes this drawing. Clicking Clean up means you accept that risk."
                        "PURGE removes only items nothing in the drawing uses; AUDIT fixes errors."
                        "It runs as one undo step: type U straight afterwards to undo it."
                        "Save the drawing afterwards to keep the result."
                        ""
                        (strcat "Drawing: " (cond ((cutonce:str-prop doc 'FullName)) ((cutonce:str-prop doc 'Name)) (""))))
            (add_list ln))
          (end_list)
          (foreach st *coclean:steps* (set_tile (strcat "cl_" (car st)) "1"))
          (set_tile "bk_dir" (strcat "Folder: " (cutonce:backup-dir)
                                     (if (cutonce:backup-dir-configured) "" "  (personal - CAD admin can set BackupDir)")))
          (cond
            ((not canbackup)
             (set_tile "cl_backup" "0") (mode_tile "cl_backup" 1)
             (set_tile "bk_note" "No backup possible: this drawing has never been saved."))
            (T
             (set_tile "cl_backup" (if (cutonce:on-p "BackupBeforeCleanup") "1" "0"))
             (if forced (mode_tile "cl_backup" 1))
             (set_tile "bk_note"
               (strcat (if (/= 0 (getvar "DBMOD"))
                         "The copy is the last saved version; unsaved changes are not in it."
                         "The copy is the drawing as last saved, before any cleanup.")
                       (if forced "  Required by your CAD administrator." "")))))
          (action_tile "learn" "(cutonce:open-kb \"GUARD_CLEANUP\")")
          (action_tile "accept" "(coclean:capture)(done_dialog 1)")
          (action_tile "cancel" "(done_dialog 0)")
          (setq result (start_dialog))
        )
      )
      (unload_dialog dcl_id)
    )
    (coclean:log "Dialog unavailable.")
  )
  (if path (vl-file-delete path))
  (if (= result 1) (cond (*coclean:choice*) ('("none"))))
)

;; ---------------------------------------------------------------------------
;; Running the cleanup
;; ---------------------------------------------------------------------------

;; Cancels a command left waiting for input (an option a release lacks),
;; never this command itself.
(defun coclean:cancel-active ( / n)
  (setq n 0)
  (while (and (= 1 (logand 1 (getvar "CMDACTIVE")))
              (cutonce:nonblank (getvar "CMDNAMES"))
              (not (wcmatch (strcase (getvar "CMDNAMES")) "*CUTONCE*"))
              (< n 4))
    (command)
    (setq n (1+ n))
  )
)

;; Every command the cleanup runs, in order, for the result and the command line.
(setq *coclean:ran* nil)

(defun coclean:note (txt)
  (setq *coclean:ran* (cons txt *coclean:ran*))
  (princ (strcat "\n[CutOnce Cleanup] " txt))
)

;; The commands are called directly (not through vl-catch-all-apply, which
;; Civil 3D does not reliably let drive the command line), with CMDECHO on so
;; PURGE and AUDIT report what they did on the command line.
(defun coclean:purge (kw names)
  (coclean:note (strcat "-PURGE " (substr kw 2) " " names " No"))
  (command "_.-PURGE" kw names "_No")
  (coclean:cancel-active)
)

(defun coclean:purge-pass (choice)
  (if (member "styles" choice)
    (foreach kw '("_Dimstyles" "_textSTyles" "_MUltileaderstyles" "_Tablestyles" "_Mlinestyles")
      (coclean:purge kw "*")))
  ;; anonymous blocks only: ` makes the first * literal
  (if (member "anon" choice) (coclean:purge "_Blocks" "`**"))
  (if (member "regapps" choice) (coclean:purge "_Regapps" "*"))
)

(defun coclean:purge-styles-civil ( )
  (coclean:note "_PURGESTYLES (Civil 3D Purge Styles dialog)")
  (initdia)
  (command "_.PURGESTYLES")
  ;; the dialog is modal; wait for it if the command is still running
  (while (and (= 1 (logand 1 (getvar "CMDACTIVE")))
              (wcmatch (strcase (cond ((getvar "CMDNAMES")) (""))) "*PURGESTYLES*"))
    (command pause))
)

(defun coclean:result-text (k before after)
  (cond
    ((not (and (numberp (cdr (assoc k before))) (numberp (cdr (assoc k after)))))
     (strcat (coclean:count-text (cdr (assoc k before))) " -> " (coclean:count-text (cdr (assoc k after)))))
    ((= (cdr (assoc k before)) (cdr (assoc k after)))
     (strcat (itoa (cdr (assoc k after))) " -> " (itoa (cdr (assoc k after))) "  (nothing unused to remove)"))
    (T (strcat (itoa (cdr (assoc k before))) " -> " (itoa (cdr (assoc k after)))
               "  (" (itoa (- (cdr (assoc k before)) (cdr (assoc k after)))) " removed)")))
)

(defun coclean:run (doc choice / before after bk echo *error* pass prevsum cursum lines r)
  (setq before (coclean:counts doc) echo (getvar "CMDECHO") *coclean:ran* nil)
  (defun *error* (msg)
    (command-s "_.UNDO" "_End")
    (setvar "CMDECHO" echo)
    (if (not (wcmatch (strcase msg) "*CANCEL*,*QUIT*,*EXIT*")) (coclean:log (strcat "Stopped: " msg)))
    (princ)
  )
  ;; 1. backup copy, when ticked
  (if (member "backup" choice)
    (if (not (setq bk (cutonce:backup doc "Before cleanup")))
      (cond
        ((and (cutonce:locked-p "BackupBeforeCleanup") (cutonce:on-p "BackupBeforeCleanup"))
         (cutonce:notice (strcat "The backup copy could not be saved, and your CAD administrator\n"
                                 "requires one before cleanup. Nothing was changed.\n\n"
                                 "Backup folder: " (cutonce:backup-dir))
                         "BACKUP")
         (exit))
        ((not (cutonce:confirm (strcat "The backup copy could not be saved (see the command line).\n\n"
                                       "Backup folder: " (cutonce:backup-dir) "\n\n"
                                       "Clean up anyway, without a backup?")
                               "Clean up without a backup" "Cancel"))
         (coclean:log "Cancelled - nothing was changed.")
         (exit))
      )
    )
  )
  ;; 2. PURGE / scale list / Purge Styles / AUDIT, as one undo step
  (setvar "CMDECHO" 1)
  (coclean:log "Cleaning up - each command and its result is shown below.")
  (command "_.UNDO" "_Begin")
  ;; purging one item can free another (a style using a regapp, a block
  ;; inside a block), so repeat while counts keep falling, at most 3 times
  (setq pass 0 cursum -1)
  (while (and (< pass 3) (/= cursum prevsum)
              (vl-some (function (lambda (k) (member k choice))) '("styles" "anon" "regapps")))
    (setq prevsum (if (= pass 0) -2 cursum))
    (coclean:purge-pass choice)
    (setq after (coclean:counts doc)
          cursum (+ (cdr (assoc "RegApps" after)) (cdr (assoc "Styles" after)) (cdr (assoc "AnonBlocks" after)))
          pass (1+ pass))
  )
  (if (member "scales" choice)
    (progn
      (coclean:note "-SCALELISTEDIT Reset Yes Exit")
      (command "_.-SCALELISTEDIT" "_Reset" "_Yes" "_Exit")
      (coclean:cancel-active)))
  (if (member "civil" choice) (coclean:purge-styles-civil))
  (if (member "audit" choice)
    (progn
      (coclean:note "AUDIT Yes (fix errors)")
      (command "_.AUDIT" "_Yes")
      (coclean:cancel-active)))
  (command "_.UNDO" "_End")
  (setvar "CMDECHO" echo)
  (setq after (coclean:counts doc))
  ;; 3. result
  (setq lines
    (mapcar (function (lambda (st / k)
              (setq k (caddr st))
              (strcat "  " (cadr st) ": "
                      (cond ((not (member (car st) choice)) "not run")
                            (k (coclean:result-text k before after))
                            (T "done (see the command line)")))))
            *coclean:steps*))
  (cutonce:log-event "CLEANUP"
    (cutonce:join
      (mapcar (function (lambda (k) (strcat k " " (coclean:count-text (cdr (assoc k before)))
                                            "->" (coclean:count-text (cdr (assoc k after))))))
              '("RegApps" "Scales" "Styles" "AnonBlocks" "CivilStyles"))
      "  "))
  (setq r
    (cutonce:notice-dialog
      (cutonce:join
        (append
          (list "CutOnce cleanup finished." "")
          lines
          (list "" "Commands run:")
          (mapcar (function (lambda (x) (strcat "  " x))) (reverse *coclean:ran*))
          (list ""
                "PURGE only removes items nothing uses, so an unchanged count means everything"
                "of that kind is still in use. Its messages are on the command line (F2)."
                ""
                (if bk (strcat "Backup copy (before cleanup): " bk) "No backup copy was made.")
                ""
                "Type U now to undo the whole cleanup."
                "Save the drawing to keep the result."))
        "\n")
      (list (cons "Learn More..." "GUARD_CLEANUP"))
      (list "Save now")
      "Close"))
  (if (= r 2) (command "_.QSAVE"))
  (princ)
)

(defun coclean:main ( / doc counts choice)
  (setq doc (cutonce:active-doc))
  (setq counts (coclean:counts doc))
  (setq choice (coclean:dialog doc counts))
  (cond
    ((null choice) (coclean:log "Cancelled - nothing was changed."))
    ((not (vl-some (function (lambda (st) (member (car st) choice))) *coclean:steps*))
     (coclean:log "Nothing ticked - nothing was changed."))
    (T (coclean:run doc choice))
  )
  (princ)
)

;; Called from the growth warning during a save: run CUTONCE-CLEANUP or
;; CUTONCE-BACKUP once the save has finished, so the file on disk is the
;; drawing as just saved.
(defun coclean:queue (cmd / r)
  (setq r (vl-catch-all-apply 'vla-SendCommand (list (cutonce:active-doc) (strcat cmd "\n"))))
  (if (vl-catch-all-error-p r)
    (coclean:log (strcat "Type " cmd " to continue."))
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

(defun c:CUTONCE-CLEANUP ( ) (coclean:main))

(defun c:CUTONCE-BACKUP ( / doc kw bk)
  (setq doc (cutonce:active-doc))
  (cond
    ((/= 1 (getvar "DWGTITLED"))
     (coclean:log "Save the drawing first - there is no file to copy yet."))
    (T
     (if (/= 0 (getvar "DBMOD"))
       (progn
         (initget "Save Copy Cancel")
         (setq kw (cond ((getkword "\nThis drawing has unsaved changes. [Save first/Copy last saved version/Cancel] <Save first>: "))
                        ("Save")))
         (if (= kw "Save") (command "_.QSAVE"))
       )
     )
     (if (/= kw "Cancel")
       (if (setq bk (cutonce:backup doc (if (= kw "Copy") "Manual (last saved version)" "Manual")))
         (princ (strcat "\n  Recorded in " (cutonce:backups-log)))
       )
     )
    )
  )
  (princ)
)

(defun c:CUTONCE-BACKUP-FOLDER ( / dir)
  (setq dir (cutonce:backup-dir))
  (vl-catch-all-apply 'cutonce:mkdir-p (list dir))
  (coclean:log (strcat "Backup folder: " dir))
  (cutonce:open-folder dir)
)

(princ)
