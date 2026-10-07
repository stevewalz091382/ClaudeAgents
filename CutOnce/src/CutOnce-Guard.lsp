;;; ============================================================================
;;; CutOnce-Guard.lsp
;;;
;;; Watches a Civil 3D session for specific, high-signal data-loss risks and
;;; warns the user the moment they happen. Warn only: nothing here cancels a
;;; command or blocks a save. Each guard can be switched on or off by the
;;; designer in CUTONCE.
;;;
;;;   1. EXPLODE converting any Civil 3D object (any AECC* type), block
;;;      reference or hatch into plain geometry. Also catches attributed blocks being
;;;      converted to text, which covers BURST (BURST runs EXPLODE internally).
;;;      [GuardExplode]
;;;   2. XREF / XBIND binding an external reference into the drawing.
;;;      [GuardXrefBind]
;;;   3. MOVE / COPY shifting an attached xref's insertion point. [GuardXrefMove]
;;;   4. Advisories for REFEDIT / REFCLOSE [GuardRefEdit], PROMOTEREFERENCE
;;;      [GuardPromote], and a once-per-session tip on TEXT / DTEXT / MTEXT
;;;      [GuardTextTip]. Every TEXT / DTEXT / MTEXT start is logged to
;;;      Events.csv: TEXT-TIP when the tip shows, TEXT-USED after that.
;;;
;;; The save-time checks (unusual growth, xrefs off 0,0,0) and Health.csv are
;;; in CutOnce-Health.lsp.
;;;
;;; Not covered: manual TIN edits made from Toolspace's right-click menu do not
;;; raise a command event, so AutoLISP cannot see them.
;;;
;;; Logs (in the CutOnce log folder, see CUTONCE-STATUS):
;;;   Events.csv   one row per flagged event   [LogEvents]
;;;   Opened.csv   one row per drawing opened  [LogOpened]
;;;
;;; Commands:
;;;   CUTONCE-GUARD-STATUS       which guards are on, reactor status
;;;   CUTONCE-GUARD-CHECKNOW     run the save-time health check now
;;;   CUTONCE-GUARD-DUMPOBJECTS  raw ObjectName counts behind the Health.csv columns
;;;   CUTONCE-GUARD-LOG          print the log file paths
;;;   CUTONCE-GUARD-SUMMARY      roll up every drawing ever tracked
;;;   CUTONCE-GUARD-LOGCOMMANDS  echo every command name as it starts (use this to
;;;                         find the real name of a ribbon or menu command)
;;;
;;; Naming: every function and global here starts with coguard: / *coguard:.
;;; Requires CutOnce-Core.lsp and CutOnce-Health.lsp.
;;; ============================================================================

(vl-load-com)

(defun coguard:log (msg) (cutonce:msg "CutOnce Guard" msg))

(setq *coguard:logall* nil)

(defun coguard:trace (msg)
  (if *coguard:logall* (princ (strcat "\n[CutOnce Guard TRACE] " msg)))
  (princ)
)

(defun coguard:opened-path ( ) (cutonce:log-file "Opened.csv"))

(defun coguard:log-event (kind detail) (cutonce:log-event kind detail))


;; ---------------------------------------------------------------------------
;; Object snapshots: count every AECC* object, block reference and hatch in
;; Model Space and every paper-space layout, keyed by ObjectName.
;; ---------------------------------------------------------------------------

