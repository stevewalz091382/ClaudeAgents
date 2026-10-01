;;; ============================================================================
;;; C3DImpact.lsp
;;;
;;; Change-impact warnings for Civil 3D. Before an alignment, surface or
;;; profile is edited, it lists the objects that depend on it (profiles,
;;; sample line groups, corridors, view frames, profile views, pipe network
;;; parts nearby, grading groups) and asks the user to Accept Risk or Cancel.
;;;
;;; TWO LEVELS
;;;
;;;   Warnings (on by default, non-invasive)
;;;     A command reactor shows the impact dialog when a grip edit (GRIP_*) or
;;;     one of the Civil 3D surface-edit commands below starts. AutoLISP
;;;     cannot cancel a command already in progress, so for these Cancel asks
;;;     the user to press ESC.
;;;
;;;   Command interception (OFF by default, opt-in per user)
;;;     Enabling it UNDEFINES the AutoCAD commands MOVE, STRETCH, ROTATE and
;;;     SCALE for the session and replaces them with versions that show the
;;;     impact dialog first and only run the real command if the user accepts.
;;;     Cancel is a true block for these four commands.
;;;     Turn on or off with C3D-IMPACT-INTERCEPT (shows a disclosure first).
;;;     CAD managers can disable or pre-enable it in C3DTools-Config.lsp.
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
;;;   C3D-IMPACT-ON / C3D-IMPACT-OFF  turn the warnings on or off
;;;   C3D-IMPACT-INTERCEPT            opt in or out of MOVE/STRETCH/ROTATE/SCALE
;;;                                   interception
;;;   C3D-IMPACT-STATUS               current state
;;;   C3D-IMPACT-DEBUG                toggle diagnostic tracing (off by default)
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
;; Dialogs (DCL written to a temp file on first use)
;; ---------------------------------------------------------------------------

(setq *c3dimpact:optin-text*
  '("Command interception is optional and OFF by default."
    ""
    "When enabled, C3DTools UNDEFINES these AutoCAD commands for the session:"
    "    MOVE    STRETCH    ROTATE    SCALE"
    "and replaces them with versions that first check the selection for"
    "alignments, surfaces and profiles and show an impact report. If you"
    "choose Accept Risk, the original command runs unchanged."
    ""
    "Side effects to be aware of:"
    " - Other LISP routines, scripts or macros that call these commands"
    "   WITHOUT the \"_.\" prefix will run the C3DTools version instead."
    " - Menu macros that use \"_.MOVE\" etc. bypass interception."
    " - The original commands are restored when you turn this off, and"
    "   at the end of every session (UNDEFINE does not persist)."
    ""
    "Your choice is remembered for your user profile. Run C3D-IMPACT-INTERCEPT"
    "again at any time to turn it off."))

