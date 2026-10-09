;;; ============================================================================
;;; CutOnce-Health.lsp
;;;
;;; One health record per drawing check, kept as history.
;;;
;;; Health.csv  one row per check:
;;;   who / when / which drawing / what triggered it (Save, Open, Audit,
;;;   Manual), table counts, Civil 3D object counts, style count, ByLayer
;;;   counts, xref counts (broken, unloaded, not at 0,0,0) and drawing
;;;   settings (units, coordinate system, scale).
;;; Xrefs.csv   one row per xref per Health.csv row: path, attach/overlay,
;;;   loaded/unloaded/not found, nested, insertion point, rotation, scale and
;;;   whether it is at 0,0,0.
;;;
;;; The latest state of each drawing is its most recent row; filter Health.csv
;;; on DrawingPath and sort by Timestamp.
;;;
;;; When:
;;;   Save    every save (beginSave), plus the growth and 0,0,0 checks
;;;   Open    when a saved drawing opens (Civil 3D COM is not used at open,
;;;           so Styles and the settings columns read n/a on those rows)
;;;   Audit   CUTONCE-AUDIT / CUTONCE-AUDIT-FOLDER
;;;   Manual  CUTONCE-GUARD-CHECKNOW
;;; Each designer switches these on or off in CUTONCE.
;;;
;;; Commands:
;;;   CUTONCE-AUDIT         record every open drawing and open Health.csv in Excel
;;;   CUTONCE-AUDIT-FOLDER  open, record and close every .dwg in a chosen folder
;;;   CUTONCE-GUARD-CHECKNOW, CUTONCE-GUARD-SUMMARY  (see CutOnce-Guard.lsp)
;;;
;;; Naming: every function and global here starts with cohealth: / *cohealth:.
;;; Requires CutOnce-Core.lsp and CutOnce-Standards.lsp.
;;; ============================================================================

(vl-load-com)

(defun cohealth:log (msg) (cutonce:msg "CutOnce Health" msg))

(defun cohealth:path ( )      (cutonce:log-file "Health.csv"))
(defun cohealth:xrefs-path ( ) (cutonce:log-file "Xrefs.csv"))

;; ---------------------------------------------------------------------------
;; Columns
;; ---------------------------------------------------------------------------

(setq *cohealth:id-columns* '("Timestamp" "Trigger" "User" "DrawingPath" "DrawingName"))

(setq *cohealth:metric-columns*
  '("Layers" "Linetypes" "Blocks" "Layouts" "RegApps" "Styles"
    "Alignments" "Profiles" "ProfileViews" "Surfaces" "Corridors" "Assemblies"
    "PipeNetworks" "GravityPipes" "GravityStructures" "PressurePipeNetworks"
    "SectionViews" "Sections" "Hatches" "TextObjects"
    "ColorNotByLayer" "LinetypeNotByLayer" "ObjectsNotByLayer"
    "BlockDefColorNotByLayer" "BlockDefLinetypeNotByLayer"
    "Xrefs" "XrefsBroken" "XrefsUnloaded" "XrefsOffOrigin"))

(setq *cohealth:setting-columns*
  '("AngularUnits" "ImperialToMetricConversion" "CoordinateSystem" "InsUnits" "DrawingScale"))

;; Metrics compared against the previous check for unusual growth.
(setq *cohealth:growth-watch*
  '("Layers" "Linetypes" "Blocks" "Layouts" "Xrefs" "RegApps" "Styles"
    "Alignments" "Profiles" "ProfileViews" "Surfaces" "Corridors" "Assemblies"
    "PipeNetworks" "PressurePipeNetworks" "SectionViews" "Sections"
    "Hatches" "TextObjects"))