(defun coguard:friendly-name (raw)
  (cond
    ((= raw "AcDbBlockReference") "Block")
    ((= raw "AcDbHatch") "Hatch")
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

(defun coguard:scan-space-into (spaceBlk counts / oname pair)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for ent spaceBlk
        (setq oname (cutonce:object-name ent))
        (if (or (= oname "AcDbBlockReference") (= oname "AcDbHatch") (wcmatch (strcase oname) "AECC*"))
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
(defun coguard:object-snapshot (doc / counts blk)
  (setq counts (coguard:scan-space-into (vla-get-ModelSpace doc) nil))
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for lay (vla-get-Layouts doc)
        (if (eq (cutonce:prop lay 'ModelType) :vlax-false)
          (if (setq blk (cutonce:prop lay 'Block))
            (setq counts (coguard:scan-space-into blk counts))
          )
        )
      )
    ))
  )
  counts
)

(defun coguard:sum-counts (counts wildcard / total)
  (setq total 0)
  (foreach pair counts
    (if (wcmatch (strcase (car pair)) (strcase wildcard)) (setq total (+ total (cdr pair))))
  )
  total
)

;; ---------------------------------------------------------------------------
;; Risk 1: EXPLODE
;; ---------------------------------------------------------------------------

(setq *coguard:explode-snapshot* nil)
(setq *coguard:explode-attrib-snapshot* nil)

(defun coguard:report-civil-loss (before after / lost bv av)
  (cond
    ((not before) (coguard:trace "EXPLODE ended without a before-snapshot."))
    (T
     (setq lost nil)
     (foreach pair before
       (setq bv (cdr pair) av (cond ((cdr (assoc (car pair) after))) (0)))
       (if (< av bv) (setq lost (cons (list (car pair) bv av) lost)))
     )
     (if lost
       (progn
         (coguard:log-event "EXPLODE-LOSS"
           (apply 'strcat
             (mapcar (function (lambda (x)
                       (strcat (coguard:friendly-name (car x)) " " (itoa (cadr x)) "->" (itoa (caddr x)) "  ")))
                     lost)))
         (cutonce:notice
           (strcat
             "CutOnce Guard: EXPLODE just removed or converted an object.\n\n"
             (apply 'strcat
               (mapcar (function (lambda (x)
                         (strcat "  " (coguard:friendly-name (car x)) ": " (itoa (cadr x)) " -> "
                                 (itoa (caddr x)) " (down " (itoa (- (cadr x) (caddr x))) ")\n")))
                       lost))
             "\nThe exploded object is now plain geometry and has lost its design intent.\n\n"
             (if (assoc "AcDbHatch" lost)
               (strcat "An exploded hatch becomes many separate lines: it loses its boundary\n"
                       "association and area, can no longer be edited as a pattern, and\n"
                       "adds to file size.\n\n")
               "")
             "If this wasn't intentional, type U now to undo."
           )
           "GUARD_EXPLODE"
         )
       )
       (coguard:trace "EXPLODE ended - no object-type count decreased.")
     )
    )
  )
)

(defun coguard:attrib-block-count (doc / n)
  (setq n 0)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for ent (vla-get-ModelSpace doc)
        (if (and (= (cutonce:object-name ent) "AcDbBlockReference")
                 (eq (cutonce:prop ent 'HasAttributes) :vlax-true))
          (setq n (1+ n))
        )
      )
    ))
  )
  n
)

(defun coguard:report-attrib-loss (before after)
  (if (and before after (< after before))
    (progn
      (coguard:log-event "ATTRIB-LOSS" (strcat "attributed blocks " (itoa before) "->" (itoa after)))
      (cutonce:notice
        (strcat
          "CutOnce Guard: EXPLODE just converted " (itoa (- before after)) " attributed block(s)\n"
          "into plain text and geometry (BURST does this too).\n\n"
          "The attribute data used for tags, schedules and data extraction is gone;\n"
          "only the displayed text remains.\n\n"
          "If this wasn't intentional, type U now to undo."
        )
        "GUARD_ATTRIB"
      )
    )
    (coguard:trace "EXPLODE ended - attributed-block count did not decrease.")
  )
)

;; ---------------------------------------------------------------------------
;; Risk 2: XREF / XBIND binding
;; ---------------------------------------------------------------------------

(setq *coguard:xref-snapshot* nil)

(defun coguard:xref-names (doc / names)
  (setq names nil)
  (vlax-for blk (vla-get-Blocks doc)
    (if (eq (cutonce:prop blk 'IsXRef) :vlax-true) (setq names (cons (vla-get-Name blk) names)))
  )
  names
)

(defun coguard:report-binds (before after / bound)
  (setq bound nil)
  (foreach n before (if (not (member n after)) (setq bound (cons n bound))))
  (if bound
    (progn
      (coguard:log-event "XREF-BIND" (apply 'strcat (mapcar (function (lambda (n) (strcat n "  "))) bound)))
      (cutonce:notice
        (strcat
          "CutOnce Guard: an xref was just bound into this drawing:\n\n"
          (apply 'strcat (mapcar (function (lambda (n) (strcat "  " n "\n"))) bound))
          "\nBinding copies all of that drawing's layers, styles and blocks in\n"
          "permanently (usually with a $0$ suffix), which commonly causes duplicate\n"
          "styles and file-size growth.\n\n"
          "To keep it live, Overlay/Attach with a Data Shortcut is usually the better choice."
        )
        "GUARD_XREF_BIND"
      )
    )
    (coguard:trace "XREF/XBIND ended - no xref was bound.")
  )
)

;; ---------------------------------------------------------------------------
;; Risk 3: MOVE / COPY of an xref, and xref insertion points off 0,0,0
;; ---------------------------------------------------------------------------

(setq *coguard:xrefpts-snapshot* nil)
(setq *coguard:check-xref-move* nil)

(defun coguard:get-point (ent propname / raw pt)
  (setq raw (cutonce:prop ent propname))
  (if raw
    (progn
      (setq pt (vl-catch-all-apply
                 (function (lambda ()
                   (if (listp raw) raw (vlax-safearray->list (vlax-variant-value raw)))))))
      (if (vl-catch-all-error-p pt) nil pt)
    )
  )
)

(defun coguard:near-zero-p (pt / tol)
  (setq tol 1e-6)
  (and pt (< (abs (car pt)) tol) (< (abs (cadr pt)) tol) (< (abs (caddr pt)) tol))
)

(defun coguard:points-equal (a b)
  (and a b (equal a b 1e-6))
)

;; Xref insertion points in Model Space: ((name point) ...)
(defun coguard:xref-insert-points (doc / xrefnames pts bname ip)
  (setq xrefnames (coguard:xref-names doc) pts nil)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for ent (vla-get-ModelSpace doc)
        (if (and (= (cutonce:object-name ent) "AcDbBlockReference")
                 (setq bname (cutonce:str-prop ent 'Name))
                 (member bname xrefnames)
                 (setq ip (coguard:get-point ent 'InsertionPoint)))
          (setq pts (cons (list bname ip) pts))
        )
      )
    ))
  )
  pts
)

(defun coguard:selection-has-xref (ss doc / xrefnames n i obj found)
  (setq found nil)
  (if ss
    (progn
      (setq xrefnames (coguard:xref-names doc) n (sslength ss) i 0)
      (while (and (< i n) (not found))
        (setq obj (vlax-ename->vla-object (ssname ss i)))
        (if (and (= (cutonce:object-name obj) "AcDbBlockReference")
                 (member (cutonce:str-prop obj 'Name) xrefnames))
          (setq found T)
        )
        (setq i (1+ i))
      )
    )
  )
  found
)

(defun coguard:report-xref-move (before after / changed match)
  (setq changed nil)
  (foreach b before
    (setq match nil)
    (foreach a after
      (if (and (= (car a) (car b)) (coguard:points-equal (cadr a) (cadr b))) (setq match T))
    )
    (if (not match) (setq changed T))
  )
  (if (or changed (/= (length before) (length after)))
    (progn
      (coguard:log-event "XREF-MOVED" "an xref insertion point changed position")
      (cutonce:notice
        (strcat
          "CutOnce Guard: an xref's position just changed (moved or copied).\n\n"
          "Moving or copying an xref shifts everything in it out of alignment\n"
          "with shared coordinates and data shortcuts.\n\n"
          "If this wasn't intentional, type U now to undo."
        )
        "GUARD_XREF_MOVED"
      )
    )
    (coguard:trace "MOVE/COPY ended - no xref moved.")
  )
)

;; ---------------------------------------------------------------------------
;; Advisories
;; ---------------------------------------------------------------------------

(defun coguard:advise-refedit ( )
  (cutonce:notice
    (strcat
      "CutOnce Guard: starting REFEDIT (in-place reference edit).\n\n"
      "Changes made now can be saved straight back into the referenced drawing\n"
      "when you close the edit, which affects every drawing that references it.\n\n"
      "Only choose \"Save back to reference\" (on REFCLOSE) if that is intended."
    )
    "GUARD_REFEDIT"
  )
)

(defun coguard:advise-refclose ( )
  (cutonce:notice
    (strcat
      "CutOnce Guard: closing the in-place reference edit.\n\n"
      "Choosing Save writes your changes into the external drawing now, for\n"
      "everyone who references it. Choose Discard if you were only looking."
    )
    "GUARD_REFEDIT"
  )
)

(defun coguard:advise-promote ( )
  (cutonce:notice
    (strcat
      "CutOnce Guard: PROMOTEREFERENCE was just run.\n\n"
      "Promoting a data-shortcut reference makes an independent copy in this\n"
      "drawing and breaks its link to the source; later changes to the source\n"
      "will no longer reach this copy."
    )
    "GUARD_PROMOTE"
  )
)


(defun coguard:advise-text-once (cmd)
  ;; Shown once per Civil 3D session, across every open drawing (blackboard),
  ;; but every use is logged so plain-text habits can be measured.
  (if (not (vl-bb-ref '*coguard:bb-text-tip-shown*))
    (progn
      (vl-bb-set '*coguard:bb-text-tip-shown* T)
      (coguard:log-event "TEXT-TIP" (strcat cmd " started, tip shown"))
      (cutonce:notice
        (strcat
          "CutOnce Guard tip (shown once per session):\n\n"
          "Plain TEXT/MTEXT for stations, elevations or offsets won't update if\n"
          "the design changes, and won't feed label-based schedules or QA/QC.\n\n"
          "If a Civil 3D label style covers what you're about to type, it stays\n"
          "live and matches your drawing standard."
        )
        "GUARD_TEXT"
      )
    )
    (coguard:log-event "TEXT-USED" (strcat cmd " started (tip already shown this session)"))
  )
)

;; ---------------------------------------------------------------------------
;; Command reactor. Each guard checks its own switch, so a guard the designer
;; turned off costs nothing (no snapshot is taken).
;; ---------------------------------------------------------------------------

(defun coguard:cmd-will-start (reactor arglist)
  (vl-catch-all-apply 'coguard:cmd-will-start-body (list arglist))
  (princ)
)

(defun coguard:cmd-will-start-body (arglist / cmd doc ss)
  (setq cmd (strcase (car arglist)))
  (if *coguard:logall* (princ (strcat "\n[CutOnce Guard] command: " cmd)))
  (setq doc (cutonce:active-doc))
  (cond
    ((= cmd "EXPLODE")
     (if (cutonce:on-p "GuardExplode")
       (setq *coguard:explode-snapshot* (coguard:object-snapshot doc)
             *coguard:explode-attrib-snapshot* (coguard:attrib-block-count doc)))
    )
    ((member cmd '("XREF" "-XREF" "XBIND" "-XBIND"))
     (if (cutonce:on-p "GuardXrefBind")
       (setq *coguard:xref-snapshot* (coguard:xref-names doc)))
    )
    ((member cmd '("MOVE" "COPY"))
     (if (cutonce:on-p "GuardXrefMove")
       (progn
         ;; MOVE/COPY are frequent: check only the pickfirst selection when
         ;; there is one, and fall back to a full scan only when there is not.
         (setq ss (ssget "_I"))
         (setq *coguard:check-xref-move* (if (or (not ss) (coguard:selection-has-xref ss doc)) T nil))
         (setq *coguard:xrefpts-snapshot* (if *coguard:check-xref-move* (coguard:xref-insert-points doc)))
       )
     )
    )
    ((= cmd "REFEDIT")
     (if (cutonce:on-p "GuardRefEdit")
       (progn (coguard:log-event "ADVISORY-REFEDIT" "REFEDIT started") (coguard:advise-refedit))))
    ((member cmd '("REFCLOSE" "-REFCLOSE"))
     (if (cutonce:on-p "GuardRefEdit")
       (progn (coguard:log-event "ADVISORY-REFCLOSE" "REFCLOSE started") (coguard:advise-refclose))))
    ((= cmd "PROMOTEREFERENCE")
     (if (cutonce:on-p "GuardPromote")
       (progn (coguard:log-event "ADVISORY-PROMOTE" "PROMOTEREFERENCE run") (coguard:advise-promote))))
    ((member cmd '("TEXT" "DTEXT" "MTEXT"))
     (if (cutonce:on-p "GuardTextTip") (coguard:advise-text-once cmd)))
  )
)

(defun coguard:cmd-ended (reactor arglist)
  (vl-catch-all-apply 'coguard:cmd-ended-body (list arglist))
  (princ)
)

(defun coguard:cmd-ended-body (arglist / cmd doc)
  (setq cmd (strcase (car arglist)))
  (setq doc (cutonce:active-doc))
  (cond
    ((= cmd "EXPLODE")
     (if *coguard:explode-snapshot*
       (coguard:report-civil-loss *coguard:explode-snapshot* (coguard:object-snapshot doc)))
     (if *coguard:explode-attrib-snapshot*
       (coguard:report-attrib-loss *coguard:explode-attrib-snapshot* (coguard:attrib-block-count doc)))
     (setq *coguard:explode-snapshot* nil *coguard:explode-attrib-snapshot* nil)
    )
    ((member cmd '("XREF" "-XREF" "XBIND" "-XBIND"))
     (if *coguard:xref-snapshot*
       (coguard:report-binds *coguard:xref-snapshot* (coguard:xref-names doc))
     )
     (setq *coguard:xref-snapshot* nil)
    )
    ((and (member cmd '("MOVE" "COPY")) *coguard:check-xref-move*)
     (coguard:report-xref-move *coguard:xrefpts-snapshot* (coguard:xref-insert-points doc))
     (setq *coguard:xrefpts-snapshot* nil *coguard:check-xref-move* nil)
    )
  )
)

(defun coguard:cmd-clear (reactor arglist)
  (setq *coguard:explode-snapshot* nil
        *coguard:explode-attrib-snapshot* nil
        *coguard:xref-snapshot* nil
        *coguard:xrefpts-snapshot* nil
        *coguard:check-xref-move* nil)
  (princ)
)

;; ---------------------------------------------------------------------------
;; Opened log: written once when this file loads into a saved drawing (the
;; loader runs once per drawing, so this is exactly one row per open).
;; ---------------------------------------------------------------------------

(defun coguard:log-opened ( / doc drawpath)
  (setq doc (cutonce:active-doc))
  (if (and (cutonce:log-on-p "LogOpened")
           (= (getvar "DWGTITLED") 1)
           (setq drawpath (cutonce:nonblank (cutonce:str-prop doc 'FullName))))
    (cutonce:append-line (coguard:opened-path) "Timestamp,User,DrawingPath,DrawingName"
      (cutonce:csv-row (list (cutonce:timestamp) (cutonce:user) drawpath (cond ((cutonce:str-prop doc 'Name)) ("")))))
  )
)

;; ---------------------------------------------------------------------------
;; Reactor. Kept in a global so it is not garbage-collected; guarded so a
;; reload does not stack duplicates. (The save reactor is in CutOnce-Health.lsp.)
;; ---------------------------------------------------------------------------

(if (not (boundp '*coguard:cmd-reactor*)) (setq *coguard:cmd-reactor* nil))

(defun coguard:init ( )
  (if (not *coguard:cmd-reactor*)
    (setq *coguard:cmd-reactor*
      (vlr-command-reactor nil
        (list (cons :vlr-commandWillStart 'coguard:cmd-will-start)
              (cons :vlr-commandEnded     'coguard:cmd-ended)
              (cons :vlr-commandCancelled 'coguard:cmd-clear)
              (cons :vlr-commandFailed    'coguard:cmd-clear))))
  )
  (vl-catch-all-apply 'coguard:log-opened nil)
)

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

(setq *coguard:switches*
  '("GuardExplode" "GuardXrefBind" "GuardXrefMove" "GuardRefEdit" "GuardPromote"
    "GuardTextTip" "GuardGrowth" "GuardXrefOrigin"))

(defun c:CUTONCE-GUARD-STATUS ( )
  (coguard:log (strcat "Command reactor:  " (if *coguard:cmd-reactor* "active" "not loaded")))
  (coguard:log (strcat "Save reactor:     " (if *cohealth:save-reactor* "active" "not loaded")))
  (coguard:log (strcat "Growth threshold: " (rtos (cohealth:growth-pct) 2 0) "%"))
  (coguard:log (strcat "Log folder:       " (cutonce:log-dir)))
  (foreach k *coguard:switches*
    (princ (strcat "\n  " (cutonce:setting-label k) ": " (if (cutonce:on-p k) "on" "off")
                   (if (cutonce:locked-p k) "  (set by CAD admin)" "")))
  )
  (princ "\n  Change these in the CutOnce Control Center (type CUTONCE).")
  (princ)
)

(defun c:CUTONCE-GUARD-CHECKNOW ( )
  (vl-catch-all-apply 'cohealth:check (list "Manual"))
  (princ)
)

(defun c:CUTONCE-GUARD-DUMPOBJECTS ( / counts)
  (setq counts (coguard:object-snapshot (cutonce:active-doc)))
  (if (not counts)
    (coguard:log "No AECC*, block or hatch objects in Model Space or any layout.")
    (progn
      (coguard:log "Raw ObjectName counts (Model Space + all layouts):")
      (foreach pair (vl-sort counts (function (lambda (a b) (< (car a) (car b)))))
        (princ (strcat "\n  " (car pair) " = " (itoa (cdr pair))))
      )
    )
  )
  (princ)
)

(defun c:CUTONCE-GUARD-LOG ( )
  (coguard:log (strcat "Health history: " (cohealth:path)))
  (coguard:log (strcat "Xref detail:    " (cohealth:xrefs-path)))
  (coguard:log (strcat "Event log:      " (cutonce:events-path)))
  (coguard:log (strcat "Opened log:     " (coguard:opened-path)))
  (coguard:log (strcat "Logging is " (if (cutonce:on-p "LogEnabled") "on." "OFF (turn it on in the Control Center: CUTONCE).")))
  (princ)
)

;; Index of a column in a CSV header line, or nil.
(defun coguard:col (header name)
  (if header (vl-position name (cutonce:csv-split header ",")))
)

;; Every drawing seen in Opened.csv or Health.csv, its latest health row and
;; its flagged-event count, whether or not it is open now.
(defun coguard:summary ( / lines hdr ip in it fields dp dn pair byDraw evcounts lastRow names vals)
  (setq byDraw nil)
  ;; Opened.csv
  (setq lines (cutonce:read-lines (coguard:opened-path)) hdr (car lines)
        ip (coguard:col hdr "DrawingPath") in (coguard:col hdr "DrawingName"))
  (if (and ip in)
    (foreach line (cdr lines)
      (setq fields (cutonce:csv-split line ","))
      (if (> (length fields) (max ip in))
        (progn
          (setq dp (nth ip fields) dn (nth in fields))
          (if (not (assoc dp byDraw)) (setq byDraw (cons (cons dp (cons dn nil)) byDraw)))
        )
      )
    )
  )
  ;; Health.csv (current layout only; archived files are not read)
  (setq lines (cutonce:read-lines (cohealth:path)) hdr (car lines))
  (if (= hdr (cohealth:header))
    (progn
      (setq ip (coguard:col hdr "DrawingPath") in (coguard:col hdr "DrawingName"))
      (foreach line (cdr lines)
        (setq fields (cutonce:csv-split line ","))
        (if (> (length fields) (max ip in))
          (progn
            (setq dp (nth ip fields) dn (nth in fields) pair (assoc dp byDraw))
            (setq byDraw (if pair
                           (subst (cons dp (cons dn fields)) pair byDraw)
                           (cons (cons dp (cons dn fields)) byDraw)))
          )
        )
      )
    )
  )
  ;; Events.csv
  (setq evcounts nil lines (cutonce:read-lines (cutonce:events-path)) hdr (car lines)
        ip (coguard:col hdr "DrawingPath"))
  (if ip
    (foreach line (cdr lines)
      (setq fields (cutonce:csv-split line ","))
      (if (> (length fields) ip)
        (progn
          (setq dp (nth ip fields) pair (assoc dp evcounts))
          (setq evcounts (if pair (subst (cons dp (1+ (cdr pair))) pair evcounts) (cons (cons dp 1) evcounts)))
        )
      )
    )
  )
  (if (not byDraw)
    (coguard:log "Nothing tracked yet - open or save a drawing first.")
    (progn
      (coguard:log (strcat (itoa (length byDraw)) " drawing(s) tracked:"))
      (foreach row byDraw
        (setq dp (car row) dn (cadr row) lastRow (cddr row))
        (princ (strcat "\n  " dn "  (" dp ")"))
        (princ (strcat "\n    flagged events: " (itoa (cond ((cdr (assoc dp evcounts))) (0)))))
        (if lastRow
          (progn
            (princ (strcat "\n    last check: " (nth 0 lastRow) " (" (nth 1 lastRow) ")\n    "))
            (setq names (cohealth:columns) vals lastRow)
            (while (and vals names)
              (if (not (member (car names) *cohealth:id-columns*))
                (princ (strcat (car names) "=" (car vals) "  ")))
              (setq vals (cdr vals) names (cdr names))
            )
          )
          (princ "\n    (opened, no health row yet)")
        )
      )
    )
  )
  (princ)
)

(defun c:CUTONCE-GUARD-SUMMARY ( / r)
  (setq r (vl-catch-all-apply 'coguard:summary nil))
  (if (vl-catch-all-error-p r) (coguard:log (strcat "Summary failed: " (vl-catch-all-error-message r))))
  (princ)
)

(defun c:CUTONCE-GUARD-LOGCOMMANDS ( )
  (setq *coguard:logall* (not *coguard:logall*))
  (coguard:log
    (if *coguard:logall*
      "Command echo ON - every command name prints as it starts. Run CUTONCE-GUARD-LOGCOMMANDS again to stop."
      "Command echo OFF."))
  (princ)
)

(coguard:init)
(princ)