(defun c3dimpact:ensure-dcl ( / path f)
  (if (not (and *c3dimpact:dcl-path* (findfile *c3dimpact:dcl-path*)))
    (progn
      (setq path (vl-filename-mktemp "c3dimpact" nil ".dcl"))
      (if (setq f (open path "w"))
        (progn
          (foreach ln
            '("c3dimpact_dialog : dialog {"
              "  label = \"Change-Impact Analysis - Civil 3D\";"
              "  : text { label = \"The following objects will be affected if you proceed:\"; }"
              "  : list_box { key = \"impact_list\"; height = 16; width = 72; }"
              "  spacer;"
              "  : row {"
              "    : button { key = \"proceed\"; label = \"  Accept Risk  \"; is_default = true; }"
              "    : button { key = \"cancel\"; label = \"  Cancel  \"; is_cancel = true; }"
              "  }"
              "}"
              "c3dimpact_optin : dialog {"
              "  label = \"C3DTools - Enable command interception?\";"
              "  : list_box { key = \"optin_text\"; height = 18; width = 76; }"
              "  spacer;"
              "  : row {"
              "    : button { key = \"enable\"; label = \"  Enable interception  \"; }"
              "    : button { key = \"cancel\"; label = \"  Cancel  \"; is_cancel = true; is_default = true; }"
              "  }"
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

;; Shows dialog `name` with `lines` in list tile `listkey`. Returns T if
;; `okkey` was pressed. If the dialog cannot be shown, returns `fallback`.
(defun c3dimpact:run-dialog (name listkey lines okkey fallback / path dcl_id result)
  (setq path (c3dimpact:ensure-dcl) result fallback)
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog name dcl_id)
        (progn
          (start_list listkey)
          (foreach ln lines (add_list ln))
          (end_list)
          (setq result nil)
          (action_tile okkey "(setq result T)(done_dialog 1)")
          (action_tile "cancel" "(setq result nil)(done_dialog 0)")
          (start_dialog)
        )
      )
      (unload_dialog dcl_id)
    )
  )
  result
)

(defun c3dimpact:show-impact (lines)
  (c3dimpact:run-dialog "c3dimpact_dialog" "impact_list"
    (if lines lines (list "No dependent objects were found by the automated scan."))
    "proceed" T)
)

;; ---------------------------------------------------------------------------
;; Command interception (opt-in): MOVE / STRETCH / ROTATE / SCALE
;; ---------------------------------------------------------------------------

(defun c3dimpact:native-override (cmdname / scanresult lines allents proceed ss2)
  (c3dimpact:dbg (strcat "intercepted " cmdname))
  (c3dimpact:begin-analysis)
  (setq scanresult (c3dimpact:scan-pickfirst))
  (if (not (cdr scanresult))
    (setq scanresult (c3dimpact:analyze-ss (ssget)))
  )
  (setq allents (cdr scanresult) proceed T)
  (if (and *c3dimpact:enabled* (setq lines (car scanresult)))
    (setq proceed (c3dimpact:show-impact (append (list (strcat "Command: " cmdname) "") lines)))
  )
  (cond
    ((not proceed) (princ (strcat "\nChange-Impact: " cmdname " cancelled.")))
    (allents
     (setq ss2 (ssadd))
     (foreach e allents (ssadd e ss2))
     (command (strcat "_." cmdname) ss2 "")
    )
    (T (command (strcat "_." cmdname)))
  )
  (princ)
)

;; The C:MOVE etc. functions exist only while interception is on. Any
;; existing definition (another add-on's override) is saved and restored.
(defun c3dimpact:install-overrides ( / sym)
  (setq *c3dimpact:saved-defs* nil)
  (foreach cn *c3dimpact:native-commands*
    (setq sym (read (strcat "C:" cn)))
    (setq *c3dimpact:saved-defs* (cons (cons sym (if (boundp sym) (eval sym))) *c3dimpact:saved-defs*))
    (eval (list 'defun sym nil (list 'c3dimpact:native-override cn)))
  )
)

(defun c3dimpact:remove-overrides ( )
  (foreach pair *c3dimpact:saved-defs* (set (car pair) (cdr pair)))
  (setq *c3dimpact:saved-defs* nil)
)

;; command-s: these run from inside another command (or at load time), where
;; plain (command ...) is not allowed.
(defun c3dimpact:intercept-on ( / failed r)
  (if (not *c3dimpact:intercepting*)
    (progn
      (c3dimpact:install-overrides)
      (setq failed nil)
      (foreach cn *c3dimpact:native-commands*
        (setq r (vl-catch-all-apply 'command-s (list "_.UNDEFINE" cn)))
        (if (vl-catch-all-error-p r) (setq failed (cons cn failed)))
      )
      (cond
        ((= (length failed) (length *c3dimpact:native-commands*))
         ;; nothing was undefined (e.g. the drawing was not ready): roll back
         (c3dimpact:remove-overrides)
         (c3dimpact:log "Command interception could not start in this drawing. Type C3D-IMPACT-INTERCEPT to retry."))
        (T
         (setq *c3dimpact:intercepting* T)
         (if failed
           (c3dimpact:log (strcat "Could not undefine: " (c3dt:join (reverse failed) " "))))
        )
      )
    )
  )
)

(defun c3dimpact:intercept-off ( )
  (if *c3dimpact:intercepting*
    (progn
      (foreach cn *c3dimpact:native-commands*
        (vl-catch-all-apply 'command-s (list "_.REDEFINE" cn))
      )
      (c3dimpact:remove-overrides)
      (setq *c3dimpact:intercepting* nil)
    )
  )
)

(defun c3dimpact:intercept-allowed-p ( ) (c3dt:cfg "ImpactInterceptAllowed" T))

;; Effective preference: the user's own choice if they made one, otherwise
;; the CAD manager's default from the config file (nil unless changed).
(defun c3dimpact:intercept-wanted-p ( / pref)
  (setq pref (c3dt:pref-get "ImpactIntercept"))
  (and (c3dimpact:intercept-allowed-p)
       (cond ((= pref "1") T)
             ((= pref "0") nil)
             (T (c3dt:cfg "ImpactInterceptDefault" nil))))
)

(defun c:C3D-IMPACT-INTERCEPT ( )
  (cond
    ((not (c3dimpact:intercept-allowed-p))
     (c3dimpact:log "Command interception has been disabled by your CAD administrator."))
    (*c3dimpact:intercepting*
     (c3dimpact:intercept-off)
     (c3dt:pref-set "ImpactIntercept" "0")
     (c3dimpact:log "Command interception OFF. MOVE, STRETCH, ROTATE and SCALE are back to normal."))
    ((c3dimpact:run-dialog "c3dimpact_optin" "optin_text" *c3dimpact:optin-text* "enable" nil)
     (c3dimpact:intercept-on)
     (if *c3dimpact:intercepting*
       (progn
         (c3dt:pref-set "ImpactIntercept" "1")
         (c3dimpact:log "Command interception ON for MOVE, STRETCH, ROTATE and SCALE. Run C3D-IMPACT-INTERCEPT again to turn it off."))
     ))
    (T (c3dimpact:log "Command interception left OFF."))
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
  (if *c3dimpact:enabled*
    (progn
      (setq cmdname (strcase (vl-princ-to-string (car args))))
      (if *c3dimpact:debug* (c3dimpact:dbg (strcat "command: " cmdname)))
      (if (c3dimpact:watched-p cmdname)
        (progn
          (c3dimpact:begin-analysis)
          (setq scanresult (c3dimpact:scan-pickfirst) lines (car scanresult))
          (if (and (wcmatch cmdname "*PROFILE*") (cdr scanresult))
            (setq lines (c3dimpact:analyze-for-profile-command (cdr scanresult)))
          )
          ;; Nothing pre-selected: infer the object type from the command
          ;; name and report on every object of that type.
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
          (if (and lines
                   (not (c3dimpact:show-impact (append (list (strcat "Command: " cmdname) "") lines))))
            (princ "\nChange-Impact: press ESC now to stop - this command cannot be cancelled automatically.")
          )
        )
      )
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
  (setq *c3dimpact:enabled* T)
  (c3dimpact:init-reactor)
  (c3dimpact:log "Warnings ON.")
  (princ)
)

(defun c:C3D-IMPACT-OFF ( )
  (setq *c3dimpact:enabled* nil)
  (c3dimpact:log "Warnings OFF. (Command interception is controlled separately by C3D-IMPACT-INTERCEPT.)")
  (princ)
)

(defun c:C3D-IMPACT-STATUS ( )
  (c3dimpact:log (strcat "Warnings: " (if *c3dimpact:enabled* "ON" "OFF")))
  (princ (strcat "\n  Command interception (MOVE/STRETCH/ROTATE/SCALE): "
                 (cond (*c3dimpact:intercepting* "ON")
                       ((not (c3dimpact:intercept-allowed-p)) "OFF (disabled by administrator)")
                       (T "OFF (run C3D-IMPACT-INTERCEPT to enable)"))))
  (princ (strcat "\n  Civil 3D COM: " (if (c3dt:civil-app) "connected" "not connected (run C3DTOOLS-FINDCIVIL)")))
  (princ (strcat "\n  Debug tracing: " (if *c3dimpact:debug* "ON" "off")))
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
  (setq *c3dimpact:enabled* (if (c3dt:cfg "ImpactWarnings" T) T nil))
  (if *c3dimpact:enabled* (c3dimpact:init-reactor))
  (if (c3dimpact:intercept-wanted-p) (vl-catch-all-apply 'c3dimpact:intercept-on nil))
)

(c3dimpact:init)
(princ)
