;;; ============================================================================
;;; C3DGuard.lsp
;;;
;;; Watches a Civil 3D session for specific, high-signal data-loss risks and
;;; warns the user the moment they happen. Warn only: nothing here cancels a
;;; command or blocks a save.
;;;
;;;   1. EXPLODE converting any Civil 3D object (any AECC* type) or block
;;;      reference into plain geometry. Also catches attributed blocks being
;;;      converted to text, which covers BURST (BURST runs EXPLODE internally).
;;;   2. XREF / XBIND binding an external reference into the drawing.
;;;   3. MOVE / COPY shifting an attached xref's insertion point.
;;;   4. Advisories for REFEDIT / REFCLOSE, PROMOTEREFERENCE, and a once-per-
;;;      session tip on TEXT / DTEXT / MTEXT.
;;;   5. A save-time health check that compares counts against the same
;;;      drawing's previous save and flags unusual growth, plus a check that
;;;      every xref is inserted at 0,0,0.
;;;
;;; Not covered: manual TIN edits made from Toolspace's right-click menu do not
;;; raise a command event, so AutoLISP cannot see them.
;;;
;;; Logs (in the CutOnce log folder, see CUTONCE-STATUS):
;;;   Health.csv   one row per save
;;;   Events.csv   one row per flagged event
;;;   Opened.csv   one row per drawing opened
;;;
;;; Commands:
;;;   C3DGUARD-STATUS       reactor and logging status
;;;   C3DGUARD-CHECKNOW     run the save-time health check now
;;;   C3DGUARD-DUMPOBJECTS  raw ObjectName counts behind the Health.csv columns
;;;   C3DGUARD-LOG          print the log file paths
;;;   C3DGUARD-SUMMARY      roll up every drawing ever tracked
;;;   C3DGUARD-LOGCOMMANDS  echo every command name as it starts (use this to
;;;                         find the real name of a ribbon or menu command)
;;;
;;; Naming: every function and global here starts with c3dguard: / *c3dguard:.
;;; Requires CutOnce-Core.lsp.
;;; ============================================================================

(vl-load-com)

(defun c3dguard:log (msg) (c3dt:msg "C3D-GUARD" msg))

(setq *c3dguard:logall* nil)

(defun c3dguard:trace (msg)
  (if *c3dguard:logall* (princ (strcat "\n[C3D-GUARD TRACE] " msg)))
  (princ)
)

(defun c3dguard:growth-pct ( / v)
  (setq v (c3dt:cfg "GuardGrowthWarnPct" 20))
  (if (numberp v) v 20)
)

(defun c3dguard:health-path ( ) (c3dt:log-file "Health.csv"))
(defun c3dguard:events-path ( ) (c3dt:log-file "Events.csv"))
(defun c3dguard:opened-path ( ) (c3dt:log-file "Opened.csv"))

;; ---------------------------------------------------------------------------
;; Event log. Never raises: a logging failure must not suppress the alert that
;; follows it.
;; ---------------------------------------------------------------------------

