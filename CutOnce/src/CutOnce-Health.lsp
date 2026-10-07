;;; ============================================================================
;;; CutOnce-Health.lsp
;;;
;;; One health record per drawing check, kept as history. This replaces the
;;; separate audit report (Civil3D_Audit_Report.csv and
;;; Civil3D_Audit_XrefDetail.csv); every column those files had is here.
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
;;; Naming: every function and global here starts with mwhealth: / *mwhealth:.
;;; Requires CutOnce-Core.lsp and CutOnce-Standards.lsp.
;;; ============================================================================

(vl-load-com)

(defun mwhealth:log (msg) (mwise:msg "CutOnce Health" msg))

(defun mwhealth:path ( )      (mwise:log-file "Health.csv"))
(defun mwhealth:xrefs-path ( ) (mwise:log-file "Xrefs.csv"))

;; ---------------------------------------------------------------------------
;; Columns
;; ---------------------------------------------------------------------------

(setq *mwhealth:id-columns* '("Timestamp" "Trigger" "User" "DrawingPath" "DrawingName"))

(setq *mwhealth:metric-columns*
  '("Layers" "Linetypes" "Blocks" "Layouts" "RegApps" "Styles"
    "Alignments" "Profiles" "ProfileViews" "Surfaces" "Corridors" "Assemblies"
    "PipeNetworks" "GravityPipes" "GravityStructures" "PressurePipeNetworks"
    "SectionViews" "Sections" "Hatches" "TextObjects"
    "ColorNotByLayer" "LinetypeNotByLayer" "ObjectsNotByLayer"
    "BlockDefColorNotByLayer" "BlockDefLinetypeNotByLayer"
    "Xrefs" "XrefsBroken" "XrefsUnloaded" "XrefsOffOrigin"))

(setq *mwhealth:setting-columns*
  '("AngularUnits" "ImperialToMetricConversion" "CoordinateSystem" "InsUnits" "DrawingScale"))

;; Metrics compared against the previous check for unusual growth.
(setq *mwhealth:growth-watch*
  '("Layers" "Linetypes" "Blocks" "Layouts" "Xrefs" "RegApps" "Styles"
    "Alignments" "Profiles" "ProfileViews" "Surfaces" "Corridors" "Assemblies"
    "PipeNetworks" "PressurePipeNetworks" "SectionViews" "Sections"
    "Hatches" "TextObjects"))

(defun mwhealth:columns ( )
  (append *mwhealth:id-columns* *mwhealth:metric-columns* *mwhealth:setting-columns*)
)

(defun mwhealth:header ( ) (mwise:join (mwhealth:columns) ","))

(setq *mwhealth:xref-header*
  (strcat "Timestamp,Trigger,User,DrawingPath,DrawingName,XrefName,XrefPath,Type,Status,"
          "Nested,Instances,InsertX,InsertY,InsertZ,Rotation,Scale,AtOrigin"))

(defun mwhealth:growth-pct ( / v)
  (setq v (mwise:cfg "GuardGrowthWarnPct" 20))
  (if (numberp v) v 20)
)

;; ---------------------------------------------------------------------------
;; Civil 3D style collections (from the former audit report). Each name is
;; tried on the Civil document, then on its Styles and Settings objects.
;; Which root (if any) holds each name is cached for the session.
;; ---------------------------------------------------------------------------

