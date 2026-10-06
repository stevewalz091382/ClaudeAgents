;;; ==========================================================================
;;; ByLayerCheck.lsp  -  Drawing standards check on open for Civil 3D
;;;
;;; When a saved drawing opens, this counts:
;;;   - Objects whose COLOR is not ByLayer      (ByBlock, ACI, or True Color)
;;;   - Objects whose LINETYPE is not ByLayer   (ByBlock or a named linetype)
;;;   - XREFs: total, broken (file not found), and unloaded
;;;   - DREFs (Civil 3D data shortcut references): total and out of date
;;; and shows the counts in a warning dialog.
;;;
;;; Settings come from ByLayerCheck-Config.lsp (*blc:config*), loaded first
;;; by ByLayerCheck-Loader.lsp.
;;;
;;; Commands:
;;;   BLCHECK          run the check now and always show the dialog
;;;   BLCHECK-STATUS   version, install folder and current settings
;;; ==========================================================================

(vl-load-com)

(setq *blc:version* "1.0.0")
(setq *blc:publisher* "Stephen Walz")

;;; ---- Settings -------------------------------------------------------------

;; Value of KEY in *blc:config*, or DEFAULT when the key is missing.
(defun blc:cfg (key default / pair)
  (if (and (boundp '*blc:config*)
           (= (type *blc:config*) 'LIST)
           (setq pair (assoc key *blc:config*))
      )
    (cdr pair)
    default
  )
)

;;; ---- Color and linetype ---------------------------------------------------

;; Adds one entity's results to COUNTS, a list of (color linetype either).
;; DXF 62 is missing, or 256, when the color is ByLayer. DXF 6 is missing
;; when the linetype is ByLayer.
(defun blc:tally (ed counts / c lt badC badL)
  (setq badC (and (setq c (cdr (assoc 62 ed))) (/= c 256))
        badL (and (setq lt (cdr (assoc 6 ed))) (/= (strcase lt) "BYLAYER"))
  )
  (list (+ (car counts) (if badC 1 0))
        (+ (cadr counts) (if badL 1 0))
        (+ (caddr counts) (if (or badC badL) 1 0))
  )
)

;; Model space and every paper space layout.
(defun blc:scan-spaces (/ ss i counts)
  (setq counts '(0 0 0))
  (if (setq ss (ssget "_X"))
    (repeat (setq i (sslength ss))
      (setq counts (blc:tally (entget (ssname ss (setq i (1- i)))) counts))
    )
  )
  counts
)

;; Named block definitions. Skips xrefs, xref-dependent blocks, and
;; anonymous blocks (*U dynamic, *D dimension, *X hatch), which are mostly
;; ByBlock by design and would only add noise.
(defun blc:scan-blocks (/ rec name flag ent ed counts)
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
          (setq counts (blc:tally ed counts)
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
(defun blc:file-found (path / pre)
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
(defun blc:scan-xrefs (/ rec flag path total broken unloaded)
  (setq total 0 broken 0 unloaded 0)
  (while (setq rec (tblnext "BLOCK" (null rec)))
    (setq flag (cdr (assoc 70 rec)))
    (if (= 4 (logand flag 4))
      (progn
        (setq total (1+ total)
              path  (cdr (assoc 1 (entget (tblobjname "BLOCK" (cdr (assoc 2 rec))))))
        )
        (cond
          ((= 32 (logand flag 32)))                             ; loaded and resolved
          ((blc:file-found path) (setq unloaded (1+ unloaded))) ; file exists, not loaded
          (T (setq broken (1+ broken)))                         ; file cannot be found
        )
      )
    )
  )
  (list total broken unloaded)
)

;;; ---- DREFs (Civil 3D data shortcut references) -----------------------------

;; T when OBJ exposes any property in PROPS and its value is true, nil when
;; it exposes one and none are true, 'NONE when it exposes none of them.
(defun blc:prop (obj props / found result v)
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
(defun blc:scan-drefs (/ ss i obj isRef apiFound total stale)
  (setq total 0 stale 0)
  (if (setq ss (ssget "_X" '((0 . "AECC_*"))))
    (repeat (setq i (sslength ss))
      (setq obj   (vlax-ename->vla-object (ssname ss (setq i (1- i))))
            isRef (blc:prop obj '("IsReferenceObject" "IsDataReference"))
      )
      (if (/= isRef 'NONE) (setq apiFound T))
      (if (= isRef T)
        (progn
          (setq total (1+ total))
          (if (= T (blc:prop obj '("IsReferenceStale" "IsReferenceOutOfDate")))
            (setq stale (1+ stale))
          )
        )
      )
    )
  )
  (list apiFound total stale)
)

;;; ---- Report ---------------------------------------------------------------

(defun blc:check (manual / blocks drefs sp bl xr dr issues msg)
  (setq blocks (blc:cfg "ScanBlocks" T)
        drefs  (blc:cfg "ScanDrefs" T)
        sp     (blc:scan-spaces)
        bl     (if blocks (blc:scan-blocks) '(0 0 0))
        xr     (blc:scan-xrefs)
        dr     (if drefs (blc:scan-drefs) '(nil 0 0))
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
      (if blocks
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
      (cond
        ((not drefs) "")
        ((car dr)
         (strcat
           "\n\nDATA REFERENCES (DREFS)"
           "\n   Total drefs:            " (itoa (cadr dr))
           "\n   Broken / out of date:   " (itoa (caddr dr))
         )
        )
        ("\n\nDATA REFERENCES (DREFS)\n   None found (or not exposed by the Civil 3D API)")
      )
    )
  )
  (princ (strcat "\n" msg "\n"))
  (if (or manual issues (blc:cfg "AlwaysShow" nil))
    (alert msg)
  )
  (princ)
)

;; Runs the check without letting an error stop the drawing from loading.
(defun blc:safe-check (manual / r)
  (setq r (vl-catch-all-apply 'blc:check (list manual)))
  (if (vl-catch-all-error-p r)
    (princ (strcat "\n[ByLayerCheck] Check failed: " (vl-catch-all-error-message r)))
  )
  (princ)
)

;;; ---- Commands -------------------------------------------------------------

(defun c:BLCHECK () (blc:safe-check T))

(defun c:BLCHECK-STATUS ()
  (princ (strcat "\nByLayerCheck " *blc:version* " - published by " *blc:publisher*))
  (princ (strcat "\n  Install folder:  "
                 (if (and (boundp '*blc:home*) *blc:home*) *blc:home* "(not set)")))
  (princ (strcat "\n  CheckOnOpen:     " (if (blc:cfg "CheckOnOpen" T) "on" "off")))
  (princ (strcat "\n  AlwaysShow:      " (if (blc:cfg "AlwaysShow" nil) "on" "off")))
  (princ (strcat "\n  ScanBlocks:      " (if (blc:cfg "ScanBlocks" T) "on" "off")))
  (princ (strcat "\n  ScanDrefs:       " (if (blc:cfg "ScanDrefs" T) "on" "off")))
  (princ)
)

;;; ---- Run on open ----------------------------------------------------------
;;; This file loads once into each drawing as it opens, after the drawing's
;;; objects are in memory. New, unsaved drawings (Drawing1.dwg) are skipped.

(if (and (blc:cfg "CheckOnOpen" T)
         (= 1 (getvar "DWGTITLED"))
    )
  (blc:safe-check nil)
)

(princ)
