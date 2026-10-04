;;; ============================================================================
;;; C3DImpact.lsp
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
;;;   Each user chooses whether a warning appears every time, or only the first
;;;   time each command runs in a Civil 3D session.
;;;
;;; COMMAND INTERCEPTION (OFF by default, opt-in per user, per command)
;;;   MOVE, STRETCH, ROTATE and SCALE can each be intercepted separately. An
;;;   intercepted command is UNDEFINED for the session and replaced by a
;;;   version that shows the warning before the real command runs.
;;;   CAD managers can disable or pre-enable it in C3DTools-Config.lsp.
;;;
;;; WATCHED CIVIL 3D COMMANDS
;;;   Only command names observed in a live Civil 3D session are watched.
;;;   Add others to "ImpactExtraCommands" in C3DTools-Config.lsp after
;;;   confirming their names with C3DGUARD-LOGCOMMANDS.
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
;;; Commands:
;;;   C3D-IMPACT-SETTINGS    dialog: warnings on/off, every time or once per
;;;                          session, and interception of each command
;;;   -C3D-IMPACT-SETTINGS   the same at the command line (for macros)
;;;   C3D-IMPACT-ON / -OFF   turn the warnings on or off
;;;   C3D-IMPACT-INTERCEPT   same as C3D-IMPACT-SETTINGS (older name)
;;;   C3D-IMPACT-STATUS      current state
;;;   C3D-IMPACT-DEBUG       toggle diagnostic tracing (off by default)
;;;
;;; Naming: every function and global here starts with c3dimpact: /
;;; *c3dimpact:. Requires C3DTools-Core.lsp.
;;; ============================================================================

(vl-load-com)

;; ---------------------------------------------------------------------------
;; State
;; ---------------------------------------------------------------------------

