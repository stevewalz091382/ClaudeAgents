;;; ======================================================================
;;; UtilityClashDetection.lsp
;;;
;;; Civil 3D 2027 - Proactive utility network clearance clash detection.
;;;
;;; WHAT IT DOES
;;;   1. Prompts the user, when a drawing is opened/activated, whether
;;;      gravity and/or pressure pipe utility networks will be designed
;;;      in that drawing.
;;;   2. If yes, asks for the required MINIMUM clear (edge-to-edge, not
;;;      centerline-to-centerline) HORIZONTAL and VERTICAL separations for:
;;;         - Gravity pipe   <-> Gravity pipe
;;;         - Pressure pipe  <-> Pressure pipe
;;;         - Gravity pipe   <-> Pressure pipe
;;;         - Any pipe       <-> Structure / Fitting / Appurtenance
;;;   3. On demand (UTILCLASHCHECK), scans the drawing's gravity Pipe
;;;      Network parts (Pipes, Structures) and Pressure Network parts
;;;      (Pressure Pipes, Fittings, Appurtenances), computes the true 3D
;;;      clearance between every pair of parts, and flags any location
;;;      where BOTH the horizontal and vertical clearance fall short of
;;;      the criteria entered in step 2.
;;;   4. Each conflict is flagged in the drawing at the conflict location
;;;      with descriptive text (attempted as a native Civil 3D General
;;;      Note Label; see LIMITATIONS below for the guaranteed fallback).
;;;
;;; INSTALLATION
;;;   Recommended (multi-drawing sessions, most robust):
;;;     1. Copy this file next to your acaddoc.lsp (or anywhere on the
;;;        AutoCAD support file search path).
;;;     2. Add a line to your acaddoc.lsp:
;;;          (load "UtilityClashDetection.lsp")
;;;        acaddoc.lsp is reloaded automatically into every drawing that
;;;        opens, which is what lets the "prompt on file open" behavior
;;;        work correctly for every drawing, not just the first one.
;;;
;;;   Simple alternative (only ever have one drawing open at a time):
;;;     Tools > Load Application, or add this file to the Startup Suite
;;;     (Options > Files tab > Startup Suite). It will prompt for the
;;;     drawing that is open at the time it loads, and for every drawing
;;;     you subsequently open or switch to during that Civil 3D session.
;;;
;;;   Either way, nothing needs to be NETLOAD'ed - this is pure AutoLISP.
;;;
;;; COMMANDS
;;;   UTILCLASHSETUP     - manually re-run the "will you be designing
;;;                         utilities?" prompt and criteria questions.
;;;   UTILCLASHSETTINGS  - jump straight to (re-)entering the 8 clearance
;;;                         values without the yes/no question.
;;;   UTILCLASHCHECK     - run the clash scan against the criteria last
;;;                         entered (asks for them first if none exist
;;;                         yet in this session).
;;;
;;;   Clearance criteria are stored with (setenv), so they persist across
;;;   drawings and sessions on the same workstation as your standard
;;;   defaults, and are always editable via UTILCLASHSETTINGS.
;;;
;;; LIMITATIONS - PLEASE READ
;;;   - Part detection is class-name based (AECC_PIPE, AECC_STRUCTURE,
;;;     AECC_PRESSURE_PIPE, AECC_PRESSURE_FITTING,
;;;     AECC_PRESSURE_APPURTENANCE) with a full-drawing entity scan as an
;;;     automatic fallback if none of those names are found. Autodesk has
;;;     changed internal class names before; if UTILCLASHCHECK reports
;;;     "0 utility parts found" in a drawing that clearly has networks,
;;;     open one part with (vla-get-ObjectName (vlax-ename->vla-object
;;;     (car (entsel)))) at the command line and add whatever name it
;;;     returns to the UC:PipeClassNames / UC:StructClassNames /
;;;     UC:PPipeClassNames / UC:PFitClassNames / UC:PApptClassNames lists
;;;     near the top of this file.
;;;   - Geometry and diameter are read through several candidate COM
;;;     property names (e.g. InnerDiameterOrWidth, Diameter, StartPoint,
;;;     Location, ...), each wrapped in error trapping, because Civil 3D
;;;     does not publish a stable public AutoLISP API for pipe/pressure
;;;     network parts (the supported automation surface for this data is
;;;     the .NET API). When none of the candidate properties resolve, the
;;;     routine falls back to the part's 3D bounding box to approximate
;;;     its centerline/location and radius. Any conflict involving a part
;;;     whose geometry came from this fallback is tagged "[APPROX GEOM]"
;;;     in its flag text and should be verified manually.
;;;   - Flagging first attempts the native Civil 3D command
;;;     AECCADDGENERALNOTELABEL so the flag is a real General Note Label
;;;     tied to your label style. Whether that command accepts the note
;;;     text non-interactively depends on your current General Note
;;;     label style and Civil 3D's in-place text editor behavior, which
;;;     is not scriptable in a fully version-proof way from AutoLISP. The
;;;     routine checks whether that command actually created something;
;;;     if it did not, it automatically falls back to a plain LEADER +
;;;     text flag on layer C-UTIL-CLASH-FLAG, which always works. Either
;;;     way, every conflict gets a visible flag in the drawing.
;;;   - Pipe endpoints/structure centers that coincide (a real, connected
;;;     joint) are treated as connections, not conflicts, using a small
;;;     tolerance (UC:Tol). Two genuinely separate parts that happen to
;;;     touch by design error will not be flagged if they are closer than
;;;     this tolerance; adjust UC:Tol if needed.
;;;   - This is an O(n^2) pairwise check. For very large models use the
;;;     "Select a work area" option in UTILCLASHCHECK to limit the scan.
;;; ======================================================================

