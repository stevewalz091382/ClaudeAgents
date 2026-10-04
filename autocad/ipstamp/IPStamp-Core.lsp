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

;;; ------------------------------------------------- anti-strip config ---
;; Hidden encrypted copy of every stamp, kept in the object's extension
;; dictionary (and of the drawing record, in the named object dictionary).
;; Pick your own neutral name per firm: an unusual name is harder to find.
(if (null *IPS:Shadow*)    (setq *IPS:Shadow* "YES"))
(if (null *IPS:ShadowKey*) (setq *IPS:ShadowKey* "QC_REF"))

;; Coordinate watermark (IPSEAL): moves coordinates by at most
;; WMStep x WMBins drawing units (default 0.000032) so that a keyed residue
;; is hidden in them. It survives xdata stripping, copy/paste, WBLOCK, DXF,
;; EXPORTTOAUTOCAD for plain objects, and explode of blocks.
(if (null *IPS:WMStep*)  (setq *IPS:WMStep* 1e-6))
(if (null *IPS:WMBins*)  (setq *IPS:WMBins* 32))
;; DXF types that IPSEAL watermarks. Add AECC_COGO_POINT only if your survey
;; standards accept a 0.00003 unit change to point coordinates.
(if (null *IPS:WMTypes*) (setq *IPS:WMTypes* "LWPOLYLINE,POLYLINE,LINE,POINT,CIRCLE,INSERT"))

;; Folder of geometry manifests written by IPXMIT (kept in-house, never sent).
;; IPScan matches received geometry against them even with every mark removed.
(if (null *IPS:ManifestDir*) (setq *IPS:ManifestDir* ""))

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

;;; ===================================================== ANTI-STRIP ===
;;; Layer 1: visible xdata stamp            (deters; easy to see)
;;; Layer 2: hidden encrypted shadow copy   (extension dictionary / NOD)
;;; Layer 3: coordinate watermark            (inside the geometry itself)
;;; Layer 4: hidden sentinel points          (invisible, watermarked)
;;; Layer 5: geometry manifests at the office (cannot be touched by recipient)

;;; ------------------------------------------------------------ helpers ---
(defun ips:split (s ch / out p)
  (while (setq p (vl-string-search ch s))
    (setq out (cons (substr s 1 p) out) s (substr s (+ p 2))))
  (reverse (cons s out)))

(defun ips:hexval (h / n)
  (setq n 0)
  (foreach c (vl-string->list (strcase h))
    (setq n (+ (* n 16) (cond ((<= 48 c 57) (- c 48)) ((<= 65 c 70) (- c 55)) (T 0)))))
  n)

(defun ips:chunks (s n / out)
  (while (> (strlen s) n)
    (setq out (cons (substr s 1 n) out) s (substr s (1+ n))))
  (reverse (cons s out)))

;;; ----------------------------------------------- keyed stream cipher ---
;; Wichmann-Hill generator seeded from the key and a per-record nonce,
;; XORed onto 16-bit character codes. Obfuscation strength, not AES: it hides
;; what the record is and makes it unforgeable without the key.
(defun ips:ks-init (nonce / h)
  (setq h (ips:hash (strcat (ips:key) "|KS|" nonce))
        *IPS:S1* (1+ (rem (ips:hexval (substr h 1 4)) 30268))
        *IPS:S2* (1+ (rem (ips:hexval (substr h 5 4)) 30306))
        *IPS:S3* (1+ (rem (ips:hexval (substr h 9 4)) 30322))))

(defun ips:ks-next ()
  (setq *IPS:S1* (rem (* 171 *IPS:S1*) 30269)
        *IPS:S2* (rem (* 172 *IPS:S2*) 30307)
        *IPS:S3* (rem (* 170 *IPS:S3*) 30323))
  (logand (boole 6 *IPS:S1* (lsh *IPS:S2* 3) (lsh *IPS:S3* 7)) 65535))

(defun ips:encrypt (plain nonce / out)
  (ips:ks-init nonce)
  (setq out "")
  (foreach c (vl-string->list plain)
    (setq out (strcat out (ips:hex4 (boole 6 c (ips:ks-next))))))
  out)

(defun ips:decrypt (hex nonce / out i c)
  (ips:ks-init nonce)
  (setq out "" i 1)
  (while (<= (+ i 3) (strlen hex))
    (setq c (boole 6 (ips:hexval (substr hex i 4)) (ips:ks-next)))
    (setq out (strcat out (if (and (> c 0) (< c 65534)) (chr c) "?"))
          i (+ i 4)))
  out)

(defun ips:nonce (seed)
  (setq *IPS:NonceN* (1+ (cond (*IPS:NonceN*) (0))))
  (substr (ips:hash (strcat seed "|" (ips:now) "|" (rtos (getvar "DATE") 2 8)
                            "|" (itoa *IPS:NonceN*) "|" (rtos (getvar "MILLISECS") 2 0)))
          1 12))

