;;; ==========================================================================
;;; ByLayerCheck.lsp  -  Drawing audit on open for Civil 3D 2027
;;;
;;; When a saved drawing opens, this file counts:
;;;   - Objects whose COLOR is not ByLayer      (ByBlock, ACI, or True Color)
;;;   - Objects whose LINETYPE is not ByLayer   (ByBlock or a named linetype)
;;;   - XREFs: total, broken (file not found), and unloaded
;;;   - DREFs (Civil 3D data shortcut references): total and out of date
;;; It then shows the counts in a warning dialog.
;;;
;;; RUN ON OPEN:  add this line to acaddoc.lsp (or put this file in the
;;;               APPLOAD Startup Suite):
;;;                   (load "ByLayerCheck.lsp")
;;; MANUAL RUN:   type BLCHECK at the command line.
;;; ==========================================================================

(vl-load-com)

;;; ---- Options -------------------------------------------------------------
(setq *BLC-AlwaysShow* nil) ; T = show the dialog even when nothing is wrong
(setq *BLC-ScanBlocks* T)   ; T = also check objects inside named block definitions

;;; ---- Color and linetype ---------------------------------------------------

;; Adds one entity's results to COUNTS, a list of (color linetype either).
;; DXF 62 is missing, or 256, when the color is ByLayer. DXF 6 is missing
;; when the linetype is ByLayer.
(defun BLC:Tally (ed counts / c lt badC badL)
  (setq badC (and (setq c (cdr (assoc 62 ed))) (/= c 256))
        badL (and (setq lt (cdr (assoc 6 ed))) (/= (strcase lt) "BYLAYER"))
  )
  (list (+ (car counts) (if badC 1 0))
        (+ (cadr counts) (if badL 1 0))
        (+ (caddr counts) (if (or badC badL) 1 0))
  )
)

