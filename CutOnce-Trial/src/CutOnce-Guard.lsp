;;; ============================================================================
;;; CutOnce-Guard.lsp  (TRIAL)
;;;
;;; Copyright (c) 2026 Stephen Walz. All rights reserved.
;;;
;;; CutOnce Trial: the EXPLODE warning only.
;;; To unlock the full version, reach out to stevewalz@hotmail.com
;;;
;;; Warns the designer when EXPLODE converts any Civil 3D object (any AECC*
;;; type), block reference or hatch into plain geometry. Also catches
;;; attributed blocks being converted to text, which covers BURST (BURST runs
;;; EXPLODE internally). Switched by WarnEXPLODE in CUTONCE, and follows the
;;; designer's frequency choice (every time, or once per command per session).
;;;
;;; The warning appears after the command (type U to undo).
;;;
;;; Naming: every function and global here starts with coguard: / *coguard:.
;;; Requires CutOnce-Core.lsp.
;;; ============================================================================

(vl-load-com)

(defun coguard:log (msg) (cutonce:msg "CutOnce Guard" msg))

(setq *coguard:logall* nil)

(defun coguard:trace (msg)
  (if *coguard:logall* (princ (strcat "\n[CutOnce Guard TRACE] " msg)))
  (princ)
)

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

;; ---------------------------------------------------------------------------
;; EXPLODE
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
       (cutonce:notice-once "GUARD_EXPLODE"
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
    (cutonce:notice-once "GUARD_ATTRIB"
      (strcat
        "CutOnce Guard: EXPLODE just converted " (itoa (- before after)) " attributed block(s)\n"
        "into plain text and geometry (BURST does this too).\n\n"
        "The attribute data used for tags, schedules and data extraction is gone;\n"
        "only the displayed text remains.\n\n"
        "If this wasn't intentional, type U now to undo."
      )
      "GUARD_ATTRIB"
    )
    (coguard:trace "EXPLODE ended - attributed-block count did not decrease.")
  )
)

;; ---------------------------------------------------------------------------
;; Command reactor. A switched-off warning costs nothing (no snapshot is taken).
;; ---------------------------------------------------------------------------

(defun coguard:cmd-will-start (reactor arglist)
  (vl-catch-all-apply 'coguard:cmd-will-start-body (list arglist))
  (princ)
)

(defun coguard:cmd-will-start-body (arglist / cmd doc)
  (setq cmd (strcase (car arglist)))
  (if *coguard:logall* (princ (strcat "\n[CutOnce Guard] command: " cmd)))
  (if (and (= cmd "EXPLODE") (cutonce:cmd-warn-p "WarnEXPLODE"))
    (setq doc (cutonce:active-doc)
          *coguard:explode-snapshot* (coguard:object-snapshot doc)
          *coguard:explode-attrib-snapshot* (coguard:attrib-block-count doc))
  )
)

(defun coguard:cmd-ended (reactor arglist)
  (vl-catch-all-apply 'coguard:cmd-ended-body (list arglist))
  (princ)
)

(defun coguard:cmd-ended-body (arglist / cmd doc)
  (setq cmd (strcase (car arglist)))
  (if (= cmd "EXPLODE")
    (progn
      (setq doc (cutonce:active-doc))
      (if *coguard:explode-snapshot*
        (coguard:report-civil-loss *coguard:explode-snapshot* (coguard:object-snapshot doc)))
      (if *coguard:explode-attrib-snapshot*
        (coguard:report-attrib-loss *coguard:explode-attrib-snapshot* (coguard:attrib-block-count doc)))
      (setq *coguard:explode-snapshot* nil *coguard:explode-attrib-snapshot* nil)
    )
  )
)

(defun coguard:cmd-clear (reactor arglist)
  (setq *coguard:explode-snapshot* nil
        *coguard:explode-attrib-snapshot* nil)
  (princ)
)

;; ---------------------------------------------------------------------------
;; Reactor. Kept in a global so it is not garbage-collected; guarded so a
;; reload does not stack duplicates.
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
)

(coguard:init)
(princ)