;;; ------------------------------------------------------ shadow records ---
;; Fields kept in the hidden copy: enough to rebuild and verify the origin.
(setq *IPS:ShadowFields*
  '("ORG" "IP" "C_USER" "C_HOST" "C_TIME" "C_DWG" "C_DWGID" "C_TYPE" "C_KEYID" "C_SIG"
    "M_USER" "M_TIME" "M_CMD" "M_DWG" "N" "GEO"))

;; rec -> list of strings for xrecord group 1: nonce, then cipher chunks.
(defun ips:shadow-pack (rec fields / body n)
  (setq body (ips:join (vl-remove nil
                         (mapcar (function (lambda (k) (if (assoc k rec) (strcat k "=" (cdr (assoc k rec))))))
                                 fields))
                       (chr 10))
        body (strcat body (chr 10) "S=" (ips:mac body))
        n    (ips:nonce body))
  (cons n (ips:chunks (ips:encrypt body n) 240)))

;; strings -> ("VALID" . rec) | ("UNREADABLE" . nil) | nil
(defun ips:shadow-unpack (strs / body lines sig rest)
  (if (and strs (cdr strs))
    (progn
      (setq body  (ips:decrypt (apply 'strcat (cdr strs)) (car strs))
            lines (ips:split body (chr 10))
            sig   (last lines)
            rest  (ips:join (reverse (cdr (reverse lines))) (chr 10)))
      (if (and (wcmatch sig "S=*") (= (substr sig 3) (ips:mac rest)))
        (cons "VALID" (ips:kv-parse (mapcar (function (lambda (l) (cons 1 l))) (reverse (cdr (reverse lines))))))
        (cons "UNREADABLE" nil)))))

(defun ips:xrec-strings (xr / typ val r)
  (setq r (vl-catch-all-apply 'vla-getxrecorddata (list xr 'typ 'val)))
  (if (not (vl-catch-all-error-p r))
    (mapcar 'cdr (vl-remove-if-not (function (lambda (p) (= (car p) 1))) (ips:pairs typ val)))))

(defun ips:xrec-set-strings (xr strs)
  (vla-setxrecorddata xr
    (ips:sa vlax-vbInteger (mapcar (function (lambda (s) 1)) strs))
    (ips:sa vlax-vbVariant strs)))

;; Hidden copy on an object (extension dictionary). Read works in ObjectDBX.
(defun ips:shadow-read (obj / ed xr)
  (if (and (= (ips:prop obj 'HasExtensionDictionary) :vlax-true)
           (not (vl-catch-all-error-p
                  (setq ed (vl-catch-all-apply 'vla-getextensiondictionary (list obj)))))
           (setq xr (ips:item ed *IPS:ShadowKey*)))
    (ips:shadow-unpack (ips:xrec-strings xr))))

(defun ips:shadow-write (obj rec / ed xr)
  (if (= (strcase *IPS:Shadow*) "YES")
    (progn
      (setq ed (vla-getextensiondictionary obj)
            xr (cond ((ips:item ed *IPS:ShadowKey*)) ((vla-addxrecord ed *IPS:ShadowKey*))))
      (ips:xrec-set-strings xr (ips:shadow-pack rec *IPS:ShadowFields*)))))

;; Hidden copy of the drawing record, in the named object dictionary.
(defun ips:dshadow-read (db / d xr)
  (if (and (setq d (ips:item (ips:prop db 'Dictionaries) *IPS:ShadowKey*))
           (setq xr (ips:item d "D")))
    (ips:shadow-unpack (ips:xrec-strings xr))))

(defun ips:dshadow-write (db info / dicts d xr)
  (if (= (strcase *IPS:Shadow*) "YES")
    (progn
      (setq dicts (vla-get-dictionaries db)
            d  (cond ((ips:item dicts *IPS:ShadowKey*)) ((vla-add dicts *IPS:ShadowKey*)))
            xr (cond ((ips:item d "D")) ((vla-addxrecord d "D"))))
      (ips:xrec-set-strings xr (ips:shadow-pack info (mapcar 'car info))))))

;;; -------------------------------------------------- coordinate watermark ---
;; Each x (and y) coordinate is nudged so that floor((x mod cell) / step)
;; equals a residue derived from the secret key. Unmarked coordinates hit
;; that residue 1 time in WMBins; marked ones always do.
(setq *IPS:WMMap*
  '(("LWPOLYLINE"      "AcDbPolyline"       Coordinates 2)
    ("POLYLINE"        "AcDb2dPolyline"     Coordinates 3)
    ("POLYLINE"        "AcDb3dPolyline"     Coordinates 3)
    ("LINE"            "AcDbLine"           StartPoint  0)
    ("LINE"            "AcDbLine"           EndPoint    0)
    ("POINT"           "AcDbPoint"          Coordinates 3)
    ("CIRCLE"          "AcDbCircle"         Center      0)
    ("ARC"             "AcDbArc"            Center      0)
    ("INSERT"          "AcDbBlockReference" InsertionPoint 0)
    ("AECC_COGO_POINT" "AeccDbCogoPoint"    EastNorth   0)))

(defun ips:wm-targets ( / h)
  (setq h (ips:hash (strcat (ips:key) "|WATERMARK")))
  (list (rem (ips:hexval (substr h 1 4)) *IPS:WMBins*)
        (rem (ips:hexval (substr h 5 4)) *IPS:WMBins*)))

(defun ips:wm-bin (v / cell r)
  (setq cell (* *IPS:WMBins* *IPS:WMStep*)
        r    (rem v cell))
  (if (< r 0.0) (setq r (+ r cell)))
  (min (1- *IPS:WMBins*) (fix (/ r *IPS:WMStep*))))

(defun ips:wm-fix (v tgt / cell r)
  (if (= (ips:wm-bin v) tgt)
    v
    (progn
      (setq cell (* *IPS:WMBins* *IPS:WMStep*)
            r    (rem v cell))
      (if (< r 0.0) (setq r (+ r cell)))
      (+ (- v r) (* (+ tgt 0.5) *IPS:WMStep*)))))

;; Watermark rows that apply to this object under the current *IPS:WMTypes*.
(defun ips:wm-rows (obj / on)
  (setq on (ips:str (ips:prop obj 'ObjectName)))
  (vl-remove-if-not
    (function (lambda (r) (and (= (cadr r) on) (wcmatch (car r) *IPS:WMTypes*))))
    *IPS:WMMap*))

;; -> list of (x . y) for every watermarkable vertex of the object.
(defun ips:wm-xy (obj / out lst i)
  (foreach r (ips:wm-rows obj)
    (cond
      ((= (caddr r) 'EastNorth)
       (setq out (cons (cons (vlax-get obj 'Easting) (vlax-get obj 'Northing)) out)))
      ((> (cadddr r) 0)
       (setq lst (vl-catch-all-apply 'vlax-get (list obj (caddr r))) i 0)
       (if (and (listp lst) (not (vl-catch-all-error-p lst)))
         (while (< (1+ i) (length lst))
           (setq out (cons (cons (nth i lst) (nth (1+ i) lst)) out)
                 i (+ i (cadddr r))))))
      (T
       (setq lst (vl-catch-all-apply 'vlax-get (list obj (caddr r))))
       (if (and (listp lst) (not (vl-catch-all-error-p lst)) (cadr lst))
         (setq out (cons (cons (car lst) (cadr lst)) out))))))
  out)

;; -> (hits . coordinates) for one object
(defun ips:wm-count (obj / tg h n)
  (setq tg (ips:wm-targets) h 0 n 0)
  (foreach p (ips:wm-xy obj)
    (setq n (+ n 2))
    (if (= (ips:wm-bin (car p)) (car tg)) (setq h (1+ h)))
    (if (= (ips:wm-bin (cdr p)) (cadr tg)) (setq h (1+ h))))
  (cons h n))

;; Applies the watermark. Returns T if any coordinate moved.
(defun ips:wm-apply (obj / tg moved lst new i old)
  (setq tg (ips:wm-targets))
  (foreach r (ips:wm-rows obj)
    (cond
      ((= (caddr r) 'EastNorth)
       (setq old (list (vlax-get obj 'Easting) (vlax-get obj 'Northing))
             new (list (ips:wm-fix (car old) (car tg)) (ips:wm-fix (cadr old) (cadr tg))))
       (if (not (equal old new 0.0))
         (progn (vlax-put obj 'Easting (car new)) (vlax-put obj 'Northing (cadr new)) (setq moved T))))
      (T
       (setq lst (vlax-get obj (caddr r)) i 0 new nil)
       (foreach v lst
         (setq new (cons (cond ((= (rem i (max 2 (cadddr r))) 0) (ips:wm-fix v (car tg)))
                               ((= (rem i (max 2 (cadddr r))) 1) (ips:wm-fix v (cadr tg)))
                               (T v))
                         new)
               i (1+ i)))
       (setq new (reverse new))
       (if (not (equal lst new 0.0))
         (progn (vlax-put obj (caddr r) new) (setq moved T))))))
  moved)

;; Binomial z-score of watermark hits against the 1-in-WMBins chance rate.
(defun ips:wm-z (hits n / p)
  (setq p (/ 1.0 *IPS:WMBins*))
  (if (> n 0) (/ (- hits (* n p)) (sqrt (* n p (- 1.0 p)))) 0.0))

;; Stamp from the visible xdata, else from the hidden copy.
(defun ips:rec-any (obj / sh)
  (cond ((ips:xd-read obj))
        ((= (car (setq sh (ips:shadow-read obj))) "VALID") (cdr sh))))

;;; ------------------------------------------------------------ sentinels ---
;; Invisible POINT entities carrying a stamp, a shadow and the watermark.
(defun ips:sentinel-p (obj)
  (and (= (ips:prop obj 'ObjectName) "AcDbPoint")
       (= (ips:prop obj 'Visible) :vlax-false)))

(princ)
