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
;;;   commands below starts, and by any intercepted command (next section).
;;;   Each designer chooses in CUTONCE:
;;;     - warnings on or off altogether               [ImpactWarnings]
;;;     - each kind on or off: grip edits [ImpactGrips], surface edits
;;;       [ImpactSurface], MOVE/STRETCH/ROTATE/SCALE [ImpactTransform], other
;;;       watched commands added by the CAD admin [ImpactOther]
;;;     - every time, or only the first time each command runs in a session
;;;   Every warning shown is logged to Events.csv as IMPACT [LogEvents].
;;;
;;; MOVE / STRETCH / ROTATE / SCALE
;;;   Warned about through the command reactor, with nothing undefined: before
;;;   the command when the objects were pre-selected, otherwise when it ends
;;;   (with "type U to undo").
;;;
;;; COMMAND INTERCEPTION (OFF by default, opt-in per user, per command)
;;;   Optional, for a warning BEFORE the edit even without a pre-selection.
;;;   Each of MOVE, STRETCH, ROTATE and SCALE can be intercepted separately.
;;;   An intercepted command is UNDEFINED for the session and replaced by a
;;;   version that shows the warning before the real command runs.
;;;   CAD managers can disable or pre-enable it in CutOnce-Config.lsp.
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
;;;   CUTONCE-IMPACT-RESTORE     turn all interception off and restore MOVE,
;;;                          STRETCH, ROTATE and SCALE
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
(if (not (boundp '*coimpact:intercepting*))      (setq *coimpact:intercepting* nil))
(if (not (boundp '*coimpact:wrapped*))           (setq *coimpact:wrapped* nil))
(if (not (boundp '*coimpact:foreign*))           (setq *coimpact:foreign* nil))
(if (not (boundp '*coimpact:dcl-path*))          (setq *coimpact:dcl-path* nil))

(setq *coimpact:native-commands* '("MOVE" "STRETCH" "ROTATE" "SCALE"))

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

;; Control Center switch that governs a command's warning.
(defun coimpact:category (cmdname)
  (cond
    ((member cmdname *coimpact:native-commands*) "ImpactTransform")
    ((wcmatch cmdname "GRIP_*") "ImpactGrips")
    ((member cmdname *coimpact:verified-commands*) "ImpactSurface")
    (T "ImpactOther")
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

(defun coimpact:warnings-wanted-p ( ) (cutonce:on-p "ImpactWarnings"))

;; "every" (default) or "once" (once per command per Civil 3D session)
(defun coimpact:warn-mode ( / p)
  (setq p (if (not (cutonce:locked-p "ImpactWarnFrequency")) (cutonce:pref-get "ImpactWarnFrequency")))
  (cond ((member p '("every" "once")) p)
        ((= (cutonce:cfg "ImpactWarnFrequency" "every") "once") "once")
        (T "every"))
)

(defun coimpact:intercept-allowed-p ( ) (cutonce:cfg "ImpactInterceptAllowed" T))

;; Per-command choice ("ImpactIntercept.MOVE" etc.); without one, the
;; administrator's ImpactInterceptDefault applies.
(defun coimpact:intercept-wanted-p (cn / p def)
  (if (coimpact:intercept-allowed-p)
    (progn
      (setq p (cutonce:pref-get (strcat "ImpactIntercept." cn)))
      (cond
        ((= p "1") T)
        ((= p "0") nil)
        (T
         (setq def (cutonce:cfg "ImpactInterceptDefault" nil))
         (cond
           ((null def) nil)
           ((listp def) (if (member cn (mapcar 'strcase (vl-remove-if-not 'cutonce:nonblank def))) T))
           (T T)))
      )
    )
  )
)

;; ---------------------------------------------------------------------------
;; "Once per session" bookkeeping. Kept on the Visual LISP blackboard so it is
;; shared by every open drawing and cleared when Civil 3D closes. All grip
;; edits (GRIP_STRETCH, GRIP_MOVE, ...) count as one command, "GRIP".
;; ---------------------------------------------------------------------------

(defun coimpact:warn-key (cmdname) (if (wcmatch cmdname "GRIP_*") "GRIP" cmdname))

(defun coimpact:should-warn-p (cmdname)
  (and (coimpact:warnings-wanted-p)
       (cutonce:on-p (coimpact:category cmdname))
       (or (= (coimpact:warn-mode) "every")
           (not (member (coimpact:warn-key cmdname) (vl-bb-ref '*coimpact:bb-warned*)))))
)

(defun coimpact:mark-warned (cmdname / key seen)
  (setq key (coimpact:warn-key cmdname) seen (vl-bb-ref '*coimpact:bb-warned*))
  (if (not (member key seen)) (vl-bb-set '*coimpact:bb-warned* (cons key seen)))
)

(defun coimpact:reset-warned ( ) (vl-bb-set '*coimpact:bb-warned* nil))

;; ---------------------------------------------------------------------------
;; Dialogs (DCL written to a temp file on first use)
;; ---------------------------------------------------------------------------

(setq *coimpact:intercept-text*
  '("Moving, stretching, rotating or scaling Civil 3D objects is always"
    "warned about (when warnings are on): before the command if the objects"
    "were selected first, otherwise right after it, with U to undo."
    ""
    "Interception is optional and OFF by default. It moves the warning BEFORE"
    "the edit in every case: each command you tick is UNDEFINED for the"
    "session and replaced by a version that asks for the selection, shows the"
    "warning, then runs the original command (press ESC to stop it)."
    ""
    "Side effects while a command is ticked:"
    " - Other LISP routines, scripts or macros that call it WITHOUT the"
    "   \"_.\" prefix will run the CutOnce version instead."
    " - Menu macros that use \"_.MOVE\" etc. bypass interception."
    " - Unticking restores the original command immediately. UNDEFINE never"
    "   lasts beyond the Civil 3D session."))

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
;;   MOVE / STRETCH / ROTATE / SCALE   the intercepted command itself
;;   SURFACE                           any surface-edit command
;;   GRIP_ALIGNMENT / GRIP_PROFILE     a grip edit, by what is selected
;;   GENERAL                           anything else (no single object)
(defun coimpact:topic (cmdname ents / kinds obj)
  (cond
    ((member cmdname *coimpact:native-commands*) cmdname)
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
          (set_tile "freq_note"
            (if (= (coimpact:warn-mode) "once")
              "Shown once per command each session. To change, type CUTONCE."
              "Shown every time. To change, type CUTONCE (Control Center)."))
          (action_tile "accept" "(done_dialog 1)")
          (action_tile "learn_more"
            (strcat "(cutonce:open-kb " (vl-prin1-to-string topic) ")"))
          (start_dialog)
        )
      )
      (unload_dialog dcl_id)
    )
  )
  (coimpact:mark-warned cmdname)
)

;; Every impact warning goes through here: logged, then shown.
(defun coimpact:warn (cmdname topic lines after)
  (cutonce:log-event "IMPACT"
    (strcat cmdname " (" topic ")" (if after " after the edit" "")
            "  " (itoa (length (vl-remove "" lines))) " report line(s)"))
  (coimpact:show-impact cmdname topic lines after)
)

;; ---------------------------------------------------------------------------
;; Command interception (opt-in, per command): MOVE / STRETCH / ROTATE / SCALE
;; ---------------------------------------------------------------------------

;; Runs the real command. A pre-selection is cleared first: the real command
;; would otherwise take the implied selection on its own and the selection
;; passed here would land on its next prompt ("Specify base point").
(defun coimpact:run-native (cmdname ents / ss)
  (if ents
    (progn
      (setq ss (ssadd))
      (foreach e ents (ssadd e ss))
      (sssetfirst nil nil)
      (command (strcat "_." cmdname) ss "")
    )
    (command (strcat "_." cmdname))
  )
)

(defun coimpact:pickfirst-ents ( / ss)
  (if (setq ss (ssget "_I")) (cdr (coimpact:analyze-ss-ents ss)))
)

(defun coimpact:native-override (cmdname / scanresult)
  (coimpact:dbg (strcat "intercepted " cmdname))
  (if (coimpact:should-warn-p cmdname)
    (progn
      (coimpact:begin-analysis)
      (setq scanresult (coimpact:scan-pickfirst))
      ;; nothing pre-selected: ask for the selection now, as the command would
      (if (not (cdr scanresult)) (setq scanresult (coimpact:analyze-ss (ssget))))
      (if (car scanresult) (coimpact:warn cmdname cmdname (car scanresult) nil))
      ;; tell the command reactor this run is already handled
      (setq *coimpact:handled* cmdname)
      (coimpact:run-native cmdname (cdr scanresult))
    )
    ;; no warning due: hand straight over to the real command
    (coimpact:run-native cmdname (coimpact:pickfirst-ents))
  )
  (princ)
)

;; Entities of a selection set, without any analysis.
(defun coimpact:analyze-ss-ents (ss / n out)
  (setq n 0 out nil)
  (repeat (sslength ss) (setq out (cons (ssname ss n) out) n (1+ n)))
  (cons nil (reverse out))
)

;; ---------------------------------------------------------------------------
;; Command wrappers
;;
;; UNDEFINE applies to every open drawing, but LISP functions belong to one
;; drawing. So C:MOVE, C:STRETCH, C:ROTATE and C:SCALE are defined in EVERY
;; drawing when this file loads, whether or not interception is on. They are
;; inert while the AutoCAD command is defined (AutoCAD always prefers its own
;; command), and once a command is undefined - from any drawing - they make
;; sure it still works everywhere: intercepted if the user wants it, plain
;; pass-through otherwise.
;;
;; A C:<cmd> that another add-on already defined is left alone, and that
;; command cannot be intercepted in that drawing.
;; ---------------------------------------------------------------------------

(defun coimpact:dispatch (cmdname)
  (if (coimpact:intercept-wanted-p cmdname)
    (coimpact:native-override cmdname)
    (progn
      (setq *coimpact:handled* nil)
      (coimpact:run-native cmdname (coimpact:pickfirst-ents))
    )
  )
  (princ)
)

(defun coimpact:install-wrappers ( / sym)
  (foreach cn *coimpact:native-commands*
    (setq sym (read (strcat "C:" cn)))
    (cond
      ;; already ours (file reloaded into this drawing) or free: define it
      ((or (member cn *coimpact:wrapped*) (not (boundp sym)) (null (eval sym)))
       (eval (list 'defun sym nil (list 'coimpact:dispatch cn)))
       (if (not (member cn *coimpact:wrapped*))
         (setq *coimpact:wrapped* (cons cn *coimpact:wrapped*)))
      )
      (T
       (if (not (member cn *coimpact:foreign*))
         (setq *coimpact:foreign* (cons cn *coimpact:foreign*)))
      )
    )
  )
)

;; command-s with command echo and messages off, so restoring a command that
;; is already defined at drawing open prints nothing.
(defun coimpact:quiet-command (verb cn / echo mutt r)
  (setq echo (getvar "CMDECHO") mutt (getvar "NOMUTT"))
  (setvar "CMDECHO" 0)
  (setvar "NOMUTT" 1)
  (setq r (vl-catch-all-apply 'command-s (list verb cn)))
  (setvar "NOMUTT" mutt)
  (setvar "CMDECHO" echo)
  (not (vl-catch-all-error-p r))
)

;; Returns T if cn is intercepted afterwards.
(defun coimpact:intercept-on (cn)
  (cond
    ((member cn *coimpact:foreign*)
     (coimpact:log (strcat "Another add-on already defines C:" cn " - " cn " is not intercepted."))
     nil)
    ((not (member cn *coimpact:wrapped*))
     (coimpact:log (strcat "Could not set up " cn " in this drawing - " cn " is not intercepted."))
     nil)
    ((coimpact:quiet-command "_.UNDEFINE" cn)
     (if (not (member cn *coimpact:intercepting*))
       (setq *coimpact:intercepting* (cons cn *coimpact:intercepting*)))
     T)
    (T
     (coimpact:log (strcat "Could not intercept " cn " in this drawing. Type CUTONCE to retry."))
     nil)
  )
)

;; Always REDEFINEs, even if this drawing did not undefine it: another
;; drawing (or an earlier session state) may have.
(defun coimpact:intercept-off (cn)
  (coimpact:quiet-command "_.REDEFINE" cn)
  (setq *coimpact:intercepting* (vl-remove cn *coimpact:intercepting*))
)

;; Brings every command in line with the stored preferences. Commands that
;; another add-on overrides are left exactly as that add-on set them.
(defun coimpact:apply-intercept-prefs ( )
  (foreach cn *coimpact:native-commands*
    (cond
      ((member cn *coimpact:foreign*) nil)
      ((coimpact:intercept-wanted-p cn) (coimpact:intercept-on cn))
      (T (coimpact:intercept-off cn))
    )
  )
)

;; Shown state: the user's choice, which applies across every drawing.
(defun coimpact:intercept-active-p (cn)
  (and (coimpact:intercept-wanted-p cn) (not (member cn *coimpact:foreign*)))
)

;; Emergency reset: turns interception off for all four commands, saves that
;; choice, and restores the AutoCAD commands.
(defun c:CUTONCE-IMPACT-RESTORE ( )
  (foreach cn *coimpact:native-commands*
    (cutonce:pref-set (strcat "ImpactIntercept." cn) "0")
    (coimpact:intercept-off cn)
  )
  (coimpact:log "MOVE, STRETCH, ROTATE and SCALE restored to the standard AutoCAD commands; interception is off.")
  (princ)
)

;; ---------------------------------------------------------------------------
;; Settings changes (shared by the dialog and the command-line version)
;; ---------------------------------------------------------------------------

(defun coimpact:set-warnings (on)
  (cutonce:set-on "ImpactWarnings" on)
  (if (cutonce:locked-p "ImpactWarnings")
    (coimpact:log "Impact warnings are set by your CAD administrator."))
)

(defun coimpact:set-warn-mode (mode)
  (if (/= mode (coimpact:warn-mode)) (coimpact:reset-warned))
  (if (= mode (if (= (cutonce:cfg "ImpactWarnFrequency" "every") "once") "once" "every"))
    (if (cutonce:pref-get "ImpactWarnFrequency") (cutonce:pref-set "ImpactWarnFrequency" ""))
    (cutonce:pref-set "ImpactWarnFrequency" mode))
)

(defun coimpact:set-intercept (cn on)
  (cutonce:pref-set (strcat "ImpactIntercept." cn) (if on "1" "0"))
  (if on (coimpact:intercept-on cn) (coimpact:intercept-off cn))
)

(defun coimpact:on-off (flag) (if flag "ON" "OFF"))

(defun coimpact:print-settings ( )
  (coimpact:log (strcat "Warnings: " (coimpact:on-off (coimpact:warnings-wanted-p))
                         (if (= (coimpact:warn-mode) "once") " (once per command per session)" " (every time)")))
  (princ "\n  Interception: ")
  (if (not (coimpact:intercept-allowed-p))
    (princ "disabled by your CAD administrator")
    (foreach cn *coimpact:native-commands*
      (princ (strcat cn " " (coimpact:on-off (coimpact:intercept-active-p cn)) "  ")))
  )
  (foreach k '("ImpactGrips" "ImpactSurface" "ImpactTransform" "ImpactOther")
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
;; MOVE / STRETCH / ROTATE / SCALE without interception
;;
;; The command reactor warns about these too, so moving Civil 3D objects is
;; covered without undefining anything:
;;   - objects pre-selected: the warning appears as the command starts
;;     (press ESC after OK to stop it);
;;   - picked after the command started: the warning appears when the command
;;     ends, from the command's own selection, and says to type U to undo.
;; A run started by the interception wrapper has already been warned about
;; and is skipped (*coimpact:handled*).
;; ---------------------------------------------------------------------------

(if (not (boundp '*coimpact:handled*)) (setq *coimpact:handled* nil))
(if (not (boundp '*coimpact:pending*)) (setq *coimpact:pending* nil))

(defun coimpact:transform-will-start (cmdname / scanresult)
  (cond
    ((= *coimpact:handled* cmdname) (setq *coimpact:handled* nil))
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
  (setq *coimpact:pending* nil *coimpact:handled* nil)
  (princ)
)

(defun coimpact:cmd-will-start-body (args / cmdname scanresult lines kind)
  (setq cmdname (strcase (vl-princ-to-string (car args))))
  (if *coimpact:debug* (coimpact:dbg (strcat "command: " cmdname)))
  (cond
    ((member cmdname *coimpact:native-commands*)
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
  (coimpact:log "Warnings ON.")
  (princ)
)

(defun c:CUTONCE-IMPACT-OFF ( )
  (coimpact:set-warnings nil)
  (coimpact:log "Warnings OFF. (Command interception is set separately in the Control Center: CUTONCE.)")
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
  (coimpact:install-wrappers)
  (vl-catch-all-apply 'coimpact:apply-intercept-prefs nil)
)

(coimpact:init)
(princ)