(if (not (boundp '*c3dimpact:debug*))             (setq *c3dimpact:debug* nil))
(if (not (boundp '*c3dimpact:enabled*))           (setq *c3dimpact:enabled* nil))
(if (not (boundp '*c3dimpact:cmd-reactor*))       (setq *c3dimpact:cmd-reactor* nil))
(if (not (boundp '*c3dimpact:intercepting*))      (setq *c3dimpact:intercepting* nil))
;; list of intercepted command names (older builds stored T here)
(if (not (listp *c3dimpact:intercepting*))        (setq *c3dimpact:intercepting* nil))
(if (not (boundp '*c3dimpact:saved-defs*))        (setq *c3dimpact:saved-defs* nil))
(if (not (boundp '*c3dimpact:dcl-path*))          (setq *c3dimpact:dcl-path* nil))

(setq *c3dimpact:native-commands* '("MOVE" "STRETCH" "ROTATE" "SCALE"))

;; Civil 3D command names observed firing :vlr-commandWillStart in a live
;; session (ribbon / command line). Grip edits are matched by "GRIP_*".
(setq *c3dimpact:verified-commands*
  '("AECCRAISELOWERSURFACE"
    "AECCADDSURFACELINE"     "AECCDELETESURFACELINE"
    "AECCADDSURFACEPOINT"    "AECCDELETESURFACEPOINT"
    "AECCEDITSURFACEPOINT"   "AECCMOVESURFACEPOINT"
    "AECCEDITSURFACESWAPEDGE"))

(defun c3dimpact:dbg (msg)
  (if *c3dimpact:debug* (princ (strcat "\n[C3D-IMPACT] " msg)))
  (princ)
)

(defun c3dimpact:log (msg) (c3dt:msg "C3D-IMPACT" msg))

(defun c3dimpact:watched-p (cmdname / extra)
  (setq extra (c3dt:cfg "ImpactExtraCommands" nil))
  (or (member cmdname *c3dimpact:verified-commands*)
      (and (listp extra) (member cmdname (mapcar 'strcase (vl-remove-if-not 'c3dt:nonblank extra))))
      (wcmatch cmdname "GRIP_*"))
)

;; ---------------------------------------------------------------------------
;; Small helpers
;; ---------------------------------------------------------------------------

(defun c3dimpact:safe-name (obj) (cond ((c3dt:str-prop obj 'Name)) ("<unnamed>")))

(defun c3dimpact:dedupe (lst / out)
  (setq out nil)
  (foreach x lst (if (not (member x out)) (setq out (cons x out))))
  (reverse out)
)

(defun c3dimpact:same-object-p (a b / ha hb)
  (setq ha (c3dt:prop a 'Handle) hb (c3dt:prop b 'Handle))
  (and ha hb (equal ha hb))
)

;; Corridors, view frames, profile views and pipe parts are not exposed as
;; collections on the Civil 3D land document, so they are found by scanning
;; Model Space for their ObjectName. Results are cached for the duration of
;; one analysis (c3dimpact:begin-analysis clears the cache), so analysing many
;; surfaces or alignments does not rescan the drawing for each one.
(setq *c3dimpact:scan-cache* nil)

(defun c3dimpact:begin-analysis ( ) (setq *c3dimpact:scan-cache* nil))

(defun c3dimpact:scan-modelspace (wildcard / hit out)
  (if (setq hit (assoc wildcard *c3dimpact:scan-cache*))
    (cdr hit)
    (progn
      (setq out nil)
      (vl-catch-all-apply
        (function (lambda ()
          (vlax-for ent (vla-get-ModelSpace (c3dt:active-doc))
            (if (wcmatch (c3dt:object-name ent) wildcard) (setq out (cons ent out)))
          )
        ))
      )
      (setq out (reverse out))
      (setq *c3dimpact:scan-cache* (cons (cons wildcard out) *c3dimpact:scan-cache*))
      out
    )
  )
)

(defun c3dimpact:corridors ( ) (c3dimpact:scan-modelspace "*Corridor*"))

;; ---------------------------------------------------------------------------
;; Bounding-box overlap (approximate pipe proximity)
;; ---------------------------------------------------------------------------

(defun c3dimpact:bbox (obj / minpt maxpt r)
  (setq r (vl-catch-all-apply 'vla-GetBoundingBox (list obj 'minpt 'maxpt)))
  (if (vl-catch-all-error-p r)
    nil
    (list (vlax-safearray->list minpt) (vlax-safearray->list maxpt))
  )
)

(defun c3dimpact:bbox-overlap-p (b1 b2 / min1 max1 min2 max2)
  (if (and b1 b2)
    (progn
      (setq min1 (car b1) max1 (cadr b1) min2 (car b2) max2 (cadr b2))
      (not (or (> (car min1) (car max2)) (> (car min2) (car max1))
               (> (cadr min1) (cadr max2)) (> (cadr min2) (cadr max1))))
    )
  )
)

(defun c3dimpact:nearby-names (algObj parts / abox out)
  (setq abox (c3dimpact:bbox algObj) out nil)
  (if abox
    (foreach part parts
      (if (c3dimpact:bbox-overlap-p abox (c3dimpact:bbox part))
        (setq out (cons (c3dimpact:safe-name part) out))
      )
    )
  )
  (reverse out)
)

;; ---------------------------------------------------------------------------
;; Relationship tests. Each tries the object reference first, then the ID.
;; ---------------------------------------------------------------------------

(defun c3dimpact:baseline-uses-alignment-p (baseline algObj / balg id1 id2)
  (setq balg (cond ((c3dt:prop baseline 'Alignment)) ((c3dt:prop baseline 'AlignmentEntity))))
  (if balg
    (c3dimpact:same-object-p balg algObj)
    (progn
      (setq id1 (c3dt:prop baseline 'AlignmentId) id2 (c3dt:prop algObj 'ObjectID))
      (and id1 id2 (equal id1 id2))
    )
  )
)

(defun c3dimpact:baseline-uses-profile-p (baseline profObj / bprof id1 id2)
  (setq bprof (cond ((c3dt:prop baseline 'Profile)) ((c3dt:prop baseline 'ProfileEntity))))
  (if bprof
    (c3dimpact:same-object-p bprof profObj)
    (progn
      (setq id1 (c3dt:prop baseline 'ProfileId) id2 (c3dt:prop profObj 'ObjectID))
      (and id1 id2 (equal id1 id2))
    )
  )
)

(defun c3dimpact:profile-uses-surface-p (profObj surfObj / psurf)
  (setq psurf (cond ((c3dt:prop profObj 'Surface)) ((c3dt:prop profObj 'SurfaceEntity))))
  (and psurf (c3dimpact:same-object-p psurf surfObj))
)

(defun c3dimpact:references-alignment-p (obj algObj / valg)
  (setq valg (c3dt:prop obj 'Alignment))
  (and valg (c3dimpact:same-object-p valg algObj))
)

(defun c3dimpact:gradinggroup-uses-surface-p (gg surfObj / gsurf)
  (setq gsurf (cond ((c3dt:prop gg 'Surface)) ((c3dt:prop gg 'BaseSurface))))
  (and gsurf (c3dimpact:same-object-p gsurf surfObj))
)

(defun c3dimpact:corridors-matching (corridors testfn obj / matched)
  (setq matched nil)
  (foreach c corridors
    (foreach b (c3dt:collection->list (c3dt:prop c 'Baselines))
      (if (apply testfn (list b obj)) (setq matched (cons c matched)))
    )
  )
  (c3dimpact:dedupe matched)
)

(defun c3dimpact:section (title objs)
  (if objs
    (append (list "" title)
            (mapcar (function (lambda (o) (strcat "  - " (c3dimpact:safe-name o)))) objs))
  )
)

;; ---------------------------------------------------------------------------
;; Impact analysis
;; ---------------------------------------------------------------------------

(defun c3dimpact:analyze-alignment (algObj / report slgs vframes parts names)
  (setq report (list (strcat "ALIGNMENT: " (c3dimpact:safe-name algObj))))
  (setq report (append report
    (c3dimpact:section "PROFILES on this alignment:"
      (c3dt:collection->list (c3dt:prop algObj 'Profiles)))))

  (setq slgs (c3dt:collection->list (c3dt:prop algObj 'SampleLineGroups)))
  (if slgs
    (setq report (append report (list "" "SAMPLE LINE GROUPS on this alignment:")
      (mapcar (function (lambda (g)
                (strcat "  - " (c3dimpact:safe-name g) " ("
                        (itoa (length (c3dt:collection->list (c3dt:prop g 'SampleLines))))
                        " sample line(s))")))
              slgs)))
  )

  (setq report (append report
    (c3dimpact:section "CORRIDORS using this alignment as a baseline:"
      (c3dimpact:corridors-matching (c3dimpact:corridors) 'c3dimpact:baseline-uses-alignment-p algObj))))

  (setq vframes (vl-remove-if-not
                  (function (lambda (vf) (c3dimpact:references-alignment-p vf algObj)))
                  (c3dimpact:scan-modelspace "*ViewFrame*")))
  (setq report (append report (c3dimpact:section "SHEETS: view frames based on this alignment:" vframes)))

  (setq parts (append (c3dimpact:scan-modelspace "*Pipe*") (c3dimpact:scan-modelspace "*Structure*")))
  (if (setq names (c3dimpact:nearby-names algObj parts))
    (setq report (append report
      (list "" "PIPE NETWORK PARTS near this alignment (bounding-box check only, verify):")
      (mapcar (function (lambda (n) (strcat "  - " n))) names)))
  )
  report
)

(defun c3dimpact:analyze-surface (surfObj / civdoc report corridors)
  (setq civdoc (c3dt:civil-doc))
  (setq report (list (strcat "SURFACE: " (c3dimpact:safe-name surfObj))))
  (setq corridors (c3dimpact:corridors))
  (foreach a (c3dt:collection->list (c3dt:prop civdoc 'AlignmentsSiteless))
    (foreach p (c3dt:collection->list (c3dt:prop a 'Profiles))
      (if (c3dimpact:profile-uses-surface-p p surfObj)
        (progn
          (setq report (append report
            (list "" (strcat "PROFILE \"" (c3dimpact:safe-name p) "\" on alignment \""
                             (c3dimpact:safe-name a) "\" is derived from this surface."))))
          (foreach c (c3dimpact:corridors-matching corridors 'c3dimpact:baseline-uses-profile-p p)
            (setq report (append report
              (list (strcat "  -> CORRIDOR \"" (c3dimpact:safe-name c) "\" uses that profile as a baseline profile."))))
          )
        )
      )
    )
  )
  (foreach site (c3dt:collection->list (c3dt:prop civdoc 'Sites))
    (foreach gg (c3dt:collection->list (c3dt:prop site 'GradingGroups))
      (if (c3dimpact:gradinggroup-uses-surface-p gg surfObj)
        (setq report (append report
          (list "" (strcat "GRADING GROUP \"" (c3dimpact:safe-name gg) "\" references this surface."))))
      )
    )
  )
  report
)

(defun c3dimpact:analyze-profile (profObj / report parentAlg pviews)
  (setq parentAlg (c3dt:prop profObj 'Alignment))
  (setq report
    (list (strcat "PROFILE: " (c3dimpact:safe-name profObj)
                  (if parentAlg (strcat " (on alignment \"" (c3dimpact:safe-name parentAlg) "\")") ""))))
  (setq report (append report
    (c3dimpact:section "CORRIDORS using this profile as a baseline:"
      (c3dimpact:corridors-matching (c3dimpact:corridors) 'c3dimpact:baseline-uses-profile-p profObj))))
  (if parentAlg
    (progn
      (setq pviews (vl-remove-if-not
                     (function (lambda (pv) (c3dimpact:references-alignment-p pv parentAlg)))
                     (c3dimpact:scan-modelspace "*ProfileView*")))
      (setq report (append report
        (c3dimpact:section "PROFILE VIEWS on the same alignment (likely display this profile):"
          (c3dimpact:dedupe pviews))))
    )
  )
  report
)

;; Whole-drawing fallbacks, used when a command picks its target after it
;; starts and nothing was pre-selected.
(defun c3dimpact:analyze-all (kind / civdoc lines)
  (setq civdoc (c3dt:civil-doc) lines nil)
  (c3dimpact:dbg (strcat "analyze-all " kind ": civil doc " (if civdoc "connected" "NOT connected")))
  (cond
    ((= kind "surface")
     (foreach s (c3dt:collection->list (c3dt:prop civdoc 'Surfaces))
       (setq lines (append lines (c3dimpact:analyze-surface s) (list "")))))
    ((= kind "alignment")
     (foreach a (c3dt:collection->list (c3dt:prop civdoc 'AlignmentsSiteless))
       (setq lines (append lines (c3dimpact:analyze-alignment a) (list "")))))
    ((= kind "profile")
     (foreach a (c3dt:collection->list (c3dt:prop civdoc 'AlignmentsSiteless))
       (foreach p (c3dt:collection->list (c3dt:prop a 'Profiles))
         (setq lines (append lines (c3dimpact:analyze-profile p) (list ""))))))
  )
  lines
)

;; Profiles are AeccDbVAlignment objects, so test for them before alignments.
(defun c3dimpact:kind (oname)
  (cond
    ((wcmatch oname "*VAlignment*") "profile")
    ((wcmatch oname "*Alignment*") "alignment")
    ((wcmatch oname "*Surface*")   "surface")
    ((wcmatch oname "*Profile*")   "profile")
  )
)

(defun c3dimpact:analyze-any (obj / kind)
  (setq kind (c3dimpact:kind (c3dt:object-name obj)))
  (cond
    ((= kind "alignment") (c3dimpact:analyze-alignment obj))
    ((= kind "surface")   (c3dimpact:analyze-surface obj))
    ((= kind "profile")   (c3dimpact:analyze-profile obj))
  )
)

;; Returns (lines . all-entities) for a selection set. all-entities keeps
;; every selected entity so the original selection can be replayed.
(defun c3dimpact:analyze-ss (ss / n ent obj lines allents)
  (setq lines nil allents nil)
  (if ss
    (progn
      (setq n 0)
      (repeat (sslength ss)
        (setq ent (ssname ss n) allents (cons ent allents))
        (setq obj (vl-catch-all-apply 'vlax-ename->vla-object (list ent)))
        (if (and (not (vl-catch-all-error-p obj)) (c3dimpact:kind (c3dt:object-name obj)))
          (setq lines (append lines (c3dimpact:analyze-any obj)))
        )
        (setq n (1+ n))
      )
    )
  )
  (c3dimpact:dbg (strcat "selection " (itoa (length allents)) " entities, " (itoa (length lines)) " report lines"))
  (cons lines (reverse allents))
)

(defun c3dimpact:scan-pickfirst ( ) (c3dimpact:analyze-ss (ssget "_I")))

;; Profile commands are usually started with the parent alignment selected.
;; Report each of that alignment's profiles rather than the alignment itself.
(defun c3dimpact:analyze-for-profile-command (allents / lines obj kind)
  (setq lines nil)
  (foreach ent allents
    (setq obj (vl-catch-all-apply 'vlax-ename->vla-object (list ent)))
    (if (not (vl-catch-all-error-p obj))
      (progn
        (setq kind (c3dimpact:kind (c3dt:object-name obj)))
        (cond
          ((= kind "profile") (setq lines (append lines (c3dimpact:analyze-profile obj))))
          ((= kind "alignment")
           (foreach p (c3dt:collection->list (c3dt:prop obj 'Profiles))
             (setq lines (append lines (c3dimpact:analyze-profile p) (list "")))))
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
;; c3dt:pref-set) and survives restarts. Where the user has not chosen, the
;; administrator's default from C3DTools-Config.lsp applies.
;; ---------------------------------------------------------------------------

(defun c3dimpact:warnings-wanted-p ( / p)
  (setq p (c3dt:pref-get "ImpactWarnings"))
  (cond ((= p "1") T)
        ((= p "0") nil)
        ((c3dt:cfg "ImpactWarnings" T) T))
)

;; "every" (default) or "once" (once per command per Civil 3D session)
(defun c3dimpact:warn-mode ( / p)
  (setq p (c3dt:pref-get "ImpactWarnFrequency"))
  (cond ((member p '("every" "once")) p)
        ((= (c3dt:cfg "ImpactWarnFrequency" "every") "once") "once")
        (T "every"))
)

(defun c3dimpact:intercept-allowed-p ( ) (c3dt:cfg "ImpactInterceptAllowed" T))

;; Per-command choice ("ImpactIntercept.MOVE" etc.). Older installs stored a
;; single "ImpactIntercept" for all four, which still applies if present.
(defun c3dimpact:intercept-wanted-p (cn / p legacy def)
  (if (c3dimpact:intercept-allowed-p)
    (progn
      (setq p (c3dt:pref-get (strcat "ImpactIntercept." cn))
            legacy (c3dt:pref-get "ImpactIntercept"))
      (cond
        ((= p "1") T)
        ((= p "0") nil)
        ((= legacy "1") T)
        ((= legacy "0") nil)
        (T
         (setq def (c3dt:cfg "ImpactInterceptDefault" nil))
         (cond
           ((null def) nil)
           ((listp def) (if (member cn (mapcar 'strcase (vl-remove-if-not 'c3dt:nonblank def))) T))
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

(defun c3dimpact:warn-key (cmdname) (if (wcmatch cmdname "GRIP_*") "GRIP" cmdname))

(defun c3dimpact:should-warn-p (cmdname)
  (and *c3dimpact:enabled*
       (or (= (c3dimpact:warn-mode) "every")
           (not (member (c3dimpact:warn-key cmdname) (vl-bb-ref '*c3dimpact:bb-warned*)))))
)

(defun c3dimpact:mark-warned (cmdname / key seen)
  (setq key (c3dimpact:warn-key cmdname) seen (vl-bb-ref '*c3dimpact:bb-warned*))
  (if (not (member key seen)) (vl-bb-set '*c3dimpact:bb-warned* (cons key seen)))
)

(defun c3dimpact:reset-warned ( ) (vl-bb-set '*c3dimpact:bb-warned* nil))

;; ---------------------------------------------------------------------------
;; Dialogs (DCL written to a temp file on first use)
;; ---------------------------------------------------------------------------

(setq *c3dimpact:intercept-text*
  '("Command interception is optional and OFF by default."
    ""
    "Each command you tick is UNDEFINED for the session and replaced by a"
    "version that first checks the selection for alignments, surfaces and"
    "profiles and shows the impact warning. After you click OK, the original"
    "command runs unchanged (press ESC at its first prompt to stop it)."
    ""
    "Side effects while a command is ticked:"
    " - Other LISP routines, scripts or macros that call it WITHOUT the"
    "   \"_.\" prefix will run the C3DTools version instead."
    " - Menu macros that use \"_.MOVE\" etc. bypass interception."
    " - Unticking restores the original command immediately. UNDEFINE never"
    "   lasts beyond the Civil 3D session."))

(defun c3dimpact:ensure-dcl ( / path f)
  (if (not (and *c3dimpact:dcl-path* (findfile *c3dimpact:dcl-path*)))
    (progn
      (setq path (vl-filename-mktemp "c3dimpact" nil ".dcl"))
      (if (setq f (open path "w"))
        (progn
          (foreach ln
            '("c3dimpact_dialog : dialog {"
              "  label = \"Change-Impact Analysis - Civil 3D\";"
              "  : text { label = \"These objects depend on what you are about to edit:\"; }"
              "  : list_box { key = \"impact_list\"; height = 16; width = 72; }"
              "  : text { label = \"Click OK, then press ESC if you want to stop this command.\"; }"
              "  : text { key = \"freq_note\"; width = 72; }"
              "  : row {"
              "    alignment = centered; fixed_width = true;"
              "    : button { key = \"accept\"; label = \"OK\"; is_default = true; is_cancel = true; width = 14; }"
              "    : button { key = \"learn_more\"; label = \"Learn More...\"; width = 16; }"
              "  }"
              "}"
              "c3dimpact_settings : dialog {"
              "  label = \"C3DTools - Change-Impact settings\";"
              "  : boxed_column {"
              "    label = \"Impact warnings\";"
              "    : toggle { key = \"warnings\"; label = \"Show impact warnings\"; }"
              "    : radio_column {"
              "      key = \"freq\";"
              "      : radio_button { key = \"every\"; label = \"Every time the command runs\"; }"
              "      : radio_button { key = \"once\"; label = \"Once per command, per Civil 3D session\"; }"
              "    }"
              "  }"
              "  : boxed_column {"
              "    label = \"Command interception (each ticked command is undefined while on)\";"
              "    : row {"
              "      : toggle { key = \"MOVE\"; label = \"MOVE\"; }"
              "      : toggle { key = \"STRETCH\"; label = \"STRETCH\"; }"
              "      : toggle { key = \"ROTATE\"; label = \"ROTATE\"; }"
              "      : toggle { key = \"SCALE\"; label = \"SCALE\"; }"
              "    }"
              "    : list_box { key = \"about\"; height = 13; width = 76; }"
              "  }"
              "  ok_cancel;"
              "}")
            (write-line ln f)
          )
          (close f)
          (setq *c3dimpact:dcl-path* path)
        )
      )
    )
  )
  *c3dimpact:dcl-path*
)

(defun c3dimpact:fill-list (key lines)
  (start_list key)
  (foreach ln lines (add_list ln))
  (end_list)
)

;; ---------------------------------------------------------------------------
;; Learn More: opens the knowledge-base page at the section for the warning
;; (anchors follow the page's "Linking warnings to articles" table). The page
;; and anchors are set in C3DTools-Config.lsp; the values below are used when
;; the config omits them.
;; ---------------------------------------------------------------------------

(setq *c3dimpact:learn-more-default-url*
  "https://designtovisualization.com/kb-tools-for-civil-3d-%c2%b7-c3d-guard-change-impact/")

(setq *c3dimpact:learn-more-default-anchors*
  '(("MOVE"           . "move-civil-objects")
    ("STRETCH"        . "stretch-civil-objects")
    ("ROTATE"         . "rotate-civil-objects")
    ("SCALE"          . "scale-civil-objects")
    ("GRIP_ALIGNMENT" . "grip-edit-alignment")
    ("GRIP_PROFILE"   . "grip-edit-profile")
    ("SURFACE"        . "surface-edits")
    ("GENERAL"        . "dynamic-model")))

;; Topic of a warning:
;;   MOVE / STRETCH / ROTATE / SCALE   the intercepted command itself
;;   SURFACE                           any surface-edit command
;;   GRIP_ALIGNMENT / GRIP_PROFILE     a grip edit, by what is selected
;;   GENERAL                           anything else (no single object)
(defun c3dimpact:topic (cmdname ents / kinds obj)
  (cond
    ((member cmdname *c3dimpact:native-commands*) cmdname)
    ((wcmatch cmdname "*SURFACE*") "SURFACE")
    ((wcmatch cmdname "GRIP_*")
     (setq kinds nil)
     (foreach e ents
       (setq obj (vl-catch-all-apply 'vlax-ename->vla-object (list e)))
       (if (not (vl-catch-all-error-p obj))
         (setq kinds (cons (c3dimpact:kind (c3dt:object-name obj)) kinds))
       )
     )
     (cond ((member "alignment" kinds) "GRIP_ALIGNMENT")
           ((member "profile" kinds) "GRIP_PROFILE")
           ((member "surface" kinds) "SURFACE")
           (T "GENERAL")))
    (T "GENERAL")
  )
)

;; Page URL plus "#anchor" for the command's topic. A topic with no anchor
;; opens the top of the page.
(defun c3dimpact:learn-more-url (topic / base i anchors anchor)
  (setq base (cond ((c3dt:nonblank (c3dt:cfg "ImpactLearnMoreUrl" nil)))
                   (*c3dimpact:learn-more-default-url*)))
  (if (setq i (vl-string-search "#" base)) (setq base (substr base 1 i)))
  (setq anchors (c3dt:cfg "ImpactLearnMoreAnchors" *c3dimpact:learn-more-default-anchors*))
  (setq anchor (if (listp anchors) (cdr (assoc topic anchors))))
  (if (c3dt:nonblank anchor)
    (strcat base "#" (vl-string-left-trim "#" anchor))
    base
  )
)

;; Opens a URL in the default browser. Tries the Windows shell first, then
;; the URL protocol handler; the URL is always printed as well, so it can be
;; copied if neither works.
(defun c3dimpact:open-url (url / sh r)
  (princ (strcat "\nLearn more: " url))
  (setq sh (vl-catch-all-apply 'vlax-get-or-create-object (list "Shell.Application")))
  (if (and sh (not (vl-catch-all-error-p sh)))
    (progn
      (setq r (vl-catch-all-apply 'vlax-invoke-method (list sh 'ShellExecute url)))
      (vl-catch-all-apply 'vlax-release-object (list sh))
    )
  )
  (if (or (null sh) (vl-catch-all-error-p sh) (vl-catch-all-error-p r))
    (vl-catch-all-apply 'startapp (list "rundll32.exe" (strcat "url.dll,FileProtocolHandler " url)))
  )
  (princ)
)

(defun c3dimpact:open-learn-more (topic)
  (c3dimpact:open-url (c3dimpact:learn-more-url topic))
)

;; Information only: AutoLISP cannot cancel a command from here, so the
;; dialog has OK (close) and Learn More (open the explanation for this
;; command; the dialog stays open).
(defun c3dimpact:show-impact (cmdname topic lines / path dcl_id)
  (setq path (c3dimpact:ensure-dcl))
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog "c3dimpact_dialog" dcl_id)
        (progn
          (c3dimpact:fill-list "impact_list"
            (append (list (strcat "Command: " cmdname) "")
                    (if lines lines (list "No dependent objects were found by the automated scan."))))
          (set_tile "freq_note"
            (if (= (c3dimpact:warn-mode) "once")
              "Shown once per command each session. Change this with C3D-IMPACT-SETTINGS."
              "Shown every time. Change this with C3D-IMPACT-SETTINGS."))
          (action_tile "accept" "(done_dialog 1)")
          (action_tile "learn_more"
            (strcat "(c3dimpact:open-learn-more " (vl-prin1-to-string topic) ")"))
          (start_dialog)
        )
      )
      (unload_dialog dcl_id)
    )
  )
  (c3dimpact:mark-warned cmdname)
)

;; ---------------------------------------------------------------------------
;; Command interception (opt-in, per command): MOVE / STRETCH / ROTATE / SCALE
;; ---------------------------------------------------------------------------

(defun c3dimpact:run-native (cmdname ents / ss)
  (if ents
    (progn
      (setq ss (ssadd))
      (foreach e ents (ssadd e ss))
      (command (strcat "_." cmdname) ss "")
    )
    (command (strcat "_." cmdname))
  )
)

(defun c3dimpact:native-override (cmdname / scanresult pick)
  (c3dimpact:dbg (strcat "intercepted " cmdname))
  (if (c3dimpact:should-warn-p cmdname)
    (progn
      (c3dimpact:begin-analysis)
      (setq scanresult (c3dimpact:scan-pickfirst))
      ;; nothing pre-selected: ask for the selection now, as the command would
      (if (not (cdr scanresult)) (setq scanresult (c3dimpact:analyze-ss (ssget))))
      (if (car scanresult) (c3dimpact:show-impact cmdname cmdname (car scanresult)))
      (c3dimpact:run-native cmdname (cdr scanresult))
    )
    ;; no warning due: hand straight over to the real command
    (progn
      (if (setq pick (ssget "_I")) (setq pick (cdr (c3dimpact:analyze-ss-ents pick))))
      (c3dimpact:run-native cmdname pick)
    )
  )
  (princ)
)

;; Entities of a selection set, without any analysis.
(defun c3dimpact:analyze-ss-ents (ss / n out)
  (setq n 0 out nil)
  (repeat (sslength ss) (setq out (cons (ssname ss n) out) n (1+ n)))
  (cons nil (reverse out))
)

;; command-s: these run from inside another command (or at load time), where
;; plain (command ...) is not allowed. Returns T if cn is intercepted after.
(defun c3dimpact:intercept-on (cn / sym saved r)
  (cond
    ((member cn *c3dimpact:intercepting*) T)
    (T
     (setq sym (read (strcat "C:" cn)))
     ;; keep any existing C:<cmd> (another add-on's) to restore later
     (setq saved (cons sym (if (boundp sym) (eval sym))))
     (eval (list 'defun sym nil (list 'c3dimpact:native-override cn)))
     (setq r (vl-catch-all-apply 'command-s (list "_.UNDEFINE" cn)))
     (if (vl-catch-all-error-p r)
       (progn
         (set sym (cdr saved))
         (c3dimpact:log (strcat "Could not intercept " cn " in this drawing. Open C3D-IMPACT-SETTINGS to retry."))
         nil
       )
       (progn
         (setq *c3dimpact:saved-defs* (cons (cons cn saved) *c3dimpact:saved-defs*)
               *c3dimpact:intercepting* (cons cn *c3dimpact:intercepting*))
         T
       )
     )
    )
  )
)

(defun c3dimpact:intercept-off (cn / saved)
  (if (member cn *c3dimpact:intercepting*)
    (progn
      (vl-catch-all-apply 'command-s (list "_.REDEFINE" cn))
      (if (setq saved (cdr (assoc cn *c3dimpact:saved-defs*)))
        (set (car saved) (cdr saved))
      )
      (setq *c3dimpact:saved-defs* (vl-remove-if (function (lambda (x) (= (car x) cn))) *c3dimpact:saved-defs*)
            *c3dimpact:intercepting* (vl-remove cn *c3dimpact:intercepting*))
    )
  )
)

;; Brings every command in line with the stored preferences.
(defun c3dimpact:apply-intercept-prefs ( )
  (foreach cn *c3dimpact:native-commands*
    (if (c3dimpact:intercept-wanted-p cn)
      (c3dimpact:intercept-on cn)
      (c3dimpact:intercept-off cn)
    )
  )
)

;; ---------------------------------------------------------------------------
;; Settings changes (shared by the dialog and the command-line version)
;; ---------------------------------------------------------------------------

(defun c3dimpact:set-warnings (on)
  (c3dt:pref-set "ImpactWarnings" (if on "1" "0"))
  (setq *c3dimpact:enabled* (if on T nil))
  (if on (c3dimpact:init-reactor))
)

(defun c3dimpact:set-warn-mode (mode)
  (if (/= mode (c3dimpact:warn-mode)) (c3dimpact:reset-warned))
  (c3dt:pref-set "ImpactWarnFrequency" mode)
)

(defun c3dimpact:set-intercept (cn on)
  (c3dt:pref-set (strcat "ImpactIntercept." cn) (if on "1" "0"))
  (if on (c3dimpact:intercept-on cn) (c3dimpact:intercept-off cn))
)

(defun c3dimpact:on-off (flag) (if flag "ON" "OFF"))

(defun c3dimpact:print-settings ( )
  (c3dimpact:log (strcat "Warnings: " (c3dimpact:on-off *c3dimpact:enabled*)
                         (if (= (c3dimpact:warn-mode) "once") " (once per command per session)" " (every time)")))
  (princ "\n  Interception: ")
  (if (not (c3dimpact:intercept-allowed-p))
    (princ "disabled by your CAD administrator")
    (foreach cn *c3dimpact:native-commands*
      (princ (strcat cn " " (c3dimpact:on-off (member cn *c3dimpact:intercepting*)) "  ")))
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; C3D-IMPACT-SETTINGS (dialog)
;; ---------------------------------------------------------------------------

(defun c:C3D-IMPACT-SETTINGS ( / path dcl_id allowed result warn freq ticks)
  (setq path (c3dimpact:ensure-dcl) allowed (c3dimpact:intercept-allowed-p))
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog "c3dimpact_settings" dcl_id)
        (progn
          (set_tile "warnings" (if *c3dimpact:enabled* "1" "0"))
          (set_tile "freq" (c3dimpact:warn-mode))
          (foreach cn *c3dimpact:native-commands*
            (set_tile cn (if (member cn *c3dimpact:intercepting*) "1" "0"))
            (if (not allowed) (mode_tile cn 1))
          )
          (c3dimpact:fill-list "about"
            (if allowed
              *c3dimpact:intercept-text*
              (list "Command interception has been disabled by your CAD administrator.")))
          (action_tile "accept"
            (strcat "(setq warn (get_tile \"warnings\") freq (get_tile \"freq\")"
                    " ticks (mapcar 'get_tile *c3dimpact:native-commands*))"
                    "(done_dialog 1)"))
          (setq result (start_dialog))
        )
      )
      (unload_dialog dcl_id)
    )
    (c3dimpact:log "Settings dialog unavailable - use -C3D-IMPACT-SETTINGS instead.")
  )
  (if (= result 1)
    (progn
      (c3dimpact:set-warnings (= warn "1"))
      (if (member freq '("every" "once")) (c3dimpact:set-warn-mode freq))
      (if allowed
        (mapcar (function (lambda (cn tick)
                  (if (not (eq (= tick "1") (if (member cn *c3dimpact:intercepting*) T nil)))
                    (c3dimpact:set-intercept cn (= tick "1")))))
                *c3dimpact:native-commands* ticks)
      )
      (c3dimpact:print-settings)
    )
  )
  (princ)
)

;; Kept so existing toolbar buttons and habits still work.
(defun c:C3D-IMPACT-INTERCEPT ( ) (c:C3D-IMPACT-SETTINGS))

;; ---------------------------------------------------------------------------
;; -C3D-IMPACT-SETTINGS (command line, for scripts and toolbar macros)
;;   e.g. a button that toggles MOVE interception:
;;        ^C^C-C3D-IMPACT-SETTINGS;Move;eXit;
;; ---------------------------------------------------------------------------

(defun c:-C3D-IMPACT-SETTINGS ( / kw cn on)
  (c3dimpact:print-settings)
  (while
    (progn
      (initget "Move Stretch Rotate Scale Warnings Frequency eXit")
      (setq kw (getkword "\nToggle [Move/Stretch/Rotate/Scale/Warnings/Frequency/eXit] <eXit>: "))
      (and kw (/= kw "eXit"))
    )
    (cond
      ((= kw "Warnings") (c3dimpact:set-warnings (not *c3dimpact:enabled*)))
      ((= kw "Frequency") (c3dimpact:set-warn-mode (if (= (c3dimpact:warn-mode) "once") "every" "once")))
      ((not (c3dimpact:intercept-allowed-p))
       (c3dimpact:log "Command interception has been disabled by your CAD administrator."))
      (T
       (setq cn (strcase kw) on (not (member cn *c3dimpact:intercepting*)))
       (if on
         (princ (strcat "\nNote: " cn " is now UNDEFINED for this session and replaced by the C3DTools"
                        " version; LISP or macros calling " cn " without \"_.\" get it too."))
       )
       (c3dimpact:set-intercept cn on)
      )
    )
    (c3dimpact:print-settings)
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Warnings: Civil 3D commands and grip edits (command reactor)
;; ---------------------------------------------------------------------------

(defun c3dimpact:cmd-will-start (reactor args / r)
  (setq r (vl-catch-all-apply 'c3dimpact:cmd-will-start-body (list args)))
  (if (vl-catch-all-error-p r)
    (c3dimpact:dbg (strcat "error: " (vl-catch-all-error-message r)))
  )
  (princ)
)

(defun c3dimpact:surface-edit-warning ( )
  '("WARNING: Manual surface edits (like Delete Line or Add Point) force a"
    "permanent deviation from the source design data. Because Civil 3D"
    "rebuilds surfaces from their definition in order, these manual changes"
    "can shift or disappear when new data is added. Where possible, change"
    "the source data (feature lines, breaklines, boundaries) instead."
    "")
)

(defun c3dimpact:cmd-will-start-body (args / cmdname scanresult lines kind)
  (setq cmdname (strcase (vl-princ-to-string (car args))))
  (if *c3dimpact:debug* (c3dimpact:dbg (strcat "command: " cmdname)))
  ;; skip before any analysis when no warning is due (off, or already shown)
  (if (and (c3dimpact:watched-p cmdname) (c3dimpact:should-warn-p cmdname))
    (progn
      (c3dimpact:begin-analysis)
      (setq scanresult (c3dimpact:scan-pickfirst) lines (car scanresult))
      (if (and (wcmatch cmdname "*PROFILE*") (cdr scanresult))
        (setq lines (c3dimpact:analyze-for-profile-command (cdr scanresult)))
      )
      ;; Nothing pre-selected: infer the object type from the command name
      ;; and report on every object of that type.
      (if (and (not lines)
               (setq kind (cond ((wcmatch cmdname "*SURFACE*") "surface")
                                ((wcmatch cmdname "*PROFILE*") "profile")
                                ((wcmatch cmdname "*ALIGNMENT*") "alignment"))))
        (if (setq lines (c3dimpact:analyze-all kind))
          (setq lines (append
            (if (= kind "surface")
              (c3dimpact:surface-edit-warning)
              (list (strcat "Could not tell which " kind " this command targets.")
                    (strcat "Showing potential impacts for ALL " kind "s in the drawing:")
                    ""))
            lines))
        )
      )
      (if lines
        (c3dimpact:show-impact cmdname (c3dimpact:topic cmdname (cdr scanresult)) lines))
    )
  )
)

(defun c3dimpact:init-reactor ( / r)
  (if (not *c3dimpact:cmd-reactor*)
    (progn
      (setq r (vl-catch-all-apply 'vlr-editor-reactor
                (list nil (list (cons :vlr-commandWillStart 'c3dimpact:cmd-will-start)))))
      (if (vl-catch-all-error-p r)
        (c3dimpact:log (strcat "Could not create the command reactor: " (vl-catch-all-error-message r)))
        (setq *c3dimpact:cmd-reactor* r)
      )
    )
  )
)

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

(defun c:C3D-IMPACT-ON ( )
  (c3dimpact:set-warnings T)
  (c3dimpact:log "Warnings ON.")
  (princ)
)

(defun c:C3D-IMPACT-OFF ( )
  (c3dimpact:set-warnings nil)
  (c3dimpact:log "Warnings OFF. (Command interception is set separately in C3D-IMPACT-SETTINGS.)")
  (princ)
)

(defun c:C3D-IMPACT-STATUS ( )
  (c3dimpact:print-settings)
  (princ (strcat "\n  Civil 3D COM: " (if (c3dt:civil-app) "connected" "not connected (run C3DTOOLS-FINDCIVIL)")))
  (princ (strcat "\n  Debug tracing: " (if *c3dimpact:debug* "ON" "off")))
  (princ "\n  Change any of these with C3D-IMPACT-SETTINGS.")
  (princ)
)

(defun c:C3D-IMPACT-DEBUG ( )
  (setq *c3dimpact:debug* (not *c3dimpact:debug*))
  (c3dimpact:log (strcat "Debug tracing " (if *c3dimpact:debug* "ON" "OFF")))
  (princ)
)

;; ---------------------------------------------------------------------------
;; Initialisation (runs once per drawing when the file loads)
;; ---------------------------------------------------------------------------

(defun c3dimpact:init ( )
  (setq *c3dimpact:enabled* (c3dimpact:warnings-wanted-p))
  (if *c3dimpact:enabled* (c3dimpact:init-reactor))
  (vl-catch-all-apply 'c3dimpact:apply-intercept-prefs nil)
)

(c3dimpact:init)
(princ)