(setq *mwhealth:style-collections*
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

(setq *mwhealth:style-root-cache* nil)

(defun mwhealth:count-styles (civilDoc / roots total cached idx n)
  (setq roots (list civilDoc (mwise:prop civilDoc 'Styles) (mwise:prop civilDoc 'Settings)))
  (setq total 0)
  (foreach nm *mwhealth:style-collections*
    (setq cached (assoc nm *mwhealth:style-root-cache*))
    (cond
      ((and cached (= (cdr cached) -1)) nil)
      (cached
       (setq total (+ total (mwise:prop-count (nth (cdr cached) roots) nm))))
      (T
       (setq idx 0 n nil)
       (while (and (< idx 3) (not n))
         (if (nth idx roots) (setq n (mwise:prop (nth idx roots) nm)))
         (if (not n) (setq idx (1+ idx)))
       )
       (if n
         (progn
           (setq total (+ total (mwise:count n)))
           (setq *mwhealth:style-root-cache* (cons (cons nm idx) *mwhealth:style-root-cache*)))
         (setq *mwhealth:style-root-cache* (cons (cons nm -1) *mwhealth:style-root-cache*))
       )
      )
    )
  )
  total
)

(defun mwhealth:getvar (doc name / r)
  (setq r (vl-catch-all-apply 'vlax-invoke (list doc 'GetVariable name)))
  (if (vl-catch-all-error-p r) "n/a" r)
)

(defun mwhealth:na (v) (if (null v) "n/a" v))

