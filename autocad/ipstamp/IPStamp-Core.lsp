;;; ==========================================================================
;;; IPStamp-Core.lsp  -  shared engine for IPStamp.lsp and IPScan.lsp
;;; --------------------------------------------------------------------------
;;; Target : AutoCAD 2027 / Civil 3D 2027 (any Unicode AutoLISP, 2021+)
;;; Pure AutoLISP + Visual LISP (vl-*, vla-*, vlax-*, vlr-*). No ARX, no .NET.
;;;
;;; Holds configuration, xdata read/write, the keyed signature, the geometry
;;; fingerprint, and the drawing-level record helpers that both the edit
;;; stamper (IPStamp.lsp) and the inbound scanner (IPScan.lsp) depend on.
;;; ==========================================================================
(vl-load-com)
(setq *IPS:CoreVersion* "1.0")
(setq *IPS:App* "IPSTAMP")                       ; registered xdata app name

;;; -------------------------------------------------------------- config ---
;;; Set any of these in acaddoc.lsp BEFORE loading the tools to override.

;; Your organisation name. Objects created under this name are "ours".
(if (null *IPS:Org*) (setq *IPS:Org* "YOUR COMPANY"))

;; IP notice written into every object we originate.
(if (null *IPS:IPNotice*)
  (setq *IPS:IPNotice*
    "Proprietary design data of YOUR COMPANY. Reuse, copying or derivation requires written permission."))

;; Path to a text file whose first line is the secret signing key.
;; Keep it on a server share staff can read but that never leaves the firm.
;; "" = use the built-in default key (stamps still work, but anyone with
;; this file can forge them, so set a real key before production use).
(if (null *IPS:KeyFile*) (setq *IPS:KeyFile* ""))

;; DXF entity types (wcmatch pattern) that receive edit stamps.
(if (null *IPS:Types*)
  (setq *IPS:Types*
    (strcat "AECC_*,INSERT,LWPOLYLINE,POLYLINE,LINE,ARC,CIRCLE,ELLIPSE,SPLINE,"
            "TEXT,MTEXT,DIMENSION,LEADER,MULTILEADER,HATCH,POINT,3DFACE,3DSOLID,"
            "REGION,MLINE,XLINE,RAY,SOLID,WIPEOUT,IMAGE")))

;; How many "who/when/command" history entries each object keeps.
(if (null *IPS:HistoryDepth*) (setq *IPS:HistoryDepth* 5))

;; Edit log: "DWG" = CSV next to the drawing, "OFF", or a folder path.
(if (null *IPS:LogMode*) (setq *IPS:LogMode* "DWG"))

;; Transmittal register CSV written by IPXMIT ("" = off).
(if (null *IPS:RegisterFile*) (setq *IPS:RegisterFile* ""))

;; Where IPScan writes its reports ("" = My Documents\IPScan).
(if (null *IPS:ReportDir*) (setq *IPS:ReportDir* ""))

;; Command classes (wcmatch patterns on the global command name) used to
;; label where newly appended objects came from.
(if (null *IPS:ImportCmds*)
  (setq *IPS:ImportCmds*
    "PASTE*,DROPGEOM,XBIND,-XBIND,XREF,-XREF,XATTACH,BIND,*IMPORT*,ACISIN,DXFIN,INSERTOBJ,*LANDXML*"))
(if (null *IPS:DeriveCmds*)  (setq *IPS:DeriveCmds* "EXPLODE,XPLODE,BURST,FLATTEN,TXTEXP"))
(if (null *IPS:InsertCmds*)  (setq *IPS:InsertCmds* "INSERT,-INSERT,CLASSICINSERT,*BLOCKSPALETTE,DDINSERT"))

;;; ----------------------------------------------------- record layout ---
;; Order in which keys are written to xdata. The SIG covers all of them.
(setq *IPS:Order*
  '("V" "ORG" "IP"
    "C_USER" "C_HOST" "C_TIME" "C_DWG" "C_DWGID" "C_TYPE" "C_KEYID" "C_SIG"
    "M_USER" "M_HOST" "M_TIME" "M_CMD" "M_DWG" "M_DWGID"
    "A_USER" "A_TIME" "A_DWG"
    "TZ" "N" "GEO" "KEYID"))
