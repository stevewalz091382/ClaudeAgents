;;; ==========================================================================
;;; IPScan.lsp  -  origin scan & report for drawings received from others
;;; --------------------------------------------------------------------------
;;; Target : AutoCAD 2027 / Civil 3D 2027. Pure AutoLISP / Visual LISP.
;;; Needs  : IPStamp-Core.lsp in the same support folder.
;;;
;;; Checks five layers of marks, so content stays traceable after the
;;; visible stamp is stripped: xdata stamp, hidden encrypted copy, coordinate
;;; watermark, hidden sentinels, and office geometry manifests.
;;;
;;; Opens each drawing read-only through ObjectDBX (no editor, no reactors,
;;; nothing saved) and reports where its content came from:
;;;   * IPStamp marks: objects that originated with us (signature verified),
;;;     forged or altered marks, other parties' marks, geometry changed since
;;;     it left us, source drawings and creators.
;;;   * Drawing-level ownership claim and our transmittal records (IPXMIT).
;;;   * File evidence for unmarked content: DWG properties and custom
;;;     properties, last-saved-by, registered applications and dictionaries
;;;     (which software touched it), xref and image paths (whose servers),
;;;     layer prefixes, fonts, title block attributes, object types.
;;;
;;; Commands
;;;   IPSCAN       scan the current drawing
;;;   IPSCANFILE   scan one received drawing
;;;   IPSCANDIR    scan a folder of received drawings (optionally subfolders)
;;;
;;; Output (in *IPS:ReportDir*, default My Documents\IPScan)
;;;   IPScan_<time>.txt            readable report, one section per file
;;;   IPScan_<time>_files.csv      one row per file, for the project register
;;;   IPScan_<time>_objects.csv    one row per stamped object
;;; ==========================================================================
(vl-load-com)

(if (null *IPS:CoreVersion*)
  (if (findfile "IPStamp-Core.lsp")
    (load "IPStamp-Core.lsp")
    (princ "\nIPScan: IPStamp-Core.lsp was not found on the support path.")))

;;; ---------------------------------------------- software fingerprints ---
;; Matched (wcmatch, upper case) against registered application names,
;; named dictionaries and object class names. These are hints, not proof:
;; extend the list with the names you see in files from known senders.
(if (null *IPS:Signatures*)
  (setq *IPS:Signatures*
    '(("AECC*,AECCDB*"                       . "Autodesk Civil 3D")
      ("AECDB*,AECB*"                        . "AutoCAD Architecture / MEP objects")
      ("ADE*,ACMAP*,AUTOCAD_MAP*,ACMAPDM*"   . "AutoCAD Map 3D")
      ("ESRI*,ARCGIS*"                       . "ArcGIS for AutoCAD")
      ("DGN*,MSTN*,BENTLEY*,MICROSTATION*"   . "MicroStation / DGN conversion")
      ("REVIT*,RVT*"                         . "Revit export")
      ("BRICS*,BRX*"                         . "BricsCAD")
      ("ODA*,TEIGHA*"                        . "ODA / Teigha based (non-Autodesk) writer")
      ("CARLSON*"                            . "Carlson")
      ("ACPP*,PNP*"                          . "AutoCAD Plant 3D")
      ("ADVANCE*,GRAITEC*"                   . "Advance Steel")
      ("SKETCHUP*"                           . "SketchUp export")
      ("IPSTAMP"                             . "IPStamp (this tool)"))))

;; Registered application names that every AutoCAD drawing carries.
(if (null *IPS:StdApps*) (setq *IPS:StdApps* "ACAD*,ACCM*,ACDB*,ACAE*,ACLY*,ACSH*"))

;;; ------------------------------------------------------------ helpers ---
(defun ips:inc (k al / p)
  (if (setq p (assoc k al))
    (subst (cons k (1+ (cdr p))) p al)
    (cons (cons k 1) al)))

(defun ips:adjoin (x l) (if (or (= x "") (member x l)) l (cons x l)))

(defun ips:top (al n)
  (ips:take (vl-sort al (function (lambda (a b) (> (cdr a) (cdr b))))) n))

(defun ips:o (s) (setq *S:Rep* (cons s *S:Rep*)))