(defun mwhealth:sum (objcounts wildcard / total)
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
;; Returns the standards facts (see mwstd:collect) plus one pair per column.
;; ---------------------------------------------------------------------------

(defun mwhealth:collect (doc civilDoc scanblocks / std oc unitZone)
  (setq std (mwstd:collect doc scanblocks))
  (setq oc (mwstd:fact std "objcounts"))
  (if civilDoc
    (setq unitZone (mwise:prop (mwise:prop (mwise:prop civilDoc 'Settings) 'DrawingSettings) 'UnitZoneSettings))
  )
  (append
    std
    (list
      (cons "Layers"               (mwise:count (vla-get-Layers doc)))
      (cons "Linetypes"            (mwise:count (vla-get-Linetypes doc)))
      (cons "Blocks"               (mwise:count (vla-get-Blocks doc)))
      (cons "Layouts"              (mwise:count (vla-get-Layouts doc)))
      (cons "RegApps"              (mwise:count (vla-get-RegisteredApplications doc)))
      (cons "Styles"               (if civilDoc (mwhealth:count-styles civilDoc) "n/a"))
      (cons "Alignments"           (mwhealth:sum oc "AECCDBALIGNMENT"))
      (cons "Profiles"             (mwhealth:sum oc "AECCDBVALIGNMENT"))
      (cons "ProfileViews"         (mwhealth:sum oc "AECCDBGRAPHPROFILE"))
      (cons "Surfaces"             (mwhealth:sum oc "AECCDBSURFACETIN,AECCDBSURFACEGRID,AECCDBSURFACEVOLUME"))
      (cons "Corridors"            (mwhealth:sum oc "AECCDBCORRIDOR"))
      (cons "Assemblies"           (mwhealth:sum oc "AECCDBASSEMBLY"))
      (cons "PipeNetworks"         (mwhealth:sum oc "AECCDBNETWORK"))
      (cons "GravityPipes"         (mwhealth:sum oc "AECCDBPIPE"))
      (cons "GravityStructures"    (mwhealth:sum oc "AECCDBSTRUCTURE"))
      (cons "PressurePipeNetworks" (mwhealth:sum oc "AECCDBPRESSUREPIPENETWORK,AECCDBPRESSURENETWORK"))
      (cons "SectionViews"         (mwhealth:sum oc "AECCDBSECTIONVIEW"))
      (cons "Sections"             (mwhealth:sum oc "AECCDBSECTION"))
      (cons "AngularUnits"               (if civilDoc (mwhealth:na (mwise:prop unitZone 'AngularUnits)) "n/a"))
      (cons "ImperialToMetricConversion" (if civilDoc (mwhealth:na (mwise:prop unitZone 'ImperialToMetricConversion)) "n/a"))
      (cons "CoordinateSystem"           (if civilDoc (mwhealth:na (mwise:prop unitZone 'CoordinateSystemCode)) "n/a"))
      (cons "InsUnits"                   (mwhealth:getvar doc "INSUNITS"))
      (cons "DrawingScale"               (mwhealth:getvar doc "DIMSCALE"))
    )
  )
)

;; ---------------------------------------------------------------------------
;; Writing
;; ---------------------------------------------------------------------------

;; Previous check of a drawing, as ((column . value) ...). The first lookup
;; in a session reads Health.csv; later ones use memory.
(setq *mwhealth:last* nil)

(defun mwhealth:remember (drawpath facts)
  (setq *mwhealth:last*
    (cons drawpath
          (mapcar (function (lambda (c) (cons c (cdr (assoc c facts))))) *mwhealth:metric-columns*)))
)

(defun mwhealth:previous (drawpath / lines pidx lastrow fields)
  (if (and *mwhealth:last* (= (car *mwhealth:last*) drawpath))
    (cdr *mwhealth:last*)
    (progn
      (setq lines (mwise:read-lines (mwhealth:path)))
      (if (and lines (= (car lines) (mwhealth:header)))
        (progn
          (setq pidx (vl-position "DrawingPath" (mwhealth:columns)))
          (foreach line (cdr lines)
            (setq fields (mwise:csv-split line ","))
            (if (and (> (length fields) pidx) (= (nth pidx fields) drawpath)) (setq lastrow fields))
          )
          (if lastrow
            (mapcar (function (lambda (c v) (cons c (if (wcmatch v "#*") (atoi v) v))))
                    (mwhealth:columns) lastrow))
        )
      )
    )
  )
)

(defun mwhealth:row (trigger drawpath drawname facts)
  (strcat
    (mwise:csv-row (list (mwise:timestamp) trigger (mwise:user) drawpath drawname))
    ","
    (mwise:csv-row (mapcar (function (lambda (c) (cdr (assoc c facts))))
                          (append *mwhealth:metric-columns* *mwhealth:setting-columns*))))
)

(defun mwhealth:xref-rows (trigger drawpath drawname facts / ts user pt)
  (setq ts (mwise:timestamp) user (mwise:user))
  (mapcar
    (function (lambda (x)
      ;; x = (name path type status nested instances point rotation scale atOrigin)
      (setq pt (nth 6 x))
      (mwise:csv-row
        (list ts trigger user drawpath drawname
              (nth 0 x) (nth 1 x) (nth 2 x) (nth 3 x) (nth 4 x) (nth 5 x)
              (if pt (car pt)) (if pt (cadr pt)) (if pt (caddr pt))
              (nth 7 x) (nth 8 x) (nth 9 x)))))
    (mwstd:fact facts "xrefdetail"))
)

;; Writes the Health.csv row (and Xrefs.csv rows when that log is on).
;; force = T writes even when logging is switched off (explicit CUTONCE-AUDIT).
(defun mwhealth:write (doc facts trigger force / drawpath drawname)
  (setq drawpath (cond ((mwise:str-prop doc 'FullName)) (""))
        drawname (cond ((mwise:str-prop doc 'Name)) ("")))
  (mwise:append-line (mwhealth:path) (mwhealth:header)
                    (mwhealth:row trigger drawpath drawname facts))
  (if (or force (mwise:log-on-p "LogXrefs"))
    (mwise:append-lines (mwhealth:xrefs-path) *mwhealth:xref-header*
                       (mwhealth:xref-rows trigger drawpath drawname facts))
  )
)

;; ---------------------------------------------------------------------------
;; Save-time checks: unusual growth and xrefs off 0,0,0
;; ---------------------------------------------------------------------------

(defun mwhealth:growth-flags (prev facts / flags oldv newv)
  (setq flags nil)
  (if prev
    (foreach metric *mwhealth:growth-watch*
      (setq oldv (cdr (assoc metric prev)) newv (cdr (assoc metric facts)))
      (if (and (numberp oldv) (numberp newv))
        (cond
          ((and (= metric "RegApps") (> newv oldv))
           (setq flags (cons (list metric oldv newv "new registered app(s), often left by a bind or a foreign block") flags)))
          ((and (= oldv 0) (> newv 0))
           (setq flags (cons (list metric oldv newv "new since the last check") flags)))
          ((and (> oldv 0) (>= (* 100.0 (/ (float (- newv oldv)) oldv)) (mwhealth:growth-pct)))
           (setq flags (cons (list metric oldv newv
                                   (strcat "up " (rtos (* 100.0 (/ (float (- newv oldv)) oldv)) 2 0) "% since the last check"))
                             flags)))
        )
      )
    )
  )
  (reverse flags)
)

(defun mwhealth:alert-growth (drawname flags)
  (mwise:log-event "SAVE-FLAG"
    (apply 'strcat (mapcar (function (lambda (x) (strcat (car x) " " (itoa (cadr x)) "->" (itoa (caddr x)) "  "))) flags)))
  (mwise:notice
    (strcat
      "CutOnce Guard: unusual growth since the last check of\n" drawname ":\n\n"
      (apply 'strcat
        (mapcar (function (lambda (x)
                  (strcat "  " (car x) ": " (itoa (cadr x)) " -> " (itoa (caddr x)) "  (" (nth 3 x) ")\n")))
                flags))
      "\nFull history: " (mwhealth:path)
      "\nTurn this check off in the CutOnce Control Center (type CUTONCE)."
    )
    "GUARD_GROWTH"
  )
)

(defun mwhealth:alert-origin (badpts)
  (mwise:log-event "XREF-BASEPOINT" (apply 'strcat (mapcar (function (lambda (p) (strcat (car p) "  "))) badpts)))
  (mwise:notice
    (strcat
      "CutOnce Guard: xref insertion point(s) are not at 0,0,0:\n\n"
      (apply 'strcat
        (mapcar (function (lambda (p) (strcat "  " (car p) ": " (mwstd:pt-text (cadr p)) "\n")))
                badpts))
      "\nA non-zero xref insertion point commonly causes misalignment against\n"
      "a shared coordinate system or data shortcuts."
      "\nTurn this check off in the CutOnce Control Center (type CUTONCE)."
    )
    "GUARD_XREF_ORIGIN"
  )
)

;; trigger: "Save" (reactor) or "Manual" (CUTONCE-GUARD-CHECKNOW).
;; Manual runs both alerts and writes the row whatever the settings say.
(defun mwhealth:check (trigger / manual doc drawpath drawname wantLog wantGrowth wantOrigin facts prev flags badpts)
  (setq manual (= trigger "Manual"))
  (setq wantLog    (or manual (mwise:log-on-p "LogHealthOnSave"))
        wantGrowth (or manual (mwise:on-p "GuardGrowth"))
        wantOrigin (or manual (mwise:on-p "GuardXrefOrigin")))
  (setq doc (mwise:active-doc))
  (setq drawpath (mwise:nonblank (mwise:str-prop doc 'FullName))
        drawname (cond ((mwise:str-prop doc 'Name)) ("")))
  (cond
    ((not (or wantLog wantGrowth wantOrigin)) nil)
    ((or (not drawpath) (/= (getvar "DWGTITLED") 1))
     (mwhealth:log "This drawing has not been saved yet - health check skipped."))
    (T
     (setq facts (mwhealth:collect doc (mwise:civil-doc) (mwise:on-p "StdScanBlocks")))
     (if wantGrowth
       (progn
         (setq prev (vl-catch-all-apply 'mwhealth:previous (list drawpath)))
         (if (vl-catch-all-error-p prev) (setq prev nil))
       )
     )
     (if wantLog (vl-catch-all-apply 'mwhealth:write (list doc facts trigger manual)))
     (mwhealth:remember drawpath facts)
     (if (and wantGrowth (setq flags (mwhealth:growth-flags prev facts)))
       (mwhealth:alert-growth drawname flags))
     (if (and wantOrigin (setq badpts (mwstd:fact facts "offorigin")))
       (mwhealth:alert-origin badpts))
    )
  )
)

(defun mwhealth:begin-save (reactor arglist)
  (vl-catch-all-apply 'mwhealth:check (list "Save"))
  (princ)
)

;; ---------------------------------------------------------------------------
;; Open: called once by the Control Center when a saved drawing finishes
;; loading. One scan feeds both the standards dialog and the Health.csv row.
;; Civil 3D COM is deliberately not used here (it may not be ready while
;; Civil 3D is still starting), so Styles and settings read n/a.
;; ---------------------------------------------------------------------------

(defun mwhealth:on-open ( / doc drawpath wantCheck wantLog facts)
  (setq wantCheck (mwise:on-p "StdCheckOnOpen")
        wantLog   (mwise:log-on-p "LogHealthOnOpen"))
  (setq doc (mwise:active-doc))
  (if (and (= 1 (getvar "DWGTITLED"))
           (setq drawpath (mwise:nonblank (mwise:str-prop doc 'FullName)))
           (or wantCheck wantLog))
    (progn
      (setq facts (mwhealth:collect doc nil (mwise:on-p "StdScanBlocks")))
      (if wantLog (vl-catch-all-apply 'mwhealth:write (list doc facts "Open" nil)))
      ;; the state at open is the baseline for this session's first save
      (mwhealth:remember drawpath facts)
      (if wantCheck (mwstd:show-report facts (cond ((mwise:str-prop doc 'Name)) ("")) nil))
    )
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Excel presentation (manual commands only)
;; ---------------------------------------------------------------------------

(defun mwhealth:open-in-excel (csvpath / xl wb ws used win)
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

(defun mwhealth:audit-doc (d / facts)
  (if (mwise:nonblank (mwise:str-prop d 'FullName))
    (progn
      (setq facts (mwhealth:collect d (mwise:civil-doc) (mwise:on-p "StdScanBlocks")))
      (mwhealth:write d facts "Audit" T)
      T
    )
    (progn (princ (strcat "\nSkipped (never saved): " (cond ((mwise:str-prop d 'Name)) ("?")))) nil)
  )
)

(defun c:CUTONCE-AUDIT ( / acadApp original n r)
  (setq acadApp (vlax-get-acad-object) original (mwise:active-doc) n 0)
  (if (not (mwise:civil-app))
    (princ "\nCivil 3D COM is not connected - Styles and settings will read n/a. Run CUTONCE-FINDCIVIL to fix.")
  )
  (vlax-for d (vla-get-Documents acadApp)
    (vl-catch-all-apply 'vla-put-ActiveDocument (list acadApp d))
    (setq r (vl-catch-all-apply 'mwhealth:audit-doc (list d)))
    (cond ((vl-catch-all-error-p r)
           (princ (strcat "\nFailed: " (cond ((mwise:str-prop d 'Name)) ("?")) " - " (vl-catch-all-error-message r))))
          (r (setq n (1+ n))))
  )
  (vl-catch-all-apply 'vla-put-ActiveDocument (list acadApp original))
  (princ (strcat "\n" (itoa n) " drawing(s) recorded in " (mwhealth:path)))
  (if (> n 0) (mwhealth:open-in-excel (mwhealth:path)))
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
            (setq r (vl-catch-all-apply 'mwhealth:audit-doc (list d)))
            (if (and r (not (vl-catch-all-error-p r))) (setq n (1+ n)))
            (vl-catch-all-apply 'vla-close (list d :vlax-false))
          )
        )
      )
      (princ (strcat "\n" (itoa n) " drawing(s) recorded in " (mwhealth:path)))
      (if (> n 0) (mwhealth:open-in-excel (mwhealth:path)))
    )
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Save reactor. Kept in a global so it is not garbage-collected; guarded so
;; a reload does not stack duplicates.
;; ---------------------------------------------------------------------------

(if (not (boundp '*mwhealth:save-reactor*)) (setq *mwhealth:save-reactor* nil))

(defun mwhealth:init ( / r)
  (if (not *mwhealth:save-reactor*)
    (progn
      (setq r (vl-catch-all-apply 'vlr-editor-reactor
                (list nil (list (cons :vlr-beginSave 'mwhealth:begin-save)))))
      (if (vl-catch-all-error-p r)
        (mwhealth:log "Could not start the save hook; run CUTONCE-GUARD-CHECKNOW by hand.")
        (setq *mwhealth:save-reactor* r)
      )
    )
  )
)

(mwhealth:init)
(princ)