;; Keys covered by the origin signature C_SIG. Written once, when the
;; object is first stamped, and carried unchanged for the object's life.
(setq *IPS:CKeys* '("ORG" "IP" "C_USER" "C_HOST" "C_TIME" "C_DWG" "C_DWGID" "C_TYPE" "C_KEYID"))
(setq *IPS:DefaultKey* "IPSTAMP-DEFAULT-KEY-CHANGE-ME")

;; Object properties folded into the geometry fingerprint (when present).
(setq *IPS:GeoProps*
  '(Coordinates StartPoint EndPoint Center Radius MajorAxis RadiusRatio
    InsertionPoint Rotation XScaleFactor YScaleFactor ZScaleFactor Height
    TextString Measurement Length Area Closed StartingStation EndingStation
    ControlPoints FitPoints Normal))
;; Object types whose bounding box depends on fonts, so it is left out.
(setq *IPS:NoBBox* "*TEXT*,*DIMENSION*,*LEADER*,*ATTRIBUTE*,*TABLE*,*LABEL*,ACDBBLOCKREFERENCE")

;;; ------------------------------------------------------------ strings ---
(defun ips:env (n) (cond ((getenv n)) ("")))

(defun ips:clip (s n) (if (> (strlen s) n) (substr s 1 n) s))

(defun ips:pad2 (n) (if (< n 10) (strcat "0" (itoa n)) (itoa n)))

(defun ips:join (lst sep / out)
  (if lst
    (progn
      (setq out (car lst))
      (foreach s (cdr lst) (setq out (strcat out sep s)))
      out)
    ""))

(defun ips:replace-all (s old new / p)
  (setq p 0)
  (while (setq p (vl-string-search old s p))
    (setq s (strcat (substr s 1 p) new (substr s (+ p 1 (strlen old))))
          p (+ p (strlen new))))
  s)

(defun ips:take (lst n / out)
  (repeat (min n (length lst))
    (setq out (cons (car lst) out) lst (cdr lst)))
  (reverse out))

