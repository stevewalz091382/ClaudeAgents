;;; ============================================================================
;;; CutOnce-Standards.lsp
;;;
;;; Drawing standards scan:
;;;   - objects whose COLOR is not ByLayer      (ByBlock, ACI or True Color)
;;;   - objects whose LINETYPE is not ByLayer   (ByBlock or a named linetype)
;;;   - the same two checks inside named block definitions (optional)
;;;   - xrefs: total, broken (file not found), unloaded
;;;   - xref inserts in Model Space that are not at 0,0,0
;;;   - Civil 3D labels whose text has been typed over (overridden), so they
;;;     no longer update with the design
;;;   - coordinate system and insertion units: none assigned, different from
;;;     the project's, or different from an xref's
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
(defun costd:xref-def (blk context prefix / name path rec flags loaded xtype db status units)
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
  ;; an xref block's Units are the referenced drawing's INSUNITS
  (setq units (cutonce:prop blk 'Units))
  (if (not (and db (not (vl-catch-all-error-p db))))
    (setq db (if (= status "Loaded") (vl-catch-all-apply 'vla-get-XRefDatabase (list blk)))))
  (list name path xtype status (if (vl-string-search "|" name) "Yes" "No")
        (if (numberp units) (fix units))
        (if (and db (not (vl-catch-all-error-p db))) (costd:geo-cs db)))
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
;; Coordinate system and insertion units
;; ---------------------------------------------------------------------------

(setq *costd:unit-names*
  '((0 . "Unitless") (1 . "Inches") (2 . "Feet") (3 . "Miles") (4 . "Millimeters")
    (5 . "Centimeters") (6 . "Meters") (7 . "Kilometers") (8 . "Microinches")
    (9 . "Mils") (10 . "Yards") (11 . "Angstroms") (12 . "Nanometers")
    (13 . "Microns") (14 . "Decimeters") (15 . "Decameters") (16 . "Hectometers")
    (17 . "Gigameters") (18 . "Astronomical units") (19 . "Light years")
    (20 . "Parsecs") (21 . "US Survey Feet") (22 . "US Survey Inches")
    (23 . "US Survey Yards") (24 . "US Survey Miles")))

(defun costd:unit-name (n / e)
  (cond ((not (numberp n)) "?")
        ((setq e (assoc (fix n) *costd:unit-names*)) (cdr e))
        (T (itoa (fix n))))
)

;; "Feet", "us survey feet", "2" or 2 -> 2; nil when not recognised.
(defun costd:units-value (v / up e)
  (cond
    ((numberp v) (fix v))
    ((not (cutonce:nonblank v)) nil)
    ((wcmatch (vl-string-trim " " v) "#,##") (atoi v))
    (T
     (setq up (strcase (vl-string-trim " " v)))
     (if (setq e (vl-member-if (function (lambda (p) (= (strcase (cdr p)) up))) *costd:unit-names*))
       (car (car e))))
  )
)

;; System variable of any open drawing (not only this namespace's), or nil.
(defun costd:doc-getvar (doc name / r)
  (setq r (vl-catch-all-apply 'vlax-invoke (list doc 'GetVariable name)))
  (if (vl-catch-all-error-p r) nil r)
)

;; Coordinate system code from a geographic-location definition, which is
;; XML (<ProjectedCoordinateSystem id="CA83-VIF" ...>) or WKT (PROJCS["..."]).
(defun costd:between (s open close / i j)
  (if (setq i (vl-string-search open s))
    (progn
      (setq i (+ i (strlen open)))
      (if (setq j (vl-string-search close s i)) (substr s (1+ i) (- j i))))
  )
)

(defun costd:cs-code-from-def (s)
  (cond
    ((not (cutonce:nonblank s)) nil)
    ((cutonce:nonblank (costd:between s "CoordinateSystem id=\"" "\"")))
    ((cutonce:nonblank (costd:between s "id=\"" "\"")))
    ((cutonce:nonblank (costd:between s "PROJCS[\"" "\"")))
    ((cutonce:nonblank (costd:between s "GEOGCS[\"" "\"")))
    ((and (< (strlen s) 64) (not (vl-string-search "<" s)) (not (vl-string-search " " s))) s)
  )
)

;; Coordinate system stored with the geographic location of a drawing or an
;; xref database (Model Space extension dictionary, ACAD_GEOGRAPHICDATA).
;; Returns the code, or nil when there is none or it cannot be read.
(defun costd:geo-cs (owner / r)
  (setq r (vl-catch-all-apply 'costd:geo-cs-body (list owner)))
  (if (vl-catch-all-error-p r) nil r)
)

(defun costd:geo-cs-body (owner / ms dict geo en ed txt v)
  (setq ms (cutonce:prop owner 'ModelSpace))
  (if (and ms
           (eq (cutonce:prop ms 'HasExtensionDictionary) :vlax-true)
           (setq dict (cutonce:invoke ms 'GetExtensionDictionary nil))
           (setq geo (cutonce:invoke dict 'Item (list "ACAD_GEOGRAPHICDATA"))))
    (progn
      (setq en (vl-catch-all-apply 'vlax-vla-object->ename (list geo)))
      (cond
        ((/= (type en) 'ENAME) nil)
        ((and (setq v (vl-catch-all-apply 'getpropertyvalue (list en "CoordinateSystem")))
              (= (type v) 'STR)
              (costd:cs-code-from-def v)))
        ((setq ed (entget en))
         ;; 301 holds the definition; long ones continue in 303 groups
         (setq txt "")
         (foreach g ed (if (member (car g) '(301 303)) (setq txt (strcat txt (cdr g)))))
         (costd:cs-code-from-def txt))
      )
    )
  )
)

;; The drawing's coordinate system: Civil 3D Drawing Settings (when the
;; Civil 3D connection is up), then CGEOCS, then the geographic location.
;; "" when none is assigned.
(defun costd:drawing-cs (doc civilDoc / zone v)
  (if civilDoc
    (setq zone (cutonce:prop (cutonce:prop (cutonce:prop civilDoc 'Settings) 'DrawingSettings) 'UnitZoneSettings)))
  (cond
    ((and zone (cutonce:nonblank (setq v (cutonce:str-prop zone 'CoordinateSystemCode)))) v)
    ((and (setq v (costd:doc-getvar doc "CGEOCS")) (= (type v) 'STR) (cutonce:nonblank v)) v)
    ((costd:geo-cs doc))
    ("")
  )
)

;; Project standards, from the nearest CutOnce-Project.ini in the drawing's
;; folder or a folder above it, else the first "ProjectStandards" entry in
;; CutOnce-Config.lsp whose path wildcard matches the drawing.
;; Returns (("CoordinateSystem" . code) ("InsUnits" . n) ("Source" . where)),
;; or nil when no project is defined. Cached per folder for the session.
(setq *costd:project-cache* nil)

(defun costd:read-ini (path / out i key)
  (setq out nil)
  (foreach ln (cutonce:read-lines path)
    (setq ln (vl-string-trim " \t" ln))
    (if (and (/= ln "")
             (not (member (substr ln 1 1) '(";" "#" "[")))
             (setq i (vl-string-search "=" ln)))
      (progn
        (setq key (strcase (vl-string-trim " \t" (substr ln 1 i))))
        (if (not (assoc key out))
          (setq out (cons (cons key (vl-string-trim " \t\"" (substr ln (+ i 2)))) out)))
      )
    )
  )
  out
)

(defun costd:find-project-ini (dir / d found parent n)
  (setq d (vl-string-right-trim "\\" (vl-string-translate "/" "\\" dir)) n 0)
  (while (and (not found) d (/= d "") (< n 12))
    (setq found (findfile (strcat d "\\CutOnce-Project.ini")))
    (setq parent (vl-filename-directory d))
    (setq d (if (and parent (/= parent d)) parent) n (1+ n))
  )
  found
)

(defun costd:project-from-config (drawpath / entries up hit)
  (setq entries (cutonce:cfg "ProjectStandards" nil)
        up (strcase (vl-string-translate "/" "\\" drawpath)))
  (if (listp entries)
    (foreach e entries
      (if (and (not hit) (listp e) (cutonce:nonblank (car e)) (listp (cdr e))
               (wcmatch up (strcase (vl-string-translate "/" "\\" (car e)))))
        (setq hit e)))
  )
  (if hit
    (list (cons "CoordinateSystem" (cond ((cutonce:nonblank (cdr (assoc "CoordinateSystem" (cdr hit))))) ("")))
          (cons "InsUnits" (costd:units-value (cdr (assoc "InsUnits" (cdr hit)))))
          (cons "Source" "CutOnce-Config.lsp ProjectStandards")))
)

(defun costd:project-standards (drawpath / dir cached ini kv out)
  (setq dir (strcase (cond ((cutonce:nonblank (vl-filename-directory drawpath))) (""))))
  (if (setq cached (assoc dir *costd:project-cache*))
    (cdr cached)
    (progn
      (setq out
        (cond
          ((and (/= dir "") (setq ini (costd:find-project-ini dir)))
           (setq kv (costd:read-ini ini))
           (list (cons "CoordinateSystem" (cond ((cutonce:nonblank (cdr (assoc "COORDINATESYSTEM" kv)))) ("")))
                 (cons "InsUnits" (costd:units-value (cdr (assoc "INSUNITS" kv))))
                 (cons "Source" ini)))
          ((costd:project-from-config drawpath))
        ))
      (setq *costd:project-cache* (cons (cons dir out) *costd:project-cache*))
      out
    )
  )
)

;; Every coordinate system / units problem, as display lines.
;; xdefs: costd:xref-defs entries (name path type status nested units cs).
(defun costd:coord-issues (cs insunits project xdefs / out pcs pins hostcs)
  (setq out nil
        hostcs (strcase cs)
        pcs  (cdr (assoc "CoordinateSystem" project))
        pins (cdr (assoc "InsUnits" project)))
  (if (and (= cs "") (cutonce:cfg "CoordSysRequired" T))
    (setq out (cons "No coordinate system is assigned to this drawing." out)))
  (if (and (cutonce:nonblank pcs) (/= cs "") (/= hostcs (strcase pcs)))
    (setq out (cons (strcat "Coordinate system " cs " does not match the project's " pcs ".") out)))
  (if (and (cutonce:nonblank pcs) (= cs ""))
    (setq out (cons (strcat "The project uses " pcs "; this drawing has none.") out)))
  (if (and (numberp insunits) (= insunits 0))
    (setq out (cons "Insertion units (INSUNITS) are Unitless." out)))
  (if (and (numberp pins) (numberp insunits) (/= pins insunits))
    (setq out (cons (strcat "Insertion units are " (costd:unit-name insunits)
                            "; the project uses " (costd:unit-name pins) ".") out)))
  (foreach x xdefs
    (if (and (cutonce:nonblank (nth 6 x)) (/= (strcase (nth 6 x)) hostcs))
      (setq out (cons (strcat "Xref " (car x) " uses " (nth 6 x) "; this drawing uses "
                              (if (= cs "") "none" cs) ".") out)))
    (if (and (numberp (nth 5 x)) (> (nth 5 x) 0) (numberp insunits) (> insunits 0) (/= (nth 5 x) insunits))
      (setq out (cons (strcat "Xref " (car x) " is in " (costd:unit-name (nth 5 x))
                              "; this drawing is in " (costd:unit-name insunits) ".") out)))
  )
  (reverse out)
)

;; ---------------------------------------------------------------------------
;; Civil 3D labels with typed-over text
;;
;; A label whose text component has been typed over keeps that text when the
;; design changes. AutoLISP has no direct call for this, so each label type
;; is asked for the properties in "LabelOverrideProperties" (CutOnce-Config.lsp)
;; through the property system (getpropertyvalue) and COM. A property that
;; reads True, non-zero or a non-empty string means overridden. A label type
;; with none of the properties readable is counted as "unchecked", never as
;; clean. CUTONCE-LABEL-PROBE lists what a selected label exposes.
;; ---------------------------------------------------------------------------

(setq *costd:label-default-props*
  '("IsTextOverridden" "TextOverridden" "HasTextOverride" "IsLabelTextOverridden"
    "TextComponentOverridden" "LabelTextOverridden" "TextOverride" "OverrideText"))

(defun costd:label-props ( / v)
  (setq v (cutonce:cfg "LabelOverrideProperties" nil))
  (if (and v (listp v)) (vl-remove-if-not 'cutonce:nonblank v) *costd:label-default-props*)
)

(defun costd:label-wildcard ( )
  (strcase (cond ((cutonce:nonblank (cutonce:cfg "LabelObjectNames" nil))) ("AECCDB*LABEL*")))
)

;; (value) when the property can be read, nil when it cannot.
(defun costd:read-prop (obj en name / r)
  (setq r (if en (vl-catch-all-apply 'getpropertyvalue (list en name))))
  (if (and en (not (vl-catch-all-error-p r)))
    (list r)
    (progn
      (setq r (vl-catch-all-apply 'vlax-get-property (list obj name)))
      (if (not (vl-catch-all-error-p r)) (list r)))
  )
)

(defun costd:override-value-p (v)
  (cond
    ((eq v :vlax-true) T)
    ((eq v :vlax-false) nil)
    ((= (type v) 'VARIANT) (costd:override-value-p (vlax-variant-value v)))
    ((= (type v) 'STR) (if (cutonce:nonblank v) T))
    ((numberp v) (/= v 0))
    ((eq v T) T)
  )
)

;; ObjectName -> the property that answers for it, or nil when none does.
(setq *costd:label-prop-cache* nil)

;; 'yes, 'no, or nil (cannot be checked).
(defun costd:label-override-state (obj oname en / cached val props p)
  (setq cached (assoc oname *costd:label-prop-cache*))
  (cond
    ((and cached (null (cdr cached))) nil)
    (cached
     (if (setq val (costd:read-prop obj en (cdr cached)))
       (if (costd:override-value-p (car val)) 'yes 'no)))
    (T
     (setq props (costd:label-props))
     (while (and props (not val))
       (setq p (car props) props (cdr props))
       (setq val (costd:read-prop obj en p))
     )
     (setq *costd:label-prop-cache* (cons (cons oname (if val p)) *costd:label-prop-cache*))
     (if val (if (costd:override-value-p (car val)) 'yes 'no))
    )
  )
)

(defun costd:label-style (obj en / st r)
  (cond
    ((cutonce:nonblank (cutonce:str-prop obj 'StyleName)))
    ((and (setq st (cutonce:prop obj 'Style)) (= (type st) 'VLA-OBJECT)
          (cutonce:nonblank (cutonce:str-prop st 'Name))))
    ((and en (setq r (vl-catch-all-apply 'getpropertyvalue (list en "StyleName")))
          (= (type r) 'STR) (cutonce:nonblank r)))
    ("(style not readable)")
  )
)

;; "AeccDbSurfaceElevationLabel" -> "SurfaceElevationLabel"
(defun costd:label-type (oname)
  (if (wcmatch (strcase oname) "AECCDB*") (substr oname 7) oname)
)

;; Called from costd:tally for each label; updates its caller's counters.
;; labels: ((type style total overridden unchecked handles) ...)
(defun costd:tally-label (obj oname / en state ltype lstyle row handle)
  (setq en (vl-catch-all-apply 'vlax-vla-object->ename (list obj)))
  (if (/= (type en) 'ENAME) (setq en nil))
  (setq state (costd:label-override-state obj oname en)
        ltype (costd:label-type oname)
        lstyle (costd:label-style obj en)
        handle (cond ((cutonce:str-prop obj 'Handle)) ("")))
  (setq labelN (1+ labelN))
  (cond ((eq state 'yes) (setq labelOvN (1+ labelOvN)))
        ((null state) (setq labelUnN (1+ labelUnN))))
  (setq row (vl-member-if (function (lambda (r) (and (= (car r) ltype) (= (cadr r) lstyle)))) labels))
  (setq row (if row (car row) (list ltype lstyle 0 0 0 nil)))
  (setq labels (cons (list ltype lstyle
                           (1+ (nth 2 row))
                           (+ (nth 3 row) (if (eq state 'yes) 1 0))
                           (+ (nth 4 row) (if state 0 1))
                           (if (eq state 'yes) (cons handle (nth 5 row)) (nth 5 row)))
                     (vl-remove row labels)))
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
  (if (wcmatch (strcase oname) labelwc)
    (vl-catch-all-apply 'costd:tally-label (list obj oname))
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
;;   ("Labels" . n) ("LabelsOverridden" . n or "n/a") ("LabelsUnchecked" . n)
;;   ("labeldetail" . ((type style total overridden unchecked handles) ...))
(defun costd:scan-spaces (doc / xrefnames spaces blk objcounts hatchN textN colN ltN eitherN inserts countall
                                labelwc labelN labelOvN labelUnN labels)
  (setq xrefnames (costd:xref-block-names doc)
        objcounts nil hatchN 0 textN 0 colN 0 ltN 0 eitherN 0 inserts nil
        countall (if (cutonce:health-extra-counts) T)
        labelwc (costd:label-wildcard) labelN 0 labelOvN 0 labelUnN 0 labels nil)
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
        (cons "Labels" labelN)
        ;; n/a when there are labels but none could be checked
        (cons "LabelsOverridden" (if (and (> labelN 0) (= labelUnN labelN)) "n/a" labelOvN))
        (cons "LabelsUnchecked" labelUnN)
        (cons "labeldetail" (vl-sort labels (function (lambda (a b) (> (nth 3 a) (nth 3 b))))))
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
;;   ("CoordinateSystem" . code or "") ("ProjectCoordinateSystem" . code or "")
;;   ("CoordUnitIssues" . n) ("coordissues" . (line ...)) ("project" . alist)
;; Block-definition counts are "n/a" when scanblocks is nil. civilDoc may be
;; nil (at open, or without the Civil 3D connection).
;; ---------------------------------------------------------------------------

(defun costd:collect (doc scanblocks civilDoc / spaces bdefs xdefs inserts detail mine first off
                                        broken unloaded offlist cs insunits project issues)
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
    ;; (name path type status nested instances point rotation scale atOrigin units cs)
    (setq detail
      (cons (list (nth 0 xd) (nth 1 xd) (nth 2 xd) (nth 3 xd) (nth 4 xd)
                  (length mine)
                  (if first (cadr first))
                  (if first (caddr first))
                  (if first (cadddr first))
                  (cond ((null mine) "") (off "No") (T "Yes"))
                  (nth 5 xd)
                  (nth 6 xd))
            detail))
    (cond ((= (nth 3 xd) "Not Found") (setq broken (1+ broken)))
          ((= (nth 3 xd) "Unloaded")  (setq unloaded (1+ unloaded))))
  )
  (setq cs (costd:drawing-cs doc civilDoc)
        insunits (costd:doc-getvar doc "INSUNITS")
        project (costd:project-standards (cond ((cutonce:str-prop doc 'FullName)) (""))))
  (setq issues (costd:coord-issues cs insunits project xdefs))
  (append
    (vl-remove (assoc "inserts" spaces) spaces)
    (list (cons "CoordinateSystem" cs)
          (cons "ProjectCoordinateSystem" (cond ((cdr (assoc "CoordinateSystem" project))) ("")))
          (cons "InsUnitsValue" insunits)
          (cons "CoordUnitIssues" (length issues))
          (cons "coordissues" issues)
          (cons "project" project))
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

(defun costd:show-report (facts drawname manual / wantBL wantXS wantXO wantLB wantCU issBL issXS issXO issLB issCU
                                                   issues lines msg bdc links lov over src)
  (setq wantBL (or manual (cutonce:on-p "StdByLayer"))
        wantXS (or manual (cutonce:on-p "StdXrefStatus"))
        wantXO (or manual (cutonce:on-p "StdXrefOrigin"))
        wantLB (or manual (cutonce:on-p "StdLabelOverrides"))
        wantCU (or manual (cutonce:on-p "StdCoordUnits"))
        bdc    (costd:fact facts "BlockDefColorNotByLayer")
        lov    (costd:fact facts "LabelsOverridden"))
  (setq issBL (and wantBL
                   (or (> (costd:fact facts "ObjectsNotByLayer") 0)
                       (and (numberp bdc)
                            (> (+ bdc (costd:fact facts "BlockDefLinetypeNotByLayer")) 0))))
        issXS (and wantXS (> (+ (costd:fact facts "XrefsBroken") (costd:fact facts "XrefsUnloaded")) 0))
        issXO (and wantXO (> (costd:fact facts "XrefsOffOrigin") 0))
        issLB (and wantLB (numberp lov) (> lov 0))
        issCU (and wantCU (> (costd:fact facts "CoordUnitIssues") 0)))
  (setq issues (or issBL issXS issXO issLB issCU))
  ;; one Learn More button per problem found, plus how to read the check
  (setq links (list (cons "Reading this check..." "STANDARDS_OPEN")))
  (if issBL (setq links (append links (list (cons "Not ByLayer..." "STD_BYLAYER")))))
  (if issXS (setq links (append links (list (cons "Broken / unloaded xrefs..." "STD_XREF_STATUS")))))
  (if issXO (setq links (append links (list (cons "Xrefs not at 0,0,0..." "STD_XREF_ORIGIN")))))
  (if issLB (setq links (append links (list (cons "Typed-over labels..." "STD_LABEL_OVERRIDE")))))
  (if issCU (setq links (append links (list (cons "Coordinates / units..." "STD_COORD_UNITS")))))
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
  (if wantLB
    (progn
      (setq over (vl-remove-if-not (function (lambda (r) (> (nth 3 r) 0))) (costd:fact facts "labeldetail")))
      (setq lines (append lines
        (list "" "CIVIL 3D LABELS WITH TYPED-OVER TEXT (will not update with the design)"
              (strcat "   Labels:                 " (costd:num (costd:fact facts "Labels")))
              (strcat "   Text overridden:        " (costd:num lov)))
        (mapcar (function (lambda (r) (strcat "      " (itoa (nth 3 r)) " x " (car r) "  -  style: " (cadr r))))
                over)
        (if (> (costd:fact facts "LabelsUnchecked") 0)
          (list (strcat "   Could not be checked:   " (costd:num (costd:fact facts "LabelsUnchecked"))
                        "  (CAD admin: see CUTONCE-LABEL-PROBE)")))
        (if (and over (cutonce:log-on-p "LogLabels"))
          (list (strcat "   Each label is listed in " (cutonce:log-file "Labels.csv"))))))
    )
  )
  (if wantCU
    (setq lines (append lines
      (list "" "COORDINATE SYSTEM AND UNITS"
            (strcat "   Coordinate system:      "
                    (cond ((cutonce:nonblank (costd:fact facts "CoordinateSystem"))) ("(none)")))
            (strcat "   Insertion units:        " (costd:unit-name (costd:fact facts "InsUnitsValue"))))
      (if (setq src (costd:fact (costd:fact facts "project") "Source"))
        (list (strcat "   Project standard from:  " src)))
      (mapcar (function (lambda (s) (strcat "      " s))) (costd:fact facts "coordissues"))))
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
              "  xrefs off 0,0,0 " (costd:num (costd:fact facts "XrefsOffOrigin"))
              "  labels overridden " (costd:num lov)
              "  coordinate/unit issues " (costd:num (costd:fact facts "CoordUnitIssues")))))
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
              (setq facts (costd:collect doc (cutonce:on-p "StdScanBlocks") (cutonce:civil-doc)))
              (costd:show-report facts (cond ((cutonce:str-prop doc 'Name)) ("")) T)))))
  (if (vl-catch-all-error-p r)
    (costd:log (strcat "Check failed: " (vl-catch-all-error-message r)))
  )
  (princ)
)

(defun c:CUTONCE-CHECK ( ) (costd:check-now))

;; For the CAD administrator: shows which property tells whether a label's
;; text has been typed over, so it can be added to LabelOverrideProperties.
(defun c:CUTONCE-LABEL-PROBE ( / sel en obj oname val)
  (setq sel (entsel "\nSelect a Civil 3D label whose text you have typed over: "))
  (cond
    ((not sel) (costd:log "Nothing selected."))
    (T
     (setq en (car sel) obj (vlax-ename->vla-object en) oname (cutonce:object-name obj))
     (costd:log (strcat "ObjectName: " oname
                        (if (wcmatch (strcase oname) (costd:label-wildcard)) "" "  (not matched by LabelObjectNames)")))
     (princ (strcat "\n  Style: " (costd:label-style obj en)))
     (princ "\n  Properties CutOnce asks for (LabelOverrideProperties):")
     (foreach p (costd:label-props)
       (setq val (costd:read-prop obj en p))
       (princ (strcat "\n    " p ": " (if val (vl-prin1-to-string (car val)) "not available")))
     )
     (setq *costd:label-prop-cache* (vl-remove (assoc oname *costd:label-prop-cache*) *costd:label-prop-cache*))
     (princ "\n\n  Every property this label exposes (property system):")
     (vl-catch-all-apply 'dumpallproperties (list en))
     (princ "\n\n  COM properties:")
     (vl-catch-all-apply 'vlax-dump-object (list obj))
     (princ (strcat "\n\n  Run this on a typed-over label and on an unchanged one of the same type."
                    "\n  A property that reads True / 1 / the typed text on the first and False / 0 / empty"
                    "\n  on the second is the one to add to LabelOverrideProperties in"
                    "\n  " (cutonce:home) "CutOnce-Config.lsp, then restart Civil 3D."))
    )
  )
  (princ)
)

(defun c:CUTONCE-CHECK-STATUS ( )
  (costd:log "Standards check settings (change in the Control Center: CUTONCE):")
  (foreach k '("StdCheckOnOpen" "StdByLayer" "StdXrefStatus" "StdXrefOrigin" "StdLabelOverrides" "StdCoordUnits"
               "StdAlwaysShow" "StdScanBlocks")
    (princ (strcat "\n  " (cutonce:setting-label k) ": " (if (cutonce:on-p k) "on" "off")
                   (if (cutonce:locked-p k) "  (set by CAD admin)" "")))
  )
  (princ)
)

(princ)
