;;; ============================================================================
;;; CutOnce-Guard.lsp
;;;
;;; Watches a Civil 3D session for specific, high-signal data-loss risks and
;;; warns the user the moment they happen. Warn only: nothing here cancels a
;;; command or blocks a save. Each guard can be switched on or off by the
;;; designer in CUTONCE.
;;;
;;;   1. EXPLODE converting any Civil 3D object (any AECC* type) or block
;;;      reference into plain geometry. Also catches attributed blocks being
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
;;; Naming: every function and global here starts with mwguard: / *mwguard:.
;;; Requires CutOnce-Core.lsp and CutOnce-Health.lsp.
;;; ============================================================================

(vl-load-com)

(defun mwguard:log (msg) (mwise:msg "CutOnce Guard" msg))

(setq *mwguard:logall* nil)

(defun mwguard:trace (msg)
  (if *mwguard:logall* (princ (strcat "\n[CutOnce Guard TRACE] " msg)))
  (princ)
)

(defun mwguard:opened-path ( ) (mwise:log-file "Opened.csv"))

(defun mwguard:log-event (kind detail) (mwise:log-event kind detail))


;; ---------------------------------------------------------------------------
;; Object snapshots: count every AECC* object and block reference in Model
;; Space and every paper-space layout, keyed by ObjectName.
;; ---------------------------------------------------------------------------