;; Model space and every paper space layout.
(defun BLC:ScanSpaces (/ ss i counts)
  (setq counts '(0 0 0))
  (if (setq ss (ssget "_X"))
    (repeat (setq i (sslength ss))
      (setq counts (BLC:Tally (entget (ssname ss (setq i (1- i)))) counts))
    )
  )
  counts
)

;; Named block definitions. Skips xrefs, xref-dependent blocks, and
;; anonymous blocks (*U dynamic, *D dimension, *X hatch), which are mostly
;; ByBlock by design and would only add noise.
(defun BLC:ScanBlocks (/ rec name flag ent ed counts)
  (setq counts '(0 0 0))
  (while (setq rec (tblnext "BLOCK" (null rec)))
    (setq name (cdr (assoc 2 rec))
          flag (cdr (assoc 70 rec))
    )
    (if (and (/= (substr name 1 1) "*")
             (zerop (logand flag (+ 4 16)))
        )
      (progn
        (setq ent (cdr (assoc -2 rec)))
        (while (and ent
                    (setq ed (entget ent))
                    (/= (cdr (assoc 0 ed)) "ENDBLK")
               )
          (setq counts (BLC:Tally ed counts)
                ent    (entnext ent)
          )
        )
      )
    )
  )
  counts
)

;;; ---- XREFs ----------------------------------------------------------------

;; Looks for an xref file at its saved path, relative to the drawing's
;; folder, and by file name alone in the drawing's folder.
(defun BLC:FileFound (path / pre)
  (setq pre (getvar "DWGPREFIX"))
  (cond
    ((or (null path) (= path "")) nil)
    ((findfile path))
    ((findfile (strcat pre path)))
    ((findfile (strcat pre
                       (vl-filename-base path)
                       (cond ((vl-filename-extension path)) (".dwg"))
               )
     )
    )
  )
)

;; Returns (total broken unloaded).
;; Block flag 4 = xref, flag 32 = xref is resolved (loaded).
(defun BLC:ScanXrefs (/ rec flag path total broken unloaded)
  (setq total 0 broken 0 unloaded 0)
  (while (setq rec (tblnext "BLOCK" (null rec)))
    (setq flag (cdr (assoc 70 rec)))
    (if (= 4 (logand flag 4))
      (progn
        (setq total (1+ total)
              path  (cdr (assoc 1 (entget (tblobjname "BLOCK" (cdr (assoc 2 rec))))))
        )
        (cond
          ((= 32 (logand flag 32)))                        ; loaded and resolved
          ((BLC:FileFound path) (setq unloaded (1+ unloaded))) ; file exists, not loaded
          (T (setq broken (1+ broken)))                    ; file cannot be found
        )
      )
    )
  )
  (list total broken unloaded)
)

;;; ---- DREFs (Civil 3D data shortcut references) -----------------------------

;; True when OBJ exposes any property in PROPS and its value is true.
;; Returns 'NONE when OBJ exposes none of them.
(defun BLC:Prop (obj props / found result v)
  (foreach p props
    (if (and (not result) (vlax-property-available-p obj p))
      (progn
        (setq found T
              v     (vl-catch-all-apply 'vlax-get-property (list obj p))
        )
        (if (= (type v) 'VARIANT) (setq v (vlax-variant-value v)))
        (if (member v (list :vlax-true -1 T)) (setq result T))
      )
    )
  )
  (cond (result T) (found nil) ('NONE))
)

;; Returns (apiFound total stale).
;; apiFound is nil when no Civil 3D object in the drawing exposes a
;; reference property through COM, so the count could not be taken.
(defun BLC:ScanDrefs (/ ss i obj isRef apiFound total stale)
  (setq total 0 stale 0)
  (if (setq ss (ssget "_X" '((0 . "AECC_*"))))
    (repeat (setq i (sslength ss))
      (setq obj   (vlax-ename->vla-object (ssname ss (setq i (1- i))))
            isRef (BLC:Prop obj '("IsReferenceObject" "IsDataReference"))
      )
      (if (/= isRef 'NONE) (setq apiFound T))
      (if (= isRef T)
        (progn
          (setq total (1+ total))
          (if (= T (BLC:Prop obj '("IsReferenceStale" "IsReferenceOutOfDate")))
            (setq stale (1+ stale))
          )
        )
      )
    )
  )
  (list apiFound total stale)
)

;;; ---- Report ---------------------------------------------------------------

(defun BLC:Check (manual / sp bl xr dr issues msg)
  (setq sp (BLC:ScanSpaces)
        bl (if *BLC-ScanBlocks* (BLC:ScanBlocks) '(0 0 0))
        xr (BLC:ScanXrefs)
        dr (BLC:ScanDrefs)
  )
  (setq issues (or (> (caddr sp) 0)
                   (> (caddr bl) 0)
                   (> (cadr xr) 0)
                   (> (caddr xr) 0)
                   (> (caddr dr) 0)
               )
  )
  (setq msg
    (strcat
      (if issues "WARNING - drawing standards check\n" "Drawing standards check\n")
      (getvar "DWGNAME")
      "\n\nOBJECTS NOT BYLAYER (model space and layouts)"
      "\n   Color not ByLayer:      " (itoa (car sp))
      "\n   Linetype not ByLayer:   " (itoa (cadr sp))
      "\n   Objects with either:    " (itoa (caddr sp))
      (if *BLC-ScanBlocks*
        (strcat
          "\n\nINSIDE BLOCK DEFINITIONS"
          "\n   Color not ByLayer:      " (itoa (car bl))
          "\n   Linetype not ByLayer:   " (itoa (cadr bl))
        )
        ""
      )
      "\n\nXREFS"
      "\n   Total xrefs:            " (itoa (car xr))
      "\n   Broken (not found):     " (itoa (cadr xr))
      "\n   Unloaded:               " (itoa (caddr xr))
      "\n\nDATA REFERENCES (DREFS)"
      (if (car dr)
        (strcat
          "\n   Total drefs:            " (itoa (cadr dr))
          "\n   Broken / out of date:   " (itoa (caddr dr))
        )
        "\n   None found (or not exposed by the Civil 3D API)"
      )
    )
  )
  (princ (strcat "\n" msg "\n"))
  (if (or manual issues *BLC-AlwaysShow*)
    (alert msg)
  )
  (princ)
)

(defun c:BLCHECK () (BLC:Check T))

;;; ---- Run on open ----------------------------------------------------------
;;; S::STARTUP runs after the drawing finishes loading, so Civil 3D objects
;;; are ready. Skips new, unsaved drawings (Drawing1.dwg).
(defun-q BLC:OnOpen ()
  (if (= 1 (getvar "DWGTITLED")) (BLC:Check nil))
)
(if (or (null S::STARTUP) (= (type S::STARTUP) 'LIST))
  (setq S::STARTUP (append S::STARTUP BLC:OnOpen))
  (BLC:OnOpen) ; S::STARTUP was defined with DEFUN and cannot be appended to
)

(princ "\nByLayerCheck loaded. Type BLCHECK to run it manually.")
(princ)
