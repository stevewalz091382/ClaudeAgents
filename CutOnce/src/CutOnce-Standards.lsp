;;; ============================================================================
;;; CutOnce-Standards.lsp
;;;
;;; Drawing standards scan (formerly the separate ByLayerCheck add-on):
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
;;; Naming: every function and global here starts with mwstd: / *mwstd:.
;;; Requires CutOnce-Core.lsp.
;;; ============================================================================

(vl-load-com)

(defun mwstd:log (msg) (mwise:msg "CutOnce Standards" msg))

;; ---------------------------------------------------------------------------
;; Entity helpers
;; ---------------------------------------------------------------------------

;; DXF data of a VLA entity, or nil when it cannot be read from this namespace.
(defun mwstd:ent-data (obj / en)
  (setq en (vl-catch-all-apply 'vlax-vla-object->ename (list obj)))
  (if (= (type en) 'ENAME) (entget en))
)

;; (badColor badLinetype) for one entity. DXF 62 is missing, or 256, when the
;; color is ByLayer; DXF 6 is missing when the linetype is ByLayer. Without
;; DXF data, the COM Color (256 = ByLayer) and Linetype properties are used.
(defun mwstd:bylayer-flags (obj ed / c lt)
  (if ed
    (setq c (cdr (assoc 62 ed)) lt (cdr (assoc 6 ed)))
    (setq c (mwise:prop obj 'Color) lt (mwise:str-prop obj 'Linetype))
  )
  (list (if (and (numberp c) (/= c 256)) T)
        (if (and (= (type lt) 'STR) (/= (strcase lt) "BYLAYER")) T))
)

(defun mwstd:bump (alist key / pair)
  (if (setq pair (assoc key alist))
    (subst (cons key (1+ (cdr pair))) pair alist)
    (cons (cons key 1) alist)
  )
)

(defun mwstd:variant->list (v / r)
  (setq r (vl-catch-all-apply
            (function (lambda ()
              (cond ((listp v) v)
                    ((= (type v) 'VARIANT) (vlax-safearray->list (vlax-variant-value v)))
                    ((= (type v) 'SAFEARRAY) (vlax-safearray->list v)))))))
  (if (vl-catch-all-error-p r) nil r)
)

;; (point rotation-degrees x-scale) of a block reference
(defun mwstd:insert-data (obj ed / pt rot sc)
  (if ed
    (setq pt  (cdr (assoc 10 ed))
          rot (cond ((cdr (assoc 50 ed))) (0.0))
          sc  (cond ((cdr (assoc 41 ed))) (1.0)))
    (setq pt  (mwstd:variant->list (mwise:prop obj 'InsertionPoint))
          rot (cond ((mwise:prop obj 'Rotation)) (0.0))
          sc  (cond ((mwise:prop obj 'XScaleFactor)) (1.0)))
  )
  (if (and pt (= (length pt) 2)) (setq pt (append pt '(0.0))))
  (list pt (* 180.0 (/ (float rot) pi)) (float sc))
)

(defun mwstd:near-zero-p (pt / tol)
  (setq tol 1e-6)
  (and pt (< (abs (car pt)) tol) (< (abs (cadr pt)) tol) (< (abs (caddr pt)) tol))
)

(defun mwstd:pt-text (pt)
  (if pt
    (strcat (rtos (car pt) 2 3) ", " (rtos (cadr pt) 2 3) ", " (rtos (caddr pt) 2 3))
    "?"
  )
)

;; ---------------------------------------------------------------------------
;; Xref definitions
;; ---------------------------------------------------------------------------

(defun mwstd:doc-prefix (doc / p)
  (cond
    ((mwise:context-doc-p doc) (getvar "DWGPREFIX"))
    ((setq p (mwise:nonblank (mwise:str-prop doc 'Path))) (mwise:dir-slash p))
    ("")
  )
)

;; Looks for an xref file at its saved path, relative to the drawing's folder,
;; and by file name alone in the drawing's folder.
(defun mwstd:file-found (path prefix)
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
(defun mwstd:xref-block-names (doc / names)
  (setq names nil)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for blk (vla-get-Blocks doc)
        (if (eq (mwise:prop blk 'IsXRef) :vlax-true)
          (setq names (cons (strcase (cond ((mwise:str-prop blk 'Name)) (""))) names)))))))
  names
)

;; One xref definition: (name path type status nested)
;;   type    "Attach" / "Overlay" / "" (unknown)
;;   status  "Loaded" / "Unloaded" / "Not Found"
;; Block flags (from the block table): 8 = overlay, 32 = resolved (loaded).
;; Nested xrefs carry their parent's name: "PARENT|CHILD".
(defun mwstd:xref-def (blk context prefix / name path rec flags loaded xtype db status)
  (setq name (cond ((mwise:str-prop blk 'Name)) ("")))
  (setq path (cond ((mwise:str-prop blk 'Path)) ("")))
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
                     ((mwstd:file-found path prefix) "Unloaded")
                     (T "Not Found")))
  (list name path xtype status (if (vl-string-search "|" name) "Yes" "No"))
)

(defun mwstd:xref-defs (doc / context prefix out)
  (setq context (mwise:context-doc-p doc) prefix (mwstd:doc-prefix doc) out nil)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for blk (vla-get-Blocks doc)
        (if (eq (mwise:prop blk 'IsXRef) :vlax-true)
          (setq out (cons (mwstd:xref-def blk context prefix) out)))))))
  (reverse out)
)

;; ---------------------------------------------------------------------------
;; Model Space and layouts: one pass
;; ---------------------------------------------------------------------------

;; Called for each entity by mwstd:scan-spaces. Updates that function's
;; local counters (AutoLISP variables are dynamically scoped).
(defun mwstd:tally (obj ismodel / oname ed flags bname)
  (setq oname (mwise:object-name obj))
  (if (or (= oname "AcDbBlockReference") (wcmatch (strcase oname) "AECC*"))
    (setq objcounts (mwstd:bump objcounts oname))
  )
  (setq ed (mwstd:ent-data obj))
  (setq flags (mwstd:bylayer-flags obj ed))
  (if (car flags) (setq colN (1+ colN)))
  (if (cadr flags) (setq ltN (1+ ltN)))
  (if (or (car flags) (cadr flags)) (setq eitherN (1+ eitherN)))
  (if ismodel
    (cond
      ((= oname "AcDbHatch") (setq hatchN (1+ hatchN)))
      ((member oname '("AcDbText" "AcDbMText")) (setq textN (1+ textN)))
      ((and (= oname "AcDbBlockReference")
            xrefnames
            (setq bname (mwise:str-prop obj 'Name))
            (member (strcase bname) xrefnames))
       (setq inserts (cons (cons bname (mwstd:insert-data obj ed)) inserts)))
    )
  )
)

;; Returns an association list:
;;   ("objcounts" . ((ObjectName . n) ...))  AECC* objects and block references
;;   ("Hatches" . n) ("TextObjects" . n)      Model Space only
;;   ("ColorNotByLayer" . n) ("LinetypeNotByLayer" . n) ("ObjectsNotByLayer" . n)
;;   ("inserts" . ((name point rotation scale) ...))   xref inserts, Model Space
(defun mwstd:scan-spaces (doc / xrefnames spaces blk objcounts hatchN textN colN ltN eitherN inserts)
  (setq xrefnames (mwstd:xref-block-names doc)
        objcounts nil hatchN 0 textN 0 colN 0 ltN 0 eitherN 0 inserts nil)
  (setq spaces (list (cons (vla-get-ModelSpace doc) T)))
  ;; the Layouts collection includes "Model"; skip it so Model Space is read once
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for lay (vla-get-Layouts doc)
        (if (and (eq (mwise:prop lay 'ModelType) :vlax-false) (setq blk (mwise:prop lay 'Block)))
          (setq spaces (cons (cons blk nil) spaces)))))))
  (foreach sp (reverse spaces)
    (vl-catch-all-apply
      (function (lambda ()
        (vlax-for obj (car sp)
          (vl-catch-all-apply 'mwstd:tally (list obj (cdr sp))))))))
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
(defun mwstd:scan-block-defs (doc / colN ltN name)
  (setq colN 0 ltN 0)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for blk (vla-get-Blocks doc)
        (setq name (cond ((mwise:str-prop blk 'Name)) ("*")))
        (if (and (/= (substr name 1 1) "*")
                 (not (vl-string-search "|" name))
                 (not (eq (mwise:prop blk 'IsLayout) :vlax-true))
                 (not (eq (mwise:prop blk 'IsXRef) :vlax-true)))
          (vl-catch-all-apply
            (function (lambda ( / flags)
              (vlax-for obj blk
                (setq flags (mwstd:bylayer-flags obj (mwstd:ent-data obj)))
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

(defun mwstd:collect (doc scanblocks / spaces bdefs xdefs inserts detail mine first off
                                        broken unloaded offlist)
  (setq spaces (mwstd:scan-spaces doc))
  (setq bdefs (if scanblocks (mwstd:scan-block-defs doc) '("n/a" "n/a")))
  (setq xdefs (mwstd:xref-defs doc))
  (setq inserts (cdr (assoc "inserts" spaces)))
  (setq detail nil broken 0 unloaded 0 offlist nil)
  (foreach xd xdefs
    (setq mine (vl-remove-if-not
                 (function (lambda (i) (= (strcase (car i)) (strcase (car xd)))))
                 inserts))
    (setq off (vl-remove-if (function (lambda (i) (mwstd:near-zero-p (cadr i)))) mine))
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

(defun mwstd:fact (facts key) (cdr (assoc key facts)))

(defun mwstd:num (v) (if (numberp v) (itoa v) (vl-princ-to-string v)))

;; ---------------------------------------------------------------------------
;; Report
;;
;; manual = T (CUTONCE-CHECK): every section is shown and the dialog always opens.
;; Otherwise only the sections switched on in CUTONCE are shown and
;; the dialog opens only when one of them finds a problem (or "always show"
;; is on). The result is always printed on the command line.
;; ---------------------------------------------------------------------------

(defun mwstd:show-report (facts drawname manual / wantBL wantXS wantXO issBL issXS issXO issues lines msg bdc links)
  (setq wantBL (or manual (mwise:on-p "StdByLayer"))
        wantXS (or manual (mwise:on-p "StdXrefStatus"))
        wantXO (or manual (mwise:on-p "StdXrefOrigin"))
        bdc    (mwstd:fact facts "BlockDefColorNotByLayer"))
  (setq issBL (and wantBL
                   (or (> (mwstd:fact facts "ObjectsNotByLayer") 0)
                       (and (numberp bdc)
                            (> (+ bdc (mwstd:fact facts "BlockDefLinetypeNotByLayer")) 0))))
        issXS (and wantXS (> (+ (mwstd:fact facts "XrefsBroken") (mwstd:fact facts "XrefsUnloaded")) 0))
        issXO (and wantXO (> (mwstd:fact facts "XrefsOffOrigin") 0)))
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
            (strcat "   Color not ByLayer:      " (mwstd:num (mwstd:fact facts "ColorNotByLayer")))
            (strcat "   Linetype not ByLayer:   " (mwstd:num (mwstd:fact facts "LinetypeNotByLayer")))
            (strcat "   Objects with either:    " (mwstd:num (mwstd:fact facts "ObjectsNotByLayer"))))
      (if (numberp bdc)
        (list ""
              "INSIDE BLOCK DEFINITIONS"
              (strcat "   Color not ByLayer:      " (mwstd:num bdc))
              (strcat "   Linetype not ByLayer:   " (mwstd:num (mwstd:fact facts "BlockDefLinetypeNotByLayer")))))))
  )
  (if (or wantXS wantXO)
    (setq lines (append lines
      (list "" "XREFS"
            (strcat "   Total xrefs:            " (mwstd:num (mwstd:fact facts "Xrefs"))))
      (if wantXS
        (list (strcat "   Broken (not found):     " (mwstd:num (mwstd:fact facts "XrefsBroken")))
              (strcat "   Unloaded:               " (mwstd:num (mwstd:fact facts "XrefsUnloaded")))))
      (if wantXS
        (mapcar (function (lambda (x) (strcat "      " (nth 3 x) ": " (car x) "  " (cadr x))))
                (vl-remove-if (function (lambda (x) (= (nth 3 x) "Loaded")))
                              (mwstd:fact facts "xrefdetail"))))
      (if wantXO
        (list (strcat "   Inserts not at 0,0,0:   " (mwstd:num (mwstd:fact facts "XrefsOffOrigin")))))
      (if wantXO
        (mapcar (function (lambda (p) (strcat "      " (car p) " at " (mwstd:pt-text (cadr p)))))
                (mwstd:fact facts "offorigin")))))
  )
  (setq lines (append lines
    (list "" "Choose what is checked in the CutOnce Control Center (type CUTONCE).")))
  (setq msg (mwise:join lines "\n"))
  (princ (strcat "\n" msg "\n"))
  (if issues
    (mwise:log-event "STANDARDS-OPEN"
      (strcat "not ByLayer " (mwstd:num (mwstd:fact facts "ObjectsNotByLayer"))
              "  broken xrefs " (mwstd:num (mwstd:fact facts "XrefsBroken"))
              "  unloaded xrefs " (mwstd:num (mwstd:fact facts "XrefsUnloaded"))
              "  xrefs off 0,0,0 " (mwstd:num (mwstd:fact facts "XrefsOffOrigin")))))
  (if (or manual issues (mwise:on-p "StdAlwaysShow"))
    (mwise:notice-links msg links)
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Commands
;; ---------------------------------------------------------------------------

(defun mwstd:check-now ( / doc facts r)
  (setq doc (mwise:active-doc))
  (setq r (vl-catch-all-apply
            (function (lambda ()
              (setq facts (mwstd:collect doc (mwise:on-p "StdScanBlocks")))
              (mwstd:show-report facts (cond ((mwise:str-prop doc 'Name)) ("")) T)))))
  (if (vl-catch-all-error-p r)
    (mwstd:log (strcat "Check failed: " (vl-catch-all-error-message r)))
  )
  (princ)
)

(defun c:CUTONCE-CHECK ( ) (mwstd:check-now))

(defun c:CUTONCE-CHECK-STATUS ( )
  (mwstd:log "Standards check settings (change in the Control Center: CUTONCE):")
  (foreach k '("StdCheckOnOpen" "StdByLayer" "StdXrefStatus" "StdXrefOrigin" "StdAlwaysShow" "StdScanBlocks")
    (princ (strcat "\n  " (mwise:setting-label k) ": " (if (mwise:on-p k) "on" "off")
                   (if (mwise:locked-p k) "  (set by CAD admin)" "")))
  )
  (princ)
)

(princ)
