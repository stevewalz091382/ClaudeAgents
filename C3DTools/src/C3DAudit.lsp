;;; ============================================================================
;;; C3DAudit.lsp
;;;
;;; Drawing audit report for Civil 3D. For each drawing it records:
;;;   - layers, linetypes, blocks, layouts, xrefs, Civil 3D style count
;;;   - alignments, surfaces, corridors, profiles
;;;   - gravity pipe networks, pipes and structures
;;;   - drawing settings (angular units, coordinate system, INSUNITS, DIMSCALE)
;;;   - per-xref detail (name, path, overlay flag)
;;;
;;; Output, in the C3DTools log folder (see C3DTOOLS-STATUS):
;;;   Civil3D_Audit_Report.csv      one row per drawing (latest audit wins)
;;;   Civil3D_Audit_XrefDetail.csv  one row per xref per drawing
;;;
;;; On save: after a drawing is saved, only THAT drawing is re-audited and its
;;; rows in both CSVs are replaced. Other open drawings are not touched. Turn
;;; this off with ("AuditOnSave" . nil) in C3DTools-Config.lsp.
;;;
;;; Commands:
;;;   C3DAUDIT         audit every open drawing and open the report in Excel
;;;   C3DAUDIT-FOLDER  open, audit and close every .dwg in a chosen folder
;;;
;;; Civil 3D COM property names can change between releases. Every Civil 3D
;;; lookup fails safe to 0 or "n/a"; spot-check a few numbers against
;;; Toolspace the first time you run this on a new release.
;;;
;;; Naming: every function and global here starts with c3daudit: / *c3daudit:.
;;; Requires C3DTools-Core.lsp.
;;; ============================================================================

(vl-load-com)

(defun c3daudit:report-path ( ) (c3dt:log-file "Civil3D_Audit_Report.csv"))
(defun c3daudit:xref-path ( )   (c3dt:log-file "Civil3D_Audit_XrefDetail.csv"))

(defun c3daudit:na (v) (if (null v) "n/a" v))

(defun c3daudit:getvar (doc name / r)
  (setq r (vl-catch-all-apply 'vlax-invoke (list doc 'GetVariable name)))
  (if (vl-catch-all-error-p r) "n/a" r)
)

;; ---------------------------------------------------------------------------
;; Xref overlay flag: block-record group 70, bit 8 = overlay.
;; ---------------------------------------------------------------------------