;; Administrator-defined count columns ("HealthExtraCounts"), minus any
;; that would repeat a built-in column: ((Column . wildcard) ...)
(defun cohealth:extra ( / builtin)
  (setq builtin (mapcar 'strcase (append *cohealth:id-columns* *cohealth:metric-columns* *cohealth:setting-columns*)))
  (vl-remove-if (function (lambda (e) (member (strcase (car e)) builtin))) (cutonce:health-extra-counts))
)

(defun cohealth:extra-columns ( ) (mapcar 'car (cohealth:extra)))

(defun cohealth:columns ( )
  (append *cohealth:id-columns* *cohealth:metric-columns* (cohealth:extra-columns) *cohealth:setting-columns*)
)

(defun cohealth:header ( ) (cutonce:join (cohealth:columns) ","))

(setq *cohealth:xref-header*
  (strcat "Timestamp,Trigger,User,DrawingPath,DrawingName,XrefName,XrefPath,Type,Status,"
          "Nested,Instances,InsertX,InsertY,InsertZ,Rotation,Scale,AtOrigin"))

(defun cohealth:growth-pct ( / v)
  (setq v (cutonce:cfg "GuardGrowthWarnPct" 20))
  (if (numberp v) v 20)
)

;; ---------------------------------------------------------------------------
;; Civil 3D style collections (from the former audit report). Each name is
;; tried on the Civil document, then on its Styles and Settings objects.
;; Which root (if any) holds each name is cached for the session.
;; ---------------------------------------------------------------------------

(setq *cohealth:style-collections*
  '("AlignmentStyles" "AlignmentLabelStyles" "AssemblyStyles"
    "BuildingSiteStyles" "CatchmentStyles" "CatchmentLabelStyles"
    "CodeSetStyles" "CorridorStyles" "FeatureLineStyles"
    "GeneralCurveLabelStyles" "GeneralLineLabelStyles"
    "GeneralLinkLabelStyles" "GeneralMarkerLabelStyles"
    "GeneralNoteLabelStyles" "GeneralShapeLabelStyles"
    "GradingCriteriaStyles" "GradingStyles" "GroupPlotStyles"
    "InterferenceStyles" "IntersectionStyles" "LinkStyles"
    "MarkerStyles" "MassHaulLineStyles" "MatchLineStyles"
    "MatchLineLabelStyles" "ParcelStyles" "ParcelLabelStyles"
    "PipeStyles" "PipeLabelStyles" "PipeRuleSetStyles"
    "PointStyles" "PointLabelStyles" "PointCloudStyles"
    "PressureAppurtenanceStyles" "PressureFittingStyles"
    "PressureFittingLabelStyles" "PressurePipeStyles"
    "PressurePipeLabelStyles" "ProfileStyles" "ProfileLabelStyles"
    "ProfileViewStyles" "ProfileViewBandStyles"
    "ProfileViewHorizontalGeometryLabelStyles"
    "ProfileViewPipeLabelStyles" "ProfileViewVerticalGeometryLabelStyles"
    "ProjectionStyles" "ProjectionLabelStyles" "SampleLineStyles"
    "SampleLineLabelStyles" "SectionStyles" "SectionLabelStyles"
    "SectionLabelSetStyles" "SectionViewStyles" "SectionViewBandStyles"
    "SectionViewLabelStyles" "SectionViewSectionStyles"
    "SectionViewSegmentLabelStyles" "SheetStyles" "SlopePatternStyles"
    "StructureStyles" "StructureLabelStyles" "StructureRuleSetStyles"
    "SuperelevationViewStyles" "SurfaceStyles" "SurfaceLabelStyles"
    "SurveyFigureStyles" "SurveyLabelStyles" "SurveyNetworkStyles"
    "TableStyles")
)

(setq *cohealth:style-root-cache* nil)

(defun cohealth:count-styles (civilDoc / roots total cached idx n)
  (setq roots (list civilDoc (cutonce:prop civilDoc 'Styles) (cutonce:prop civilDoc 'Settings)))
  (setq total 0)
  (foreach nm *cohealth:style-collections*
    (setq cached (assoc nm *cohealth:style-root-cache*))
    (cond
      ((and cached (= (cdr cached) -1)) nil)
      (cached
       (setq total (+ total (cutonce:prop-count (nth (cdr cached) roots) nm))))
      (T
       (setq idx 0 n nil)
       (while (and (< idx 3) (not n))
         (if (nth idx roots) (setq n (cutonce:prop (nth idx roots) nm)))
         (if (not n) (setq idx (1+ idx)))
       )
       (if n
         (progn
           (setq total (+ total (cutonce:count n)))
           (setq *cohealth:style-root-cache* (cons (cons nm idx) *cohealth:style-root-cache*)))
         (setq *cohealth:style-root-cache* (cons (cons nm -1) *cohealth:style-root-cache*))
       )
      )
    )
  )
  total
)

(defun cohealth:getvar (doc name / r)
  (setq r (vl-catch-all-apply 'vlax-invoke (list doc 'GetVariable name)))
  (if (vl-catch-all-error-p r) "n/a" r)
)

(defun cohealth:na (v) (if (null v) "n/a" v))

(defun cohealth:sum (objcounts wildcard / total)
  (setq total 0)
  (foreach pair objcounts
    (if (wcmatch (strcase (car pair)) (strcase wildcard)) (setq total (+ total (cdr pair))))
  )
  total
)

;; ---------------------------------------------------------------------------
;; Collect: every Health.csv value for one drawing.
;; civilDoc may be nil (at open, plain AutoCAD, or no COM connection); the
;; Styles and settings columns then read n/a.
;; Returns the standards facts (see costd:collect) plus one pair per column.
;; ---------------------------------------------------------------------------

(defun cohealth:collect (doc civilDoc scanblocks / std oc unitZone)
  (setq std (costd:collect doc scanblocks))
  (setq oc (costd:fact std "objcounts"))
  (if civilDoc
    (setq unitZone (cutonce:prop (cutonce:prop (cutonce:prop civilDoc 'Settings) 'DrawingSettings) 'UnitZoneSettings))
  )
  (append
    std
    (list
      (cons "Layers"               (cutonce:count (vla-get-Layers doc)))
      (cons "Linetypes"            (cutonce:count (vla-get-Linetypes doc)))
      (cons "Blocks"               (cutonce:count (vla-get-Blocks doc)))
      (cons "Layouts"              (cutonce:count (vla-get-Layouts doc)))
      (cons "RegApps"              (cutonce:count (vla-get-RegisteredApplications doc)))
      (cons "Styles"               (if civilDoc (cohealth:count-styles civilDoc) "n/a"))
      (cons "Alignments"           (cohealth:sum oc "AECCDBALIGNMENT"))
      (cons "Profiles"             (cohealth:sum oc "AECCDBVALIGNMENT"))
      (cons "ProfileViews"         (cohealth:sum oc "AECCDBGRAPHPROFILE"))
      (cons "Surfaces"             (cohealth:sum oc "AECCDBSURFACETIN,AECCDBSURFACEGRID,AECCDBSURFACEVOLUME"))
      (cons "Corridors"            (cohealth:sum oc "AECCDBCORRIDOR"))
      (cons "Assemblies"           (cohealth:sum oc "AECCDBASSEMBLY"))
      (cons "PipeNetworks"         (cohealth:sum oc "AECCDBNETWORK"))
      (cons "GravityPipes"         (cohealth:sum oc "AECCDBPIPE"))
      (cons "GravityStructures"    (cohealth:sum oc "AECCDBSTRUCTURE"))
      (cons "PressurePipeNetworks" (cohealth:sum oc "AECCDBPRESSUREPIPENETWORK,AECCDBPRESSURENETWORK"))
      (cons "SectionViews"         (cohealth:sum oc "AECCDBSECTIONVIEW"))
      (cons "Sections"             (cohealth:sum oc "AECCDBSECTION"))
      (cons "AngularUnits"               (if civilDoc (cohealth:na (cutonce:prop unitZone 'AngularUnits)) "n/a"))
      (cons "ImperialToMetricConversion" (if civilDoc (cohealth:na (cutonce:prop unitZone 'ImperialToMetricConversion)) "n/a"))
      (cons "CoordinateSystem"           (if civilDoc (cohealth:na (cutonce:prop unitZone 'CoordinateSystemCode)) "n/a"))
      (cons "InsUnits"                   (cohealth:getvar doc "INSUNITS"))
      (cons "DrawingScale"               (cohealth:getvar doc "DIMSCALE"))
    )
    ;; administrator-defined columns (Model Space and every layout)
    (mapcar (function (lambda (e) (cons (car e) (cohealth:sum oc (cdr e))))) (cohealth:extra))
  )
)

;; ---------------------------------------------------------------------------
;; Writing
;; ---------------------------------------------------------------------------

;; Previous check of a drawing, as ((column . value) ...). The first lookup
;; in a session reads Health.csv; later ones use memory.
(setq *cohealth:last* nil)

(defun cohealth:remember (drawpath facts)
  (setq *cohealth:last*
    (cons drawpath
          (mapcar (function (lambda (c) (cons c (cdr (assoc c facts)))))
                  (append *cohealth:metric-columns* (cohealth:extra-columns)))))
)

(defun cohealth:previous (drawpath / lines pidx lastrow fields)
  (if (and *cohealth:last* (= (car *cohealth:last*) drawpath))
    (cdr *cohealth:last*)
    (progn
      (setq lines (cutonce:read-lines (cohealth:path)))
      (if (and lines (= (car lines) (cohealth:header)))
        (progn
          (setq pidx (vl-position "DrawingPath" (cohealth:columns)))
          (foreach line (cdr lines)
            (setq fields (cutonce:csv-split line ","))
            (if (and (> (length fields) pidx) (= (nth pidx fields) drawpath)) (setq lastrow fields))
          )
          (if lastrow
            (mapcar (function (lambda (c v) (cons c (if (wcmatch v "#*") (atoi v) v))))
                    (cohealth:columns) lastrow))
        )
      )
    )
  )
)

(defun cohealth:row (trigger drawpath drawname facts)
  (strcat
    (cutonce:csv-row (list (cutonce:timestamp) trigger (cutonce:user) drawpath drawname))
    ","
    (cutonce:csv-row (mapcar (function (lambda (c) (cdr (assoc c facts))))
                          (append *cohealth:metric-columns* (cohealth:extra-columns) *cohealth:setting-columns*))))
)

(defun cohealth:xref-rows (trigger drawpath drawname facts / ts user pt)
  (setq ts (cutonce:timestamp) user (cutonce:user))
  (mapcar
    (function (lambda (x)
      ;; x = (name path type status nested instances point rotation scale atOrigin)
      (setq pt (nth 6 x))
      (cutonce:csv-row
        (list ts trigger user drawpath drawname
              (nth 0 x) (nth 1 x) (nth 2 x) (nth 3 x) (nth 4 x) (nth 5 x)
              (if pt (car pt)) (if pt (cadr pt)) (if pt (caddr pt))
              (nth 7 x) (nth 8 x) (nth 9 x)))))
    (costd:fact facts "xrefdetail"))
)

;; Writes the Health.csv row (and Xrefs.csv rows when that log is on).
;; force = T writes even when logging is switched off (explicit CUTONCE-AUDIT).
(defun cohealth:write (doc facts trigger force / drawpath drawname)
  (setq drawpath (cond ((cutonce:str-prop doc 'FullName)) (""))
        drawname (cond ((cutonce:str-prop doc 'Name)) ("")))
  (cutonce:append-line (cohealth:path) (cohealth:header)
                    (cohealth:row trigger drawpath drawname facts))
  (if (or force (cutonce:log-on-p "LogXrefs"))
    (cutonce:append-lines (cohealth:xrefs-path) *cohealth:xref-header*
                       (cohealth:xref-rows trigger drawpath drawname facts))
  )
)

;; ---------------------------------------------------------------------------
;; Save-time checks: unusual growth and xrefs off 0,0,0
;; ---------------------------------------------------------------------------

(defun cohealth:growth-flags (prev facts / flags oldv newv)
  (setq flags nil)
  (if prev
    (foreach metric (append *cohealth:growth-watch* (cohealth:extra-columns))
      (setq oldv (cdr (assoc metric prev)) newv (cdr (assoc metric facts)))
      (if (and (numberp oldv) (numberp newv))
        (cond
          ((and (= metric "RegApps") (> newv oldv))
           (setq flags (cons (list metric oldv newv "new registered app(s), often left by a bind or a foreign block") flags)))
          ((and (= oldv 0) (> newv 0))
           (setq flags (cons (list metric oldv newv "new since the last check") flags)))
          ((and (> oldv 0) (>= (* 100.0 (/ (float (- newv oldv)) oldv)) (cohealth:growth-pct)))
           (setq flags (cons (list metric oldv newv
                                   (strcat "up " (rtos (* 100.0 (/ (float (- newv oldv)) oldv)) 2 0) "% since the last check"))
                             flags)))
        )
      )
    )
  )
  (reverse flags)
)

;; Save-check warnings follow the designer's frequency choice, counted per
;; check per drawing; a manual check (CUTONCE-GUARD-CHECKNOW) always shows.
(defun cohealth:show (key text topic manual)
  (if manual (cutonce:notice text topic) (cutonce:notice-once key text topic))
)

(defun cohealth:alert-growth (drawname flags manual)
  (cutonce:log-event "SAVE-FLAG"
    (apply 'strcat (mapcar (function (lambda (x) (strcat (car x) " " (itoa (cadr x)) "->" (itoa (caddr x)) "  "))) flags)))
  (cohealth:show (strcat "GUARD_GROWTH|" drawname)
    (strcat
      "CutOnce Guard: unusual growth since the last check of\n" drawname ":\n\n"
      (apply 'strcat
        (mapcar (function (lambda (x)
                  (strcat "  " (car x) ": " (itoa (cadr x)) " -> " (itoa (caddr x)) "  (" (nth 3 x) ")\n")))
                flags))
      "\nFull history: " (cohealth:path)
      "\nTurn this check off in the CutOnce Control Center (type CUTONCE)."
    )
    "GUARD_GROWTH"
    manual
  )
)

(defun cohealth:alert-origin (drawname badpts manual)
  (cutonce:log-event "XREF-BASEPOINT" (apply 'strcat (mapcar (function (lambda (p) (strcat (car p) "  "))) badpts)))
  (cohealth:show (strcat "GUARD_XREF_ORIGIN|" drawname)
    (strcat
      "CutOnce Guard: xref insertion point(s) are not at 0,0,0:\n\n"
      (apply 'strcat
        (mapcar (function (lambda (p) (strcat "  " (car p) ": " (costd:pt-text (cadr p)) "\n")))
                badpts))
      "\nA non-zero xref insertion point commonly causes misalignment against\n"
      "a shared coordinate system or data shortcuts."
      "\nTurn this check off in the CutOnce Control Center (type CUTONCE)."
    )
    "GUARD_XREF_ORIGIN"
    manual
  )
)

;; trigger: "Save" (reactor) or "Manual" (CUTONCE-GUARD-CHECKNOW).
;; Manual runs both alerts and writes the row whatever the settings say.
(defun cohealth:check (trigger / manual doc drawpath drawname wantLog wantGrowth wantOrigin facts prev flags badpts)
  (setq manual (= trigger "Manual"))
  (setq wantLog    (or manual (cutonce:log-on-p "LogHealthOnSave"))
        wantGrowth (or manual (cutonce:on-p "GuardGrowth"))
        wantOrigin (or manual (cutonce:on-p "GuardXrefOrigin")))
  (setq doc (cutonce:active-doc))
  (setq drawpath (cutonce:nonblank (cutonce:str-prop doc 'FullName))
        drawname (cond ((cutonce:str-prop doc 'Name)) ("")))
  (cond
    ((not (or wantLog wantGrowth wantOrigin)) nil)
    ((or (not drawpath) (/= (getvar "DWGTITLED") 1))
     (cohealth:log "This drawing has not been saved yet - health check skipped."))
    (T
     (setq facts (cohealth:collect doc (cutonce:civil-doc) (cutonce:on-p "StdScanBlocks")))
     (if wantGrowth
       (progn
         (setq prev (vl-catch-all-apply 'cohealth:previous (list drawpath)))
         (if (vl-catch-all-error-p prev) (setq prev nil))
       )
     )
     (if wantLog (vl-catch-all-apply 'cohealth:write (list doc facts trigger manual)))
     (cohealth:remember drawpath facts)
     (if (and wantGrowth (setq flags (cohealth:growth-flags prev facts)))
       (cohealth:alert-growth drawname flags manual))
     (if (and wantOrigin (setq badpts (costd:fact facts "offorigin")))
       (cohealth:alert-origin drawname badpts manual))
    )
  )
)

(defun cohealth:begin-save (reactor arglist)
  (vl-catch-all-apply 'cohealth:check (list "Save"))
  (princ)
)

;; ---------------------------------------------------------------------------
;; Open: called once by the Control Center when a saved drawing finishes
;; loading. One scan feeds both the standards dialog and the Health.csv row.
;; Civil 3D COM is deliberately not used here (it may not be ready while
;; Civil 3D is still starting), so Styles and settings read n/a.
;; ---------------------------------------------------------------------------

(defun cohealth:on-open ( / doc drawpath wantCheck wantLog facts)
  (setq wantCheck (cutonce:on-p "StdCheckOnOpen")
        wantLog   (cutonce:log-on-p "LogHealthOnOpen"))
  (setq doc (cutonce:active-doc))
  (if (and (= 1 (getvar "DWGTITLED"))
           (setq drawpath (cutonce:nonblank (cutonce:str-prop doc 'FullName)))
           (or wantCheck wantLog))
    (progn
      (setq facts (cohealth:collect doc nil (cutonce:on-p "StdScanBlocks")))
      (if wantLog (vl-catch-all-apply 'cohealth:write (list doc facts "Open" nil)))
      ;; the state at open is the baseline for this session's first save
      (cohealth:remember drawpath facts)
      (if wantCheck (costd:show-report facts (cond ((cutonce:str-prop doc 'Name)) ("")) nil))
    )
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Excel presentation (manual commands only)
;; ---------------------------------------------------------------------------

(defun cohealth:open-in-excel (csvpath / xl wb ws used win)
  (setq xl (vl-catch-all-apply 'vlax-get-or-create-object (list "Excel.Application")))
  (if (or (vl-catch-all-error-p xl) (null xl))
    (princ (strcat "\nExcel is not available - open " csvpath " by hand."))
    (vl-catch-all-apply
      (function (lambda ()
        (vlax-put-property xl 'Visible :vlax-true)
        (setq wb (vlax-invoke (vlax-get-property xl 'Workbooks) 'Open csvpath))
        (setq ws (vlax-get-property wb 'ActiveSheet))
        (vlax-put-property (vlax-get-property (vlax-invoke (vlax-get-property ws 'Rows) 'Item 1) 'Font) 'Bold :vlax-true)
        (setq used (vlax-get-property ws 'UsedRange))
        (vl-catch-all-apply 'vlax-invoke (list used 'AutoFilter))
        (vlax-invoke (vlax-get-property used 'Columns) 'AutoFit)
        (setq win (vlax-get-property xl 'ActiveWindow))
        (vlax-put-property win 'SplitRow 1)
        (vlax-put-property win 'FreezePanes :vlax-true)
      ))
    )
  )
)

;; ---------------------------------------------------------------------------
;; CUTONCE-AUDIT: every open drawing. Each drawing is made active in turn so the
;; Civil 3D ActiveDocument follows it, then the original drawing is restored.
;; Rows are written with Trigger = Audit, even when logging is switched off,
;; because the user asked for them.
;; ---------------------------------------------------------------------------

(defun cohealth:audit-doc (d / facts)
  (if (cutonce:nonblank (cutonce:str-prop d 'FullName))
    (progn
      (setq facts (cohealth:collect d (cutonce:civil-doc) (cutonce:on-p "StdScanBlocks")))
      (cohealth:write d facts "Audit" T)
      T
    )
    (progn (princ (strcat "\nSkipped (never saved): " (cond ((cutonce:str-prop d 'Name)) ("?")))) nil)
  )
)

(defun c:CUTONCE-AUDIT ( / acadApp original n r)
  (setq acadApp (vlax-get-acad-object) original (cutonce:active-doc) n 0)
  (if (not (cutonce:civil-app))
    (princ "\nCivil 3D COM is not connected - Styles and settings will read n/a. Run CUTONCE-FINDCIVIL to fix.")
  )
  (vlax-for d (vla-get-Documents acadApp)
    (vl-catch-all-apply 'vla-put-ActiveDocument (list acadApp d))
    (setq r (vl-catch-all-apply 'cohealth:audit-doc (list d)))
    (cond ((vl-catch-all-error-p r)
           (princ (strcat "\nFailed: " (cond ((cutonce:str-prop d 'Name)) ("?")) " - " (vl-catch-all-error-message r))))
          (r (setq n (1+ n))))
  )
  (vl-catch-all-apply 'vla-put-ActiveDocument (list acadApp original))
  (princ (strcat "\n" (itoa n) " drawing(s) recorded in " (cohealth:path)))
  (if (> n 0) (cohealth:open-in-excel (cohealth:path)))
  (princ)
)

;; CUTONCE-AUDIT-FOLDER: opens each .dwg (visibly - Civil 3D objects are not
;; reliably readable through ObjectDBX), records it, closes it without saving.
(defun c:CUTONCE-AUDIT-FOLDER ( / acadApp picked folder d n r)
  (setq acadApp (vlax-get-acad-object) n 0)
  (setq picked (getfiled "Pick any .dwg in the folder to audit (every .dwg in it will be processed)" "" "dwg" 16))
  (if (not picked)
    (princ "\nCancelled.")
    (progn
      (setq folder (vl-filename-directory picked))
      (foreach fn (vl-directory-files folder "*.dwg" 1)
        (setq d (vl-catch-all-apply 'vla-open (list (vla-get-Documents acadApp) (strcat folder "\\" fn))))
        (if (vl-catch-all-error-p d)
          (princ (strcat "\nSkipped (could not open): " fn))
          (progn
            (vl-catch-all-apply 'vla-put-ActiveDocument (list acadApp d))
            (setq r (vl-catch-all-apply 'cohealth:audit-doc (list d)))
            (if (and r (not (vl-catch-all-error-p r))) (setq n (1+ n)))
            (vl-catch-all-apply 'vla-close (list d :vlax-false))
          )
        )
      )
      (princ (strcat "\n" (itoa n) " drawing(s) recorded in " (cohealth:path)))
      (if (> n 0) (cohealth:open-in-excel (cohealth:path)))
    )
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Save reactor. Kept in a global so it is not garbage-collected; guarded so
;; a reload does not stack duplicates.
;; ---------------------------------------------------------------------------

(if (not (boundp '*cohealth:save-reactor*)) (setq *cohealth:save-reactor* nil))

(defun cohealth:init ( / r)
  (if (not *cohealth:save-reactor*)
    (progn
      (setq r (vl-catch-all-apply 'vlr-editor-reactor
                (list nil (list (cons :vlr-beginSave 'cohealth:begin-save)))))
      (if (vl-catch-all-error-p r)
        (cohealth:log "Could not start the save hook; run CUTONCE-GUARD-CHECKNOW by hand.")
        (setq *cohealth:save-reactor* r)
      )
    )
  )
)

(cohealth:init)
(princ)