(defun ips:o-top (title al n)
  (if al
    (progn
      (ips:o title)
      (foreach p (ips:top al n)
        (ips:o (strcat "    " (itoa (cdr p)) "  " (car p))))
      (if (> (length al) n) (ips:o (strcat "    ... " (itoa (- (length al) n)) " more"))))))

(defun ips:o-list (title lst n)
  (if lst
    (progn
      (ips:o title)
      (foreach s (ips:take (reverse lst) n) (ips:o (strcat "    " s)))
      (if (> (length lst) n) (ips:o (strcat "    ... " (itoa (- (length lst) n)) " more"))))))

(defun ips:report-dir ( / d)
  (setq d (if (= *IPS:ReportDir* "")
            (strcat (vl-string-right-trim "\\" (getvar "MYDOCUMENTSPREFIX")) "\\IPScan")
            (vl-string-right-trim "\\/" *IPS:ReportDir*)))
  (vl-mkdir d)
  d)

(defun ips:fmtname (s)
  (cond ((cdr (assoc s '(("AC1015" . "2000 format (2000-2002)")
                         ("AC1018" . "2004 format (2004-2006)")
                         ("AC1021" . "2007 format (2007-2009)")
                         ("AC1024" . "2010 format (2010-2012)")
                         ("AC1027" . "2013 format (2013-2017)")
                         ("AC1032" . "2018 format (2018 and later)")))))
        ((wcmatch s "AC####") "newer DWG format")
        (T "not a recognised DWG header")))

;; -> (size "modified" "AC1032" "description")
(defun ips:file-info (path / f c s st)
  (setq s "")
  (if (setq f (open path "r"))
    (progn
      (repeat 6 (if (setq c (read-char f)) (setq s (strcat s (chr c)))))
      (close f)))
  (setq st (vl-file-systime path))
  (list (vl-file-size path)
        (if st
          (strcat (itoa (car st)) "-" (ips:pad2 (cadr st)) "-" (ips:pad2 (nth 3 st)) " "
                  (ips:pad2 (nth 4 st)) ":" (ips:pad2 (nth 5 st)))
          "?")
        s
        (ips:fmtname s)))

(defun ips:edtime (jd)
  (menucmd (strcat "M=$(edtime," (rtos jd 2 8) ",YYYY-MO-DD HH:MM)")))

