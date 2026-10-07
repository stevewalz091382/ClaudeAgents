;;; ============================================================================
;;; CutOnce-Impact.lsp
;;;
;;; Change-impact warnings for Civil 3D. Before an alignment, surface or
;;; profile is edited, it lists the objects that depend on it (profiles,
;;; sample line groups, corridors, view frames, profile views, pipe network
;;; parts nearby, grading groups). The warning is information only: OK closes
;;; it (the user presses ESC afterwards to stop the edit) and Learn More opens
;;; the knowledge-base section for that command in the default browser.
;;;
;;; WARNINGS (on by default)
;;;   Shown when a grip edit (GRIP_*) or one of the Civil 3D surface-edit
;;;   commands below starts, and for MOVE / STRETCH / ROTATE / SCALE.
;;;   Each designer chooses in CUTONCE (Command warnings):
;;;     - command warnings on or off altogether        [CommandWarnings]
;;;     - each command on or off: [WarnMOVE] [WarnSTRETCH] [WarnROTATE]
;;;       [WarnSCALE] [WarnGRIPS] [WarnSURFACE] [WarnOTHER]
;;;     - every time, or only the first time each command warns in a session
;;;       [WarnFrequency]
;;;   Every warning is logged to Events.csv as IMPACT [LogEvents], even when
;;;   the dialog is not shown again.
;;;
;;; MOVE / STRETCH / ROTATE / SCALE
;;;   Warned about through the command reactor, with nothing undefined: before
;;;   the command when the objects were pre-selected, otherwise when it ends
;;;   (with "type U to undo").
;;;
;;; WATCHED CIVIL 3D COMMANDS
;;;   Only command names observed in a live Civil 3D session are watched.
;;;   Add others to "ImpactExtraCommands" in CutOnce-Config.lsp after
;;;   confirming their names with CUTONCE-GUARD-LOGCOMMANDS.
;;;
;;; LIMITATIONS
;;;   - Pre-edit analysis of a specific object needs it pre-selected (as it is
;;;     for grip edits). Surface-edit commands pick their target after they
;;;     start, so for those every surface in the drawing is analysed.
;;;   - Surface edits started from Toolspace's right-click menu do not raise a
;;;     command event and are not seen.
;;;   - Pipe proximity is a bounding-box overlap check, not true intersection.
;;;   - Corridor target surfaces set in subassembly parameters are not traced.
;;;
;;; Commands (settings are in CutOnce-ControlCenter.lsp: CUTONCE):
;;;   CUTONCE-IMPACT-ON / -OFF   turn the warnings on or off
;;;   CUTONCE-IMPACT-STATUS      current state
;;;   CUTONCE-IMPACT-DEBUG       toggle diagnostic tracing (off by default)
;;;
;;; Naming: every function and global here starts with coimpact: /
;;; *coimpact:. Requires CutOnce-Core.lsp.
;;; ============================================================================

(vl-load-com)

;; ---------------------------------------------------------------------------
;; State
;; ---------------------------------------------------------------------------