(vl-load-com)

;; ---------------------------------------------------------------------
;; 0. CONFIGURATION
;; ---------------------------------------------------------------------

(setq UC:FlagLayer     "C-UTIL-CLASH-FLAG")
(setq UC:Tol           0.01)   ; distance below which two parts are treated
                                ; as a real connection, not a clash

(setq UC:PipeClassNames  '("AECC_PIPE"))
(setq UC:StructClassNames '("AECC_STRUCTURE"))
(setq UC:PPipeClassNames '("AECC_PRESSURE_PIPE"))
(setq UC:PFitClassNames  '("AECC_PRESSURE_FITTING"))
(setq UC:PApptClassNames '("AECC_PRESSURE_APPURTENANCE"))

(setq *UC:AskedDocs* '())

;; ---------------------------------------------------------------------
;; 1. SMALL HELPERS
;; ---------------------------------------------------------------------

(defun UC:JoinComma (lst / s)
  (setq s (car lst))
  (foreach x (cdr lst) (setq s (strcat s "," x)))
  s
)

(defun UC:TryGetProp (obj propNames / result p v)
  (setq result nil)
  (foreach p propNames
    (if (not result)
      (progn
        (setq v (vl-catch-all-apply 'vlax-get-property (list obj p)))
        (if (not (vl-catch-all-error-p v)) (setq result v))
      )
    )
  )
  result
)

(defun UC:VariantPt (v / r)
  (cond
    ((null v) nil)
    ((listp v) v)
    (t
     (setq r (vl-catch-all-apply 'vlax-safearray->list (list (vl-catch-all-apply 'vlax-variant-value (list v)))))
     (if (vl-catch-all-error-p r) nil r)
    )
  )
)

(defun UC:V- (a b) (mapcar '- a b))
(defun UC:V+ (a b) (mapcar '+ a b))
(defun UC:V* (a s) (mapcar '(lambda (x) (* x s)) a))
(defun UC:Dot (a b) (apply '+ (mapcar '* a b)))
(defun UC:Len (a) (sqrt (UC:Dot a a)))
(defun UC:MidPt (a b) (mapcar '(lambda (x y) (/ (+ x y) 2.0)) a b))
(defun UC:Clamp01 (v) (cond ((< v 0.0) 0.0) ((> v 1.0) 1.0) (t v)))

;; ---------------------------------------------------------------------
;; 2. 3D CLOSEST-POINT-BETWEEN-TWO-SEGMENTS (handles point/point,
;;    point/segment and segment/segment uniformly - a "node" element is
;;    just a degenerate segment whose two endpoints are equal).
;; ---------------------------------------------------------------------

(defun UC:ClosestSegSeg (a1 a2 b1 b2 / d1 d2 r a e f c b s tt denom EPS c1 c2)
  (setq EPS 1e-9)
  (setq d1 (UC:V- a2 a1))
  (setq d2 (UC:V- b2 b1))
  (setq r  (UC:V- a1 b1))
  (setq a (UC:Dot d1 d1))
  (setq e (UC:Dot d2 d2))
  (setq f (UC:Dot d2 r))
  (cond
    ((and (<= a EPS) (<= e EPS))
     (setq s 0.0 tt 0.0)
    )
    ((<= a EPS)
     (setq s 0.0)
     (setq tt (UC:Clamp01 (/ f e)))
    )
    (t
     (setq c (UC:Dot d1 r))
     (cond
       ((<= e EPS)
        (setq tt 0.0)
        (setq s (UC:Clamp01 (/ (- c) a)))
       )
       (t
        (setq b (UC:Dot d1 d2))
        (setq denom (- (* a e) (* b b)))
        (if (> denom EPS)
          (setq s (UC:Clamp01 (/ (- (* b f) (* c e)) denom)))
          (setq s 0.0)
        )
        (setq tt (/ (+ (* b s) f) e))
        (cond
          ((< tt 0.0)
           (setq tt 0.0)
           (setq s (UC:Clamp01 (/ (- c) a)))
          )
          ((> tt 1.0)
           (setq tt 1.0)
           (setq s (UC:Clamp01 (/ (- b c) a)))
          )
        )
       )
     )
    )
  )
  (setq c1 (UC:V+ a1 (UC:V* d1 s)))
  (setq c2 (UC:V+ b1 (UC:V* d2 tt)))
  (list c1 c2)
)

;; ---------------------------------------------------------------------
;; 3. PERSISTED CLEARANCE CRITERIA  (workstation-wide defaults via
;;    setenv/getenv, always editable through UTILCLASHSETTINGS)
;; ---------------------------------------------------------------------

(defun UC:GetDefault (key default / v)
  (setq v (getenv key))
  (if v (atof v) default)
)

(defun UC:SetDefault (key val) (setenv key (rtos val 2 4)))

(defun UC:HaveSettings () (if (getenv "UTILCLASH_HGG") T nil))

(defun UC:LoadSettingsList ()
  (list
    (UC:GetDefault "UTILCLASH_HGG"   5.0)
    (UC:GetDefault "UTILCLASH_HPP"   5.0)
    (UC:GetDefault "UTILCLASH_HGP"   5.0)
    (UC:GetDefault "UTILCLASH_HNODE" 3.0)
    (UC:GetDefault "UTILCLASH_VGG"   1.0)
    (UC:GetDefault "UTILCLASH_VPP"   1.0)
    (UC:GetDefault "UTILCLASH_VGP"   1.5)
    (UC:GetDefault "UTILCLASH_VNODE" 1.0)
  )
)

(defun UC:AskReal (prompt default / v)
  (setq v (getdist (strcat prompt " <" (rtos default 2 2) ">: ")))
  (if v v default)
)

(defun UC:GetClearanceCriteria ( / hgg hpp hgp hnode vgg vpp vgp vnode)
  (princ "\n============================================================")
  (princ "\n UTILITY NETWORK CLEARANCE CRITERIA  (values in drawing units)")
  (princ "\n============================================================")
  (princ "\n-- Minimum HORIZONTAL clear distance --")
  (setq hgg   (UC:AskReal "\nGravity pipe <-> Gravity pipe" (UC:GetDefault "UTILCLASH_HGG" 5.0)))
  (setq hpp   (UC:AskReal "\nPressure pipe <-> Pressure pipe" (UC:GetDefault "UTILCLASH_HPP" 5.0)))
  (setq hgp   (UC:AskReal "\nGravity pipe <-> Pressure pipe" (UC:GetDefault "UTILCLASH_HGP" 5.0)))
  (setq hnode (UC:AskReal "\nAny pipe <-> Structure/Fitting/Appurtenance" (UC:GetDefault "UTILCLASH_HNODE" 3.0)))
  (princ "\n-- Minimum VERTICAL clear distance --")
  (setq vgg   (UC:AskReal "\nGravity pipe <-> Gravity pipe" (UC:GetDefault "UTILCLASH_VGG" 1.0)))
  (setq vpp   (UC:AskReal "\nPressure pipe <-> Pressure pipe" (UC:GetDefault "UTILCLASH_VPP" 1.0)))
  (setq vgp   (UC:AskReal "\nGravity pipe <-> Pressure pipe" (UC:GetDefault "UTILCLASH_VGP" 1.5)))
  (setq vnode (UC:AskReal "\nAny pipe <-> Structure/Fitting/Appurtenance" (UC:GetDefault "UTILCLASH_VNODE" 1.0)))
  (UC:SetDefault "UTILCLASH_HGG"   hgg)
  (UC:SetDefault "UTILCLASH_HPP"   hpp)
  (UC:SetDefault "UTILCLASH_HGP"   hgp)
  (UC:SetDefault "UTILCLASH_HNODE" hnode)
  (UC:SetDefault "UTILCLASH_VGG"   vgg)
  (UC:SetDefault "UTILCLASH_VPP"   vpp)
  (UC:SetDefault "UTILCLASH_VGP"   vgp)
  (UC:SetDefault "UTILCLASH_VNODE" vnode)
  (princ "\nUTILCLASH: Criteria saved as this workstation's default.")
  (list hgg hpp hgp hnode vgg vpp vgp vnode)
)

(defun UC:RequiredClearance (g1 g2 settings / hgg hpp hgp hnode vgg vpp vgp vnode)
  (setq hgg   (nth 0 settings) hpp (nth 1 settings) hgp (nth 2 settings) hnode (nth 3 settings))
  (setq vgg   (nth 4 settings) vpp (nth 5 settings) vgp (nth 6 settings) vnode (nth 7 settings))
  (cond
    ((or (= g1 "NODE") (= g2 "NODE"))                  (list hnode vnode))
    ((and (= g1 "GRAVITY")  (= g2 "GRAVITY"))          (list hgg vgg))
    ((and (= g1 "PRESSURE") (= g2 "PRESSURE"))         (list hpp vpp))
    (t                                                  (list hgp vgp))
  )
)

;; ---------------------------------------------------------------------
;; 4. PROMPT ON FILE OPEN
;; ---------------------------------------------------------------------

(defun UC:PromptOnOpen ( / ans)
  (initget "Yes No")
  (setq ans (getkword
    "\nUTILCLASH: Will you be designing gravity or pressure utility (pipe) networks in this drawing? [Yes/No] <No>: "))
  (if (null ans) (setq ans "No"))
  (if (= ans "Yes")
    (progn
      (UC:GetClearanceCriteria)
      (princ "\nUTILCLASH: Run UTILCLASHCHECK any time to scan for clearance conflicts.")
    )
    (princ "\nUTILCLASH: Skipped. Run UTILCLASHSETUP later if you start designing utilities.")
  )
  (princ)
)

;; ---------------------------------------------------------------------
;; 5. ENTITY CLASSIFICATION / GEOMETRY EXTRACTION
;;
;;    Every recognized part becomes: (typ grp p1 p2 radius name handle approx)
;;      typ    - "GRAVITY-PIPE" | "GRAVITY-STRUCTURE" | "PRESSURE-PIPE" |
;;               "PRESSURE-FITTING" | "PRESSURE-APPURTENANCE"
;;      grp    - "GRAVITY" | "PRESSURE" | "NODE"  (for the clearance matrix)
;;      p1,p2  - 3D endpoints (equal for point-type parts)
;;      radius - half the part's diameter/width, from COM data if
;;               available, else approximated from its bounding box
;;      approx - T if geometry/radius came from the bounding-box fallback
;; ---------------------------------------------------------------------

(defun UC:BBoxMinMax (ent / res minp maxp)
  (setq minp nil maxp nil)
  (setq res (vl-catch-all-apply 'vla-getboundingbox (list ent 'minp 'maxp)))
  (if (vl-catch-all-error-p res)
    nil
    (progn
      (setq minp (vlax-safearray->list (vlax-variant-value minp)))
      (setq maxp (vlax-safearray->list (vlax-variant-value maxp)))
      (list minp maxp)
    )
  )
)

(defun UC:BBoxCenter (ent / bb)
  (setq bb (UC:BBoxMinMax ent))
  (if bb (mapcar '(lambda (a b) (/ (+ a b) 2.0)) (car bb) (cadr bb)) nil)
)

(defun UC:BBoxRadius (ent / bb minp maxp dx dy dz)
  (setq bb (UC:BBoxMinMax ent))
  (if (null bb)
    nil
    (progn
      (setq minp (car bb) maxp (cadr bb))
      (setq dx (- (car maxp)   (car minp)))
      (setq dy (- (cadr maxp)  (cadr minp)))
      (setq dz (- (caddr maxp) (caddr minp)))
      (/ (apply 'min (list dx dy dz)) 2.0)
    )
  )
)

(defun UC:ClassifyEntity (ent / objname hnd typ grp p1 p2 dia rad approx nm)
  (setq objname (strcase (vla-get-ObjectName ent)))
  (setq hnd (vla-get-Handle ent))
  (setq approx nil)
  (setq typ nil)
  (cond
    ((and (vl-string-search "PIPE" objname) (vl-string-search "PRESSURE" objname))
     (setq typ "PRESSURE-PIPE" grp "PRESSURE")
     (setq p1  (UC:TryGetProp ent '(StartPoint)))
     (setq p2  (UC:TryGetProp ent '(EndPoint)))
     (setq dia (UC:TryGetProp ent '(InnerDiameterOrWidth Diameter)))
    )
    ((and (vl-string-search "FITTING" objname) (vl-string-search "PRESSURE" objname))
     (setq typ "PRESSURE-FITTING" grp "NODE")
     (setq p1  (UC:TryGetProp ent '(Location InsertionPoint Position)))
     (setq p2  p1)
     (setq dia (UC:TryGetProp ent '(InnerDiameterOrWidth Diameter PartOuterDiameter)))
    )
    ((and (vl-string-search "APPURTENANCE" objname) (vl-string-search "PRESSURE" objname))
     (setq typ "PRESSURE-APPURTENANCE" grp "NODE")
     (setq p1  (UC:TryGetProp ent '(Location InsertionPoint Position)))
     (setq p2  p1)
     (setq dia (UC:TryGetProp ent '(InnerDiameterOrWidth Diameter)))
    )
    ((vl-string-search "STRUCTURE" objname)
     (setq typ "GRAVITY-STRUCTURE" grp "NODE")
     (setq p1  (UC:TryGetProp ent '(Location CenterPoint InsertionPoint Position)))
     (setq p2  p1)
     (setq dia (UC:TryGetProp ent '(InnerDiameterOrWidth StructureDiameter Diameter FrameDiameter)))
    )
    ((vl-string-search "PIPE" objname)
     (setq typ "GRAVITY-PIPE" grp "GRAVITY")
     (setq p1  (UC:TryGetProp ent '(StartPoint CenterlineStartPoint)))
     (setq p2  (UC:TryGetProp ent '(EndPoint CenterlineEndPoint)))
     (setq dia (UC:TryGetProp ent '(InnerDiameterOrWidth Diameter InnerPipeDiamOrWidth)))
    )
  )
  (if (null typ)
    nil
    (progn
      (setq p1 (UC:VariantPt p1))
      (setq p2 (UC:VariantPt p2))
      (if (or (null p1) (null p2))
        (progn
          (setq p1 (UC:BBoxCenter ent))
          (setq p2 p1)
          (setq approx T)
        )
      )
      (if (or (null p1) (null p2))
        nil
        (progn
          (if (and dia (numberp dia) (> dia 0.0))
            (setq rad (/ dia 2.0))
            (progn (setq rad (UC:BBoxRadius ent)) (setq approx T))
          )
          (if (null rad) (setq rad 0.0))
          (setq nm (strcat typ " #" hnd))
          (list typ grp p1 p2 rad nm hnd approx)
        )
      )
    )
  )
)

;; ---------------------------------------------------------------------
;; 6. COLLECT ALL RECOGNIZED UTILITY PARTS IN THE DRAWING
;; ---------------------------------------------------------------------

(defun UC:AllClassNames ()
  (append UC:PipeClassNames UC:StructClassNames
          UC:PPipeClassNames UC:PFitClassNames UC:PApptClassNames)
)

(defun UC:CollectAllElements (useSelection / ss filt elements ent elem i)
  (setq filt (UC:JoinComma (UC:AllClassNames)))
  (setq ss
    (if useSelection
      (progn
        (princ "\nUTILCLASH: Select utility parts (window your work area), then press Enter...")
        (ssget (list (cons 0 filt)))
      )
      (ssget "_X" (list (cons 0 filt)))
    )
  )
  (if (and (null ss) (not useSelection))
    (progn
      (princ "\nUTILCLASH: No entities matched the known class names; scanning the entire drawing instead (this may take a moment)...")
      (setq ss (ssget "_X"))
    )
  )
  (setq elements '())
  (if ss
    (progn
      (setq i 0)
      (repeat (sslength ss)
        (setq ent (vlax-ename->vla-object (ssname ss i)))
        (setq elem (vl-catch-all-apply 'UC:ClassifyEntity (list ent)))
        (if (and elem (not (vl-catch-all-error-p elem)))
          (setq elements (cons elem elements))
        )
        (setq i (1+ i))
      )
    )
  )
  elements
)

;; ---------------------------------------------------------------------
;; 7. FLAGGING
;; ---------------------------------------------------------------------

(defun UC:EnsureFlagLayer ()
  (if (not (tblsearch "LAYER" UC:FlagLayer))
    (entmake
      (list
        (cons 0 "LAYER")
        (cons 100 "AcDbSymbolTableRecord")
        (cons 100 "AcDbLayerTableRecord")
        (cons 2 UC:FlagLayer)
        (cons 70 0)
        (cons 62 1)
        (cons 6 "CONTINUOUS")
      )
    )
  )
)

(defun UC:FallbackFlag (pt txt / oldlayer leaderPt)
  (setq oldlayer (getvar "CLAYER"))
  (setvar "CLAYER" UC:FlagLayer)
  (setq leaderPt (list (+ (car pt) 5.0) (+ (cadr pt) 5.0) (caddr pt)))
  (vl-catch-all-apply 'command (list "._LEADER" pt leaderPt "" txt ""))
  (setvar "CLAYER" oldlayer)
)

(defun UC:FlagConflict (c / e1 e2 pt clearH reqH clearV reqV txt success before after)
  (setq e1 (nth 0 c) e2 (nth 1 c) pt (nth 2 c))
  (setq clearH (nth 3 c) reqH (nth 4 c) clearV (nth 5 c) reqV (nth 6 c))
  (UC:EnsureFlagLayer)
  (setq txt
    (strcat
      "CLEARANCE CONFLICT: " (nth 0 e1) " vs " (nth 0 e2)
      "  H-clear=" (rtos (max clearH 0.0) 2 2) " (req " (rtos reqH 2 2) ")"
      "  V-clear=" (rtos (max clearV 0.0) 2 2) " (req " (rtos reqV 2 2) ")"
    )
  )
  (if (or (nth 7 e1) (nth 7 e2)) (setq txt (strcat txt "  [APPROX GEOM]")))
  (setq before (entlast))
  (setq success (vl-catch-all-apply 'command (list "._AeccAddGeneralNoteLabel" pt txt "")))
  (setq after (entlast))
  (if (or (vl-catch-all-error-p success) (equal before after))
    (UC:FallbackFlag pt txt)
  )
  (princ (strcat "\n  - " txt))
)

;; ---------------------------------------------------------------------
;; 8. MAIN CLASH CHECK
;; ---------------------------------------------------------------------

(defun c:UTILCLASHCHECK ( / settings mode useSel elements n i j e1 e2
                            res cp1 cp2 rawDist horiz vert clearH clearV
                            g1 g2 req reqH reqV conflicts count)
  (setq settings
    (if (UC:HaveSettings)
      (UC:LoadSettingsList)
      (progn
        (princ "\nUTILCLASH: No clearance criteria set yet.")
        (UC:GetClearanceCriteria)
      )
    )
  )
  (initget "All Select")
  (setq mode (getkword "\nCheck [A]ll utility parts in drawing or [S]elect a work area? <A>: "))
  (setq useSel (= mode "Select"))
  (princ "\nUTILCLASH: Scanning for gravity and pressure utility network parts...")
  (setq elements (UC:CollectAllElements useSel))
  (setq n (length elements))
  (princ (strcat "\nUTILCLASH: " (itoa n) " utility part(s) found."))
  (if (< n 2)
    (progn (princ "\nUTILCLASH: Not enough utility parts to check for clashes.") (princ))
    (progn
      (setq conflicts '())
      (setq i 0)
      (while (< i n)
        (setq e1 (nth i elements))
        (setq j (1+ i))
        (while (< j n)
          (setq e2 (nth j elements))
          (setq res (UC:ClosestSegSeg (nth 2 e1) (nth 3 e1) (nth 2 e2) (nth 3 e2)))
          (setq cp1 (car res) cp2 (cadr res))
          (setq rawDist (UC:Len (UC:V- cp1 cp2)))
          (if (> rawDist UC:Tol)
            (progn
              (setq horiz (sqrt (+ (expt (- (car cp1) (car cp2)) 2)
                                    (expt (- (cadr cp1) (cadr cp2)) 2))))
              (setq vert (abs (- (caddr cp1) (caddr cp2))))
              (setq clearH (- horiz (+ (nth 4 e1) (nth 4 e2))))
              (setq clearV (- vert  (+ (nth 4 e1) (nth 4 e2))))
              (setq g1 (nth 1 e1) g2 (nth 1 e2))
              (setq req (UC:RequiredClearance g1 g2 settings))
              (setq reqH (car req) reqV (cadr req))
              (if (and (< clearH reqH) (< clearV reqV))
                (setq conflicts
                  (cons (list e1 e2 (UC:MidPt cp1 cp2) clearH reqH clearV reqV) conflicts))
              )
            )
          )
          (setq j (1+ j))
        )
        (setq i (1+ i))
      )
      (setq count (length conflicts))
      (princ (strcat "\nUTILCLASH: " (itoa count) " clearance conflict(s) detected."))
      (foreach c conflicts (UC:FlagConflict c))
      (princ)
    )
  )
  (princ)
)

;; ---------------------------------------------------------------------
;; 9. USER-FACING SETUP COMMANDS
;; ---------------------------------------------------------------------

(defun c:UTILCLASHSETUP ()
  (UC:PromptOnOpen)
  (princ)
)

(defun c:UTILCLASHSETTINGS ()
  (UC:GetClearanceCriteria)
  (princ)
)

;; ---------------------------------------------------------------------
;; 10. DOCUMENT-OPEN REACTOR
;;
;;     Registered as an application-level VLR-DocManager-Reactor tagged
;;     "UTILCLASH-DOCMGR", so re-loading this file (e.g. every time
;;     acaddoc.lsp runs in a newly opened drawing) never creates a
;;     duplicate reactor - vlr-reactors is queried application-wide, not
;;     per-document, which is what lets this stay a single instance for
;;     the whole Civil 3D session while still working across documents
;;     whose AutoLISP variable/function space is otherwise independent.
;; ---------------------------------------------------------------------

(defun UC:OnDocActivated (calling-reactor doc-list / doc key)
  (setq doc (car doc-list))
  (setq key (vla-get-FullName doc))
  (if (not (member key *UC:AskedDocs*))
    (progn
      (setq *UC:AskedDocs* (cons key *UC:AskedDocs*))
      (UC:PromptOnOpen)
    )
  )
)

(defun UC:EnsureDocManagerReactor ( / existing found r rd)
  (setq found nil)
  (setq existing (vlr-reactors :VLR-Docmanager-Reactor))
  (foreach r existing
    (setq rd (vl-catch-all-apply 'vlr-data (list r)))
    (if (and (not (vl-catch-all-error-p rd)) (equal rd "UTILCLASH-DOCMGR"))
      (setq found T)
    )
  )
  (if (not found)
    (vlr-docmanager-reactor "UTILCLASH-DOCMGR" (list (cons :VLR-documentActivated 'UC:OnDocActivated)))
  )
)

;; ---------------------------------------------------------------------
;; 11. INITIALIZATION - runs each time this file is loaded
;; ---------------------------------------------------------------------

(UC:EnsureDocManagerReactor)

(setq UC:CurDocKey (vla-get-FullName (vla-get-ActiveDocument (vlax-get-acad-object))))
(if (not (member UC:CurDocKey *UC:AskedDocs*))
  (progn
    (setq *UC:AskedDocs* (cons UC:CurDocKey *UC:AskedDocs*))
    (UC:PromptOnOpen)
  )
)

(princ "\nUTILCLASH: Loaded. Commands: UTILCLASHSETUP | UTILCLASHSETTINGS | UTILCLASHCHECK")
(princ)
