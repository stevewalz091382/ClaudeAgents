;;; ============================================================================
;;; CutOnce-Standards.lsp
;;;
;;; Drawing standards scan:
;;;   - objects whose COLOR is not ByLayer      (ByBlock, ACI or True Color)
;;;   - objects whose LINETYPE is not ByLayer   (ByBlock or a named linetype)
;;;   - the same two checks inside named block definitions (optional)
;;;   - xrefs: total, broken (file not found), unloaded
;;;   - xref inserts in Model Space that are not at 0,0,0
;;;
;;; One pass over Model Space and every layout also collects the object counts
;;; CutOnce Health writes to Health.csv, so the drawing is only read once.
;;;
;;; The scan uses COM, so CUTONCE-AUDIT can run it on any open drawing. In the
;;; drawing this namespace belongs to, entity data (entget) is used for color,
;;; linetype and xref flags because it is faster and exact.
;;;
;;; When a saved drawing opens, the result is shown in a dialog if anything
;;; is wrong (or always, if the user chose that in CUTONCE).
;;;
;;; Commands:
;;;   CUTONCE-CHECK          run the check now and always show the result
;;;   CUTONCE-CHECK-STATUS   current standards-check settings
;;;
;;; Naming: every function and global here starts with costd: / *costd:.
;;; Requires CutOnce-Core.lsp.
;;; ============================================================================

(vl-load-com)

(defun costd:log (msg) (cutonce:msg "CutOnce Standards" msg))

;; ---------------------------------------------------------------------------
;; Entity helpers
;; ---------------------------------------------------------------------------