(if (not (boundp '*coimpact:debug*))             (setq *coimpact:debug* nil))
(if (not (boundp '*coimpact:cmd-reactor*))       (setq *coimpact:cmd-reactor* nil))
(if (not (boundp '*coimpact:dcl-path*))          (setq *coimpact:dcl-path* nil))

;; Commands whose Civil 3D objects get the change-impact analysis.
(setq *coimpact:transform-commands* '("MOVE" "STRETCH" "ROTATE" "SCALE"))

;; Civil 3D command names observed firing :vlr-commandWillStart in a live
;; session (ribbon / command line). Grip edits are matched by "GRIP_*".
(setq *coimpact:verified-commands*
  '("AECCRAISELOWERSURFACE"
    "AECCADDSURFACELINE"     "AECCDELETESURFACELINE"
    "AECCADDSURFACEPOINT"    "AECCDELETESURFACEPOINT"
    "AECCEDITSURFACEPOINT"   "AECCMOVESURFACEPOINT"
    "AECCEDITSURFACESWAPEDGE"))

(defun coimpact:dbg (msg)
  (if *coimpact:debug* (princ (strcat "\n[CutOnce Impact] " msg)))
  (princ)
)

(defun coimpact:log (msg) (cutonce:msg "CutOnce Impact" msg))

;; Control Center row that governs a command's warning.
(defun coimpact:category (cmdname)
  (cond
    ((member cmdname *coimpact:transform-commands*) (strcat "Warn" cmdname))
    ((wcmatch cmdname "GRIP_*") "WarnGRIPS")
    ((member cmdname *coimpact:verified-commands*) "WarnSURFACE")
    (T "WarnOTHER")
  )
)

(defun coimpact:watched-p (cmdname / extra)
  (setq extra (cutonce:cfg "ImpactExtraCommands" nil))
  (or (member cmdname *coimpact:verified-commands*)
      (and (listp extra) (member cmdname (mapcar 'strcase (vl-remove-if-not 'cutonce:nonblank extra))))
      (wcmatch cmdname "GRIP_*"))
)

;; ---------------------------------------------------------------------------
;; Small helpers
;; ---------------------------------------------------------------------------

(defun coimpact:safe-name (obj) (cond ((cutonce:str-prop obj 'Name)) ("<unnamed>")))

(defun coimpact:dedupe (lst / out)
  (setq out nil)
  (foreach x lst (if (not (member x out)) (setq out (cons x out))))
  (reverse out)
)

(defun coimpact:same-object-p (a b / ha hb)
  (setq ha (cutonce:prop a 'Handle) hb (cutonce:prop b 'Handle))
  (and ha hb (equal ha hb))
)

;; Corridors, view frames, profile views and pipe parts are not exposed as
;; collections on the Civil 3D land document, so they are found by scanning
;; Model Space for their ObjectName. Results are cached for the duration of
;; one analysis (coimpact:begin-analysis clears the cache), so analysing many
;; surfaces or alignments does not rescan the drawing for each one.
(setq *coimpact:scan-cache* nil)

(defun coimpact:begin-analysis ( ) (setq *coimpact:scan-cache* nil))

(defun coimpact:scan-modelspace (wildcard / hit out)
  (if (setq hit (assoc wildcard *coimpact:scan-cache*))
    (cdr hit)
    (progn
      (setq out nil)
      (vl-catch-all-apply
        (function (lambda ()
          (vlax-for ent (vla-get-ModelSpace (cutonce:active-doc))
            (if (wcmatch (cutonce:object-name ent) wildcard) (setq out (cons ent out)))
          )
        ))
      )
      (setq out (reverse out))
      (setq *coimpact:scan-cache* (cons (cons wildcard out) *coimpact:scan-cache*))
      out
    )
  )
)

(defun coimpact:corridors ( ) (coimpact:scan-modelspace "*Corridor*"))

;; ---------------------------------------------------------------------------
;; Bounding-box overlap (approximate pipe proximity)
;; ---------------------------------------------------------------------------

(defun coimpact:bbox (obj / minpt maxpt r)
  (setq r (vl-catch-all-apply 'vla-GetBoundingBox (list obj 'minpt 'maxpt)))
  (if (vl-catch-all-error-p r)
    nil
    (list (vlax-safearray->list minpt) (vlax-safearray->list maxpt))
  )
)

(defun coimpact:bbox-overlap-p (b1 b2 / min1 max1 min2 max2)
  (if (and b1 b2)
    (progn
      (setq min1 (car b1) max1 (cadr b1) min2 (car b2) max2 (cadr b2))
      (not (or (> (car min1) (car max2)) (> (car min2) (car max1))
               (> (cadr min1) (cadr max2)) (> (cadr min2) (cadr max1))))
    )
  )
)

(defun coimpact:nearby-names (algObj parts / abox out)
  (setq abox (coimpact:bbox algObj) out nil)
  (if abox
    (foreach part parts
      (if (coimpact:bbox-overlap-p abox (coimpact:bbox part))
        (setq out (cons (coimpact:safe-name part) out))
      )
    )
  )
  (reverse out)
)

;; ---------------------------------------------------------------------------
;; Relationship tests. Each tries the object reference first, then the ID.
;; ---------------------------------------------------------------------------

(defun coimpact:baseline-uses-alignment-p (baseline algObj / balg id1 id2)
  (setq balg (cond ((cutonce:prop baseline 'Alignment)) ((cutonce:prop baseline 'AlignmentEntity))))
  (if balg
    (coimpact:same-object-p balg algObj)
    (progn
      (setq id1 (cutonce:prop baseline 'AlignmentId) id2 (cutonce:prop algObj 'ObjectID))
      (and id1 id2 (equal id1 id2))
    )
  )
)

(defun coimpact:baseline-uses-profile-p (baseline profObj / bprof id1 id2)
  (setq bprof (cond ((cutonce:prop baseline 'Profile)) ((cutonce:prop baseline 'ProfileEntity))))
  (if bprof
    (coimpact:same-object-p bprof profObj)
    (progn
      (setq id1 (cutonce:prop baseline 'ProfileId) id2 (cutonce:prop profObj 'ObjectID))
      (and id1 id2 (equal id1 id2))
    )
  )
)

(defun coimpact:profile-uses-surface-p (profObj surfObj / psurf)
  (setq psurf (cond ((cutonce:prop profObj 'Surface)) ((cutonce:prop profObj 'SurfaceEntity))))
  (and psurf (coimpact:same-object-p psurf surfObj))
)

(defun coimpact:references-alignment-p (obj algObj / valg)
  (setq valg (cutonce:prop obj 'Alignment))
  (and valg (coimpact:same-object-p valg algObj))
)

(defun coimpact:gradinggroup-uses-surface-p (gg surfObj / gsurf)
  (setq gsurf (cond ((cutonce:prop gg 'Surface)) ((cutonce:prop gg 'BaseSurface))))
  (and gsurf (coimpact:same-object-p gsurf surfObj))
)

(defun coimpact:corridors-matching (corridors testfn obj / matched)
  (setq matched nil)
  (foreach c corridors
    (foreach b (cutonce:collection->list (cutonce:prop c 'Baselines))
      (if (apply testfn (list b obj)) (setq matched (cons c matched)))
    )
  )
  (coimpact:dedupe matched)
)

(defun coimpact:section (title objs)
  (if objs
    (append (list "" title)
            (mapcar (function (lambda (o) (strcat "  - " (coimpact:safe-name o)))) objs))
  )
)

;; ---------------------------------------------------------------------------
;; Impact analysis
;; ---------------------------------------------------------------------------

(defun coimpact:analyze-alignment (algObj / report slgs vframes parts names)
  (setq report (list (strcat "ALIGNMENT: " (coimpact:safe-name algObj))))
  (setq report (append report
    (coimpact:section "PROFILES on this alignment:"
      (cutonce:collection->list (cutonce:prop algObj 'Profiles)))))

  (setq slgs (cutonce:collection->list (cutonce:prop algObj 'SampleLineGroups)))
  (if slgs
    (setq report (append report (list "" "SAMPLE LINE GROUPS on this alignment:")
      (mapcar (function (lambda (g)
                (strcat "  - " (coimpact:safe-name g) " ("
                        (itoa (length (cutonce:collection->list (cutonce:prop g 'SampleLines))))
                        " sample line(s))")))
              slgs)))
  )

  (setq report (append report
    (coimpact:section "CORRIDORS using this alignment as a baseline:"
      (coimpact:corridors-matching (coimpact:corridors) 'coimpact:baseline-uses-alignment-p algObj))))

  (setq vframes (vl-remove-if-not
                  (function (lambda (vf) (coimpact:references-alignment-p vf algObj)))
                  (coimpact:scan-modelspace "*ViewFrame*")))
  (setq report (append report (coimpact:section "SHEETS: view frames based on this alignment:" vframes)))

  (setq parts (append (coimpact:scan-modelspace "*Pipe*") (coimpact:scan-modelspace "*Structure*")))
  (if (setq names (coimpact:nearby-names algObj parts))
    (setq report (append report
      (list "" "PIPE NETWORK PARTS near this alignment (bounding-box check only, verify):")
      (mapcar (function (lambda (n) (strcat "  - " n))) names)))
  )
  report
)

(defun coimpact:analyze-surface (surfObj / civdoc report corridors)
  (setq civdoc (cutonce:civil-doc))
  (setq report (list (strcat "SURFACE: " (coimpact:safe-name surfObj))))
  (setq corridors (coimpact:corridors))
  (foreach a (cutonce:collection->list (cutonce:prop civdoc 'AlignmentsSiteless))
    (foreach p (cutonce:collection->list (cutonce:prop a 'Profiles))
      (if (coimpact:profile-uses-surface-p p surfObj)
        (progn
          (setq report (append report
            (list "" (strcat "PROFILE \"" (coimpact:safe-name p) "\" on alignment \""
                             (coimpact:safe-name a) "\" is derived from this surface."))))
          (foreach c (coimpact:corridors-matching corridors 'coimpact:baseline-uses-profile-p p)
            (setq report (append report
              (list (strcat "  -> CORRIDOR \"" (coimpact:safe-name c) "\" uses that profile as a baseline profile."))))
          )
        )
      )
    )
  )
  (foreach site (cutonce:collection->list (cutonce:prop civdoc 'Sites))
    (foreach gg (cutonce:collection->list (cutonce:prop site 'GradingGroups))
      (if (coimpact:gradinggroup-uses-surface-p gg surfObj)
        (setq report (append report
          (list "" (strcat "GRADING GROUP \"" (coimpact:safe-name gg) "\" references this surface."))))
      )
    )
  )
  report
)

(defun coimpact:analyze-profile (profObj / report parentAlg pviews)
  (setq parentAlg (cutonce:prop profObj 'Alignment))
  (setq report
    (list (strcat "PROFILE: " (coimpact:safe-name profObj)
                  (if parentAlg (strcat " (on alignment \"" (coimpact:safe-name parentAlg) "\")") ""))))
  (setq report (append report
    (coimpact:section "CORRIDORS using this profile as a baseline:"
      (coimpact:corridors-matching (coimpact:corridors) 'coimpact:baseline-uses-profile-p profObj))))
  (if parentAlg
    (progn
      (setq pviews (vl-remove-if-not
                     (function (lambda (pv) (coimpact:references-alignment-p pv parentAlg)))
                     (coimpact:scan-modelspace "*ProfileView*")))
      (setq report (append report
        (coimpact:section "PROFILE VIEWS on the same alignment (likely display this profile):"
          (coimpact:dedupe pviews))))
    )
  )
  report
)

;; Whole-drawing fallbacks, used when a command picks its target after it
;; starts and nothing was pre-selected.
(defun coimpact:analyze-all (kind / civdoc lines)
  (setq civdoc (cutonce:civil-doc) lines nil)
  (coimpact:dbg (strcat "analyze-all " kind ": civil doc " (if civdoc "connected" "NOT connected")))
  (cond
    ((= kind "surface")
     (foreach s (cutonce:collection->list (cutonce:prop civdoc 'Surfaces))
       (setq lines (append lines (coimpact:analyze-surface s) (list "")))))
    ((= kind "alignment")
     (foreach a (cutonce:collection->list (cutonce:prop civdoc 'AlignmentsSiteless))
       (setq lines (append lines (coimpact:analyze-alignment a) (list "")))))
    ((= kind "profile")
     (foreach a (cutonce:collection->list (cutonce:prop civdoc 'AlignmentsSiteless))
       (foreach p (cutonce:collection->list (cutonce:prop a 'Profiles))
         (setq lines (append lines (coimpact:analyze-profile p) (list ""))))))
  )
  lines
)

;; Profiles are AeccDbVAlignment objects, so test for them before alignments.
(defun coimpact:kind (oname)
  (cond
    ((wcmatch oname "*VAlignment*") "profile")
    ((wcmatch oname "*Alignment*") "alignment")
    ((wcmatch oname "*Surface*")   "surface")
    ((wcmatch oname "*Profile*")   "profile")
  )
)

(defun coimpact:analyze-any (obj / kind)
  (setq kind (coimpact:kind (cutonce:object-name obj)))
  (cond
    ((= kind "alignment") (coimpact:analyze-alignment obj))
    ((= kind "surface")   (coimpact:analyze-surface obj))
    ((= kind "profile")   (coimpact:analyze-profile obj))
  )
)

;; Returns (lines . all-entities) for a selection set. all-entities keeps
;; every selected entity so the original selection can be replayed.
(defun coimpact:analyze-ss (ss / n ent obj lines allents)
  (setq lines nil allents nil)
  (if ss
    (progn
      (setq n 0)
      (repeat (sslength ss)
        (setq ent (ssname ss n) allents (cons ent allents))
        (setq obj (vl-catch-all-apply 'vlax-ename->vla-object (list ent)))
        (if (and (not (vl-catch-all-error-p obj)) (coimpact:kind (cutonce:object-name obj)))
          (setq lines (append lines (coimpact:analyze-any obj)))
        )
        (setq n (1+ n))
      )
    )
  )
  (coimpact:dbg (strcat "selection " (itoa (length allents)) " entities, " (itoa (length lines)) " report lines"))
  (cons lines (reverse allents))
)

(defun coimpact:scan-pickfirst ( ) (coimpact:analyze-ss (ssget "_I")))

;; Profile commands are usually started with the parent alignment selected.
;; Report each of that alignment's profiles rather than the alignment itself.
(defun coimpact:analyze-for-profile-command (allents / lines obj kind)
  (setq lines nil)
  (foreach ent allents
    (setq obj (vl-catch-all-apply 'vlax-ename->vla-object (list ent)))
    (if (not (vl-catch-all-error-p obj))
      (progn
        (setq kind (coimpact:kind (cutonce:object-name obj)))
        (cond
          ((= kind "profile") (setq lines (append lines (coimpact:analyze-profile obj))))
          ((= kind "alignment")
           (foreach p (cutonce:collection->list (cutonce:prop obj 'Profiles))
             (setq lines (append lines (coimpact:analyze-profile p) (list "")))))
        )
      )
    )
  )
  lines
)

;; ---------------------------------------------------------------------------
;; Preferences
;;
;; Every setting the user changes is stored in their AutoCAD profile (see
;; cutonce:pref-set) and survives restarts. Where the user has not chosen, the
;; administrator's default from CutOnce-Config.lsp applies.
;; ---------------------------------------------------------------------------

(defun coimpact:warnings-wanted-p ( ) (cutonce:on-p "CommandWarnings"))

;; ---------------------------------------------------------------------------
;; Frequency ("once per command per session") is tracked in CutOnce-Core.lsp.
;; All grip edits (GRIP_STRETCH, GRIP_MOVE, ...) count as one command, "GRIP".
;; ---------------------------------------------------------------------------

(defun coimpact:warn-key (cmdname)
  (strcat "IMPACT:" (if (wcmatch cmdname "GRIP_*") "GRIP" cmdname))
)

(defun coimpact:should-warn-p (cmdname)
  (and (cutonce:cmd-warn-p (coimpact:category cmdname))
       (cutonce:warn-due-p (coimpact:warn-key cmdname)))
)

;; ---------------------------------------------------------------------------
;; Dialogs (DCL written to a temp file on first use)
;; ---------------------------------------------------------------------------

(defun coimpact:ensure-dcl ( / path f)
  (if (not (and *coimpact:dcl-path* (findfile *coimpact:dcl-path*)))
    (progn
      (setq path (vl-filename-mktemp "coimpact" nil ".dcl"))
      (if (setq f (open path "w"))
        (progn
          (foreach ln
            '("coimpact_dialog : dialog {"
              "  label = \"CutOnce - Change-Impact Analysis\";"
              "  : text { label = \"These objects depend on what you are about to edit:\"; }"
              "  : list_box { key = \"impact_list\"; height = 16; width = 72; }"
              "  : text { key = \"hint\"; width = 72; }"
              "  : text { key = \"freq_note\"; width = 72; }"
              "  : row {"
              "    alignment = centered; fixed_width = true;"
              "    : button { key = \"accept\"; label = \"OK\"; is_default = true; is_cancel = true; width = 14; }"
              "    : button { key = \"learn_more\"; label = \"Learn More...\"; width = 16; }"
              "  }"
              "}")
            (write-line ln f)
          )
          (close f)
          (setq *coimpact:dcl-path* path)
        )
      )
    )
  )
  *coimpact:dcl-path*
)

(defun coimpact:fill-list (key lines)
  (start_list key)
  (foreach ln lines (add_list ln))
  (end_list)
)

;; ---------------------------------------------------------------------------
;; Learn More topic (see cutonce:kb-url in CutOnce-Core.lsp)
;; ---------------------------------------------------------------------------

;; Topic of a warning:
;;   MOVE / STRETCH / ROTATE / SCALE   the command itself
;;   SURFACE                           any surface-edit command
;;   GRIP_ALIGNMENT / GRIP_PROFILE     a grip edit, by what is selected
;;   GENERAL                           anything else (no single object)
(defun coimpact:topic (cmdname ents / kinds obj)
  (cond
    ((member cmdname *coimpact:transform-commands*) cmdname)
    ((wcmatch cmdname "*SURFACE*") "SURFACE")
    ((wcmatch cmdname "GRIP_*")
     (setq kinds nil)
     (foreach e ents
       (setq obj (vl-catch-all-apply 'vlax-ename->vla-object (list e)))
       (if (not (vl-catch-all-error-p obj))
         (setq kinds (cons (coimpact:kind (cutonce:object-name obj)) kinds))
       )
     )
     (cond ((member "alignment" kinds) "GRIP_ALIGNMENT")
           ((member "profile" kinds) "GRIP_PROFILE")
           ((member "surface" kinds) "SURFACE")
           (T "GENERAL")))
    (T "GENERAL")
  )
)

;; Information only: AutoLISP cannot cancel a command from here, so the
;; dialog has OK (close) and Learn More (open the explanation for this
;; command; the dialog stays open).
;; after = T when the edit has already been applied (warning raised when the
;; command ended), so the hint says to undo rather than to press ESC.
(defun coimpact:show-impact (cmdname topic lines after / path dcl_id)
  (setq path (coimpact:ensure-dcl))
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog "coimpact_dialog" dcl_id)
        (progn
          (coimpact:fill-list "impact_list"
            (append (list (strcat "Command: " cmdname) "")
                    (if lines lines (list "No dependent objects were found by the automated scan."))))
          (set_tile "hint"
            (if after
              (strcat cmdname " has already been applied. Type U to undo it.")
              "Click OK, then press ESC if you want to stop this command."))
          (set_tile "freq_note" (cutonce:freq-note))
          (action_tile "accept" "(done_dialog 1)")
          (action_tile "learn_more"
            (strcat "(cutonce:open-kb " (vl-prin1-to-string topic) ")"))
          (start_dialog)
        )
      )
      (unload_dialog dcl_id)
    )
  )
  (cutonce:mark-warned (coimpact:warn-key cmdname))
)

;; Every impact warning goes through here: logged, then shown.
(defun coimpact:warn (cmdname topic lines after)
  (cutonce:log-event "IMPACT"
    (strcat cmdname " (" topic ")" (if after " after the edit" "")
            "  " (itoa (length (vl-remove "" lines))) " report line(s)"))
  (coimpact:show-impact cmdname topic lines after)
)

;; ---------------------------------------------------------------------------
;; Settings changes (shared by the dialog and the command-line version)
;; ---------------------------------------------------------------------------

(defun coimpact:set-warnings (on)
  (cutonce:set-on "CommandWarnings" on)
  (if (cutonce:locked-p "CommandWarnings")
    (coimpact:log "Command warnings are set by your CAD administrator."))
)

(defun coimpact:on-off (flag) (if flag "ON" "OFF"))

(defun coimpact:print-settings ( )
  (coimpact:log (strcat "Warnings: " (coimpact:on-off (coimpact:warnings-wanted-p))
                         (if (= (cutonce:warn-mode) "once") " (once per command per session)" " (every time)")))
  (foreach k '("WarnMOVE" "WarnSTRETCH" "WarnROTATE" "WarnSCALE" "WarnGRIPS" "WarnSURFACE" "WarnOTHER")
    (princ (strcat "\n  " (cutonce:setting-label k) ": " (coimpact:on-off (cutonce:on-p k))
                   (if (cutonce:locked-p k) "  (set by CAD admin)" "")))
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Warnings: Civil 3D commands and grip edits (command reactor)
;; ---------------------------------------------------------------------------

(defun coimpact:cmd-will-start (reactor args / r)
  (setq r (vl-catch-all-apply 'coimpact:cmd-will-start-body (list args)))
  (if (vl-catch-all-error-p r)
    (coimpact:dbg (strcat "error: " (vl-catch-all-error-message r)))
  )
  (princ)
)

(defun coimpact:surface-edit-warning ( )
  '("WARNING: Manual surface edits (like Delete Line or Add Point) force a"
    "permanent deviation from the source design data. Because Civil 3D"
    "rebuilds surfaces from their definition in order, these manual changes"
    "can shift or disappear when new data is added. Where possible, change"
    "the source data (feature lines, breaklines, boundaries) instead."
    "")
)

;; ---------------------------------------------------------------------------
;; MOVE / STRETCH / ROTATE / SCALE
;;
;; The command reactor warns about these, with nothing undefined:
;;   - objects pre-selected: the warning appears as the command starts
;;     (press ESC after OK to stop it);
;;   - picked after the command started: the warning appears when the command
;;     ends, from the command's own selection, and says to type U to undo.
;; ---------------------------------------------------------------------------

(if (not (boundp '*coimpact:pending*)) (setq *coimpact:pending* nil))

(defun coimpact:transform-will-start (cmdname / scanresult)
  (cond
    ((coimpact:should-warn-p cmdname)
     (coimpact:begin-analysis)
     (setq scanresult (coimpact:scan-pickfirst))
     (cond
       ((car scanresult) (coimpact:warn cmdname cmdname (car scanresult) nil))
       ((not (cdr scanresult)) (setq *coimpact:pending* cmdname))
     ))
  )
)

(defun coimpact:transform-ended (cmdname / scanresult)
  (if (= *coimpact:pending* cmdname)
    (progn
      (setq *coimpact:pending* nil)
      (if (coimpact:should-warn-p cmdname)
        (progn
          (coimpact:begin-analysis)
          (setq scanresult (coimpact:analyze-ss (ssget "_P")))
          (if (car scanresult) (coimpact:warn cmdname cmdname (car scanresult) T))
        )
      )
    )
  )
)

(defun coimpact:cmd-ended (reactor args / r)
  (setq r (vl-catch-all-apply 'coimpact:transform-ended
            (list (strcase (vl-princ-to-string (car args))))))
  (if (vl-catch-all-error-p r) (coimpact:dbg (strcat "error: " (vl-catch-all-error-message r))))
  (princ)
)

(defun coimpact:cmd-abandoned (reactor args)
  (setq *coimpact:pending* nil)
  (princ)
)

(defun coimpact:cmd-will-start-body (args / cmdname scanresult lines kind)
  (setq cmdname (strcase (vl-princ-to-string (car args))))
  (if *coimpact:debug* (coimpact:dbg (strcat "command: " cmdname)))
  (cond
    ((member cmdname *coimpact:transform-commands*)
     (coimpact:transform-will-start cmdname))
    ;; skip before any analysis when no warning is due (off, or already shown)
    ((and (coimpact:watched-p cmdname) (coimpact:should-warn-p cmdname))
     (coimpact:begin-analysis)
     (setq scanresult (coimpact:scan-pickfirst) lines (car scanresult))
     (if (and (wcmatch cmdname "*PROFILE*") (cdr scanresult))
       (setq lines (coimpact:analyze-for-profile-command (cdr scanresult)))
     )
     ;; Nothing pre-selected: infer the object type from the command name
     ;; and report on every object of that type.
     (if (and (not lines)
              (setq kind (cond ((wcmatch cmdname "*SURFACE*") "surface")
                               ((wcmatch cmdname "*PROFILE*") "profile")
                               ((wcmatch cmdname "*ALIGNMENT*") "alignment"))))
       (if (setq lines (coimpact:analyze-all kind))
         (setq lines (append
           (if (= kind "surface")
             (coimpact:surface-edit-warning)
             (list (strcat "Could not tell which " kind " this command targets.")
                   (strcat "Showing potential impacts for ALL " kind "s in the drawing:")
                   ""))
           lines))
       )
     )
     (if lines
       (coimpact:warn cmdname (coimpact:topic cmdname (cdr scanresult)) lines nil))
    )
  )
)

(defun coimpact:init-reactor ( / r)
  (if (not *coimpact:cmd-reactor*)
    (progn
      (setq r (vl-catch-all-apply 'vlr-editor-reactor
                (list nil (list (cons :vlr-commandWillStart 'coimpact:cmd-will-start)
                                (cons :vlr-commandEnded     'coimpact:cmd-ended)
                                (cons :vlr-commandCancelled 'coimpact:cmd-abandoned)
                                (cons :vlr-commandFailed    'coimpact:cmd-abandoned)))))
      (if (vl-catch-all-error-p r)
        (coimpact:log (strcat "Could not create the command reactor: " (vl-catch-all-error-message r)))
        (setq *coimpact:cmd-reactor* r)
      )
    )
  )
)

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

(defun c:CUTONCE-IMPACT-ON ( )
  (coimpact:set-warnings T)
  (coimpact:log "Command warnings ON.")
  (princ)
)

(defun c:CUTONCE-IMPACT-OFF ( )
  (coimpact:set-warnings nil)
  (coimpact:log "Command warnings OFF. Turn them back on with CUTONCE-IMPACT-ON or in the Control Center (CUTONCE).")
  (princ)
)

(defun c:CUTONCE-IMPACT-STATUS ( )
  (coimpact:print-settings)
  (princ (strcat "\n  Civil 3D COM: " (if (cutonce:civil-app) "connected" "not connected (run CUTONCE-FINDCIVIL)")))
  (princ (strcat "\n  Debug tracing: " (if *coimpact:debug* "ON" "off")))
  (princ "\n  Change any of these in the CutOnce Control Center (type CUTONCE).")
  (princ)
)

(defun c:CUTONCE-IMPACT-DEBUG ( )
  (setq *coimpact:debug* (not *coimpact:debug*))
  (coimpact:log (strcat "Debug tracing " (if *coimpact:debug* "ON" "OFF")))
  (princ)
)

;; ---------------------------------------------------------------------------
;; Initialisation (runs once per drawing when the file loads)
;; ---------------------------------------------------------------------------

(defun coimpact:init ( )
  ;; always on: each warning checks the designer's switches when it fires
  (coimpact:init-reactor)
)

(coimpact:init)
(princ)