;; Opens a drawing for reading. Uses the editor's copy if it is already open.
;; -> (database released-after-scan-p) or nil
(defun ips:dbx-open (path / doc dbx r)
  (vlax-for d (vla-get-documents (vlax-get-acad-object))
    (if (= (strcase (vla-get-fullname d)) (strcase path)) (setq doc d)))
  (cond
    (doc (list doc nil))
    ((and (setq dbx (vl-catch-all-apply 'vla-getinterfaceobject
                      (list (vlax-get-acad-object)
                            (strcat "ObjectDBX.AxDbDocument." (itoa (atoi (getvar "ACADVER")))))))
          (not (vl-catch-all-error-p dbx))
          (not (vl-catch-all-error-p (setq r (vl-catch-all-apply 'vla-open (list dbx path))))))
     (list dbx T))
    (T
     (setq *S:OpenErr*
       (cond ((vl-catch-all-error-p dbx) (strcat "ObjectDBX unavailable: " (vl-catch-all-error-message dbx)))
             ((vl-catch-all-error-p r) (vl-catch-all-error-message r))
             (T "unknown error")))
     (if (and dbx (not (vl-catch-all-error-p dbx))) (vlax-release-object dbx))
     nil)))

(defun ips:pick-folder (msg / sh f self p ok)
  (setq sh (vl-catch-all-apply 'vlax-create-object (list "Shell.Application")))
  (if (and sh (not (vl-catch-all-error-p sh)))
    (progn
      (setq ok T
            f (vl-catch-all-apply 'vlax-invoke-method
                (list sh 'BrowseForFolder (vla-get-hwnd (vlax-get-acad-object)) msg 0)))
      (if (and f (not (vl-catch-all-error-p f))
               (setq self (ips:prop f 'Self)))
        (setq p (ips:prop self 'Path)))
      (vlax-release-object sh)))
  (if (and (not ok) (setq p (getfiled "Pick any drawing in the folder to scan" "" "dwg" 0)))
    (setq p (vl-filename-directory p)))
  (if (and p (= (type p) 'STR) (/= p "")) p))

(defun ips:dwg-files (dir recurse / out)
  (setq dir (vl-string-right-trim "\\/" dir))
  (foreach f (vl-directory-files dir "*.dwg" 1)
    (setq out (cons (strcat dir "\\" f) out)))
  (if recurse
    (foreach d (vl-directory-files dir nil -1)
      (if (not (member d '("." "..")))
        (setq out (append out (ips:dwg-files (strcat dir "\\" d) T))))))
  (vl-sort out '<))

(defun ips:layer-prefix (nm / i c)
  (setq i 1)
  (while (and (<= i (strlen nm)) (not (member (substr nm i 1) '("-" "_" " " "." "$"))))
    (setq i (1+ i)))
  (strcase (ips:clip (substr nm 1 (1- i)) 12)))

;;; ----------------------------------------------------- per-object scan ---
(defun ips:scan-reset ()
  (setq *S:Total* 0 *S:Layout* 0 *S:InBlocks* 0 *S:Stamped* 0 *S:Unstamped* 0
        *S:OursValid* 0 *S:OursBad* 0 *S:OursOtherKey* 0 *S:GeoChanged* 0
        *S:SigBad* 0 *S:Proxy* 0
        *S:Stripped* 0 *S:Mismatch* 0 *S:ShadowOther* 0 *S:Sentinels* 0
        *S:WMHits* 0 *S:WMN* 0 *S:WMObjs* 0 *S:MMatch* nil *S:MTotal* 0
        *S:Foreign* nil *S:Origins* nil *S:Creators* nil *S:Editors* nil
        *S:CTypes* nil *S:Types* nil *S:Images* nil *S:Attrs* nil *S:Xrefs* nil))

(defun ips:scan-attrs (ent / atts)
  (if (= (ips:prop ent 'HasAttributes) :vlax-true)
    (progn
      (setq atts (vl-catch-all-apply 'vlax-invoke (list ent 'GetAttributes)))
      (if (not (vl-catch-all-error-p atts))
        (foreach a atts
          (if (/= (ips:str (ips:prop a 'TextString)) "")
            (setq *S:Attrs* (ips:adjoin (strcat (ips:str (ips:prop a 'TagString)) " = "
                                                (ips:str (ips:prop a 'TextString)))
                                        *S:Attrs*))))))))

(defun ips:scan-ent (ent where layout / on rec v g org sh wm src m)
  (setq on (ips:str (ips:prop ent 'ObjectName))
        *S:Total* (1+ *S:Total*)
        *S:Types* (ips:inc on *S:Types*))
  (if layout (setq *S:Layout* (1+ *S:Layout*)) (setq *S:InBlocks* (1+ *S:InBlocks*)))
  (if (wcmatch (strcase on) "*ZOMBIE*,*PROXY*") (setq *S:Proxy* (1+ *S:Proxy*)))
  (if (= on "AcDbRasterImage")
    (setq *S:Images* (ips:adjoin (ips:str (ips:prop ent 'ImageFile)) *S:Images*)))
  (if (and layout (/= where "Model") (= on "AcDbBlockReference") (< (length *S:Attrs*) 80))
    (ips:scan-attrs ent))
  ;; Layer 2: hidden encrypted copy
  (setq sh (ips:shadow-read ent) rec (ips:xd-read ent) src "xdata")
  (cond
    ((and (null rec) (= (car sh) "VALID"))
     (setq rec (cdr sh) src "hidden copy only (visible stamp STRIPPED)" *S:Stripped* (1+ *S:Stripped*)))
    ((and rec (= (car sh) "VALID") (/= (ips:kv "C_SIG" rec) (ips:kv "C_SIG" (cdr sh))))
     (setq src "visible stamp DIFFERS from hidden copy" *S:Mismatch* (1+ *S:Mismatch*)))
    ((= (car sh) "UNREADABLE") (setq *S:ShadowOther* (1+ *S:ShadowOther*))))
  ;; Layer 3: coordinate watermark
  (if (ips:wm-rows ent)
    (progn
      (setq wm (ips:wm-count ent)
            *S:WMHits* (+ *S:WMHits* (car wm))
            *S:WMN*    (+ *S:WMN* (cdr wm)))
      (if (and (>= (cdr wm) 4) (= (car wm) (cdr wm))) (setq *S:WMObjs* (1+ *S:WMObjs*)))))
  ;; Layer 4: sentinels
  (if (ips:sentinel-p ent) (setq *S:Sentinels* (1+ *S:Sentinels*)))
  ;; Layer 5: geometry we transmitted (office manifests)
  (if (and *S:MSyms* layout (setq m (vl-symbol-value (read (strcat "IPM_" (ips:geo ent))))))
    (setq *S:MMatch* (ips:inc m *S:MMatch*) *S:MTotal* (1+ *S:MTotal*)))
  (if rec
    (progn
      (setq v   (ips:verify rec)
            g   (ips:geo-status ent rec)
            org (ips:str (ips:kv "ORG" rec))
            *S:Stamped*  (1+ *S:Stamped*)
            *S:Origins*  (ips:inc (strcat org " | " (ips:str (ips:kv "C_DWG" rec))
                                          " | " (ips:str (ips:kv "C_DWGID" rec)))
                                  *S:Origins*)
            *S:Creators* (ips:inc (ips:str (ips:kv "C_USER" rec)) *S:Creators*)
            *S:CTypes*   (ips:inc (ips:str (ips:kv "C_TYPE" rec)) *S:CTypes*))
      (if (ips:kv "M_USER" rec)
        (setq *S:Editors* (ips:inc (ips:kv "M_USER" rec) *S:Editors*)))
      (if (= (cadr v) "INVALID") (setq *S:SigBad* (1+ *S:SigBad*)))
      (if (= org *IPS:Org*)
        (progn
          (cond ((= (car v) "VALID")     (setq *S:OursValid* (1+ *S:OursValid*)))
                ((= (car v) "OTHER-KEY") (setq *S:OursOtherKey* (1+ *S:OursOtherKey*)))
                (T                       (setq *S:OursBad* (1+ *S:OursBad*))))
          (if (= g "CHANGED") (setq *S:GeoChanged* (1+ *S:GeoChanged*))))
        (setq *S:Foreign* (ips:inc org *S:Foreign*)))
      (if *S:Csv*
        (write-line
          (ips:csv-line
            (list *S:Path* where (ips:prop ent 'Handle) on org
                  (ips:kv "C_TYPE" rec) (ips:kv "C_USER" rec) (ips:kv "C_TIME" rec)
                  (ips:kv "C_DWG" rec) (ips:kv "C_DWGID" rec)
                  (ips:kv "M_USER" rec) (ips:kv "M_TIME" rec) (ips:kv "M_CMD" rec) (ips:kv "M_DWG" rec)
                  (ips:kv "N" rec) (car v) (cadr v) g src
                  (if wm (strcat (itoa (car wm)) "/" (itoa (cdr wm))) "")))
          *S:Csv*)))
    (setq *S:Unstamped* (1+ *S:Unstamped*))))

;;; ---------------------------------------------------- per-drawing scan ---
(defun ips:collect-names (coll / out)
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for it coll
        (setq out (ips:adjoin (ips:str (ips:prop it 'Name)) out)))))
    nil)
  out)

;; Scans one database and appends its report section.
;; -> list of values for the files CSV
(defun ips:scan-db (db path current / fi nm lay lo where apps odd dicts layers prefixes fonts
                                      layouts si props cust i n k v info xmit hints names ost
                                      dsh dstrip z)
  (ips:scan-reset)
  (setq *S:Path* path
        fi (ips:file-info path))
  ;; --- objects in every layout and block definition
  (vlax-for blk (vla-get-blocks db)
    (setq nm (ips:str (ips:prop blk 'Name)))
    (cond
      ((= (ips:prop blk 'IsXRef) :vlax-true)
       (setq *S:Xrefs* (ips:adjoin (strcat nm "  ->  " (ips:str (ips:prop blk 'Path))) *S:Xrefs*)))
      ((wcmatch nm "*|*") nil)                        ; xref-dependent, lives in the xref
      (T
       (setq lay (= (ips:prop blk 'IsLayout) :vlax-true)
             where (if (and lay (setq lo (ips:prop blk 'Layout)))
                     (ips:str (ips:prop lo 'Name))
                     (strcat "Block:" nm)))
       (vl-catch-all-apply
         (function (lambda () (vlax-for ent blk (vl-catch-all-apply 'ips:scan-ent (list ent where lay)))))
         nil))))
  ;; --- drawing-level evidence
  (setq apps    (ips:collect-names (ips:prop db 'RegisteredApplications))
        odd     (vl-remove-if (function (lambda (a) (wcmatch (strcase a) *IPS:StdApps*))) apps)
        dicts   (ips:collect-names (ips:prop db 'Dictionaries))
        layers  (ips:collect-names (ips:prop db 'Layers))
        layouts (ips:collect-names (ips:prop db 'Layouts))
        info    (ips:xrec-read db "DWGINFO")
        dsh     (ips:dshadow-read db)
        xmit    (mapcar 'cdr (vl-remove-if-not (function (lambda (p) (= (car p) "XMIT")))
                                               (ips:xrec-read db "XMIT"))))
  (foreach l layers
    (if (not (wcmatch l "*|*")) (setq prefixes (ips:inc (ips:layer-prefix l) prefixes))))
  (vl-catch-all-apply
    (function (lambda ()
      (vlax-for s (ips:prop db 'TextStyles)
        (setq fonts (ips:adjoin (strcase (ips:str (ips:prop s 'FontFile))) fonts)))))
    nil)
  (if (setq si (ips:prop db 'SummaryInfo))
    (progn
      (foreach p '(Title Subject Author Keywords Comments LastSavedBy RevisionNumber HyperlinkBase)
        (if (/= (setq v (ips:str (ips:prop si p))) "")
          (setq props (cons (strcat (vl-symbol-name p) ": " v) props))))
      (setq i 0
            n (vl-catch-all-apply 'vla-numcustominfo (list si)))
      (repeat (if (= (type n) 'INT) n 0)
        (if (not (vl-catch-all-error-p (vl-catch-all-apply 'vla-getcustombyindex (list si i 'k 'v))))
          (setq cust (cons (strcat (ips:str k) " = " (ips:str v)) cust)))
        (setq i (1+ i)))))
  (setq names (append apps dicts (mapcar 'car *S:Types*)))
  (foreach sig *IPS:Signatures*
    (if (vl-some (function (lambda (n) (wcmatch (strcase n) (car sig)))) names)
      (setq hints (cons (cdr sig) hints))))
  (if (and (null info) (= (car dsh) "VALID"))
    (setq info (cdr dsh) dstrip T))
  (setq ost (if (ips:kv "OWNER" info) (ips:owner-status info))
        z   (ips:wm-z *S:WMHits* *S:WMN*))

  ;; --- write the section
  (ips:o "")
  (ips:o "==========================================================================")
  (ips:o (strcat "FILE: " path))
  (ips:o (strcat "  " (ips:str (car fi)) " bytes   modified " (cadr fi)
                 "   header " (caddr fi) " (" (cadddr fi) ")"))
  (ips:o "")
  (ips:o "ORIGIN VERDICT")
  (if (> *S:OursValid* 0)
    (ips:o (strcat "  [OUR IP]   " (itoa *S:OursValid*) " object(s) carry VERIFIED \"" *IPS:Org*
                   "\" origin stamps. This file contains our design content.")))
  (if (> *S:OursBad* 0)
    (ips:o (strcat "  [ALERT]    " (itoa *S:OursBad*) " object(s) claim \"" *IPS:Org*
                   "\" origin but FAIL the signature check: stamp altered or forged.")))
  (if (> *S:OursOtherKey* 0)
    (ips:o (strcat "  [ALERT]    " (itoa *S:OursOtherKey*) " object(s) claim \"" *IPS:Org*
                   "\" but are signed with a key that is not ours (impersonation, or a retired key).")))
  (if (> *S:GeoChanged* 0)
    (ips:o (strcat "  [CHANGED]  " (itoa *S:GeoChanged*)
                   " of our object(s) were modified after their last tracked edit (changed outside our office).")))
  (if (> *S:SigBad* 0)
    (ips:o (strcat "  [ALERT]    " (itoa *S:SigBad*) " stamp record(s) were hand-edited (record signature fails).")))
  (if (> *S:Stripped* 0)
    (ips:o (strcat "  [STRIPPED] " (itoa *S:Stripped*) " object(s) had the visible stamp REMOVED. The hidden"
                   " encrypted copy survives and proves origin. Removal was deliberate.")))
  (if dstrip
    (ips:o "  [STRIPPED] The drawing ownership record was REMOVED; recovered from its hidden copy."))
  (if (> *S:Mismatch* 0)
    (ips:o (strcat "  [ALERT]    " (itoa *S:Mismatch*) " object(s) whose visible stamp differs from the hidden copy (stamp rewritten).")))
  (if (and (>= *S:WMN* 20) (>= z 4.0))
    (ips:o (strcat "  [WATERMARK] " (if (>= z 8.0) "VERIFIED" "PROBABLE") ": " (itoa *S:WMHits*) " of "
                   (itoa *S:WMN*) " coordinates carry our watermark (chance would give about "
                   (itoa (fix (/ *S:WMN* (float *IPS:WMBins*)))) "; z = " (rtos z 2 1) "). "
                   (itoa *S:WMObjs*) " object(s) fully sealed.")))
  (if (> *S:Sentinels* 0)
    (ips:o (strcat "  [SENTINEL] " (itoa *S:Sentinels*) " hidden sentinel point(s) found.")))
  (foreach p (ips:top *S:MMatch* 5)
    (ips:o (strcat "  [MANIFEST] " (itoa (cdr p)) " object(s) are geometrically identical to what we sent: " (car p))))
  (if (> *S:ShadowOther* 0)
    (ips:o (strcat "  [HIDDEN]   " (itoa *S:ShadowOther*) " hidden copies not readable with our key (another firm, or a retired key).")))
  (if *S:Foreign*
    (ips:o (strcat "  [OTHERS]   Stamps from other parties / unclaimed: "
                   (ips:join (mapcar (function (lambda (p) (strcat (car p) " (" (itoa (cdr p)) ")")))
                                     (ips:top *S:Foreign* 6))
                             ", "))))
  (cond
    (ost
     (ips:o (strcat "  [CLAIM]    Drawing claimed by \"" (ips:kv "OWNER" info) "\" on "
                    (ips:str (ips:kv "MARKED_TIME" info)) " by " (ips:str (ips:kv "MARKED_BY" info))
                    ": " (ips:sigtext ost)))))
  (if xmit
    (ips:o (strcat "  [TRACE]    We transmitted this drawing " (itoa (length xmit))
                   " time(s). Latest: " (car xmit))))
  (if (and (= *S:Stamped* 0) (< z 4.0) (null *S:MMatch*) (= *S:Sentinels* 0))
    (ips:o "  [UNKNOWN]  No IPStamp marks, watermark or manifest match. Judge origin from the file evidence below.")
    (if (> *S:Unstamped* 0)
      (ips:o (strcat "  [UNKNOWN]  " (itoa *S:Unstamped*) " of " (itoa *S:Total*)
                     " objects carry no stamp (origin not recorded)."))))
  (if hints (ips:o (strcat "  [SOFTWARE] Signs of: " (ips:join (reverse hints) "; "))))
  (if (> *S:Proxy* 0)
    (ips:o (strcat "  [PROXY]    " (itoa *S:Proxy*) " proxy object(s): created by an application not loaded here.")))

  (ips:o "")
  (ips:o "IPSTAMP MARKS")
  (ips:o (strcat "  Objects: " (itoa *S:Total*) " (" (itoa *S:Layout*) " in layouts, "
                 (itoa *S:InBlocks*) " inside block definitions)"))
  (ips:o (strcat "  Stamped: " (itoa *S:Stamped*) "   unstamped: " (itoa *S:Unstamped*)))
  (ips:o-top "  Source drawings (owner | drawing | DWG id):" *S:Origins* 15)
  (ips:o-top "  Created by:" *S:Creators* 10)
  (ips:o-top "  Last edited by:" *S:Editors* 10)
  (ips:o-top "  How objects arrived:" *S:CTypes* 10)

  (ips:o "")
  (ips:o "DRAWING IDENTITY")
  (if info
    (foreach p info (ips:o (strcat "  " (car p) " = " (cdr p))))
    (ips:o "  No IPStamp drawing record (never opened with IPStamp loaded)."))
  (ips:o-list "  Transmittals recorded by IPXMIT (newest first):" (reverse xmit) 10)
  (if current
    (progn
      (ips:o (strcat "  FINGERPRINTGUID = " (getvar "FINGERPRINTGUID") "   (survives SaveAs copies)"))
      (ips:o (strcat "  VERSIONGUID     = " (getvar "VERSIONGUID")))
      (ips:o (strcat "  Created         = " (ips:edtime (getvar "TDCREATE"))))
      (ips:o (strcat "  Last updated    = " (ips:edtime (getvar "TDUPDATE"))))
      (ips:o (strcat "  Editing time    = " (rtos (* 24.0 (getvar "TDINDWG")) 2 1) " hours"))))

  (ips:o "")
  (ips:o "FILE PROPERTIES (DWGPROPS)")
  (if props (foreach s (reverse props) (ips:o (strcat "  " s))) (ips:o "  (none)"))
  (ips:o-list "  Custom properties:" cust 20)

  (ips:o "")
  (ips:o "SOFTWARE AND STANDARDS EVIDENCE")
  (ips:o-list "  Non-standard registered applications:" odd 25)
  (ips:o-list "  Named dictionaries:" dicts 25)
  (ips:o-list "  Text fonts:" fonts 15)
  (ips:o (strcat "  Layers: " (itoa (length layers))))
  (ips:o-top "  Layer name prefixes (office standard fingerprint):" prefixes 10)
  (ips:o-list "  Layouts:" layouts 15)

  (ips:o "")
  (ips:o "EXTERNAL REFERENCES (paths show whose servers the file came from)")
  (if (or *S:Xrefs* *S:Images*)
    (progn
      (ips:o-list "  Xrefs:" *S:Xrefs* 30)
      (ips:o-list "  Images:" *S:Images* 30))
    (ips:o "  (none)"))

  (ips:o-list "TITLE BLOCK ATTRIBUTES (paper space)" *S:Attrs* 40)
  (ips:o-top "OBJECT TYPES" *S:Types* 15)

  ;; --- one line for the files CSV
  (list path (car fi) (cadr fi) (caddr fi)
        *S:Total* *S:Stamped* *S:OursValid* *S:OursBad* *S:OursOtherKey* *S:GeoChanged*
        *S:Unstamped* (ips:join (mapcar 'car *S:Foreign*) "; ")
        (ips:kv "OWNER" info) (ips:str ost) (ips:kv "DWGID" info) (length xmit)
        (ips:prop si 'LastSavedBy) (ips:prop si 'Author) (ips:join (reverse hints) "; ")
        *S:Stripped* (if dstrip "YES" "") *S:WMHits* *S:WMN* (rtos z 2 1) *S:Sentinels* *S:MTotal*))

;;; ----------------------------------------------------------- manifests ---
;; Loads every .ipm file into interned symbols IPM_<geo> -> "label", which
;; gives hashed lookup without a hash table.
(defun ips:manifest-load ( / dir f ln hdr label n)
  (setq *S:MSyms* nil n 0)
  (if (and (/= *IPS:ManifestDir* "") (vl-file-directory-p *IPS:ManifestDir*))
    (progn
      (setq dir (vl-string-right-trim "\\/" *IPS:ManifestDir*))
      (foreach fn (vl-directory-files dir "*.ipm" 1)
        (if (setq f (open (strcat dir "\\" fn) "r"))
          (progn
            (setq hdr (ips:split (cond ((read-line f)) ("")) "|")
                  label (strcat (ips:str (nth 5 hdr)) " sent " (ips:str (nth 1 hdr))
                                " to " (ips:str (nth 3 hdr)) " (" (ips:str (nth 4 hdr)) ")"))
            (while (setq ln (read-line f))
              (if (= (strlen ln) 16)
                (progn
                  (set (read (strcat "IPM_" ln)) label)
                  (setq *S:MSyms* (cons ln *S:MSyms*) n (1+ n)))))
            (close f))))))
  n)

(defun ips:manifest-unload ()
  (foreach g *S:MSyms* (set (read (strcat "IPM_" g)) nil))
  (setq *S:MSyms* nil))

;;; ---------------------------------------------------------------- run ---
(defun ips:scan-run (paths current / dir st rpt csvp idxp rows res row n)
  (setq dir  (ips:report-dir)
        st   (ips:fname-stamp)
        rpt  (strcat dir "\\IPScan_" st ".txt")
        csvp (strcat dir "\\IPScan_" st "_objects.csv")
        idxp (strcat dir "\\IPScan_" st "_files.csv")
        *S:Rep* nil n 0
        *IPS:KeyCache* nil)
  (ips:o "IPSCAN ORIGIN REPORT")
  (ips:o (strcat "Run " (ips:now) " (" (ips:tz) ") by " (ips:user) " on " (ips:host)))
  (ips:o (strcat "Our organisation: \"" *IPS:Org* "\"   signing key id " (ips:keyid)
                 (if (ips:default-key-p) "  (DEFAULT KEY - verification proves little)" "")))
  (ips:o (strcat "Files: " (itoa (length paths))
                 "   office manifests loaded: " (itoa (ips:manifest-load)) " object fingerprints"))
  (setq *S:Csv* (open csvp "w"))
  (if *S:Csv*
    (write-line (ips:csv-line '("file" "location" "handle" "object" "owner" "origin_type"
                                "created_by" "created_time" "created_in" "created_dwgid"
                                "last_edit_by" "last_edit_time" "last_edit_cmd" "last_edit_dwg"
                                "edits" "origin_sig" "record_sig" "geometry" "evidence" "watermark"))
                *S:Csv*))
  (foreach p paths
    (setq n (1+ n))
    (princ (strcat "\rIPScan " (itoa n) "/" (itoa (length paths)) ": " (vl-filename-base p) "          "))
    (setq res (if current (list (ips:doc) nil) (ips:dbx-open p)))
    (if res
      (progn
        (setq row (vl-catch-all-apply 'ips:scan-db (list (car res) p current)))
        (if (vl-catch-all-error-p row)
          (progn
            (ips:o "")
            (ips:o (strcat "FILE: " p))
            (ips:o (strcat "  SCAN ERROR: " (vl-catch-all-error-message row))))
          (setq rows (cons row rows)))
        (if (cadr res) (vlax-release-object (car res))))
      (progn
        (ips:o "")
        (ips:o (strcat "FILE: " p))
        (ips:o (strcat "  COULD NOT OPEN: " (ips:str *S:OpenErr*)
                       " (password protected, damaged, or locked by another user)")))))
  (if *S:Csv* (close *S:Csv*))
  (setq *S:Csv* nil)
  (ips:manifest-unload)
  (ips:write-lines rpt (reverse *S:Rep*))
  (ips:write-lines idxp
    (cons (ips:csv-line '("file" "bytes" "modified" "dwg_header" "objects" "stamped" "ours_verified"
                          "ours_failed" "ours_other_key" "ours_changed" "unstamped" "other_owners"
                          "drawing_owner" "owner_claim" "dwgid" "transmittals" "last_saved_by"
                          "author" "software_hints" "stripped_objects" "drawing_record_stripped"
                          "watermark_hits" "watermark_coords" "watermark_z" "sentinels" "manifest_matches"))
          (mapcar 'ips:csv-line (reverse rows))))
  (princ (strcat "\nIPScan: " (itoa (length rows)) " of " (itoa (length paths)) " file(s) scanned."))
  (foreach r (reverse rows)
    (princ (strcat "\n  " (vl-filename-base (car r)) ": "
                   (itoa (nth 6 r)) " ours verified, "
                   (itoa (+ (nth 7 r) (nth 8 r))) " suspect, "
                   (itoa (nth 9 r)) " changed, "
                   (itoa (nth 10 r)) " unstamped, "
                   (itoa (nth 19 r)) " stripped, watermark z " (nth 23 r))))
  (princ (strcat "\nReport:  " rpt "\nFiles:   " idxp "\nObjects: " csvp))
  (startapp "notepad.exe" (strcat "\"" rpt "\""))
  (princ))

;;; ----------------------------------------------------------- commands ---
(defun c:IPSCAN ()
  (ips:scan-run (list (strcat (getvar "DWGPREFIX") (getvar "DWGNAME"))) T))

(defun c:IPSCANFILE ( / f)
  (if (setq f (getfiled "Select a received drawing to scan" "" "dwg" 0))
    (ips:scan-run (list f) nil))
  (princ))

(defun c:IPSCANDIR ( / dir sub files)
  (if (setq dir (ips:pick-folder "Folder of received drawings to scan"))
    (progn
      (initget "Yes No")
      (setq sub   (getkword "\nInclude subfolders? [Yes/No] <Yes>: ")
            files (ips:dwg-files dir (/= sub "No")))
      (if files
        (ips:scan-run files nil)
        (princ (strcat "\nIPSCANDIR: no .dwg files in " dir)))))
  (princ))

(princ "\nIPScan loaded. Commands: IPSCAN (current drawing)  IPSCANFILE  IPSCANDIR")
(princ)