(defun ips:unvar (v)
  (if (= (type v) 'VARIANT) (ips:unvar (vlax-variant-value v)) v))

;; Stable number format: independent of DIMZIN, 4 decimals, no trailing 0s.
(defun ips:num (x / s)
  (setq s (rtos x 2 4))
  (if (vl-string-search "." s)
    (setq s (vl-string-right-trim "." (vl-string-right-trim "0" s))))
  (cond ((= (substr s 1 1) ".") (setq s (strcat "0" s)))
        ((= (substr s 1 2) "-.") (setq s (strcat "-0" (substr s 2)))))
  (if (member s '("-0" "")) "0" s))

;; Anything -> string.
(defun ips:str (v / r)
  (cond ((null v) "")
        ((= (type v) 'STR) v)
        ((= (type v) 'INT) (itoa v))
        ((= (type v) 'REAL) (ips:num v))
        ((= (type v) 'VARIANT) (ips:str (vlax-variant-value v)))
        ((= (type v) 'SAFEARRAY)
         (setq r (vl-catch-all-apply 'vlax-safearray->list (list v)))
         (if (vl-catch-all-error-p r) "" (ips:str r)))
        ((and (listp v) (vl-list-length v)) (ips:join (mapcar 'ips:str v) ","))
        ((= (type v) 'VLA-OBJECT) "<object>")
        (T (vl-princ-to-string v))))

;;; ------------------------------------------------------------ records ---
;; A record is an ordered alist of ("KEY" . "value") string pairs.
(defun ips:kv (key rec) (cdr (assoc key rec)))

(defun ips:put (rec key val / s old)
  (setq s (ips:clip (ips:str val) (- 240 (strlen key))))
  (if (setq old (assoc key rec))
    (subst (cons key s) old rec)
    (append rec (list (cons key s)))))

(defun ips:put* (rec pairs)
  (foreach p pairs (setq rec (ips:put rec (car p) (cdr p))))
  rec)

;; ((code . "KEY=VAL") ...) -> (("KEY" . "VAL") ...), codes 1 and 1000 only.
(defun ips:kv-parse (pairs / out p)
  (foreach pr pairs
    (if (and (member (car pr) '(1 1000))
             (= (type (cdr pr)) 'STR)
             (setq p (vl-string-search "=" (cdr pr))))
      (setq out (cons (cons (substr (cdr pr) 1 p) (substr (cdr pr) (+ p 2))) out))))
  (reverse out))

;; Two safearrays (type codes, values) -> ((code . value) ...)
(defun ips:pairs (typ val / r)
  (setq typ (ips:unvar typ) val (ips:unvar val))
  (if (and (= (type typ) 'SAFEARRAY) (= (type val) 'SAFEARRAY))
    (progn
      (setq r (vl-catch-all-apply
                (function
                  (lambda ()
                    (mapcar (function (lambda (c v) (cons c (ips:unvar v))))
                            (vlax-safearray->list typ)
                            (vlax-safearray->list val))))
                nil))
      (if (not (vl-catch-all-error-p r)) r))))

(defun ips:sa (vt lst)
  (vlax-safearray-fill (vlax-make-safearray vt (cons 0 (1- (length lst)))) lst))

(defun ips:item (coll name / r)
  (if (and coll
           (not (vl-catch-all-error-p
                  (setq r (vl-catch-all-apply 'vla-item (list coll name))))))
    r))

(defun ips:prop (obj p / v)
  (if (and obj
           (not (vl-catch-all-error-p
                  (setq v (vl-catch-all-apply 'vlax-get-property (list obj p))))))
    v))

;;; --------------------------------------------------------------- xdata ---
;; Works on any object in any open database, including ObjectDBX documents.
(defun ips:xd-read (obj / typ val r)
  (setq r (vl-catch-all-apply 'vla-getxdata (list obj *IPS:App* 'typ 'val)))
  (if (not (vl-catch-all-error-p r))
    (ips:kv-parse (ips:pairs typ val))))

(defun ips:xd-write (obj rec / lst)
  (setq lst (cons (cons 1001 *IPS:App*)
                  (mapcar (function (lambda (p) (cons 1000 (strcat (car p) "=" (cdr p))))) rec)))
  (vla-setxdata obj
                (ips:sa vlax-vbInteger (mapcar 'car lst))
                (ips:sa vlax-vbVariant (mapcar 'cdr lst))))

;;; -------------------------------------------- drawing-level records ---
;; Named Object Dictionary -> "IPSTAMP" -> xrecords "DWGINFO", "XMIT".
(defun ips:xrec-read (db name / dict xr typ val r)
  (if (and (setq dict (ips:item (ips:prop db 'Dictionaries) *IPS:App*))
           (setq xr (ips:item dict name))
           (not (vl-catch-all-error-p
                  (setq r (vl-catch-all-apply 'vla-getxrecorddata (list xr 'typ 'val))))))
    (ips:kv-parse (ips:pairs typ val))))

;;; ------------------------------------------------------ time / identity ---
;; Local time from CDATE, formatted YYYY-MM-DD HH:MM:SS (DIMZIN-proof).
(defun ips:now ( / s p d t6)
  (setq s (rtos (getvar "CDATE") 2 6)
        p (vl-string-search "." s)
        d (if p (substr s 1 p) s)
        t6 (substr (strcat (if p (substr s (+ p 2)) "") "000000") 1 6))
  (strcat (substr d 1 4) "-" (substr d 5 2) "-" (substr d 7 2) " "
          (substr t6 1 2) ":" (substr t6 3 2) ":" (substr t6 5 2)))

(defun ips:fname-stamp () (vl-string-translate "-: " "--_" (ips:now)))

(defun ips:tz ()
  (cond (*IPS:TZ*)
        ((setq *IPS:TZ*
           (vl-registry-read
             "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation"
             "TimeZoneKeyName")))
        ((setq *IPS:TZ* "local time"))))

(defun ips:user ( / d)
  (setq d (ips:env "USERDOMAIN"))
  (if (= d "") (getvar "LOGINNAME") (strcat d "\\" (getvar "LOGINNAME"))))

(defun ips:host () (ips:env "COMPUTERNAME"))

;;; ------------------------------------------------- keyed signature ---
;; Four interleaved polynomial hashes mod 16-bit primes -> 16 hex chars.
;; Every intermediate stays below 2^31 so AutoLISP integers never wrap.
;; This is tamper-evidence, not cryptography: see README "Limits".
(defun ips:hex4 (n / s)
  (setq s "")
  (repeat 4
    (setq s (strcat (substr "0123456789ABCDEF" (1+ (rem n 16)) 1) s)
          n (/ n 16)))
  s)

(defun ips:hash (str / a b c d)
  (setq a 1 b 7 c 13 d 29)
  (foreach ch (vl-string->list str)
    (setq a (rem (+ (* a 31) ch) 65521)
          b (rem (+ (* b 131) ch) 65519)
          c (rem (+ (* c 1031) ch a) 65497)
          d (rem (+ (* d 29989) ch b) 65479)))
  (strcat (ips:hex4 a) (ips:hex4 b) (ips:hex4 c) (ips:hex4 d)))

(defun ips:key ( / path f ln)
  (if (null *IPS:KeyCache*)
    (progn
      (if (and (/= *IPS:KeyFile* "")
               (setq path (findfile *IPS:KeyFile*))
               (setq f (open path "r")))
        (progn (setq ln (read-line f)) (close f)))
      (if ln (setq ln (vl-string-trim " \t" ln)))
      (setq *IPS:KeyCache* (if (and ln (/= ln "")) ln *IPS:DefaultKey*))))
  *IPS:KeyCache*)

(defun ips:default-key-p () (= (ips:key) *IPS:DefaultKey*))

(defun ips:keyid () (substr (ips:hash (strcat "KEYID|" (ips:key))) 1 8))

(defun ips:mac (data / k)
  (setq k (ips:key))
  (ips:hash (strcat k "|" data "|" (ips:hash (strcat data "|" k)) "|" k)))

(defun ips:canon-c (rec)
  (ips:join (mapcar (function (lambda (k) (strcat k "=" (ips:str (ips:kv k rec))))) *IPS:CKeys*) "|"))

(defun ips:canon-all (rec)
  (ips:join (mapcar (function (lambda (p) (strcat (car p) "=" (cdr p))))
                    (vl-remove-if (function (lambda (p) (= (car p) "SIG"))) rec))
            "|"))

(defun ips:canon-owner (info)
  (ips:join (mapcar (function (lambda (k) (ips:str (ips:kv k info))))
                    '("OWNER_DWGID" "OWNER" "MARKED_BY" "MARKED_TIME"))
            "|"))

;; -> "VALID" | "INVALID" | "OTHER-KEY" | "NONE"
(defun ips:check (rec kidkey sigkey data / s)
  (setq s (ips:kv sigkey rec))
  (cond ((or (null s) (= s "")) "NONE")
        ((/= (ips:kv kidkey rec) (ips:keyid)) "OTHER-KEY")
        ((= s (ips:mac data)) "VALID")
        (T "INVALID")))

;; -> (origin-signature-status record-signature-status)
(defun ips:verify (rec)
  (list (ips:check rec "C_KEYID" "C_SIG" (ips:canon-c rec))
        (ips:check rec "KEYID" "SIG" (ips:canon-all rec))))

(defun ips:owner-status (info)
  (ips:check info "OWNER_KEYID" "OWNER_SIG" (ips:canon-owner info)))

(defun ips:sigtext (s)
  (cond ((= s "VALID") "VALID (signed with our key)")
        ((= s "INVALID") "FAILED (record altered or forged)")
        ((= s "OTHER-KEY") "signed with a different key (not ours, cannot verify)")
        (T "missing")))

;;; ------------------------------------------------ geometry fingerprint ---
(defun ips:bbox (obj / mn mx r)
  (setq r (vl-catch-all-apply 'vla-getboundingbox (list obj 'mn 'mx)))
  (if (and (not (vl-catch-all-error-p r)) mn mx)
    (strcat (ips:str mn) ";" (ips:str mx))))

;; Hash of the object's geometric properties. Uses only ActiveX, so it gives
;; the same answer in the editor and in an ObjectDBX scan.
(defun ips:geo (obj / on parts v)
  (setq on (ips:str (ips:prop obj 'ObjectName))
        parts (list on))
  (foreach p *IPS:GeoProps*
    (if (setq v (ips:prop obj p))
      (setq parts (cons (strcat (vl-symbol-name p) ":" (ips:str v)) parts))))
  (if (and (not (wcmatch (strcase on) *IPS:NoBBox*)) (setq v (ips:bbox obj)))
    (setq parts (cons (strcat "BB:" v) parts)))
  (ips:hash (ips:join (reverse parts) "|")))

;; -> "UNCHANGED" | "CHANGED" | "NONE"
(defun ips:geo-status (obj rec / g)
  (setq g (ips:kv "GEO" rec))
  (cond ((or (null g) (= g "")) "NONE")
        ((= g (ips:geo obj)) "UNCHANGED")
        (T "CHANGED")))

;;; ----------------------------------------------------------------- CSV ---
(defun ips:csvq (s) (strcat "\"" (ips:replace-all (ips:str s) "\"" "\"\"") "\""))

(defun ips:csv-line (fields) (ips:join (mapcar 'ips:csvq fields) ","))

(defun ips:append-lines (path header lines / new f)
  (setq new (not (findfile path)))
  (if (setq f (open path "a"))
    (progn
      (if (and new header) (write-line header f))
      (foreach l lines (write-line l f))
      (close f)
      T)))

(defun ips:write-lines (path lines / f)
  (if (setq f (open path "w"))
    (progn (foreach l lines (write-line l f)) (close f) T)))

(defun ips:doc () (vla-get-activedocument (vlax-get-acad-object)))

(princ)