;; DXF data of a VLA entity, or nil when it cannot be read from this namespace.
(defun costd:ent-data (obj / en)
  (setq en (vl-catch-all-apply 'vlax-vla-object->ename (list obj)))
  (if (= (type en) 'ENAME) (entget en))
)

;; (badColor badLinetype) for one entity. DXF 62 is missing, or 256, when the
;; color is ByLayer; DXF 6 is missing when the linetype is ByLayer. Without
;; DXF data, the COM Color (256 = ByLayer) and Linetype properties are used.
(defun costd:bylayer-flags (obj ed / c lt)
  (if ed
    (setq c (cdr (assoc 62 ed)) lt (cdr (assoc 6 ed)))
    (setq c (cutonce:prop obj 'Color) lt (cutonce:str-prop obj 'Linetype))
  )
  (list (if (and (numberp c) (/= c 256)) T)
        (if (and (= (type lt) 'STR) (/= (strcase lt) "BYLAYER")) T))
)

(defun costd:bump (alist key / pair)
  (if (setq pair (assoc key alist))
    (subst (cons key (1+ (cdr pair))) pair alist)
    (cons (cons key 1) alist)
  )
)

(defun costd:variant->list (v / r)
  (setq r (vl-catch-all-apply
            (function (lambda ()
              (cond ((listp v) v)
                    ((= (type v) 'VARIANT) (vlax-safearray->list (vlax-variant-value v)))
                    ((= (type v) 'SAFEARRAY) (vlax-safearray->list v)))))))
  (if (vl-catch-all-error-p r) nil r)
)

;; (point rotation-degrees x-scale) of a block reference
(defun costd:insert-data (obj ed / pt rot sc)
  (if ed
    (setq pt  (cdr (assoc 10 ed))
          rot (cond ((cdr (assoc 50 ed))) (0.0))
          sc  (cond ((cdr (assoc 41 ed))) (1.0)))
    (setq pt  (costd:variant->list (cutonce:prop obj 'InsertionPoint))
          rot (cond ((cutonce:prop obj 'Rotation)) (0.0))
          sc  (cond ((cutonce:prop obj 'XScaleFactor)) (1.0)))
  )
  (if (and pt (= (length pt) 2)) (setq pt (append pt '(0.0))))
  (list pt (* 180.0 (/ (float rot) pi)) (float sc))
)

(defun costd:near-zero-p (pt / tol)
  (setq tol 1e-6)
  (and pt (< (abs (car pt)) tol) (< (abs (cadr pt)) tol) (< (abs (caddr pt)) tol))
)

(defun costd:pt-text (pt)
  (if pt
    (strcat (rtos (car pt) 2 3) ", " (rtos (cadr pt) 2 3) ", " (rtos (caddr pt) 2 3))
    "?"
  )
)

;; ---------------------------------------------------------------------------
;; Xref definitions
;; ---------------------------------------------------------------------------

(defun costd:doc-prefix (doc / p)
  (cond
    ((cutonce:context-doc-p doc) (getvar "DWGPREFIX"))
    ((setq p (cutonce:nonblank (cutonce:str-prop doc 'Path))) (cutonce:dir-slash p))
    ("")
  )
)

;; Looks for an xref file at its saved path, relative to the drawing's folder,
;; and by file name alone in the drawing's folder.
(defun costd:file-found (path prefix)
  (cond
    ((or (null path) (= path "")) nil)
    ((findfile path))
    ((and (/= prefix "") (findfile (strcat prefix path))))
    ((and (/= prefix "")
          (findfile (strcat prefix (vl-filename-base path)
                            (cond ((vl-filename-extension path)) (".dwg"))))))
  )
)

;; Upper-case names of every xref block (for matching block references).
(defun costd:xref-block-names (doc / names)
  (setq names nil)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for blk (vla-get-Blocks doc)
        (if (eq (cutonce:prop blk 'IsXRef) :vlax-true)
          (setq names (cons (strcase (cond ((cutonce:str-prop blk 'Name)) (""))) names)))))))
  names
)

;; One xref definition: (name path type status nested)
;;   type    "Attach" / "Overlay" / "" (unknown)
;;   status  "Loaded" / "Unloaded" / "Not Found"
;; Block flags (from the block table): 8 = overlay, 32 = resolved (loaded).
;; Nested xrefs carry their parent's name: "PARENT|CHILD".
(defun costd:xref-def (blk context prefix / name path rec flags loaded xtype db status)
  (setq name (cond ((cutonce:str-prop blk 'Name)) ("")))
  (setq path (cond ((cutonce:str-prop blk 'Path)) ("")))
  (if (and context (setq rec (tblsearch "BLOCK" name)))
    (progn
      (setq flags (cond ((cdr (assoc 70 rec))) (0)))
      (setq loaded (= 32 (logand flags 32))
            xtype (if (= 8 (logand flags 8)) "Overlay" "Attach"))
      (if (= path "")
        (setq path (cond ((cdr (assoc 1 (entget (tblobjname "BLOCK" name))))) (""))))
    )
    (progn
      ;; XRefDatabase is only available for a loaded xref
      (setq db (vl-catch-all-apply 'vla-get-XRefDatabase (list blk)))
      (setq loaded (and (not (vl-catch-all-error-p db)) db)
            xtype "")
    )
  )
  (setq status (cond (loaded "Loaded")
                     ((costd:file-found path prefix) "Unloaded")
                     (T "Not Found")))
  (list name path xtype status (if (vl-string-search "|" name) "Yes" "No"))
)

(defun costd:xref-defs (doc / context prefix out)
  (setq context (cutonce:context-doc-p doc) prefix (costd:doc-prefix doc) out nil)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for blk (vla-get-Blocks doc)
        (if (eq (cutonce:prop blk 'IsXRef) :vlax-true)
          (setq out (cons (costd:xref-def blk context prefix) out)))))))
  (reverse out)
)

;; ---------------------------------------------------------------------------
;; Model Space and layouts: one pass
;; ---------------------------------------------------------------------------

;; Called for each entity by costd:scan-spaces. Updates that function's
;; local counters (AutoLISP variables are dynamically scoped).
(defun costd:tally (obj ismodel / oname ed flags bname)
  (setq oname (cutonce:object-name obj))
  (if (or countall (= oname "AcDbBlockReference") (wcmatch (strcase oname) "AECC*"))
    (setq objcounts (costd:bump objcounts oname))
  )
  (setq ed (costd:ent-data obj))
  (setq flags (costd:bylayer-flags obj ed))
  (if (car flags) (setq colN (1+ colN)))
  (if (cadr flags) (setq ltN (1+ ltN)))
  (if (or (car flags) (cadr flags)) (setq eitherN (1+ eitherN)))
  (if ismodel
    (cond
      ((= oname "AcDbHatch") (setq hatchN (1+ hatchN)))
      ((member oname '("AcDbText" "AcDbMText")) (setq textN (1+ textN)))
      ((and (= oname "AcDbBlockReference")
            xrefnames
            (setq bname (cutonce:str-prop obj 'Name))
            (member (strcase bname) xrefnames))
       (setq inserts (cons (cons bname (costd:insert-data obj ed)) inserts)))
    )
  )
)

;; Returns an association list:
;;   ("objcounts" . ((ObjectName . n) ...))  AECC* objects and block references
;;                                            (every type when HealthExtraCounts is set)
;;   ("Hatches" . n) ("TextObjects" . n)      Model Space only
;;   ("ColorNotByLayer" . n) ("LinetypeNotByLayer" . n) ("ObjectsNotByLayer" . n)
;;   ("inserts" . ((name point rotation scale) ...))   xref inserts, Model Space
(defun costd:scan-spaces (doc / xrefnames spaces blk objcounts hatchN textN colN ltN eitherN inserts countall)
  (setq xrefnames (costd:xref-block-names doc)
        objcounts nil hatchN 0 textN 0 colN 0 ltN 0 eitherN 0 inserts nil
        countall (if (cutonce:health-extra-counts) T))
  (setq spaces (list (cons (vla-get-ModelSpace doc) T)))
  ;; the Layouts collection includes "Model"; skip it so Model Space is read once
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for lay (vla-get-Layouts doc)
        (if (and (eq (cutonce:prop lay 'ModelType) :vlax-false) (setq blk (cutonce:prop lay 'Block)))
          (setq spaces (cons (cons blk nil) spaces)))))))
  (foreach sp (reverse spaces)
    (vl-catch-all-apply
      (function (lambda ()
        (vlax-for obj (car sp)
          (vl-catch-all-apply 'costd:tally (list obj (cdr sp))))))))
  (list (cons "objcounts" objcounts)
        (cons "Hatches" hatchN)
        (cons "TextObjects" textN)
        (cons "ColorNotByLayer" colN)
        (cons "LinetypeNotByLayer" ltN)
        (cons "ObjectsNotByLayer" eitherN)
        (cons "inserts" (reverse inserts)))
)

;; Named block definitions. Skips layouts, xrefs, xref-dependent blocks and
;; anonymous blocks (*U dynamic, *D dimension, *X hatch), which are mostly
;; ByBlock by design and would only add noise. Returns (color linetype).
(defun costd:scan-block-defs (doc / colN ltN name)
  (setq colN 0 ltN 0)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for blk (vla-get-Blocks doc)
        (setq name (cond ((cutonce:str-prop blk 'Name)) ("*")))
        (if (and (/= (substr name 1 1) "*")
                 (not (vl-string-search "|" name))
                 (not (eq (cutonce:prop blk 'IsLayout) :vlax-true))
                 (not (eq (cutonce:prop blk 'IsXRef) :vlax-true)))
          (vl-catch-all-apply
            (function (lambda ( / flags)
              (vlax-for obj blk
                (setq flags (costd:bylayer-flags obj (costd:ent-data obj)))
                (if (car flags) (setq colN (1+ colN)))
                (if (cadr flags) (setq ltN (1+ ltN)))))))
        )
      )
    ))
  )
  (list colN ltN)
)

;; ---------------------------------------------------------------------------
;; Everything the standards check and Health.csv need, in one call.
;;   ("xrefdetail" . ((name path type status nested instances point rotation
;;                     scale atOrigin) ...))
;;   ("offorigin"  . ((name point) ...))   Model Space inserts not at 0,0,0
;; Block-definition counts are "n/a" when scanblocks is nil.
;; ---------------------------------------------------------------------------

(defun costd:collect (doc scanblocks / spaces bdefs xdefs inserts detail mine first off
                                        broken unloaded offlist)
  (setq spaces (costd:scan-spaces doc))
  (setq bdefs (if scanblocks (costd:scan-block-defs doc) '("n/a" "n/a")))
  (setq xdefs (costd:xref-defs doc))
  (setq inserts (cdr (assoc "inserts" spaces)))
  (setq detail nil broken 0 unloaded 0 offlist nil)
  (foreach xd xdefs
    (setq mine (vl-remove-if-not
                 (function (lambda (i) (= (strcase (car i)) (strcase (car xd)))))
                 inserts))
    (setq off (vl-remove-if (function (lambda (i) (costd:near-zero-p (cadr i)))) mine))
    (foreach i off (setq offlist (cons (list (car i) (cadr i)) offlist)))
    (setq first (car mine))
    (setq detail
      (cons (append xd
                    (list (length mine)
                          (if first (cadr first))
                          (if first (caddr first))
                          (if first (cadddr first))
                          (cond ((null mine) "") (off "No") (T "Yes"))))
            detail))
    (cond ((= (nth 3 xd) "Not Found") (setq broken (1+ broken)))
          ((= (nth 3 xd) "Unloaded")  (setq unloaded (1+ unloaded))))
  )
  (append
    (vl-remove (assoc "inserts" spaces) spaces)
    (list (cons "BlockDefColorNotByLayer" (car bdefs))
          (cons "BlockDefLinetypeNotByLayer" (cadr bdefs))
          (cons "Xrefs" (length xdefs))
          (cons "XrefsBroken" broken)
          (cons "XrefsUnloaded" unloaded)
          (cons "XrefsOffOrigin" (length offlist))
          (cons "xrefdetail" (reverse detail))
          (cons "offorigin" (reverse offlist))))
)

(defun costd:fact (facts key) (cdr (assoc key facts)))

(defun costd:num (v) (if (numberp v) (itoa v) (vl-princ-to-string v)))

;; ---------------------------------------------------------------------------
;; Report
;;
;; manual = T (CUTONCE-CHECK): every section is shown and the dialog always opens.
;; Otherwise only the sections switched on in CUTONCE are shown and
;; the dialog opens only when one of them finds a problem (or "always show"
;; is on). The result is always printed on the command line.
;; ---------------------------------------------------------------------------

(defun costd:show-report (facts drawname manual / wantBL wantXS wantXO issBL issXS issXO issues lines msg bdc links)
  (setq wantBL (or manual (cutonce:on-p "StdByLayer"))
        wantXS (or manual (cutonce:on-p "StdXrefStatus"))
        wantXO (or manual (cutonce:on-p "StdXrefOrigin"))
        bdc    (costd:fact facts "BlockDefColorNotByLayer"))
  (setq issBL (and wantBL
                   (or (> (costd:fact facts "ObjectsNotByLayer") 0)
                       (and (numberp bdc)
                            (> (+ bdc (costd:fact facts "BlockDefLinetypeNotByLayer")) 0))))
        issXS (and wantXS (> (+ (costd:fact facts "XrefsBroken") (costd:fact facts "XrefsUnloaded")) 0))
        issXO (and wantXO (> (costd:fact facts "XrefsOffOrigin") 0)))
  (setq issues (or issBL issXS issXO))
  ;; one Learn More button per problem found, plus how to read the check
  (setq links (list (cons "Reading this check..." "STANDARDS_OPEN")))
  (if issBL (setq links (append links (list (cons "Not ByLayer..." "STD_BYLAYER")))))
  (if issXS (setq links (append links (list (cons "Broken / unloaded xrefs..." "STD_XREF_STATUS")))))
  (if issXO (setq links (append links (list (cons "Xrefs not at 0,0,0..." "STD_XREF_ORIGIN")))))
  (setq lines (list (if issues "WARNING - drawing standards check" "Drawing standards check")
                    drawname))
  (if wantBL
    (setq lines (append lines
      (list ""
            "OBJECTS NOT BYLAYER (model space and layouts)"
            (strcat "   Color not ByLayer:      " (costd:num (costd:fact facts "ColorNotByLayer")))
            (strcat "   Linetype not ByLayer:   " (costd:num (costd:fact facts "LinetypeNotByLayer")))
            (strcat "   Objects with either:    " (costd:num (costd:fact facts "ObjectsNotByLayer"))))
      (if (numberp bdc)
        (list ""
              "INSIDE BLOCK DEFINITIONS"
              (strcat "   Color not ByLayer:      " (costd:num bdc))
              (strcat "   Linetype not ByLayer:   " (costd:num (costd:fact facts "BlockDefLinetypeNotByLayer")))))))
  )
  (if (or wantXS wantXO)
    (setq lines (append lines
      (list "" "XREFS"
            (strcat "   Total xrefs:            " (costd:num (costd:fact facts "Xrefs"))))
      (if wantXS
        (list (strcat "   Broken (not found):     " (costd:num (costd:fact facts "XrefsBroken")))
              (strcat "   Unloaded:               " (costd:num (costd:fact facts "XrefsUnloaded")))))
      (if wantXS
        (mapcar (function (lambda (x) (strcat "      " (nth 3 x) ": " (car x) "  " (cadr x))))
                (vl-remove-if (function (lambda (x) (= (nth 3 x) "Loaded")))
                              (costd:fact facts "xrefdetail"))))
      (if wantXO
        (list (strcat "   Inserts not at 0,0,0:   " (costd:num (costd:fact facts "XrefsOffOrigin")))))
      (if wantXO
        (mapcar (function (lambda (p) (strcat "      " (car p) " at " (costd:pt-text (cadr p)))))
                (costd:fact facts "offorigin")))))
  )
  (setq lines (append lines
    (list "" "Choose what is checked in the CutOnce Control Center (type CUTONCE).")))
  (setq msg (cutonce:join lines "\n"))
  (princ (strcat "\n" msg "\n"))
  (if issues
    (cutonce:log-event "STANDARDS-OPEN"
      (strcat "not ByLayer " (costd:num (costd:fact facts "ObjectsNotByLayer"))
              "  broken xrefs " (costd:num (costd:fact facts "XrefsBroken"))
              "  unloaded xrefs " (costd:num (costd:fact facts "XrefsUnloaded"))
              "  xrefs off 0,0,0 " (costd:num (costd:fact facts "XrefsOffOrigin")))))
  (if (or manual issues (cutonce:on-p "StdAlwaysShow"))
    (cutonce:notice-links msg links)
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

(defun costd:check-now ( / doc facts r)
  (setq doc (cutonce:active-doc))
  (setq r (vl-catch-all-apply
            (function (lambda ()
              (setq facts (costd:collect doc (cutonce:on-p "StdScanBlocks")))
              (costd:show-report facts (cond ((cutonce:str-prop doc 'Name)) ("")) T)))))
  (if (vl-catch-all-error-p r)
    (costd:log (strcat "Check failed: " (vl-catch-all-error-message r)))
  )
  (princ)
)

(defun c:CUTONCE-CHECK ( ) (costd:check-now))

(defun c:CUTONCE-CHECK-STATUS ( )
  (costd:log "Standards check settings (change in the Control Center: CUTONCE):")
  (foreach k '("StdCheckOnOpen" "StdByLayer" "StdXrefStatus" "StdXrefOrigin" "StdAlwaysShow" "StdScanBlocks")
    (princ (strcat "\n  " (cutonce:setting-label k) ": " (if (cutonce:on-p k) "on" "off")
                   (if (cutonce:locked-p k) "  (set by CAD admin)" "")))
  )
  (princ)
)

(princ)