(defun c3dguard:log-event (kind detail)
  (vl-catch-all-apply 'c3dguard:log-event-body (list kind detail))
  (princ)
)

(defun c3dguard:log-event-body (kind detail / doc)
  (setq doc (c3dt:active-doc))
  (c3dt:append-line (c3dguard:events-path)
    "Timestamp,DrawingPath,DrawingName,EventType,Detail"
    (c3dt:csv-row (list (c3dt:timestamp)
                        (cond ((c3dt:str-prop doc 'FullName)) (""))
                        (cond ((c3dt:str-prop doc 'Name)) (""))
                        kind detail)))
)

;; ---------------------------------------------------------------------------
;; Object snapshots: count every AECC* object and block reference in Model
;; Space and every paper-space layout, keyed by ObjectName.
;; ---------------------------------------------------------------------------

(defun c3dguard:friendly-name (raw)
  (cond
    ((= raw "AcDbBlockReference") "Block")
    ((= raw "AeccDbAlignment") "Alignment")
    ((= raw "AeccDbVAlignment") "Profile")
    ((= raw "AeccDbGraphProfile") "Profile View")
    ((= raw "AeccDbSurfaceTin") "Surface (TIN)")
    ((= raw "AeccDbSurfaceGrid") "Surface (Grid)")
    ((= raw "AeccDbSurfaceVolume") "Surface (Volume)")
    ((= raw "AeccDbCorridor") "Corridor")
    ((= raw "AeccDbNetwork") "Gravity Pipe Network")
    ((= raw "AeccDbPipe") "Gravity Pipe")
    ((= raw "AeccDbStructure") "Gravity Structure")
    ((= raw "AeccDbPressurePipeNetwork") "Pressure Pipe Network")
    ((= raw "AeccDbPressurePipe") "Pressure Pipe")
    ((= raw "AeccDbPressureFitting") "Pressure Fitting")
    ((= raw "AeccDbPressureAppurtenance") "Pressure Appurtenance")
    ((= raw "AeccDbParcel") "Parcel")
    ((= raw "AeccDbSampleLine") "Sample Line")
    ((= raw "AeccDbSampleLineGroup") "Sample Line Group")
    ((= raw "AeccDbSectionView") "Section View")
    ((= raw "AeccDbAssembly") "Assembly")
    ((= raw "AeccDbFeatureLine") "Feature Line")
    (T raw)
  )
)

(defun c3dguard:scan-space-into (spaceBlk counts / oname pair)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for ent spaceBlk
        (setq oname (c3dt:object-name ent))
        (if (or (= oname "AcDbBlockReference") (wcmatch (strcase oname) "AECC*"))
          (progn
            (setq pair (assoc oname counts))
            (setq counts (if pair
                           (subst (cons oname (1+ (cdr pair))) pair counts)
                           (cons (cons oname 1) counts)))
          )
        )
      )
    ))
  )
  counts
)

;; The Layouts collection includes "Model", whose block is Model Space;
;; skip it so Model Space is not counted twice.
(defun c3dguard:object-snapshot (doc / counts blk)
  (setq counts (c3dguard:scan-space-into (vla-get-ModelSpace doc) nil))
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for lay (vla-get-Layouts doc)
        (if (eq (c3dt:prop lay 'ModelType) :vlax-false)
          (if (setq blk (c3dt:prop lay 'Block))
            (setq counts (c3dguard:scan-space-into blk counts))
          )
        )
      )
    ))
  )
  counts
)

(defun c3dguard:sum-counts (counts wildcard / total)
  (setq total 0)
  (foreach pair counts
    (if (wcmatch (strcase (car pair)) (strcase wildcard)) (setq total (+ total (cdr pair))))
  )
  total
)

;; ---------------------------------------------------------------------------
;; Risk 1: EXPLODE
;; ---------------------------------------------------------------------------

(setq *c3dguard:explode-snapshot* nil)
(setq *c3dguard:explode-attrib-snapshot* nil)

(defun c3dguard:report-civil-loss (before after / lost bv av)
  (cond
    ((not before) (c3dguard:trace "EXPLODE ended without a before-snapshot."))
    (T
     (setq lost nil)
     (foreach pair before
       (setq bv (cdr pair) av (cond ((cdr (assoc (car pair) after))) (0)))
       (if (< av bv) (setq lost (cons (list (car pair) bv av) lost)))
     )
     (if lost
       (progn
         (c3dguard:log-event "EXPLODE-LOSS"
           (apply 'strcat
             (mapcar (function (lambda (x)
                       (strcat (c3dguard:friendly-name (car x)) " " (itoa (cadr x)) "->" (itoa (caddr x)) "  ")))
                     lost)))
         (alert
           (strcat
             "C3D-GUARD: EXPLODE just removed or converted an object.\n\n"
             (apply 'strcat
               (mapcar (function (lambda (x)
                         (strcat "  " (c3dguard:friendly-name (car x)) ": " (itoa (cadr x)) " -> "
                                 (itoa (caddr x)) " (down " (itoa (- (cadr x) (caddr x))) ")\n")))
                       lost))
             "\nThe exploded object is now plain geometry and has lost its design intent.\n\n"
             "If this wasn't intentional, type U now to undo."
           )
         )
       )
       (c3dguard:trace "EXPLODE ended - no object-type count decreased.")
     )
    )
  )
)

(defun c3dguard:attrib-block-count (doc / n)
  (setq n 0)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for ent (vla-get-ModelSpace doc)
        (if (and (= (c3dt:object-name ent) "AcDbBlockReference")
                 (eq (c3dt:prop ent 'HasAttributes) :vlax-true))
          (setq n (1+ n))
        )
      )
    ))
  )
  n
)

(defun c3dguard:report-attrib-loss (before after)
  (if (and before after (< after before))
    (progn
      (c3dguard:log-event "ATTRIB-LOSS" (strcat "attributed blocks " (itoa before) "->" (itoa after)))
      (alert
        (strcat
          "C3D-GUARD: EXPLODE just converted " (itoa (- before after)) " attributed block(s)\n"
          "into plain text and geometry (BURST does this too).\n\n"
          "The attribute data used for tags, schedules and data extraction is gone;\n"
          "only the displayed text remains.\n\n"
          "If this wasn't intentional, type U now to undo."
        )
      )
    )
    (c3dguard:trace "EXPLODE ended - attributed-block count did not decrease.")
  )
)

;; ---------------------------------------------------------------------------
;; Risk 2: XREF / XBIND binding
;; ---------------------------------------------------------------------------

(setq *c3dguard:xref-snapshot* nil)

(defun c3dguard:xref-names (doc / names)
  (setq names nil)
  (vlax-for blk (vla-get-Blocks doc)
    (if (eq (c3dt:prop blk 'IsXRef) :vlax-true) (setq names (cons (vla-get-Name blk) names)))
  )
  names
)

(defun c3dguard:report-binds (before after / bound)
  (setq bound nil)
  (foreach n before (if (not (member n after)) (setq bound (cons n bound))))
  (if bound
    (progn
      (c3dguard:log-event "XREF-BIND" (apply 'strcat (mapcar (function (lambda (n) (strcat n "  "))) bound)))
      (alert
        (strcat
          "C3D-GUARD: an xref was just bound into this drawing:\n\n"
          (apply 'strcat (mapcar (function (lambda (n) (strcat "  " n "\n"))) bound))
          "\nBinding copies all of that drawing's layers, styles and blocks in\n"
          "permanently (usually with a $0$ suffix), which commonly causes duplicate\n"
          "styles and file-size growth.\n\n"
          "To keep it live, Overlay/Attach with a Data Shortcut is usually the better choice."
        )
      )
    )
    (c3dguard:trace "XREF/XBIND ended - no xref was bound.")
  )
)

;; ---------------------------------------------------------------------------
;; Risk 3: MOVE / COPY of an xref, and xref insertion points off 0,0,0
;; ---------------------------------------------------------------------------

(setq *c3dguard:xrefpts-snapshot* nil)
(setq *c3dguard:check-xref-move* nil)

(defun c3dguard:get-point (ent propname / raw pt)
  (setq raw (c3dt:prop ent propname))
  (if raw
    (progn
      (setq pt (vl-catch-all-apply
                 (function (lambda ()
                   (if (listp raw) raw (vlax-safearray->list (vlax-variant-value raw)))))))
      (if (vl-catch-all-error-p pt) nil pt)
    )
  )
)

(defun c3dguard:near-zero-p (pt / tol)
  (setq tol 1e-6)
  (and pt (< (abs (car pt)) tol) (< (abs (cadr pt)) tol) (< (abs (caddr pt)) tol))
)

(defun c3dguard:points-equal (a b)
  (and a b (equal a b 1e-6))
)

;; One pass over Model Space: hatch and text counts plus xref insertion points.
(defun c3dguard:modelspace-scan (doc / xrefnames hatchN textN pts objname bname ip)
  (setq xrefnames (c3dguard:xref-names doc))
  (setq hatchN 0 textN 0 pts nil)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for ent (vla-get-ModelSpace doc)
        (setq objname (c3dt:object-name ent))
        (cond
          ((= objname "AcDbHatch") (setq hatchN (1+ hatchN)))
          ((or (= objname "AcDbText") (= objname "AcDbMText")) (setq textN (1+ textN)))
          ((= objname "AcDbBlockReference")
           (setq bname (c3dt:str-prop ent 'Name))
           (if (and bname (member bname xrefnames) (setq ip (c3dguard:get-point ent 'InsertionPoint)))
             (setq pts (cons (list bname ip) pts))
           )
          )
        )
      )
    ))
  )
  (list hatchN textN pts)
)

(defun c3dguard:xref-insert-points (doc) (caddr (c3dguard:modelspace-scan doc)))

(defun c3dguard:selection-has-xref (ss doc / xrefnames n i obj found)
  (setq found nil)
  (if ss
    (progn
      (setq xrefnames (c3dguard:xref-names doc) n (sslength ss) i 0)
      (while (and (< i n) (not found))
        (setq obj (vlax-ename->vla-object (ssname ss i)))
        (if (and (= (c3dt:object-name obj) "AcDbBlockReference")
                 (member (c3dt:str-prop obj 'Name) xrefnames))
          (setq found T)
        )
        (setq i (1+ i))
      )
    )
  )
  found
)

(defun c3dguard:report-xref-move (before after / changed match)
  (setq changed nil)
  (foreach b before
    (setq match nil)
    (foreach a after
      (if (and (= (car a) (car b)) (c3dguard:points-equal (cadr a) (cadr b))) (setq match T))
    )
    (if (not match) (setq changed T))
  )
  (if (or changed (/= (length before) (length after)))
    (progn
      (c3dguard:log-event "XREF-MOVED" "an xref insertion point changed position")
      (c3dt:notice
        (strcat
          "C3D-GUARD: an xref's position just changed (moved or copied).\n\n"
          "Moving or copying an xref shifts everything in it out of alignment\n"
          "with shared coordinates and data shortcuts.\n\n"
          "If this wasn't intentional, type U now to undo."
        )
        "GUARD_XREF_MOVED"
      )
    )
    (c3dguard:trace "MOVE/COPY ended - no xref moved.")
  )
)

(defun c3dguard:off-origin-xrefs (pts / bad)
  (setq bad nil)
  (foreach p pts (if (not (c3dguard:near-zero-p (cadr p))) (setq bad (cons p bad))))
  bad
)

;; ---------------------------------------------------------------------------
;; Advisories
;; ---------------------------------------------------------------------------

(defun c3dguard:advise-refedit ( )
  (alert
    (strcat
      "C3D-GUARD: starting REFEDIT (in-place reference edit).\n\n"
      "Changes made now can be saved straight back into the referenced drawing\n"
      "when you close the edit, which affects every drawing that references it.\n\n"
      "Only choose \"Save back to reference\" (on REFCLOSE) if that is intended."
    )
  )
)

(defun c3dguard:advise-refclose ( )
  (alert
    (strcat
      "C3D-GUARD: closing the in-place reference edit.\n\n"
      "Choosing Save writes your changes into the external drawing now, for\n"
      "everyone who references it. Choose Discard if you were only looking."
    )
  )
)

(defun c3dguard:advise-promote ( )
  (alert
    (strcat
      "C3D-GUARD: PROMOTEREFERENCE was just run.\n\n"
      "Promoting a data-shortcut reference makes an independent copy in this\n"
      "drawing and breaks its link to the source; later changes to the source\n"
      "will no longer reach this copy."
    )
  )
)

(setq *c3dguard:text-tip-shown* nil)

(defun c3dguard:advise-text-once ( )
  (if (not *c3dguard:text-tip-shown*)
    (progn
      (setq *c3dguard:text-tip-shown* T)
      (c3dt:notice
        (strcat
          "C3D-GUARD tip (shown once per session):\n\n"
          "Plain TEXT/MTEXT for stations, elevations or offsets won't update if\n"
          "the design changes, and won't feed label-based schedules or QA/QC.\n\n"
          "If a Civil 3D label style covers what you're about to type, it stays\n"
          "live and matches your drawing standard."
        )
        "GUARD_TEXT"
      )
    )
  )
)

;; ---------------------------------------------------------------------------
;; Command reactor
;; ---------------------------------------------------------------------------

(defun c3dguard:cmd-will-start (reactor arglist)
  (vl-catch-all-apply 'c3dguard:cmd-will-start-body (list arglist))
  (princ)
)

(defun c3dguard:cmd-will-start-body (arglist / cmd doc ss)
  (setq cmd (strcase (car arglist)))
  (if *c3dguard:logall* (princ (strcat "\n[C3D-GUARD] command: " cmd)))
  (setq doc (c3dt:active-doc))
  (cond
    ((= cmd "EXPLODE")
     (setq *c3dguard:explode-snapshot* (c3dguard:object-snapshot doc))
     (setq *c3dguard:explode-attrib-snapshot* (c3dguard:attrib-block-count doc))
    )
    ((member cmd '("XREF" "-XREF" "XBIND" "-XBIND"))
     (setq *c3dguard:xref-snapshot* (c3dguard:xref-names doc))
    )
    ((member cmd '("MOVE" "COPY"))
     ;; MOVE/COPY are frequent: check only the pickfirst selection when there
     ;; is one, and fall back to a full scan only when there is not.
     (setq ss (ssget "_I"))
     (setq *c3dguard:check-xref-move* (if (or (not ss) (c3dguard:selection-has-xref ss doc)) T nil))
     (setq *c3dguard:xrefpts-snapshot* (if *c3dguard:check-xref-move* (c3dguard:xref-insert-points doc)))
    )
    ((= cmd "REFEDIT") (c3dguard:advise-refedit))
    ((member cmd '("REFCLOSE" "-REFCLOSE")) (c3dguard:advise-refclose))
    ((= cmd "PROMOTEREFERENCE") (c3dguard:advise-promote))
    ((member cmd '("TEXT" "DTEXT" "MTEXT")) (c3dguard:advise-text-once))
  )
)

(defun c3dguard:cmd-ended (reactor arglist)
  (vl-catch-all-apply 'c3dguard:cmd-ended-body (list arglist))
  (princ)
)

(defun c3dguard:cmd-ended-body (arglist / cmd doc)
  (setq cmd (strcase (car arglist)))
  (setq doc (c3dt:active-doc))
  (cond
    ((= cmd "EXPLODE")
     (c3dguard:report-civil-loss *c3dguard:explode-snapshot* (c3dguard:object-snapshot doc))
     (c3dguard:report-attrib-loss *c3dguard:explode-attrib-snapshot* (c3dguard:attrib-block-count doc))
     (setq *c3dguard:explode-snapshot* nil *c3dguard:explode-attrib-snapshot* nil)
    )
    ((member cmd '("XREF" "-XREF" "XBIND" "-XBIND"))
     (if *c3dguard:xref-snapshot*
       (c3dguard:report-binds *c3dguard:xref-snapshot* (c3dguard:xref-names doc))
     )
     (setq *c3dguard:xref-snapshot* nil)
    )
    ((and (member cmd '("MOVE" "COPY")) *c3dguard:check-xref-move*)
     (c3dguard:report-xref-move *c3dguard:xrefpts-snapshot* (c3dguard:xref-insert-points doc))
     (setq *c3dguard:xrefpts-snapshot* nil *c3dguard:check-xref-move* nil)
    )
  )
)

(defun c3dguard:cmd-clear (reactor arglist)
  (setq *c3dguard:explode-snapshot* nil
        *c3dguard:explode-attrib-snapshot* nil
        *c3dguard:xref-snapshot* nil
        *c3dguard:xrefpts-snapshot* nil
        *c3dguard:check-xref-move* nil)
  (princ)
)

;; ---------------------------------------------------------------------------
;; Save-time health check
;; ---------------------------------------------------------------------------

(setq *c3dguard:metric-order*
  '("Layers" "Linetypes" "Blocks" "Layouts" "Xrefs" "RegApps"
    "Alignments" "Profiles" "ProfileViews" "Surfaces" "Corridors" "Assemblies"
    "PipeNetworks" "PressurePipeNetworks" "SectionViews" "Sections"
    "Hatches" "TextObjects")
)

;; Previous snapshot for this drawing: (drawpath . values). Health.csv is read
;; only on the first save of a session; later saves compare against memory.
(setq *c3dguard:last-snapshot* nil)

;; Returns (list metric-values xref-insertion-points).
(defun c3dguard:snapshot-now (doc / nXrefs scan objcounts)
  (setq nXrefs 0)
  (vlax-for blk (vla-get-Blocks doc)
    (if (eq (c3dt:prop blk 'IsXRef) :vlax-true) (setq nXrefs (1+ nXrefs)))
  )
  (setq objcounts (c3dguard:object-snapshot doc))
  (setq scan (c3dguard:modelspace-scan doc))
  (list
    (list
      (c3dt:count (vla-get-Layers doc))
      (c3dt:count (vla-get-Linetypes doc))
      (c3dt:count (vla-get-Blocks doc))
      (c3dt:count (vla-get-Layouts doc))
      nXrefs
      (c3dt:count (vla-get-RegisteredApplications doc))
      (c3dguard:sum-counts objcounts "AECCDBALIGNMENT")
      (c3dguard:sum-counts objcounts "AECCDBVALIGNMENT")
      (c3dguard:sum-counts objcounts "AECCDBGRAPHPROFILE")
      (c3dguard:sum-counts objcounts "AECCDBSURFACETIN,AECCDBSURFACEGRID,AECCDBSURFACEVOLUME")
      (c3dguard:sum-counts objcounts "AECCDBCORRIDOR")
      (c3dguard:sum-counts objcounts "AECCDBASSEMBLY")
      (c3dguard:sum-counts objcounts "AECCDBNETWORK")
      (c3dguard:sum-counts objcounts "AECCDBPRESSUREPIPENETWORK,AECCDBPRESSURENETWORK")
      (c3dguard:sum-counts objcounts "AECCDBSECTIONVIEW")
      (c3dguard:sum-counts objcounts "AECCDBSECTION")
      (car scan)
      (cadr scan)
    )
    (caddr scan)
  )
)

;; Last Health.csv row for this drawing, as a list of integers (or nil).
(defun c3dguard:previous-values (drawpath nmetrics / lastrow fields)
  (if (and *c3dguard:last-snapshot* (= (car *c3dguard:last-snapshot*) drawpath))
    (cdr *c3dguard:last-snapshot*)
    (progn
      (foreach line (cdr (c3dt:read-lines (c3dguard:health-path)))
        (setq fields (c3dt:csv-split line ","))
        (if (and (>= (length fields) 2) (= (nth 1 fields) drawpath)) (setq lastrow fields))
      )
      (if (and lastrow (= (length (cdddr lastrow)) nmetrics))
        (mapcar 'atoi (cdddr lastrow))
      )
    )
  )
)

(defun c3dguard:begin-save (reactor arglist)
  (vl-catch-all-apply 'c3dguard:health-check nil)
  (princ)
)

(defun c3dguard:health-check ( / doc snap vals xrefpts badpts drawpath drawname prevvals
                                 flags i oldv newv)
  (setq doc (c3dt:active-doc))
  (setq drawpath (c3dt:str-prop doc 'FullName))
  (setq drawname (cond ((c3dt:str-prop doc 'Name)) ("")))
  (setq snap (c3dguard:snapshot-now doc))
  (setq vals (car snap) xrefpts (cadr snap))
  (if (not (c3dt:nonblank drawpath))
    (c3dguard:log "This drawing has not been saved yet - health log skipped.")
    (progn
      (setq prevvals (vl-catch-all-apply 'c3dguard:previous-values (list drawpath (length vals))))
      (if (vl-catch-all-error-p prevvals) (setq prevvals nil))
      (vl-catch-all-apply 'c3dt:append-line
        (list (c3dguard:health-path)
              (strcat "Timestamp,DrawingPath,DrawingName," (c3dt:join *c3dguard:metric-order* ","))
              (strcat (c3dt:csv-row (list (c3dt:timestamp) drawpath drawname)) "," (c3dt:csv-row vals))))
      (setq *c3dguard:last-snapshot* (cons drawpath vals))

      (setq flags nil i 0)
      (if prevvals
        (foreach metric *c3dguard:metric-order*
          (setq oldv (nth i prevvals) newv (nth i vals))
          (cond
            ((and (= metric "RegApps") (> newv oldv))
             (setq flags (cons (list metric oldv newv "new registered app(s), often left by a bind or a foreign block") flags)))
            ((and (= oldv 0) (> newv 0))
             (setq flags (cons (list metric oldv newv "new since last save") flags)))
            ((and (> oldv 0) (>= (* 100.0 (/ (float (- newv oldv)) oldv)) (c3dguard:growth-pct)))
             (setq flags (cons (list metric oldv newv
                                     (strcat "up " (rtos (* 100.0 (/ (float (- newv oldv)) oldv)) 2 0) "% since last save"))
                               flags)))
          )
          (setq i (1+ i))
        )
      )
      (if flags
        (progn
          (c3dguard:log-event "SAVE-FLAG"
            (apply 'strcat (mapcar (function (lambda (x) (strcat (car x) " " (itoa (cadr x)) "->" (itoa (caddr x)) "  "))) flags)))
          (alert
            (strcat
              "C3D-GUARD: unusual growth since the last save of\n" drawname ":\n\n"
              (apply 'strcat
                (mapcar (function (lambda (x)
                          (strcat "  " (car x) ": " (itoa (cadr x)) " -> " (itoa (caddr x)) "  (" (nth 3 x) ")\n")))
                        flags))
              "\nFull history: " (c3dguard:health-path)
            )
          )
        )
      )

      (if (setq badpts (c3dguard:off-origin-xrefs xrefpts))
        (progn
          (c3dguard:log-event "XREF-BASEPOINT" (apply 'strcat (mapcar (function (lambda (p) (strcat (car p) "  "))) badpts)))
          (alert
            (strcat
              "C3D-GUARD: xref insertion point(s) are not at 0,0,0:\n\n"
              (apply 'strcat
                (mapcar (function (lambda (p)
                          (strcat "  " (car p) ": " (rtos (car (cadr p)) 2 3) ", "
                                  (rtos (cadr (cadr p)) 2 3) ", " (rtos (caddr (cadr p)) 2 3) "\n")))
                        badpts))
              "\nA non-zero xref insertion point commonly causes misalignment against\n"
              "a shared coordinate system or data shortcuts."
            )
          )
        )
      )
    )
  )
)

;; ---------------------------------------------------------------------------
;; Opened log: written once when this file loads into a saved drawing (the
;; loader runs once per drawing, so this is exactly one row per open).
;; ---------------------------------------------------------------------------

(defun c3dguard:log-opened ( / doc drawpath)
  (setq doc (c3dt:active-doc))
  (if (and (= (getvar "DWGTITLED") 1) (setq drawpath (c3dt:nonblank (c3dt:str-prop doc 'FullName))))
    (c3dt:append-line (c3dguard:opened-path) "Timestamp,DrawingPath,DrawingName"
      (c3dt:csv-row (list (c3dt:timestamp) drawpath (cond ((c3dt:str-prop doc 'Name)) ("")))))
  )
)

;; ---------------------------------------------------------------------------
;; Reactors. Kept in globals so they are not garbage-collected; guarded so a
;; reload does not stack duplicates.
;; ---------------------------------------------------------------------------

(if (not (boundp '*c3dguard:cmd-reactor*)) (setq *c3dguard:cmd-reactor* nil))
(if (not (boundp '*c3dguard:editor-reactor*)) (setq *c3dguard:editor-reactor* nil))

(defun c3dguard:init ( )
  (if (not *c3dguard:cmd-reactor*)
    (setq *c3dguard:cmd-reactor*
      (vlr-command-reactor nil
        (list (cons :vlr-commandWillStart 'c3dguard:cmd-will-start)
              (cons :vlr-commandEnded     'c3dguard:cmd-ended)
              (cons :vlr-commandCancelled 'c3dguard:cmd-clear)
              (cons :vlr-commandFailed    'c3dguard:cmd-clear))))
  )
  (if (not *c3dguard:editor-reactor*)
    (setq *c3dguard:editor-reactor*
      (vlr-editor-reactor nil (list (cons :vlr-beginSave 'c3dguard:begin-save))))
  )
  (vl-catch-all-apply 'c3dguard:log-opened nil)
)

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

(defun c:C3DGUARD-STATUS ( )
  (c3dguard:log (strcat "Command reactor:  " (if *c3dguard:cmd-reactor* "active" "not loaded")))
  (c3dguard:log (strcat "Save reactor:     " (if *c3dguard:editor-reactor* "active" "not loaded")))
  (c3dguard:log (strcat "Growth threshold: " (rtos (c3dguard:growth-pct) 2 0) "%"))
  (c3dguard:log (strcat "Log folder:       " (c3dt:log-dir)))
  (princ)
)

(defun c:C3DGUARD-CHECKNOW ( )
  (c3dguard:health-check)
  (princ)
)

(defun c:C3DGUARD-DUMPOBJECTS ( / counts)
  (setq counts (c3dguard:object-snapshot (c3dt:active-doc)))
  (if (not counts)
    (c3dguard:log "No AECC* or block objects in Model Space or any layout.")
    (progn
      (c3dguard:log "Raw ObjectName counts (Model Space + all layouts):")
      (foreach pair (vl-sort counts (function (lambda (a b) (< (car a) (car b)))))
        (princ (strcat "\n  " (car pair) " = " (itoa (cdr pair))))
      )
    )
  )
  (princ)
)

(defun c:C3DGUARD-LOG ( )
  (c3dguard:log (strcat "Health history: " (c3dguard:health-path)))
  (c3dguard:log (strcat "Event log:      " (c3dguard:events-path)))
  (c3dguard:log (strcat "Opened log:     " (c3dguard:opened-path)))
  (princ)
)

;; Every drawing seen in Opened.csv or Health.csv, its latest health row and
;; its flagged-event count, whether or not it is open now.
(defun c:C3DGUARD-SUMMARY ( / fields dp dn pair byDraw evcounts lastRow names vals)
  (setq byDraw nil)
  (foreach line (cdr (c3dt:read-lines (c3dguard:opened-path)))
    (setq fields (c3dt:csv-split line ","))
    (if (>= (length fields) 3)
      (progn
        (setq dp (nth 1 fields) dn (nth 2 fields))
        (if (not (assoc dp byDraw)) (setq byDraw (cons (cons dp (cons dn nil)) byDraw)))
      )
    )
  )
  (foreach line (cdr (c3dt:read-lines (c3dguard:health-path)))
    (setq fields (c3dt:csv-split line ","))
    (if (>= (length fields) 3)
      (progn
        (setq dp (nth 1 fields) dn (nth 2 fields) pair (assoc dp byDraw))
        (setq byDraw (if pair
                       (subst (cons dp (cons dn line)) pair byDraw)
                       (cons (cons dp (cons dn line)) byDraw)))
      )
    )
  )
  (setq evcounts nil)
  (foreach line (cdr (c3dt:read-lines (c3dguard:events-path)))
    (setq fields (c3dt:csv-split line ","))
    (if (>= (length fields) 2)
      (progn
        (setq dp (nth 1 fields) pair (assoc dp evcounts))
        (setq evcounts (if pair (subst (cons dp (1+ (cdr pair))) pair evcounts) (cons (cons dp 1) evcounts)))
      )
    )
  )
  (if (not byDraw)
    (c3dguard:log "Nothing tracked yet - open or save a drawing first.")
    (progn
      (c3dguard:log (strcat (itoa (length byDraw)) " drawing(s) tracked:"))
      (foreach row byDraw
        (setq dp (car row) dn (cadr row) lastRow (cddr row))
        (princ (strcat "\n  " dn "  (" dp ")"))
        (princ (strcat "\n    flagged events: " (itoa (cond ((cdr (assoc dp evcounts))) (0)))))
        (if lastRow
          (progn
            (setq fields (c3dt:csv-split lastRow ","))
            (princ (strcat "\n    last save: " (car fields) "\n    "))
            (setq vals (cdddr fields) names *c3dguard:metric-order*)
            (while (and vals names)
              (princ (strcat (car names) "=" (car vals) "  "))
              (setq vals (cdr vals) names (cdr names))
            )
          )
          (princ "\n    (opened, never saved with CutOnce loaded)")
        )
      )
    )
  )
  (princ)
)

(defun c:C3DGUARD-LOGCOMMANDS ( )
  (setq *c3dguard:logall* (not *c3dguard:logall*))
  (c3dguard:log
    (if *c3dguard:logall*
      "Command echo ON - every command name prints as it starts. Run C3DGUARD-LOGCOMMANDS again to stop."
      "Command echo OFF."))
  (princ)
)

(c3dguard:init)
(princ)
