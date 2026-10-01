;;; ============================================================================
;;; C3DTools-Core.lsp
;;;
;;; Shared services for C3DGuard, C3DAudit and C3DImpact:
;;;   - configuration lookup (C3DTools-Config.lsp + environment overrides)
;;;   - install and log folder resolution
;;;   - fail-safe COM property helpers
;;;   - CSV helpers
;;;   - a cached connection to the Civil 3D COM application object
;;;
;;; Naming: every function and global in this file starts with c3dt: or
;;; *c3dt:, so nothing here can collide with other LISP loaded in the session.
;;; ============================================================================

(vl-load-com)

(setq *c3dt:version* "1.0.0")
(setq *c3dt:publisher* "Stephen Walz")

;; ---------------------------------------------------------------------------
;; Configuration
;;
;; C3DTools-Config.lsp sets *c3dt:config* to an association list of
;; ("Key" . value) pairs before this file loads. A key that is missing from
;; the list falls back to the default given at the call site.
;; ---------------------------------------------------------------------------

(defun c3dt:cfg (key default / pair)
  (setq pair (if (boundp '*c3dt:config*) (assoc key *c3dt:config*)))
  (if pair (cdr pair) default)
)

(defun c3dt:nonblank (s)
  (if (and (= (type s) 'STR) (/= (vl-string-trim " \t" s) "")) s nil)
)

;; Per-user preference stored in the AutoCAD profile (HKCU), survives restarts.
(defun c3dt:pref-get (name)
  (c3dt:nonblank (getenv (strcat "C3DTools." name)))
)

(defun c3dt:pref-set (name value)
  (vl-catch-all-apply 'setenv (list (strcat "C3DTools." name) value))
  value
)

;; ---------------------------------------------------------------------------
;; Folders
;; ---------------------------------------------------------------------------

;; Normalises to backslashes and guarantees exactly one trailing backslash.
(defun c3dt:dir-slash (d)
  (setq d (vl-string-right-trim "\\" (vl-string-translate "/" "\\" d)))
  (strcat d "\\")
)

;; vl-mkdir creates one level only; this creates every missing parent.
(defun c3dt:mkdir-p (dir / trimmed parent)
  (setq trimmed (vl-string-right-trim "\\" (vl-string-translate "/" "\\" dir)))
  (cond
    ((= trimmed "") nil)
    ((vl-file-directory-p trimmed) T)
    (T
     (setq parent (vl-filename-directory trimmed))
     (if (and parent (/= parent "") (/= parent trimmed))
       (c3dt:mkdir-p parent)
     )
     (vl-mkdir trimmed)
    )
  )
)

;; Install folder, as resolved by C3DTools-Loader.lsp.
(defun c3dt:home ( )
  (if (and (boundp '*c3dt:home*) *c3dt:home*) *c3dt:home* "")
)

;; Log folder. Resolution order:
;;   1. C3DTOOLS_LOGDIR (Windows environment variable, or setenv in AutoCAD)
;;   2. "LogDir" in C3DTools-Config.lsp
;;   3. %LOCALAPPDATA%\C3DTools\Logs\
;;   4. AutoCAD's TEMPPREFIX folder + C3DTools\Logs\
;; Resolved once per drawing session and cached.
(setq *c3dt:log-dir* nil)

(defun c3dt:log-dir ( / d la)
  (if (not *c3dt:log-dir*)
    (progn
      (setq d
        (cond
          ((c3dt:nonblank (getenv "C3DTOOLS_LOGDIR")))
          ((c3dt:nonblank (c3dt:cfg "LogDir" nil)))
          ((setq la (c3dt:nonblank (getenv "LOCALAPPDATA")))
           (strcat la "\\C3DTools\\Logs"))
          (T (strcat (getvar "TEMPPREFIX") "C3DTools\\Logs"))
        )
      )
      (setq d (c3dt:dir-slash d))
      (vl-catch-all-apply 'c3dt:mkdir-p (list d))
      (setq *c3dt:log-dir* d)
    )
  )
  *c3dt:log-dir*
)

(defun c3dt:log-file (name) (strcat (c3dt:log-dir) name))

;; ---------------------------------------------------------------------------
;; Messages
;; ---------------------------------------------------------------------------

(defun c3dt:msg (tag msg)
  (princ (strcat "\n[" tag "] " msg))
  (princ)
)

;; ---------------------------------------------------------------------------
;; Fail-safe COM helpers. None of these ever raise: a missing or renamed
;; property returns nil (or 0 for counts).
;; ---------------------------------------------------------------------------

(defun c3dt:prop (obj propname / r)
  (if (= (type obj) 'VLA-OBJECT)
    (progn
      (setq r (vl-catch-all-apply 'vlax-get-property (list obj propname)))
      (if (vl-catch-all-error-p r) nil r)
    )
  )
)

(defun c3dt:invoke (obj methodname args / r)
  (if (= (type obj) 'VLA-OBJECT)
    (progn
      (setq r (vl-catch-all-apply 'vlax-invoke-method (append (list obj methodname) args)))
      (if (vl-catch-all-error-p r) nil r)
    )
  )
)

(defun c3dt:count (obj / n)
  (setq n (c3dt:prop obj 'Count))
  (if (= (type n) 'INT) n 0)
)

;; Count of a collection-valued property: (c3dt:prop-count doc 'Surfaces)
(defun c3dt:prop-count (obj propname)
  (c3dt:count (c3dt:prop obj propname))
)

(defun c3dt:str-prop (obj propname / v)
  (setq v (c3dt:prop obj propname))
  (if (= (type v) 'STR) v nil)
)

(defun c3dt:object-name (obj)
  (cond ((c3dt:str-prop obj 'ObjectName)) (""))
)

(defun c3dt:collection->list (coll / lst)
  (setq lst nil)
  (if (= (type coll) 'VLA-OBJECT)
    (vl-catch-all-apply
      (function (lambda () (vlax-for itm coll (setq lst (cons itm lst)))))
    )
  )
  (reverse lst)
)

(defun c3dt:active-doc ( )
  (vla-get-ActiveDocument (vlax-get-acad-object))
)

;; ---------------------------------------------------------------------------
;; CSV helpers
;; ---------------------------------------------------------------------------

;; RFC 4180 quoting: wrap in quotes, double any embedded quote.
(defun c3dt:csv-quote (s / out i n ch)
  (setq out "\"" i 1 n (strlen s))
  (while (<= i n)
    (setq ch (substr s i 1))
    (setq out (strcat out (if (= ch "\"") "\"\"" ch)))
    (setq i (1+ i))
  )
  (strcat out "\"")
)

;; Quote-aware split on a single-character separator.
(defun c3dt:csv-split (str sep / i n ch inq field out)
  (setq i 1 n (strlen str) field "" inq nil out nil)
  (while (<= i n)
    (setq ch (substr str i 1))
    (cond
      ((and inq (= ch "\"") (< i n) (= (substr str (1+ i) 1) "\""))
       (setq field (strcat field "\"") i (+ i 2))
      )
      ((= ch "\"") (setq inq (not inq) i (1+ i)))
      ((and (not inq) (= ch sep)) (setq out (cons field out) field "" i (1+ i)))
      (T (setq field (strcat field ch) i (1+ i)))
    )
  )
  (reverse (cons field out))
)

;; Joins plain strings with a separator, no quoting (headers, fixed names).
(defun c3dt:join (strs sep / s)
  (setq s nil)
  (foreach x strs (setq s (if s (strcat s sep x) x)))
  (if s s "")
)

;; One value -> CSV field. Strings are always quoted.
(defun c3dt:csv-field (v)
  (cond
    ((= (type v) 'STR)  (c3dt:csv-quote v))
    ((= (type v) 'INT)  (itoa v))
    ((= (type v) 'REAL) (rtos v 2 6))
    ((null v) "")
    ((eq v :vlax-true) "True")
    ((eq v :vlax-false) "False")
    (T (c3dt:csv-quote (vl-princ-to-string v)))
  )
)

(defun c3dt:csv-row (lst / s x)
  (setq s nil)
  (foreach x lst
    (setq s (if s (strcat s "," (c3dt:csv-field x)) (c3dt:csv-field x)))
  )
  (if s s "")
)

(defun c3dt:timestamp ( )
  (menucmd "M=$(edtime,$(getvar,date),YYYY-MO-DD HH:MM:SS)")
)

;; ---------------------------------------------------------------------------
;; Text file helpers. All return nil on failure rather than raising.
;; ---------------------------------------------------------------------------

(defun c3dt:read-lines (path / f line out)
  (setq out nil)
  (if (and path (findfile path) (setq f (open path "r")))
    (progn
      (while (setq line (read-line f)) (setq out (cons line out)))
      (close f)
    )
  )
  (reverse out)
)

(defun c3dt:write-lines (path lines / f)
  (if (setq f (open path "w"))
    (progn
      (foreach ln lines (write-line ln f))
      (close f)
      T
    )
  )
)

;; Appends one line, writing header first if the file does not exist yet.
(defun c3dt:append-line (path header line / isnew f)
  (setq isnew (not (findfile path)))
  (if (setq f (open path (if isnew "w" "a")))
    (progn
      (if (and isnew header) (write-line header f))
      (write-line line f)
      (close f)
      T
    )
  )
)

;; ---------------------------------------------------------------------------
;; Civil 3D COM connection (cached)
;;
;; The Civil 3D application object is reached through
;; AcadApplication.GetInterfaceObject("AeccXUiLand.AeccApplication.<ver>").
;; Finding <ver> is the slow part, so the result is cached at three levels:
;;   1. this drawing session      (*c3dt:civil-app*)
;;   2. every drawing this session (the Visual LISP blackboard)
;;   3. future sessions            (per-user AutoCAD profile, C3DTools.CivilProgID)
;; On a cache miss only a short candidate list is tried. The full registry
;; scan is never run automatically; C3DTOOLS-FINDCIVIL runs it on demand and
;; stores the answer.
;; ---------------------------------------------------------------------------

(setq *c3dt:civil-app* nil)

(setq *c3dt:civil-prefix* "AeccXUiLand.AeccApplication")

(defun c3dt:try-civil-progid (pid / r)
  (setq r (vl-catch-all-apply 'vlax-invoke-method
            (list (vlax-get-acad-object) 'GetInterfaceObject pid)))
  (if (or (vl-catch-all-error-p r) (/= (type r) 'VLA-OBJECT)) nil r)
)

(defun c3dt:civil-candidates ( / out minor curver)
  (setq out nil)
  (foreach pid (list (c3dt:pref-get "CivilProgID")
                     (vl-bb-ref '*c3dt:bb-civil-progid*)
                     (vl-catch-all-apply 'vl-registry-read
                       (list (strcat "HKEY_CLASSES_ROOT\\" *c3dt:civil-prefix* "\\CurVer")))
                     *c3dt:civil-prefix*)
    (if (and (= (type pid) 'STR) (not (member pid out))) (setq out (cons pid out)))
  )
  (setq minor 9)
  (while (>= minor 0)
    (setq curver (strcat *c3dt:civil-prefix* ".13." (itoa minor)))
    (if (not (member curver out)) (setq out (cons curver out)))
    (setq minor (1- minor))
  )
  (reverse out)
)

(defun c3dt:remember-civil-progid (pid)
  (vl-bb-set '*c3dt:bb-civil-progid* pid)
  (vl-bb-set '*c3dt:bb-civil-failed* nil)
  (if (/= pid (c3dt:pref-get "CivilProgID")) (c3dt:pref-set "CivilProgID" pid))
)

(defun c3dt:civil-app ( / app)
  (cond
    ((and (= (type *c3dt:civil-app*) 'VLA-OBJECT)
          (not (vlax-object-released-p *c3dt:civil-app*)))
     *c3dt:civil-app*)
    ;; already failed once this session (plain AutoCAD, or unknown release):
    ;; do not pay for the probe again on every save
    ((vl-bb-ref '*c3dt:bb-civil-failed*) nil)
    (T
     (foreach pid (c3dt:civil-candidates)
       (if (and (not app) (setq app (c3dt:try-civil-progid pid)))
         (c3dt:remember-civil-progid pid)
       )
     )
     (if app
       (setq *c3dt:civil-app* app)
       (vl-bb-set '*c3dt:bb-civil-failed* T)
     )
     app
    )
  )
)

(defun c3dt:civil-doc ( / app d)
  (if (setq app (c3dt:civil-app))
    (progn
      (setq d (vl-catch-all-apply 'vlax-get-property (list app 'ActiveDocument)))
      (if (vl-catch-all-error-p d) nil d)
    )
  )
)

;; "AeccXUiLand.AeccApplication.13.9" -> 13009, version-less -> -1
(defun c3dt:progid-rank (pid / rest dot)
  (setq rest (substr pid (1+ (strlen *c3dt:civil-prefix*))))
  (if (and (> (strlen rest) 1) (= (substr rest 1 1) "."))
    (progn
      (setq rest (substr rest 2) dot (vl-string-search "." rest))
      (if dot
        (+ (* 1000 (atoi (substr rest 1 dot))) (atoi (substr rest (+ dot 2))))
        (* 1000 (atoi rest))
      )
    )
    -1
  )
)

;; Diagnostic: full HKCR scan (slow, on demand only), tests each ProgID live,
;; and stores the first working one so every later connection is instant.
(defun c:C3DTOOLS-FINDCIVIL ( / all matches found)
  (c3dt:msg "C3DTools" "Scanning the registry for Civil 3D ProgIDs (this can take a while)...")
  (setq all (vl-catch-all-apply 'vl-registry-descendents (list "HKEY_CLASSES_ROOT")))
  (if (vl-catch-all-error-p all) (setq all nil))
  (setq matches nil)
  (foreach k all
    (if (wcmatch (strcase k) (strcat (strcase *c3dt:civil-prefix*) "*"))
      (setq matches (cons k matches))
    )
  )
  (setq matches (vl-sort matches (function (lambda (a b) (> (c3dt:progid-rank a) (c3dt:progid-rank b))))))
  (if (not matches)
    (c3dt:msg "C3DTools" "No Civil 3D ProgID is registered. This is plain AutoCAD, or Civil 3D needs a repair install.")
    (foreach pid matches
      (if (c3dt:try-civil-progid pid)
        (progn
          (princ (strcat "\n  " pid "  ->  connects"))
          (if (not found) (setq found pid))
        )
        (princ (strcat "\n  " pid "  ->  does not instantiate"))
      )
    )
  )
  (if found
    (progn
      (c3dt:remember-civil-progid found)
      (setq *c3dt:civil-app* nil)
      (c3dt:msg "C3DTools" (strcat "Saved " found " for future sessions."))
    )
  )
  (princ)
)

(defun c:C3DTOOLS-STATUS ( / app)
  (setq app (c3dt:civil-app))
  (c3dt:msg "C3DTools" (strcat "Version " *c3dt:version* " - published by " *c3dt:publisher*))
  (princ (strcat "\n  Install folder:  " (c3dt:home)))
  (princ (strcat "\n  Log folder:      " (c3dt:log-dir)))
  (princ (strcat "\n  Civil 3D COM:    "
                 (if app
                   (strcat "connected (" (cond ((vl-bb-ref '*c3dt:bb-civil-progid*)) ("?")) ")")
                   "not connected - run C3DTOOLS-FINDCIVIL")))
  (princ "\n  Tool status:     C3DGUARD-STATUS, C3D-IMPACT-STATUS")
  (princ)
)

(princ)