(defun c3daudit:xref-overlay (blk / ent flags)
  (setq ent (vl-catch-all-apply 'vlax-vla-object->ename (list blk)))
  (if (vl-catch-all-error-p ent)
    "Unknown"
    (progn
      (setq flags (cdr (assoc 70 (entget ent))))
      (if (and flags (= 8 (logand flags 8))) "True" "False")
    )
  )
)

;; ---------------------------------------------------------------------------
;; Civil 3D style collections. Each name is tried on the Civil document, then
;; on its Styles and Settings objects. Which root (if any) holds each name is
;; cached for the session, so later saves make one COM call per style family
;; and skip names this release does not have.
;; ---------------------------------------------------------------------------

(setq *c3daudit:style-collections*
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

;; ("StyleName" . root-index) where root-index is 0, 1, 2, or -1 for "none".
(setq *c3daudit:style-root-cache* nil)

(defun c3daudit:count-styles (civilDoc / roots total cached idx n)
  (setq roots (list civilDoc (c3dt:prop civilDoc 'Styles) (c3dt:prop civilDoc 'Settings)))
  (setq total 0)
  (foreach nm *c3daudit:style-collections*
    (setq cached (assoc nm *c3daudit:style-root-cache*))
    (cond
      ((and cached (= (cdr cached) -1)) nil)
      (cached
       (setq total (+ total (c3dt:prop-count (nth (cdr cached) roots) nm))))
      (T
       (setq idx 0 n nil)
       (while (and (< idx 3) (not n))
         (if (nth idx roots)
           (setq n (c3dt:prop (nth idx roots) nm))
         )
         (if (not n) (setq idx (1+ idx)))
       )
       (if n
         (progn
           (setq total (+ total (c3dt:count n)))
           (setq *c3daudit:style-root-cache* (cons (cons nm idx) *c3daudit:style-root-cache*))
         )
         (setq *c3daudit:style-root-cache* (cons (cons nm -1) *c3daudit:style-root-cache*))
       )
      )
    )
  )
  total
)

;; ---------------------------------------------------------------------------
;; Per-drawing metrics.
;; Returns (list (list metric-name value) ... (list "XrefDetail" xref-rows)).
;; civilDoc may be nil (plain AutoCAD, or no COM connection).
;; ---------------------------------------------------------------------------

(defun c3daudit:metrics (doc civilDoc / nXrefs xrefRows nAlign nSurf nCorr nProf
                                       nNet nPipe nStruct styleTotal unitZone docname docpath)
  (setq docname (cond ((c3dt:str-prop doc 'Name)) ("")))
  (setq docpath (cond ((c3dt:str-prop doc 'FullName)) ("")))
  (setq nXrefs 0 xrefRows nil)
  (vlax-for blk (vla-get-Blocks doc)
    (if (eq (c3dt:prop blk 'IsXRef) :vlax-true)
      (setq nXrefs (1+ nXrefs)
            xrefRows (cons (list docname (vla-get-Name blk)
                                 (c3daudit:na (c3dt:str-prop blk 'Path))
                                 (c3daudit:xref-overlay blk)
                                 docpath)
                           xrefRows))
    )
  )
  (if civilDoc
    (progn
      (setq nAlign (c3dt:prop-count civilDoc 'Alignments)
            nSurf  (c3dt:prop-count civilDoc 'Surfaces)
            nCorr  (c3dt:prop-count civilDoc 'Corridors))
      (setq nProf 0)
      (foreach al (c3dt:collection->list (c3dt:prop civilDoc 'Alignments))
        (setq nProf (+ nProf (c3dt:prop-count al 'Profiles)))
      )
      (setq nNet 0 nPipe 0 nStruct 0)
      (foreach net (c3dt:collection->list (c3dt:prop civilDoc 'Pipenetworks))
        (setq nNet    (1+ nNet)
              nPipe   (+ nPipe   (c3dt:prop-count net 'Pipes))
              nStruct (+ nStruct (c3dt:prop-count net 'Structures)))
      )
      (setq styleTotal (c3daudit:count-styles civilDoc))
      (setq unitZone (c3dt:prop (c3dt:prop (c3dt:prop civilDoc 'Settings) 'DrawingSettings) 'UnitZoneSettings))
    )
    (setq nAlign "n/a" nSurf "n/a" nCorr "n/a" nProf "n/a"
          nNet "n/a" nPipe "n/a" nStruct "n/a" styleTotal "n/a" unitZone nil)
  )
  (list
    (list "DocumentFileName"           docname)
    (list "DocumentPath"               docpath)
    (list "NumberOfLayers"             (c3dt:count (vla-get-Layers doc)))
    (list "NumberOfLinetypes"          (c3dt:count (vla-get-Linetypes doc)))
    (list "NumberOfBlocks"             (c3dt:count (vla-get-Blocks doc)))
    (list "NumberOfLayouts"            (c3dt:count (vla-get-Layouts doc)))
    (list "NumberOfXrefs"              nXrefs)
    (list "NumberOfStyles"             styleTotal)
    (list "NumberOfAlignments"         nAlign)
    (list "NumberOfSurfaces"           nSurf)
    (list "NumberOfCorridors"          nCorr)
    (list "NumberOfProfiles"           nProf)
    (list "NumberOfGravityNetworks"    nNet)
    (list "NumberOfGravityPipes"       nPipe)
    (list "NumberOfGravityStructures"  nStruct)
    (list "AngularUnits"               (c3daudit:na (c3dt:prop unitZone 'AngularUnits)))
    (list "ImperialToMetricConversion" (c3daudit:na (c3dt:prop unitZone 'ImperialToMetricConversion)))
    (list "CoordinateSystem"           (c3daudit:na (c3dt:prop unitZone 'CoordinateSystemCode)))
    (list "InsUnits"                   (c3daudit:getvar doc "INSUNITS"))
    (list "DrawingScale"               (c3daudit:getvar doc "DIMSCALE"))
    (list "AuditedAt"                  (c3dt:timestamp))
    (list "XrefDetail"                 (reverse xrefRows))
  )
)

(defun c3daudit:row-metrics (row) (reverse (cdr (reverse row))))

;; ---------------------------------------------------------------------------
;; CSV upsert: replace this drawing's rows, keep every other drawing's rows.
;; keyIndex is the 0-based column that identifies the drawing.
;; ---------------------------------------------------------------------------

(defun c3daudit:upsert (path header keyIndex keyValues newLines / old kept fields)
  (setq old (c3dt:read-lines path) kept nil)
  ;; a header from an older layout means the old rows cannot be merged
  (if (and old (= (car old) header))
    (foreach line (cdr old)
      (setq fields (c3dt:csv-split line ","))
      (if (not (member (nth keyIndex fields) keyValues)) (setq kept (cons line kept)))
    )
  )
  (c3dt:write-lines path (append (list header) (reverse kept) newLines))
)

;; rows: list of metric lists as returned by c3daudit:metrics
(defun c3daudit:write-rows (rows / header keys reportLines xrefLines)
  (setq header (c3dt:join (mapcar 'car (c3daudit:row-metrics (car rows))) ","))
  (setq keys nil reportLines nil xrefLines nil)
  (foreach row rows
    (setq keys (cons (cadr (assoc "DocumentPath" row)) keys))
    (setq reportLines (cons (c3dt:csv-row (mapcar 'cadr (c3daudit:row-metrics row))) reportLines))
    (foreach xr (cadr (last row))
      (setq xrefLines (cons (c3dt:csv-row xr) xrefLines))
    )
  )
  ;; both sheets are keyed by the drawing's full path
  (c3daudit:upsert (c3daudit:report-path) header 1 keys (reverse reportLines))
  (c3daudit:upsert (c3daudit:xref-path) "DrawingFile,XrefName,XrefPath,IsOverlay,DrawingPath" 4
    keys (reverse xrefLines))
)

;; ---------------------------------------------------------------------------
;; Excel presentation (manual commands only)
;; ---------------------------------------------------------------------------

(defun c3daudit:open-in-excel (csvpath / xl wb ws used lastRow lastCol dataRange win)
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
        (setq lastRow (vlax-get-property (vlax-get-property used 'Rows) 'Count))
        (setq lastCol (vlax-get-property (vlax-get-property used 'Columns) 'Count))
        (if (> lastRow 1)
          (progn
            (setq dataRange (vlax-invoke ws 'Range (vlax-invoke ws 'Cells 2 3) (vlax-invoke ws 'Cells lastRow lastCol)))
            (vl-catch-all-apply 'vlax-invoke (list (vlax-get-property dataRange 'FormatConditions) 'AddColorScale 3))
          )
        )
        (vlax-invoke (vlax-get-property used 'Columns) 'AutoFit)
        (setq win (vlax-get-property xl 'ActiveWindow))
        (vlax-put-property win 'SplitRow 1)
        (vlax-put-property win 'FreezePanes :vlax-true)
      ))
    )
  )
)

;; ---------------------------------------------------------------------------
;; Audit of the current drawing only (save hook and fast path).
;; ---------------------------------------------------------------------------

(defun c3daudit:audit-current ( / doc)
  (setq doc (c3dt:active-doc))
  (if (c3dt:nonblank (c3dt:str-prop doc 'FullName))
    (c3daudit:write-rows (list (c3daudit:metrics doc (c3dt:civil-doc))))
  )
)

;; ---------------------------------------------------------------------------
;; C3DAUDIT: every open drawing. Each drawing is made active in turn so the
;; Civil 3D ActiveDocument follows it, then the original drawing is restored.
;; ---------------------------------------------------------------------------

(defun c:C3DAUDIT ( / acadApp original rows)
  (setq acadApp (vlax-get-acad-object) original (c3dt:active-doc) rows nil)
  (if (not (c3dt:civil-app))
    (princ "\nCivil 3D COM is not connected - Civil 3D counts will read n/a. Run C3DTOOLS-FINDCIVIL to fix.")
  )
  (vlax-for d (vla-get-Documents acadApp)
    (vl-catch-all-apply 'vla-put-ActiveDocument (list acadApp d))
    (setq rows (cons (c3daudit:metrics d (c3dt:civil-doc)) rows))
  )
  (vl-catch-all-apply 'vla-put-ActiveDocument (list acadApp original))
  (if rows
    (progn
      (c3daudit:write-rows (reverse rows))
      (princ (strcat "\nWrote " (c3daudit:report-path)))
      (c3daudit:open-in-excel (c3daudit:report-path))
    )
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; C3DAUDIT-FOLDER: opens each .dwg (visibly - Civil 3D objects are not
;; reliably readable through ObjectDBX), audits it, closes it without saving.
;; ---------------------------------------------------------------------------

(defun c:C3DAUDIT-FOLDER ( / acadApp picked folder d rows)
  (setq acadApp (vlax-get-acad-object) rows nil)
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
            (setq rows (cons (c3daudit:metrics d (c3dt:civil-doc)) rows))
            (vl-catch-all-apply 'vla-close (list d :vlax-false))
          )
        )
      )
      (if rows
        (progn
          (c3daudit:write-rows (reverse rows))
          (princ (strcat "\nWrote " (c3daudit:report-path)))
          (c3daudit:open-in-excel (c3daudit:report-path))
        )
        (princ "\nNo drawings were audited.")
      )
    )
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Save hook. :vlr-saveComplete runs after the file is written, so the audit
;; never delays the save itself. Failures are swallowed.
;; ---------------------------------------------------------------------------

(defun c3daudit:on-save (reactor arglist)
  (vl-catch-all-apply 'c3daudit:audit-current nil)
  (princ)
)

(if (not (boundp '*c3daudit:save-reactor*)) (setq *c3daudit:save-reactor* nil))

(defun c3daudit:init ( / r)
  (if (and (c3dt:cfg "AuditOnSave" T) (not *c3daudit:save-reactor*))
    (progn
      (setq r (vl-catch-all-apply 'vlr-editor-reactor
                (list nil (list (cons :vlr-saveComplete 'c3daudit:on-save)))))
      (if (vl-catch-all-error-p r)
        (c3dt:msg "C3D-AUDIT" "Could not start the audit-on-save hook; run C3DAUDIT by hand.")
        (setq *c3daudit:save-reactor* r)
      )
    )
  )
)

(c3daudit:init)
(princ)
