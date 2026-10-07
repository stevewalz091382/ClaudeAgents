;;; ============================================================================
;;; CutOnce-Core.lsp
;;;
;;; CutOnce (formerly ModelWise, and before that C3DTools). Shared services for the Standards, Health,
;;; Guard and Impact modules and the CutOnce Control Center:
;;;   - configuration lookup (CutOnce-Config.lsp + environment overrides)
;;;   - per-user settings registry (what the Control Center switches on/off)
;;;   - install and log folder resolution
;;;   - fail-safe COM property helpers
;;;   - CSV helpers (with automatic archiving when a log's columns change)
;;;   - the shared Events.csv writer
;;;   - a cached connection to the Civil 3D COM application object
;;;
;;; Naming: every function and global in this file starts with mwise: or
;;; *mwise:, so nothing here can collide with other LISP loaded in the session.
;;; ============================================================================

(vl-load-com)

(setq *mwise:version* "2.0.0")
(setq *mwise:publisher* "Stephen Walz")

;; ---------------------------------------------------------------------------
;; Configuration
;;
;; CutOnce-Config.lsp sets *mwise:config* to an association list of
;; ("Key" . value) pairs before this file loads. A key that is missing from
;; the list falls back to the default given at the call site.
;; ---------------------------------------------------------------------------

(defun mwise:cfg (key default / pair)
  (setq pair (if (boundp '*mwise:config*) (assoc key *mwise:config*)))
  (if pair (cdr pair) default)
)

(defun mwise:nonblank (s)
  (if (and (= (type s) 'STR) (/= (vl-string-trim " \t" s) "")) s nil)
)

;; Per-user preference stored in the AutoCAD profile (HKCU), survives restarts.
(defun mwise:pref-get (name)
  (mwise:nonblank (getenv (strcat "CutOnce." name)))
)

(defun mwise:pref-set (name value)
  (vl-catch-all-apply 'setenv (list (strcat "CutOnce." name) value))
  value
)

;; One-time carry-over of each designer's choices from ModelWise (stored as
;; ModelWise.<name>) or, failing that, C3DTools (C3DTools.<name>). Runs once
;; per user profile.
(setq *mwise:migrated-prefs*
  '("ImpactWarnFrequency" "ImpactIntercept" "ImpactIntercept.MOVE" "ImpactIntercept.STRETCH"
    "ImpactIntercept.ROTATE" "ImpactIntercept.SCALE" "CivilProgID"))

(defun mwise:migrate-prefs ( / v)
  (if (not (getenv "CutOnce.PrefsMigrated"))
    (progn
      (foreach k (append (mapcar 'car *mwise:settings*) *mwise:migrated-prefs*)
        (if (and (setq v (cond ((mwise:nonblank (getenv (strcat "ModelWise." k))))
                               ((mwise:nonblank (getenv (strcat "C3DTools." k))))))
                 (not (mwise:pref-get k)))
          (mwise:pref-set k v))
      )
      (vl-catch-all-apply 'setenv (list "CutOnce.PrefsMigrated" "1"))
    )
  )
)

;; ---------------------------------------------------------------------------
;; Settings registry
;;
;; Every on/off choice a designer can make in the Model Manager Control
;; Center (CUTONCE). For each key, the effective value is:
;;   1. the administrator's value, if the key is listed in "LockedSettings"
;;   2. otherwise the user's own choice (AutoCAD profile, CutOnce.<key>)
;;   3. otherwise the administrator's default: ("<key>" . T/nil) in the config
;;   4. otherwise the built-in default below
;;
;; Fields: key, Control Center group, label, built-in default.
;; ---------------------------------------------------------------------------

(setq *mwise:settings*
  '(
    ;; Change-impact warnings
    ("ImpactWarnings"   "Impact"   "Show change-impact warnings"                          T)
    ("ImpactGrips"      "Impact"   "Grip edits of alignments and profiles"                T)
    ("ImpactSurface"    "Impact"   "Surface edit commands"                                T)
    ("ImpactTransform"  "Impact"   "MOVE / STRETCH / ROTATE / SCALE of Civil 3D objects" T)
    ("ImpactOther"      "Impact"   "Other watched commands (added by CAD admin)"          T)
    ;; Data-loss guards
    ("GuardExplode"     "Guard"    "EXPLODE / BURST of Civil 3D objects and attributes"   T)
    ("GuardXrefBind"    "Guard"    "Xref bound into the drawing (XREF / XBIND)"           T)
    ("GuardXrefMove"    "Guard"    "Xref moved or copied"                                 T)
    ("GuardRefEdit"     "Guard"    "REFEDIT / REFCLOSE advisory"                          T)
    ("GuardPromote"     "Guard"    "PROMOTEREFERENCE advisory"                            T)
    ("GuardTextTip"     "Guard"    "TEXT / MTEXT tip (once per session)"                  T)
    ;; Save checks
    ("GuardGrowth"      "Save"     "Unusual growth since the last check"                  T)
    ("GuardXrefOrigin"  "Save"     "Xref not inserted at 0,0,0"                           T)
    ;; Standards check when a drawing opens
    ("StdCheckOnOpen"   "Open"     "Run the standards check when a drawing opens"         T)
    ("StdByLayer"       "Open"     "Objects whose color or linetype is not ByLayer"       T)
    ("StdXrefStatus"    "Open"     "Xrefs that are broken (not found) or unloaded"        T)
    ("StdXrefOrigin"    "Open"     "Xrefs not inserted at 0,0,0"                          T)
    ("StdAlwaysShow"    "Open"     "Show the result even when nothing is wrong"           nil)
    ("StdScanBlocks"    "Open"     "Include block definitions in ByLayer counts (slower)" T)
    ;; Logging
    ("LogEnabled"       "Log"      "Write logs"                                           T)
    ("LogHealthOnSave"  "Log"      "Health.csv row on every save"                         T)
    ("LogHealthOnOpen"  "Log"      "Health.csv row when a drawing opens"                  T)
    ("LogXrefs"         "Log"      "Xrefs.csv detail with every Health.csv row"           T)
    ("LogEvents"        "Log"      "Events.csv row for every warning"                     T)
    ("LogOpened"        "Log"      "Opened.csv row for every drawing opened"              T)
  )
)

(vl-catch-all-apply 'mwise:migrate-prefs nil)

(defun mwise:setting-keys ( ) (mapcar 'car *mwise:settings*))

(defun mwise:setting-label (key / e)
  (if (setq e (assoc key *mwise:settings*)) (caddr e) key)
)

;; Administrator default: the same key at the top level of the config,
;; falling back to the built-in default.
(defun mwise:setting-default (key / e)
  (setq e (assoc key *mwise:settings*))
  (if (mwise:cfg key (if e (cadddr e) T)) T nil)
)

(defun mwise:locked-p (key / l)
  (setq l (mwise:cfg "LockedSettings" nil))
  (if (and l (listp l)
           (member (strcase key) (mapcar 'strcase (vl-remove-if-not 'mwise:nonblank l))))
    T
  )
)

(defun mwise:on-p (key / p)
  (if (mwise:locked-p key)
    (mwise:setting-default key)
    (progn
      (setq p (mwise:pref-get key))
      (cond ((= p "1") T)
            ((= p "0") nil)
            (T (mwise:setting-default key))))
  )
)

;; Stores the user's choice. A choice equal to the administrator default is
;; stored as "no choice", so a later change to the default still reaches
;; this user. Locked keys are never written.
(defun mwise:set-on (key on)
  (if (not (mwise:locked-p key))
    (if (eq (if on T nil) (mwise:setting-default key))
      (if (mwise:pref-get key) (mwise:pref-set key ""))
      (mwise:pref-set key (if on "1" "0"))
    )
  )
)

;; Logging gate: the master switch and the specific log.
(defun mwise:log-on-p (key)
  (and (mwise:on-p "LogEnabled") (mwise:on-p key))
)

;; ---------------------------------------------------------------------------
;; Folders
;; ---------------------------------------------------------------------------

;; Normalises to backslashes and guarantees exactly one trailing backslash.
(defun mwise:dir-slash (d)
  (setq d (vl-string-right-trim "\\" (vl-string-translate "/" "\\" d)))
  (strcat d "\\")
)

;; vl-mkdir creates one level only; this creates every missing parent.
(defun mwise:mkdir-p (dir / trimmed parent)
  (setq trimmed (vl-string-right-trim "\\" (vl-string-translate "/" "\\" dir)))
  (cond
    ((= trimmed "") nil)
    ((vl-file-directory-p trimmed) T)
    (T
     (setq parent (vl-filename-directory trimmed))
     (if (and parent (/= parent "") (/= parent trimmed))
       (mwise:mkdir-p parent)
     )
     (vl-mkdir trimmed)
    )
  )
)

;; Install folder, as resolved by CutOnce-Loader.lsp.
(defun mwise:home ( )
  (if (and (boundp '*mwise:home*) *mwise:home*) *mwise:home* "")
)

;; Log folder. Resolution order:
;;   1. CUTONCE_LOGDIR (Windows environment variable, or setenv in AutoCAD)
;;   2. "LogDir" in CutOnce-Config.lsp
;;   3. %LOCALAPPDATA%\CutOnce\Logs\
;;   4. AutoCAD's TEMPPREFIX folder + CutOnce\Logs\
;; Resolved once per drawing session and cached.
(setq *mwise:log-dir* nil)

(defun mwise:log-dir ( / d la)
  (if (not *mwise:log-dir*)
    (progn
      (setq d
        (cond
          ((mwise:nonblank (getenv "CUTONCE_LOGDIR")))
          ;; set by the ModelWise installer; honored until it is replaced
          ((mwise:nonblank (getenv "MODELWISE_LOGDIR")))
          ;; set by the C3DTools installer; honored until it is replaced
          ((mwise:nonblank (getenv "C3DTOOLS_LOGDIR")))
          ((mwise:nonblank (mwise:cfg "LogDir" nil)))
          ((setq la (mwise:nonblank (getenv "LOCALAPPDATA")))
           (strcat la "\\CutOnce\\Logs"))
          (T (strcat (getvar "TEMPPREFIX") "CutOnce\\Logs"))
        )
      )
      (setq d (mwise:dir-slash d))
      (vl-catch-all-apply 'mwise:mkdir-p (list d))
      (setq *mwise:log-dir* d)
    )
  )
  *mwise:log-dir*
)

(defun mwise:log-file (name) (strcat (mwise:log-dir) name))

;; ---------------------------------------------------------------------------
;; Messages
;; ---------------------------------------------------------------------------

(defun mwise:msg (tag msg)
  (princ (strcat "\n[" tag "] " msg))
  (princ)
)

;; ---------------------------------------------------------------------------
;; Fail-safe COM helpers. None of these ever raise: a missing or renamed
;; property returns nil (or 0 for counts).
;; ---------------------------------------------------------------------------

(defun mwise:prop (obj propname / r)
  (if (= (type obj) 'VLA-OBJECT)
    (progn
      (setq r (vl-catch-all-apply 'vlax-get-property (list obj propname)))
      (if (vl-catch-all-error-p r) nil r)
    )
  )
)

(defun mwise:invoke (obj methodname args / r)
  (if (= (type obj) 'VLA-OBJECT)
    (progn
      (setq r (vl-catch-all-apply 'vlax-invoke-method (append (list obj methodname) args)))
      (if (vl-catch-all-error-p r) nil r)
    )
  )
)

(defun mwise:count (obj / n)
  (setq n (mwise:prop obj 'Count))
  (if (= (type n) 'INT) n 0)
)

;; Count of a collection-valued property: (mwise:prop-count doc 'Surfaces)
(defun mwise:prop-count (obj propname)
  (mwise:count (mwise:prop obj propname))
)

(defun mwise:str-prop (obj propname / v)
  (setq v (mwise:prop obj propname))
  (if (= (type v) 'STR) v nil)
)

(defun mwise:object-name (obj)
  (cond ((mwise:str-prop obj 'ObjectName)) (""))
)

(defun mwise:collection->list (coll / lst)
  (setq lst nil)
  (if (= (type coll) 'VLA-OBJECT)
    (vl-catch-all-apply
      (function (lambda () (vlax-for itm coll (setq lst (cons itm lst)))))
    )
  )
  (reverse lst)
)

(defun mwise:active-doc ( )
  (vla-get-ActiveDocument (vlax-get-acad-object))
)

;; The drawing this LISP namespace belongs to. Table and entity functions
;; (tblsearch, entget, ssget) always work on this drawing, even while a
;; command such as CUTONCE-AUDIT makes another drawing active through COM.
(defun mwise:context-doc ( / r)
  (setq r (vl-catch-all-apply
            (function (lambda () (vla-get-Document (vlax-ename->vla-object (namedobjdict)))))))
  (if (or (vl-catch-all-error-p r) (/= (type r) 'VLA-OBJECT)) nil r)
)

(defun mwise:doc-key (doc)
  (strcat (cond ((mwise:str-prop doc 'FullName)) ("")) "|" (cond ((mwise:str-prop doc 'Name)) ("")))
)

(defun mwise:context-doc-p (doc / c)
  (and (setq c (mwise:context-doc)) (= (mwise:doc-key c) (mwise:doc-key doc)))
)

(defun mwise:user ( ) (cond ((mwise:nonblank (getvar "LOGINNAME"))) ("")))

;; ---------------------------------------------------------------------------
;; CSV helpers
;; ---------------------------------------------------------------------------

;; RFC 4180 quoting: wrap in quotes, double any embedded quote.
(defun mwise:csv-quote (s / out i n ch)
  (setq out "\"" i 1 n (strlen s))
  (while (<= i n)
    (setq ch (substr s i 1))
    (setq out (strcat out (if (= ch "\"") "\"\"" ch)))
    (setq i (1+ i))
  )
  (strcat out "\"")
)

;; Quote-aware split on a single-character separator.
(defun mwise:csv-split (str sep / i n ch inq field out)
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
(defun mwise:join (strs sep / s)
  (setq s nil)
  (foreach x strs (setq s (if s (strcat s sep x) x)))
  (if s s "")
)

;; One value -> CSV field. Strings are always quoted.
(defun mwise:csv-field (v)
  (cond
    ((= (type v) 'STR)  (mwise:csv-quote v))
    ((= (type v) 'INT)  (itoa v))
    ((= (type v) 'REAL) (rtos v 2 6))
    ((null v) "")
    ((eq v :vlax-true) "True")
    ((eq v :vlax-false) "False")
    (T (mwise:csv-quote (vl-princ-to-string v)))
  )
)

(defun mwise:csv-row (lst / s x)
  (setq s nil)
  (foreach x lst
    (setq s (if s (strcat s "," (mwise:csv-field x)) (mwise:csv-field x)))
  )
  (if s s "")
)

(defun mwise:timestamp ( )
  (menucmd "M=$(edtime,$(getvar,date),YYYY-MO-DD HH:MM:SS)")
)

;; ---------------------------------------------------------------------------
;; Text file helpers. All return nil on failure rather than raising.
;; ---------------------------------------------------------------------------

(defun mwise:read-lines (path / f line out)
  (setq out nil)
  (if (and path (findfile path) (setq f (open path "r")))
    (progn
      (while (setq line (read-line f)) (setq out (cons line out)))
      (close f)
    )
  )
  (reverse out)
)

(defun mwise:write-lines (path lines / f)
  (if (setq f (open path "w"))
    (progn
      (foreach ln lines (write-line ln f))
      (close f)
      T
    )
  )
)

(defun mwise:first-line (path / f l)
  (if (and path (findfile path) (setq f (open path "r")))
    (progn (setq l (read-line f)) (close f) l)
  )
)

;; A log written by an older version with different columns is renamed to
;; <name>-archived-<date>.csv once, so the new rows start a clean file and
;; nothing is lost. Checked once per file per drawing session.
;; Returns T when the file is safe to append to.
(setq *mwise:header-ok* nil)

(defun mwise:ensure-header (path header / first archived)
  (cond
    ((or (null header) (member path *mwise:header-ok*)) T)
    (T
     (setq first (mwise:first-line path))
     (cond
       ((or (null first) (= first header))
        (setq *mwise:header-ok* (cons path *mwise:header-ok*))
        T)
       (T
        (setq archived (strcat (vl-filename-directory path) "\\" (vl-filename-base path) "-archived-"
                               (menucmd "M=$(edtime,$(getvar,date),YYYYMODD-HHMMSS)")
                               (cond ((vl-filename-extension path)) (".csv"))))
        (if (vl-file-rename path archived)
          (progn
            (mwise:msg "CutOnce" (strcat "Log columns changed in this version. Previous log kept as " archived))
            (setq *mwise:header-ok* (cons path *mwise:header-ok*))
            T)
          (progn
            (mwise:msg "CutOnce" (strcat "Could not archive " path " (open in Excel?). Not logged this time."))
            nil)
        ))
     ))
  )
)

;; Appends lines, writing header first if the file does not exist yet.
(defun mwise:append-lines (path header lines / isnew f)
  (if (and lines (mwise:ensure-header path header))
    (progn
      (setq isnew (not (findfile path)))
      (if (setq f (open path (if isnew "w" "a")))
        (progn
          (if (and isnew header) (write-line header f))
          (foreach ln lines (write-line ln f))
          (close f)
          T
        )
      )
    )
  )
)

(defun mwise:append-line (path header line)
  (mwise:append-lines path header (list line))
)

;; ---------------------------------------------------------------------------
;; Events.csv: one row per warning, from every tool. Never raises: a logging
;; failure must not suppress the warning that follows it.
;; ---------------------------------------------------------------------------

(defun mwise:events-path ( ) (mwise:log-file "Events.csv"))

(defun mwise:log-event (kind detail)
  (if (mwise:log-on-p "LogEvents")
    (vl-catch-all-apply 'mwise:log-event-body (list kind detail))
  )
  (princ)
)

(defun mwise:log-event-body (kind detail / doc)
  (setq doc (mwise:active-doc))
  (mwise:append-line (mwise:events-path)
    "Timestamp,User,DrawingPath,DrawingName,EventType,Detail"
    (mwise:csv-row (list (mwise:timestamp) (mwise:user)
                        (cond ((mwise:str-prop doc 'FullName)) (""))
                        (cond ((mwise:str-prop doc 'Name)) (""))
                        kind detail)))
)

;; ---------------------------------------------------------------------------
;; Civil 3D COM connection (cached)
;;
;; The Civil 3D application object is reached through
;; AcadApplication.GetInterfaceObject("AeccXUiLand.AeccApplication.<ver>").
;; Finding <ver> is the slow part, so the result is cached at three levels:
;;   1. this drawing session      (*mwise:civil-app*)
;;   2. every drawing this session (the Visual LISP blackboard)
;;   3. future sessions            (per-user AutoCAD profile, CutOnce.CivilProgID)
;; On a cache miss only a short candidate list is tried. The full registry
;; scan is never run automatically; CUTONCE-FINDCIVIL runs it on demand and
;; stores the answer.
;; ---------------------------------------------------------------------------

(setq *mwise:civil-app* nil)

(setq *mwise:civil-prefix* "AeccXUiLand.AeccApplication")

(defun mwise:try-civil-progid (pid / r)
  (setq r (vl-catch-all-apply 'vlax-invoke-method
            (list (vlax-get-acad-object) 'GetInterfaceObject pid)))
  (if (or (vl-catch-all-error-p r) (/= (type r) 'VLA-OBJECT)) nil r)
)

(defun mwise:civil-candidates ( / out minor curver)
  (setq out nil)
  (foreach pid (list (mwise:pref-get "CivilProgID")
                     (vl-bb-ref '*mwise:bb-civil-progid*)
                     (vl-catch-all-apply 'vl-registry-read
                       (list (strcat "HKEY_CLASSES_ROOT\\" *mwise:civil-prefix* "\\CurVer")))
                     *mwise:civil-prefix*)
    (if (and (= (type pid) 'STR) (not (member pid out))) (setq out (cons pid out)))
  )
  (setq minor 9)
  (while (>= minor 0)
    (setq curver (strcat *mwise:civil-prefix* ".13." (itoa minor)))
    (if (not (member curver out)) (setq out (cons curver out)))
    (setq minor (1- minor))
  )
  (reverse out)
)

(defun mwise:remember-civil-progid (pid)
  (vl-bb-set '*mwise:bb-civil-progid* pid)
  (vl-bb-set '*mwise:bb-civil-failed* nil)
  (if (/= pid (mwise:pref-get "CivilProgID")) (mwise:pref-set "CivilProgID" pid))
)

(defun mwise:civil-app ( / app)
  (cond
    ((and (= (type *mwise:civil-app*) 'VLA-OBJECT)
          (not (vlax-object-released-p *mwise:civil-app*)))
     *mwise:civil-app*)
    ;; already failed once this session (plain AutoCAD, or unknown release):
    ;; do not pay for the probe again on every save
    ((vl-bb-ref '*mwise:bb-civil-failed*) nil)
    (T
     (foreach pid (mwise:civil-candidates)
       (if (and (not app) (setq app (mwise:try-civil-progid pid)))
         (mwise:remember-civil-progid pid)
       )
     )
     (if app
       (setq *mwise:civil-app* app)
       (vl-bb-set '*mwise:bb-civil-failed* T)
     )
     app
    )
  )
)

(defun mwise:civil-doc ( / app d)
  (if (setq app (mwise:civil-app))
    (progn
      (setq d (vl-catch-all-apply 'vlax-get-property (list app 'ActiveDocument)))
      (if (vl-catch-all-error-p d) nil d)
    )
  )
)

;; "AeccXUiLand.AeccApplication.13.9" -> 13009, version-less -> -1
(defun mwise:progid-rank (pid / rest dot)
  (setq rest (substr pid (1+ (strlen *mwise:civil-prefix*))))
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
(defun c:CUTONCE-FINDCIVIL ( / all matches found)
  (mwise:msg "CutOnce" "Scanning the registry for Civil 3D ProgIDs (this can take a while)...")
  (setq all (vl-catch-all-apply 'vl-registry-descendents (list "HKEY_CLASSES_ROOT")))
  (if (vl-catch-all-error-p all) (setq all nil))
  (setq matches nil)
  (foreach k all
    (if (wcmatch (strcase k) (strcat (strcase *mwise:civil-prefix*) "*"))
      (setq matches (cons k matches))
    )
  )
  (setq matches (vl-sort matches (function (lambda (a b) (> (mwise:progid-rank a) (mwise:progid-rank b))))))
  (if (not matches)
    (mwise:msg "CutOnce" "No Civil 3D ProgID is registered. This is plain AutoCAD, or Civil 3D needs a repair install.")
    (foreach pid matches
      (if (mwise:try-civil-progid pid)
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
      (mwise:remember-civil-progid found)
      (setq *mwise:civil-app* nil)
      (mwise:msg "CutOnce" (strcat "Saved " found " for future sessions."))
    )
  )
  (princ)
)

;; ---------------------------------------------------------------------------
;; Knowledge-base links ("Learn More")
;;
;; Every warning has a topic; the topic maps to a section anchor on the
;; "Civil 3D Warnings Explained" page, following its "Linking warnings to
;; articles" table (#link-map). LearnMoreUrl / LearnMoreAnchors in
;; CutOnce-Config.lsp override the defaults below. A topic missing from the
;; config falls back to its default; set it to "" to open the top of the page.
;;
;; Configs carried over from C3DTools point at the retired page; that address
;; (and the anchors written for it) is ignored so they reach the new page.
;; ---------------------------------------------------------------------------

(setq *mwise:kb-default-url*
  "https://designtovisualization.com/kb-c3d-and-modelwise-assistant/")

(setq *mwise:kb-retired-urls*
  '("kb-tools-for-civil-3d-"))

(setq *mwise:kb-default-anchors*
  '(;; change-impact warnings
    ("MOVE"              . "move-civil-objects")
    ("STRETCH"           . "stretch-civil-objects")
    ("ROTATE"            . "rotate-civil-objects")
    ("SCALE"             . "scale-civil-objects")
    ("GRIP_ALIGNMENT"    . "grip-edit-alignment")
    ("GRIP_PROFILE"      . "grip-edit-profile")
    ("SURFACE"           . "surface-edits")
    ("GENERAL"           . "dynamic-model")
    ;; standards check
    ("STANDARDS_OPEN"    . "standards-check")
    ("STD_BYLAYER"       . "objects-not-bylayer")
    ("STD_XREF_STATUS"   . "xrefs-broken-unloaded")
    ("STD_XREF_ORIGIN"   . "xref-not-at-origin")
    ;; guard
    ("GUARD_EXPLODE"     . "explode-civil-objects")
    ("GUARD_ATTRIB"      . "explode-attributed-blocks")
    ("GUARD_XREF_BIND"   . "xref-bind")
    ("GUARD_XREF_MOVED"  . "xref-moved")
    ("GUARD_XREF_ORIGIN" . "xref-not-at-origin")
    ("GUARD_REFEDIT"     . "refedit")
    ("GUARD_PROMOTE"     . "promote-reference")
    ("GUARD_TEXT"        . "text-instead-of-labels")
    ("GUARD_GROWTH"      . "drawing-growth")
    ;; control center
    ("CONTROL_CENTER"    . "control-center")
    ("LINK_MAP"          . "link-map")))

(defun mwise:kb-retired-p (url)
  (vl-some (function (lambda (frag) (vl-string-search (strcase frag) (strcase url))))
           *mwise:kb-retired-urls*)
)

(defun mwise:kb-url (topic / base i anchors pair anchor)
  (setq base (cond ((mwise:nonblank (mwise:cfg "LearnMoreUrl" nil)))
                   ((mwise:nonblank (mwise:cfg "ImpactLearnMoreUrl" nil)))))
  (if (or (null base) (mwise:kb-retired-p base))
    (setq base *mwise:kb-default-url* anchors nil)
    (setq anchors (cond ((mwise:cfg "LearnMoreAnchors" nil)) ((mwise:cfg "ImpactLearnMoreAnchors" nil))))
  )
  (if (setq i (vl-string-search "#" base)) (setq base (substr base 1 i)))
  (setq pair (if (and anchors (listp anchors)) (assoc topic anchors)))
  (setq anchor (if pair (cdr pair) (cdr (assoc topic *mwise:kb-default-anchors*))))
  (if (mwise:nonblank anchor)
    (strcat base "#" (vl-string-left-trim "#" anchor))
    base
  )
)

;; Opens a URL in the default browser: Windows shell first, then the URL
;; protocol handler. The URL is always printed so it can be copied.
(defun mwise:open-url (url / sh r)
  (princ (strcat "\nLearn more: " url))
  (setq sh (vl-catch-all-apply 'vlax-get-or-create-object (list "Shell.Application")))
  (if (and sh (not (vl-catch-all-error-p sh)))
    (progn
      (setq r (vl-catch-all-apply 'vlax-invoke-method (list sh 'ShellExecute url)))
      (vl-catch-all-apply 'vlax-release-object (list sh))
    )
  )
  (if (or (null sh) (vl-catch-all-error-p sh) (vl-catch-all-error-p r))
    (vl-catch-all-apply 'startapp (list "rundll32.exe" (strcat "url.dll,FileProtocolHandler " url)))
  )
  (princ)
)

(defun mwise:open-kb (topic) (mwise:open-url (mwise:kb-url topic)))

;; ---------------------------------------------------------------------------
;; Notice dialog: a message with OK and one or more Learn More buttons, each
;; opening its own section of the knowledge-base page. Used for every warning
;; that has a section. Falls back to a plain alert (with the links written
;; out) if the dialog cannot be shown.
;;
;;   (mwise:notice text "GUARD_XREF_BIND")                one Learn More button
;;   (mwise:notice-links text '(("About ByLayer..." . "STD_BYLAYER") ...))
;; ---------------------------------------------------------------------------

;; DCL with the buttons baked in; written fresh for each notice because the
;; number and labels of the buttons vary. Returns the temp file path.
(defun mwise:write-notice-dcl (links / path f i)
  (setq path (vl-filename-mktemp "cutonce" nil ".dcl"))
  (if (setq f (open path "w"))
    (progn
      (foreach ln
        (append
          (list "mw_notice : dialog {"
                "  label = \"CutOnce\";"
                "  : list_box { key = \"notice_text\"; height = 16; width = 80; }"
                "  : row {"
                "    alignment = centered; fixed_width = true;"
                "    : button { key = \"accept\"; label = \"OK\"; is_default = true; is_cancel = true; width = 12; }")
          (progn
            (setq i 0)
            (mapcar (function (lambda (lk)
                      (setq i (1+ i))
                      (strcat "    : button { key = \"learn_" (itoa i) "\"; label = \""
                              (vl-string-translate "\"" "'" (car lk)) "\"; }")))
                    links))
          (list "  }" "}"))
        (write-line ln f)
      )
      (close f)
      path
    )
  )
)

(defun mwise:split-lines (s / i out)
  (setq out nil)
  (while (setq i (vl-string-search "\n" s))
    (setq out (cons (substr s 1 i) out) s (substr s (+ i 2)))
  )
  (reverse (cons s out))
)

(defun mwise:notice-links (text links / path dcl_id shown i)
  (setq links (vl-remove-if-not (function (lambda (lk) (cdr lk))) links))
  (setq path (mwise:write-notice-dcl links) shown nil)
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog "mw_notice" dcl_id)
        (progn
          (start_list "notice_text")
          (foreach ln (mwise:split-lines text) (add_list ln))
          (end_list)
          (action_tile "accept" "(done_dialog 1)")
          (setq i 0)
          (foreach lk links
            (setq i (1+ i))
            (action_tile (strcat "learn_" (itoa i))
                         (strcat "(mwise:open-kb " (vl-prin1-to-string (cdr lk)) ")"))
          )
          (start_dialog)
          (setq shown T)
        )
      )
      (unload_dialog dcl_id)
    )
  )
  (if path (vl-file-delete path))
  (if (not shown)
    (alert (strcat text "\n"
                   (apply 'strcat
                     (mapcar (function (lambda (lk) (strcat "\n" (car lk) " " (mwise:kb-url (cdr lk)))))
                             links))))
  )
  (princ)
)

(defun mwise:notice (text topic)
  (mwise:notice-links text (list (cons "Learn More..." topic)))
)

(defun c:CUTONCE-STATUS ( / app)
  (setq app (mwise:civil-app))
  (mwise:msg "CutOnce" (strcat "Version " *mwise:version* " - published by " *mwise:publisher*))
  (princ (strcat "\n  Install folder:  " (mwise:home)))
  (princ (strcat "\n  Log folder:      " (mwise:log-dir)))
  (princ (strcat "\n  Civil 3D COM:    "
                 (if app
                   (strcat "connected (" (cond ((vl-bb-ref '*mwise:bb-civil-progid*)) ("?")) ")")
                   "not connected - run CUTONCE-FINDCIVIL")))
  (princ (strcat "\n  Logging:         " (if (mwise:on-p "LogEnabled") "on" "OFF")))
  (princ "\n  Settings:        CUTONCE (dialog), -CUTONCE List (command line)")
  (princ "\n  Tool status:     CUTONCE-GUARD-STATUS, CUTONCE-IMPACT-STATUS, CUTONCE-CHECK-STATUS")
  (princ)
)

(princ)