(defun mwguard:friendly-name (raw)
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

(defun mwguard:scan-space-into (spaceBlk counts / oname pair)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for ent spaceBlk
        (setq oname (mwise:object-name ent))
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
(defun mwguard:object-snapshot (doc / counts blk)
  (setq counts (mwguard:scan-space-into (vla-get-ModelSpace doc) nil))
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for lay (vla-get-Layouts doc)
        (if (eq (mwise:prop lay 'ModelType) :vlax-false)
          (if (setq blk (mwise:prop lay 'Block))
            (setq counts (mwguard:scan-space-into blk counts))
          )
        )
      )
    ))
  )
  counts
)

(defun mwguard:sum-counts (counts wildcard / total)
  (setq total 0)
  (foreach pair counts
    (if (wcmatch (strcase (car pair)) (strcase wildcard)) (setq total (+ total (cdr pair))))
  )
  total
)

;; ---------------------------------------------------------------------------
;; Risk 1: EXPLODE
;; ---------------------------------------------------------------------------

(setq *mwguard:explode-snapshot* nil)
(setq *mwguard:explode-attrib-snapshot* nil)

(defun mwguard:report-civil-loss (before after / lost bv av)
  (cond
    ((not before) (mwguard:trace "EXPLODE ended without a before-snapshot."))
    (T
     (setq lost nil)
     (foreach pair before
       (setq bv (cdr pair) av (cond ((cdr (assoc (car pair) after))) (0)))
       (if (< av bv) (setq lost (cons (list (car pair) bv av) lost)))
     )
     (if lost
       (progn
         (mwguard:log-event "EXPLODE-LOSS"
           (apply 'strcat
             (mapcar (function (lambda (x)
                       (strcat (mwguard:friendly-name (car x)) " " (itoa (cadr x)) "->" (itoa (caddr x)) "  ")))
                     lost)))
         (mwise:notice
           (strcat
             "CutOnce Guard: EXPLODE just removed or converted an object.\n\n"
             (apply 'strcat
               (mapcar (function (lambda (x)
                         (strcat "  " (mwguard:friendly-name (car x)) ": " (itoa (cadr x)) " -> "
                                 (itoa (caddr x)) " (down " (itoa (- (cadr x) (caddr x))) ")\n")))
                       lost))
             "\nThe exploded object is now plain geometry and has lost its design intent.\n\n"
             "If this wasn't intentional, type U now to undo."
           )
           "GUARD_EXPLODE"
         )
       )
       (mwguard:trace "EXPLODE ended - no object-type count decreased.")
     )
    )
  )
)

(defun mwguard:attrib-block-count (doc / n)
  (setq n 0)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for ent (vla-get-ModelSpace doc)
        (if (and (= (mwise:object-name ent) "AcDbBlockReference")
                 (eq (mwise:prop ent 'HasAttributes) :vlax-true))
          (setq n (1+ n))
        )
      )
    ))
  )
  n
)

(defun mwguard:report-attrib-loss (before after)
  (if (and before after (< after before))
    (progn
      (mwguard:log-event "ATTRIB-LOSS" (strcat "attributed blocks " (itoa before) "->" (itoa after)))
      (mwise:notice
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
    (mwguard:trace "EXPLODE ended - attributed-block count did not decrease.")
  )
)

;; ---------------------------------------------------------------------------
;; Risk 2: XREF / XBIND binding
;; ---------------------------------------------------------------------------

(setq *mwguard:xref-snapshot* nil)

(defun mwguard:xref-names (doc / names)
  (setq names nil)
  (vlax-for blk (vla-get-Blocks doc)
    (if (eq (mwise:prop blk 'IsXRef) :vlax-true) (setq names (cons (vla-get-Name blk) names)))
  )
  names
)

(defun mwguard:report-binds (before after / bound)
  (setq bound nil)
  (foreach n before (if (not (member n after)) (setq bound (cons n bound))))
  (if bound
    (progn
      (mwguard:log-event "XREF-BIND" (apply 'strcat (mapcar (function (lambda (n) (strcat n "  "))) bound)))
      (mwise:notice
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
    (mwguard:trace "XREF/XBIND ended - no xref was bound.")
  )
)

;; ---------------------------------------------------------------------------
;; Risk 3: MOVE / COPY of an xref, and xref insertion points off 0,0,0
;; ---------------------------------------------------------------------------

(setq *mwguard:xrefpts-snapshot* nil)
(setq *mwguard:check-xref-move* nil)

(defun mwguard:get-point (ent propname / raw pt)
  (setq raw (mwise:prop ent propname))
  (if raw
    (progn
      (setq pt (vl-catch-all-apply
                 (function (lambda ()
                   (if (listp raw) raw (vlax-safearray->list (vlax-variant-value raw)))))))
      (if (vl-catch-all-error-p pt) nil pt)
    )
  )
)

(defun mwguard:near-zero-p (pt / tol)
  (setq tol 1e-6)
  (and pt (< (abs (car pt)) tol) (< (abs (cadr pt)) tol) (< (abs (caddr pt)) tol))
)

(defun mwguard:points-equal (a b)
  (and a b (equal a b 1e-6))
)

;; Xref insertion points in Model Space: ((name point) ...)
(defun mwguard:xref-insert-points (doc / xrefnames pts bname ip)
  (setq xrefnames (mwguard:xref-names doc) pts nil)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for ent (vla-get-ModelSpace doc)
        (if (and (= (mwise:object-name ent) "AcDbBlockReference")
                 (setq bname (mwise:str-prop ent 'Name))
                 (member bname xrefnames)
                 (setq ip (mwguard:get-point ent 'InsertionPoint)))
          (setq pts (cons (list bname ip) pts))
        )
      )
    ))
  )
  pts
)

(defun mwguard:selection-has-xref (ss doc / xrefnames n i obj found)
  (setq found nil)
  (if ss
    (progn
      (setq xrefnames (mwguard:xref-names doc) n (sslength ss) i 0)
      (while (and (< i n) (not found))
        (setq obj (vlax-ename->vla-object (ssname ss i)))
        (if (and (= (mwise:object-name obj) "AcDbBlockReference")
                 (member (mwise:str-prop obj 'Name) xrefnames))
          (setq found T)
        )
        (setq i (1+ i))
      )
    )
  )
  found
)

(defun mwguard:report-xref-move (before after / changed match)
  (setq changed nil)
  (foreach b before
    (setq match nil)
    (foreach a after
      (if (and (= (car a) (car b)) (mwguard:points-equal (cadr a) (cadr b))) (setq match T))
    )
    (if (not match) (setq changed T))
  )
  (if (or changed (/= (length before) (length after)))
    (progn
      (mwguard:log-event "XREF-MOVED" "an xref insertion point changed position")
      (mwise:notice
        (strcat
          "CutOnce Guard: an xref's position just changed (moved or copied).\n\n"
          "Moving or copying an xref shifts everything in it out of alignment\n"
          "with shared coordinates and data shortcuts.\n\n"
          "If this wasn't intentional, type U now to undo."
        )
        "GUARD_XREF_MOVED"
      )
    )
    (mwguard:trace "MOVE/COPY ended - no xref moved.")
  )
)

;; ---------------------------------------------------------------------------
;; Advisories
;; ---------------------------------------------------------------------------

(defun mwguard:advise-refedit ( )
  (mwise:notice
    (strcat
      "CutOnce Guard: starting REFEDIT (in-place reference edit).\n\n"
      "Changes made now can be saved straight back into the referenced drawing\n"
      "when you close the edit, which affects every drawing that references it.\n\n"
      "Only choose \"Save back to reference\" (on REFCLOSE) if that is intended."
    )
    "GUARD_REFEDIT"
  )
)

(defun mwguard:advise-refclose ( )
  (mwise:notice
    (strcat
      "CutOnce Guard: closing the in-place reference edit.\n\n"
      "Choosing Save writes your changes into the external drawing now, for\n"
      "everyone who references it. Choose Discard if you were only looking."
    )
    "GUARD_REFEDIT"
  )
)

(defun mwguard:advise-promote ( )
  (mwise:notice
    (strcat
      "CutOnce Guard: PROMOTEREFERENCE was just run.\n\n"
      "Promoting a data-shortcut reference makes an independent copy in this\n"
      "drawing and breaks its link to the source; later changes to the source\n"
      "will no longer reach this copy."
    )
    "GUARD_PROMOTE"
  )
)


(defun mwguard:advise-text-once (cmd)
  ;; Shown once per Civil 3D session, across every open drawing (blackboard),
  ;; but every use is logged so plain-text habits can be measured.
  (if (not (vl-bb-ref '*mwguard:bb-text-tip-shown*))
    (progn
      (vl-bb-set '*mwguard:bb-text-tip-shown* T)
      (mwguard:log-event "TEXT-TIP" (strcat cmd " started, tip shown"))
      (mwise:notice
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
    (mwguard:log-event "TEXT-USED" (strcat cmd " started (tip already shown this session)"))
  )
)

;; ---------------------------------------------------------------------------
;; Command reactor. Each guard checks its own switch, so a guard the designer
;; turned off costs nothing (no snapshot is taken).
;; ---------------------------------------------------------------------------

(defun mwguard:cmd-will-start (reactor arglist)
  (vl-catch-all-apply 'mwguard:cmd-will-start-body (list arglist))
  (princ)
)

(defun mwguard:cmd-will-start-body (arglist / cmd doc ss)
  (setq cmd (strcase (car arglist)))
  (if *mwguard:logall* (princ (strcat "\n[CutOnce Guard] command: " cmd)))
  (setq doc (mwise:active-doc))
  (cond
    ((= cmd "EXPLODE")
     (if (mwise:on-p "GuardExplode")
       (setq *mwguard:explode-snapshot* (mwguard:object-snapshot doc)
             *mwguard:explode-attrib-snapshot* (mwguard:attrib-block-count doc)))
    )
    ((member cmd '("XREF" "-XREF" "XBIND" "-XBIND"))
     (if (mwise:on-p "GuardXrefBind")
       (setq *mwguard:xref-snapshot* (mwguard:xref-names doc)))
    )
    ((member cmd '("MOVE" "COPY"))
     (if (mwise:on-p "GuardXrefMove")
       (progn
         ;; MOVE/COPY are frequent: check only the pickfirst selection when
         ;; there is one, and fall back to a full scan only when there is not.
         (setq ss (ssget "_I"))
         (setq *mwguard:check-xref-move* (if (or (not ss) (mwguard:selection-has-xref ss doc)) T nil))
         (setq *mwguard:xrefpts-snapshot* (if *mwguard:check-xref-move* (mwguard:xref-insert-points doc)))
       )
     )
    )
    ((= cmd "REFEDIT")
     (if (mwise:on-p "GuardRefEdit")
       (progn (mwguard:log-event "ADVISORY-REFEDIT" "REFEDIT started") (mwguard:advise-refedit))))
    ((member cmd '("REFCLOSE" "-REFCLOSE"))
     (if (mwise:on-p "GuardRefEdit")
       (progn (mwguard:log-event "ADVISORY-REFCLOSE" "REFCLOSE started") (mwguard:advise-refclose))))
    ((= cmd "PROMOTEREFERENCE")
     (if (mwise:on-p "GuardPromote")
       (progn (mwguard:log-event "ADVISORY-PROMOTE" "PROMOTEREFERENCE run") (mwguard:advise-promote))))
    ((member cmd '("TEXT" "DTEXT" "MTEXT"))
     (if (mwise:on-p "GuardTextTip") (mwguard:advise-text-once cmd)))
  )
)

(defun mwguard:cmd-ended (reactor arglist)
  (vl-catch-all-apply 'mwguard:cmd-ended-body (list arglist))
  (princ)
)

(defun mwguard:cmd-ended-body (arglist / cmd doc)
  (setq cmd (strcase (car arglist)))
  (setq doc (mwise:active-doc))
  (cond
    ((= cmd "EXPLODE")
     (if *mwguard:explode-snapshot*
       (mwguard:report-civil-loss *mwguard:explode-snapshot* (mwguard:object-snapshot doc)))
     (if *mwguard:explode-attrib-snapshot*
       (mwguard:report-attrib-loss *mwguard:explode-attrib-snapshot* (mwguard:attrib-block-count doc)))
     (setq *mwguard:explode-snapshot* nil *mwguard:explode-attrib-snapshot* nil)
    )
    ((member cmd '("XREF" "-XREF" "XBIND" "-XBIND"))
     (if *mwguard:xref-snapshot*
       (mwguard:report-binds *mwguard:xref-snapshot* (mwguard:xref-names doc))
     )
     (setq *mwguard:xref-snapshot* nil)
    )
    ((and (member cmd '("MOVE" "COPY")) *mwguard:check-xref-move*)
     (mwguard:report-xref-move *mwguard:xrefpts-snapshot* (mwguard:xref-insert-points doc))
     (setq *mwguard:xrefpts-snapshot* nil *mwguard:check-xref-move* nil)
    )
  )
)

(defun mwguard:cmd-clear (reactor arglist)
  (setq *mwguard:explode-snapshot* nil
        *mwguard:explode-attrib-snapshot* nil
        *mwguard:xref-snapshot* nil
        *mwguard:xrefpts-snapshot* nil
        *mwguard:check-xref-move* nil)
  (princ)
)

;; ---------------------------------------------------------------------------
;; Opened log: written once when this file loads into a saved drawing (the
;; loader runs once per drawing, so this is exactly one row per open).
;; ---------------------------------------------------------------------------

(defun mwguard:log-opened ( / doc drawpath)
  (setq doc (mwise:active-doc))
  (if (and (mwise:log-on-p "LogOpened")
           (= (getvar "DWGTITLED") 1)
           (setq drawpath (mwise:nonblank (mwise:str-prop doc 'FullName))))
    (mwise:append-line (mwguard:opened-path) "Timestamp,User,DrawingPath,DrawingName"
      (mwise:csv-row (list (mwise:timestamp) (mwise:user) drawpath (cond ((mwise:str-prop doc 'Name)) ("")))))
  )
)

;; ---------------------------------------------------------------------------
;; Reactor. Kept in a global so it is not garbage-collected; guarded so a
;; reload does not stack duplicates. (The save reactor is in CutOnce-Health.lsp.)
;; ---------------------------------------------------------------------------

(if (not (boundp '*mwguard:cmd-reactor*)) (setq *mwguard:cmd-reactor* nil))

(defun mwguard:init ( )
  (if (not *mwguard:cmd-reactor*)
    (setq *mwguard:cmd-reactor*
      (vlr-command-reactor nil
        (list (cons :vlr-commandWillStart 'mwguard:cmd-will-start)
              (cons :vlr-commandEnded     'mwguard:cmd-ended)
              (cons :vlr-commandCancelled 'mwguard:cmd-clear)
              (cons :vlr-commandFailed    'mwguard:cmd-clear))))
  )
  (vl-catch-all-apply 'mwguard:log-opened nil)
)

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

(setq *mwguard:switches*
  '("GuardExplode" "GuardXrefBind" "GuardXrefMove" "GuardRefEdit" "GuardPromote"
    "GuardTextTip" "GuardGrowth" "GuardXrefOrigin"))

(defun c:CUTONCE-GUARD-STATUS ( )
  (mwguard:log (strcat "Command reactor:  " (if *mwguard:cmd-reactor* "active" "not loaded")))
  (mwguard:log (strcat "Save reactor:     " (if *mwhealth:save-reactor* "active" "not loaded")))
  (mwguard:log (strcat "Growth threshold: " (rtos (mwhealth:growth-pct) 2 0) "%"))
  (mwguard:log (strcat "Log folder:       " (mwise:log-dir)))
  (foreach k *mwguard:switches*
    (princ (strcat "\n  " (mwise:setting-label k) ": " (if (mwise:on-p k) "on" "off")
                   (if (mwise:locked-p k) "  (set by CAD admin)" "")))
  )
  (princ "\n  Change these in the CutOnce Control Center (type CUTONCE).")
  (princ)
)

(defun c:CUTONCE-GUARD-CHECKNOW ( )
  (vl-catch-all-apply 'mwhealth:check (list "Manual"))
  (princ)
)

(defun c:CUTONCE-GUARD-DUMPOBJECTS ( / counts)
  (setq counts (mwguard:object-snapshot (mwise:active-doc)))
  (if (not counts)
    (mwguard:log "No AECC* or block objects in Model Space or any layout.")
    (progn
      (mwguard:log "Raw ObjectName counts (Model Space + all layouts):")
      (foreach pair (vl-sort counts (function (lambda (a b) (< (car a) (car b)))))
        (princ (strcat "\n  " (car pair) " = " (itoa (cdr pair))))
      )
    )
  )
  (princ)
)

(defun c:CUTONCE-GUARD-LOG ( )
  (mwguard:log (strcat "Health history: " (mwhealth:path)))
  (mwguard:log (strcat "Xref detail:    " (mwhealth:xrefs-path)))
  (mwguard:log (strcat "Event log:      " (mwise:events-path)))
  (mwguard:log (strcat "Opened log:     " (mwguard:opened-path)))
  (mwguard:log (strcat "Logging is " (if (mwise:on-p "LogEnabled") "on." "OFF (turn it on in the Control Center: CUTONCE).")))
  (princ)
)

;; Index of a column in a CSV header line, or nil.
(defun mwguard:col (header name)
  (if header (vl-position name (mwise:csv-split header ",")))
)

;; Every drawing seen in Opened.csv or Health.csv, its latest health row and
;; its flagged-event count, whether or not it is open now.
(defun mwguard:summary ( / lines hdr ip in it fields dp dn pair byDraw evcounts lastRow names vals)
  (setq byDraw nil)
  ;; Opened.csv
  (setq lines (mwise:read-lines (mwguard:opened-path)) hdr (car lines)
        ip (mwguard:col hdr "DrawingPath") in (mwguard:col hdr "DrawingName"))
  (if (and ip in)
    (foreach line (cdr lines)
      (setq fields (mwise:csv-split line ","))
      (if (> (length fields) (max ip in))
        (progn
          (setq dp (nth ip fields) dn (nth in fields))
          (if (not (assoc dp byDraw)) (setq byDraw (cons (cons dp (cons dn nil)) byDraw)))
        )
      )
    )
  )
  ;; Health.csv (current layout only; archived files are not read)
  (setq lines (mwise:read-lines (mwhealth:path)) hdr (car lines))
  (if (= hdr (mwhealth:header))
    (progn
      (setq ip (mwguard:col hdr "DrawingPath") in (mwguard:col hdr "DrawingName"))
      (foreach line (cdr lines)
        (setq fields (mwise:csv-split line ","))
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
  (setq evcounts nil lines (mwise:read-lines (mwise:events-path)) hdr (car lines)
        ip (mwguard:col hdr "DrawingPath"))
  (if ip
    (foreach line (cdr lines)
      (setq fields (mwise:csv-split line ","))
      (if (> (length fields) ip)
        (progn
          (setq dp (nth ip fields) pair (assoc dp evcounts))
          (setq evcounts (if pair (subst (cons dp (1+ (cdr pair))) pair evcounts) (cons (cons dp 1) evcounts)))
        )
      )
    )
  )
  (if (not byDraw)
    (mwguard:log "Nothing tracked yet - open or save a drawing first.")
    (progn
      (mwguard:log (strcat (itoa (length byDraw)) " drawing(s) tracked:"))
      (foreach row byDraw
        (setq dp (car row) dn (cadr row) lastRow (cddr row))
        (princ (strcat "\n  " dn "  (" dp ")"))
        (princ (strcat "\n    flagged events: " (itoa (cond ((cdr (assoc dp evcounts))) (0)))))
        (if lastRow
          (progn
            (princ (strcat "\n    last check: " (nth 0 lastRow) " (" (nth 1 lastRow) ")\n    "))
            (setq names (mwhealth:columns) vals lastRow)
            (while (and vals names)
              (if (not (member (car names) *mwhealth:id-columns*))
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
  (setq r (vl-catch-all-apply 'mwguard:summary nil))
  (if (vl-catch-all-error-p r) (mwguard:log (strcat "Summary failed: " (vl-catch-all-error-message r))))
  (princ)
)

(defun c:CUTONCE-GUARD-LOGCOMMANDS ( )
  (setq *mwguard:logall* (not *mwguard:logall*))
  (mwguard:log
    (if *mwguard:logall*
      "Command echo ON - every command name prints as it starts. Run CUTONCE-GUARD-LOGCOMMANDS again to stop."
      "Command echo OFF."))
  (princ)
)

(mwguard:init)
(princ)
