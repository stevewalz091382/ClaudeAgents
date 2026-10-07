;;; ============================================================================
;;; CutOnce-Core.lsp
;;;
;;; CutOnce. Shared services for the Standards, Health,
;;; Guard and Impact modules and the CutOnce Control Center:
;;;   - configuration lookup (CutOnce-Config.lsp + environment overrides)
;;;   - per-user settings registry (what the Control Center switches on/off)
;;;   - install and log folder resolution
;;;   - fail-safe COM property helpers
;;;   - CSV helpers (with automatic archiving when a log's columns change)
;;;   - the shared Events.csv writer
;;;   - a cached connection to the Civil 3D COM application object
;;;
;;; Naming: every function and global in this file starts with cutonce: or
;;; *cutonce:, so nothing here can collide with other LISP loaded in the session.
;;; ============================================================================

(vl-load-com)

(setq *cutonce:version* "2.0.0")
(setq *cutonce:publisher* "Stephen Walz")

;; ---------------------------------------------------------------------------
;; Configuration
;;
;; CutOnce-Config.lsp sets *cutonce:config* to an association list of
;; ("Key" . value) pairs before this file loads. A key that is missing from
;; the list falls back to the default given at the call site.
;; ---------------------------------------------------------------------------

(defun cutonce:cfg (key default / pair)
  (setq pair (if (boundp '*cutonce:config*) (assoc key *cutonce:config*)))
  (if pair (cdr pair) default)
)

(defun cutonce:nonblank (s)
  (if (and (= (type s) 'STR) (/= (vl-string-trim " \t" s) "")) s nil)
)

;; Per-user preference stored in the AutoCAD profile (HKCU), survives restarts.
(defun cutonce:pref-get (name)
  (cutonce:nonblank (getenv (strcat "CutOnce." name)))
)

(defun cutonce:pref-set (name value)
  (vl-catch-all-apply 'setenv (list (strcat "CutOnce." name) value))
  value
)

;; ---------------------------------------------------------------------------
;; Settings registry
;;
;; Every on/off choice a designer can make in the CutOnce Control
;; Center (CUTONCE). For each key, the effective value is:
;;   1. the administrator's value, if the key is listed in "LockedSettings"
;;   2. otherwise the user's own choice (AutoCAD profile, CutOnce.<key>)
;;   3. otherwise the administrator's default: ("<key>" . T/nil) in the config
;;   4. otherwise the built-in default below
;;
;; Fields: key, Control Center group, label, built-in default.
;; ---------------------------------------------------------------------------

(setq *cutonce:settings*
  '(
    ;; Command warnings: a master switch, then one row per command
    ("CommandWarnings"  "Cmd"      "Show command warnings"                                 T)
    ("WarnMOVE"         "Cmd"      "MOVE - Civil 3D objects and xrefs"                     T)
    ("WarnCOPY"         "Cmd"      "COPY - xrefs"                                          T)
    ("WarnSTRETCH"      "Cmd"      "STRETCH - Civil 3D objects"                            T)
    ("WarnROTATE"       "Cmd"      "ROTATE - Civil 3D objects"                             T)
    ("WarnSCALE"        "Cmd"      "SCALE - Civil 3D objects"                              T)
    ("WarnEXPLODE"      "Cmd"      "EXPLODE / BURST - Civil 3D objects, blocks, hatches"   T)
    ("WarnXREFBIND"     "Cmd"      "XREF / XBIND - binding an xref"                        T)
    ("WarnREFEDIT"      "Cmd"      "REFEDIT / REFCLOSE"                                    T)
    ("WarnPROMOTE"      "Cmd"      "Promoting a data shortcut reference"                   T)
    ("WarnTEXT"         "Cmd"      "TEXT - label style tip"                                T)
    ("WarnDTEXT"        "Cmd"      "DTEXT - label style tip"                               T)
    ("WarnMTEXT"        "Cmd"      "MTEXT - label style tip"                               T)
    ("WarnGRIPS"        "Cmd"      "Grip edits of alignments, profiles, surfaces"          T)
    ("WarnSURFACE"      "Cmd"      "Surface edit commands"                                 T)
    ("WarnOTHER"        "Cmd"      "Other watched commands (added by CAD admin)"           T)
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

(defun cutonce:setting-keys ( ) (mapcar 'car *cutonce:settings*))

(defun cutonce:setting-label (key / e)
  (if (setq e (assoc key *cutonce:settings*)) (caddr e) key)
)

;; Administrator default: the same key at the top level of the config,
;; falling back to the built-in default.
(defun cutonce:setting-default (key / e)
  (setq e (assoc key *cutonce:settings*))
  (if (cutonce:cfg key (if e (cadddr e) T)) T nil)
)

(defun cutonce:locked-p (key / l)
  (setq l (cutonce:cfg "LockedSettings" nil))
  (if (and l (listp l)
           (member (strcase key) (mapcar 'strcase (vl-remove-if-not 'cutonce:nonblank l))))
    T
  )
)

(defun cutonce:on-p (key / p)
  (if (cutonce:locked-p key)
    (cutonce:setting-default key)
    (progn
      (setq p (cutonce:pref-get key))
      (cond ((= p "1") T)
            ((= p "0") nil)
            (T (cutonce:setting-default key))))
  )
)

;; Stores the user's choice. A choice equal to the administrator default is
;; stored as "no choice", so a later change to the default still reaches
;; this user. Locked keys are never written.
(defun cutonce:set-on (key on)
  (if (not (cutonce:locked-p key))
    (if (eq (if on T nil) (cutonce:setting-default key))
      (if (cutonce:pref-get key) (cutonce:pref-set key ""))
      (cutonce:pref-set key (if on "1" "0"))
    )
  )
)

;; Logging gate: the master switch and the specific log.
(defun cutonce:log-on-p (key)
  (and (cutonce:on-p "LogEnabled") (cutonce:on-p key))
)

;; A command warning shows only when the master switch and its own row are on.
(defun cutonce:cmd-warn-p (key)
  (and (cutonce:on-p "CommandWarnings") (cutonce:on-p key))
)

;; ---------------------------------------------------------------------------
;; Warning frequency: "every" time, or "once" per command per Civil 3D session.
;; Applies to every command warning and save check. What has been shown is
;; kept on the Visual LISP blackboard, so it is shared by every open drawing
;; and forgotten when Civil 3D closes. Events.csv is written either way.
;; ---------------------------------------------------------------------------

(defun cutonce:default-warn-mode ( )
  (if (= (cutonce:cfg "WarnFrequency" "every") "once") "once" "every")
)

(defun cutonce:warn-mode ( / p)
  (setq p (if (not (cutonce:locked-p "WarnFrequency")) (cutonce:pref-get "WarnFrequency")))
  (if (member p '("every" "once")) p (cutonce:default-warn-mode))
)

(defun cutonce:reset-warned ( ) (vl-bb-set '*cutonce:bb-warned* nil))

(defun cutonce:set-warn-mode (mode)
  (if (/= mode (cutonce:warn-mode)) (cutonce:reset-warned))
  (if (= mode (cutonce:default-warn-mode))
    (if (cutonce:pref-get "WarnFrequency") (cutonce:pref-set "WarnFrequency" ""))
    (cutonce:pref-set "WarnFrequency" mode))
)

;; key identifies one warning, e.g. "IMPACT:MOVE" or "GUARD_EXPLODE".
(defun cutonce:warn-due-p (key)
  (or (= (cutonce:warn-mode) "every")
      (not (member key (vl-bb-ref '*cutonce:bb-warned*))))
)

(defun cutonce:mark-warned (key / seen)
  (setq seen (vl-bb-ref '*cutonce:bb-warned*))
  (if (not (member key seen)) (vl-bb-set '*cutonce:bb-warned* (cons key seen)))
)

(defun cutonce:freq-note ( )
  (if (= (cutonce:warn-mode) "once")
    "Shown once per command each session. To change, type CUTONCE."
    "Shown every time. To change, type CUTONCE (Control Center).")
)

;; ---------------------------------------------------------------------------
;; Folders
;; ---------------------------------------------------------------------------

;; Normalises to backslashes and guarantees exactly one trailing backslash.
(defun cutonce:dir-slash (d)
  (setq d (vl-string-right-trim "\\" (vl-string-translate "/" "\\" d)))
  (strcat d "\\")
)

;; vl-mkdir creates one level only; this creates every missing parent.
(defun cutonce:mkdir-p (dir / trimmed parent)
  (setq trimmed (vl-string-right-trim "\\" (vl-string-translate "/" "\\" dir)))
  (cond
    ((= trimmed "") nil)
    ((vl-file-directory-p trimmed) T)
    (T
     (setq parent (vl-filename-directory trimmed))
     (if (and parent (/= parent "") (/= parent trimmed))
       (cutonce:mkdir-p parent)
     )
     (vl-mkdir trimmed)
    )
  )
)

;; Install folder, as resolved by CutOnce-Loader.lsp.
(defun cutonce:home ( )
  (if (and (boundp '*cutonce:home*) *cutonce:home*) *cutonce:home* "")
)

;; Log folder. Resolution order:
;;   1. CUTONCE_LOGDIR (Windows environment variable, or setenv in AutoCAD)
;;   2. "LogDir" in CutOnce-Config.lsp
;;   3. %LOCALAPPDATA%\CutOnce\Logs\
;;   4. AutoCAD's TEMPPREFIX folder + CutOnce\Logs\
;; Resolved once per drawing session and cached.
(setq *cutonce:log-dir* nil)

(defun cutonce:log-dir ( / d la)
  (if (not *cutonce:log-dir*)
    (progn
      (setq d
        (cond
          ((cutonce:nonblank (getenv "CUTONCE_LOGDIR")))
          ((cutonce:nonblank (cutonce:cfg "LogDir" nil)))
          ((setq la (cutonce:nonblank (getenv "LOCALAPPDATA")))
           (strcat la "\\CutOnce\\Logs"))
          (T (strcat (getvar "TEMPPREFIX") "CutOnce\\Logs"))
        )
      )
      (setq d (cutonce:dir-slash d))
      (vl-catch-all-apply 'cutonce:mkdir-p (list d))
      (setq *cutonce:log-dir* d)
    )
  )
  *cutonce:log-dir*
)

(defun cutonce:log-file (name) (strcat (cutonce:log-dir) name))

;; ---------------------------------------------------------------------------
;; Messages
;; ---------------------------------------------------------------------------

(defun cutonce:msg (tag msg)
  (princ (strcat "\n[" tag "] " msg))
  (princ)
)

;; ---------------------------------------------------------------------------
;; Fail-safe COM helpers. None of these ever raise: a missing or renamed
;; property returns nil (or 0 for counts).
;; ---------------------------------------------------------------------------

(defun cutonce:prop (obj propname / r)
  (if (= (type obj) 'VLA-OBJECT)
    (progn
      (setq r (vl-catch-all-apply 'vlax-get-property (list obj propname)))
      (if (vl-catch-all-error-p r) nil r)
    )
  )
)

(defun cutonce:invoke (obj methodname args / r)
  (if (= (type obj) 'VLA-OBJECT)
    (progn
      (setq r (vl-catch-all-apply 'vlax-invoke-method (append (list obj methodname) args)))
      (if (vl-catch-all-error-p r) nil r)
    )
  )
)

(defun cutonce:count (obj / n)
  (setq n (cutonce:prop obj 'Count))
  (if (= (type n) 'INT) n 0)
)

;; Count of a collection-valued property: (cutonce:prop-count doc 'Surfaces)
(defun cutonce:prop-count (obj propname)
  (cutonce:count (cutonce:prop obj propname))
)

(defun cutonce:str-prop (obj propname / v)
  (setq v (cutonce:prop obj propname))
  (if (= (type v) 'STR) v nil)
)

(defun cutonce:object-name (obj)
  (cond ((cutonce:str-prop obj 'ObjectName)) (""))
)

(defun cutonce:collection->list (coll / lst)
  (setq lst nil)
  (if (= (type coll) 'VLA-OBJECT)
    (vl-catch-all-apply
      (function (lambda () (vlax-for itm coll (setq lst (cons itm lst)))))
    )
  )
  (reverse lst)
)

(defun cutonce:active-doc ( )
  (vla-get-ActiveDocument (vlax-get-acad-object))
)

;; The drawing this LISP namespace belongs to. Table and entity functions
;; (tblsearch, entget, ssget) always work on this drawing, even while a
;; command such as CUTONCE-AUDIT makes another drawing active through COM.
(defun cutonce:context-doc ( / r)
  (setq r (vl-catch-all-apply
            (function (lambda () (vla-get-Document (vlax-ename->vla-object (namedobjdict)))))))
  (if (or (vl-catch-all-error-p r) (/= (type r) 'VLA-OBJECT)) nil r)
)

(defun cutonce:doc-key (doc)
  (strcat (cond ((cutonce:str-prop doc 'FullName)) ("")) "|" (cond ((cutonce:str-prop doc 'Name)) ("")))
)

(defun cutonce:context-doc-p (doc / c)
  (and (setq c (cutonce:context-doc)) (= (cutonce:doc-key c) (cutonce:doc-key doc)))
)

(defun cutonce:user ( ) (cond ((cutonce:nonblank (getvar "LOGINNAME"))) ("")))

;; ---------------------------------------------------------------------------
;; CSV helpers
;; ---------------------------------------------------------------------------

;; RFC 4180 quoting: wrap in quotes, double any embedded quote.
(defun cutonce:csv-quote (s / out i n ch)
  (setq out "\"" i 1 n (strlen s))
  (while (<= i n)
    (setq ch (substr s i 1))
    (setq out (strcat out (if (= ch "\"") "\"\"" ch)))
    (setq i (1+ i))
  )
  (strcat out "\"")
)

;; Quote-aware split on a single-character separator.
(defun cutonce:csv-split (str sep / i n ch inq field out)
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
(defun cutonce:join (strs sep / s)
  (setq s nil)
  (foreach x strs (setq s (if s (strcat s sep x) x)))
  (if s s "")
)

;; One value -> CSV field. Strings are always quoted.
(defun cutonce:csv-field (v)
  (cond
    ((= (type v) 'STR)  (cutonce:csv-quote v))
    ((= (type v) 'INT)  (itoa v))
    ((= (type v) 'REAL) (rtos v 2 6))
    ((null v) "")
    ((eq v :vlax-true) "True")
    ((eq v :vlax-false) "False")
    (T (cutonce:csv-quote (vl-princ-to-string v)))
  )
)

(defun cutonce:csv-row (lst / s x)
  (setq s nil)
  (foreach x lst
    (setq s (if s (strcat s "," (cutonce:csv-field x)) (cutonce:csv-field x)))
  )
  (if s s "")
)

(defun cutonce:timestamp ( )
  (menucmd "M=$(edtime,$(getvar,date),YYYY-MO-DD HH:MM:SS)")
)

;; ---------------------------------------------------------------------------
;; Text file helpers. All return nil on failure rather than raising.
;; ---------------------------------------------------------------------------

(defun cutonce:read-lines (path / f line out)
  (setq out nil)
  (if (and path (findfile path) (setq f (open path "r")))
    (progn
      (while (setq line (read-line f)) (setq out (cons line out)))
      (close f)
    )
  )
  (reverse out)
)

(defun cutonce:write-lines (path lines / f)
  (if (setq f (open path "w"))
    (progn
      (foreach ln lines (write-line ln f))
      (close f)
      T
    )
  )
)

(defun cutonce:first-line (path / f l)
  (if (and path (findfile path) (setq f (open path "r")))
    (progn (setq l (read-line f)) (close f) l)
  )
)

;; A log written by an older version with different columns is renamed to
;; <name>-archived-<date>.csv once, so the new rows start a clean file and
;; nothing is lost. Checked once per file per drawing session.
;; Returns T when the file is safe to append to.
(setq *cutonce:header-ok* nil)

(defun cutonce:ensure-header (path header / first archived)
  (cond
    ((or (null header) (member path *cutonce:header-ok*)) T)
    (T
     (setq first (cutonce:first-line path))
     (cond
       ((or (null first) (= first header))
        (setq *cutonce:header-ok* (cons path *cutonce:header-ok*))
        T)
       (T
        (setq archived (strcat (vl-filename-directory path) "\\" (vl-filename-base path) "-archived-"
                               (menucmd "M=$(edtime,$(getvar,date),YYYYMODD-HHMMSS)")
                               (cond ((vl-filename-extension path)) (".csv"))))
        (if (vl-file-rename path archived)
          (progn
            (cutonce:msg "CutOnce" (strcat "Log columns changed in this version. Previous log kept as " archived))
            (setq *cutonce:header-ok* (cons path *cutonce:header-ok*))
            T)
          (progn
            (cutonce:msg "CutOnce" (strcat "Could not archive " path " (open in Excel?). Not logged this time."))
            nil)
        ))
     ))
  )
)

;; Appends lines, writing header first if the file does not exist yet.
(defun cutonce:append-lines (path header lines / isnew f)
  (if (and lines (cutonce:ensure-header path header))
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

(defun cutonce:append-line (path header line)
  (cutonce:append-lines path header (list line))
)

;; ---------------------------------------------------------------------------
;; Events.csv: one row per warning, from every tool. Never raises: a logging
;; failure must not suppress the warning that follows it.
;; ---------------------------------------------------------------------------

(defun cutonce:events-path ( ) (cutonce:log-file "Events.csv"))

(defun cutonce:log-event (kind detail)
  (if (cutonce:log-on-p "LogEvents")
    (vl-catch-all-apply 'cutonce:log-event-body (list kind detail))
  )
  (princ)
)

(defun cutonce:log-event-body (kind detail / doc)
  (setq doc (cutonce:active-doc))
  (cutonce:append-line (cutonce:events-path)
    "Timestamp,User,DrawingPath,DrawingName,EventType,Detail"
    (cutonce:csv-row (list (cutonce:timestamp) (cutonce:user)
                        (cond ((cutonce:str-prop doc 'FullName)) (""))
                        (cond ((cutonce:str-prop doc 'Name)) (""))
                        kind detail)))
)

;; ---------------------------------------------------------------------------
;; Civil 3D COM connection (cached)
;;
;; The Civil 3D application object is reached through
;; AcadApplication.GetInterfaceObject("AeccXUiLand.AeccApplication.<ver>").
;; Finding <ver> is the slow part, so the result is cached at three levels:
;;   1. this drawing session      (*cutonce:civil-app*)
;;   2. every drawing this session (the Visual LISP blackboard)
;;   3. future sessions            (per-user AutoCAD profile, CutOnce.CivilProgID)
;; On a cache miss only a short candidate list is tried. The full registry
;; scan is never run automatically; CUTONCE-FINDCIVIL runs it on demand and
;; stores the answer.
;; ---------------------------------------------------------------------------

(setq *cutonce:civil-app* nil)

(setq *cutonce:civil-prefix* "AeccXUiLand.AeccApplication")

(defun cutonce:try-civil-progid (pid / r)
  (setq r (vl-catch-all-apply 'vlax-invoke-method
            (list (vlax-get-acad-object) 'GetInterfaceObject pid)))
  (if (or (vl-catch-all-error-p r) (/= (type r) 'VLA-OBJECT)) nil r)
)

(defun cutonce:civil-candidates ( / out minor curver)
  (setq out nil)
  (foreach pid (list (cutonce:pref-get "CivilProgID")
                     (vl-bb-ref '*cutonce:bb-civil-progid*)
                     (vl-catch-all-apply 'vl-registry-read
                       (list (strcat "HKEY_CLASSES_ROOT\\" *cutonce:civil-prefix* "\\CurVer")))
                     *cutonce:civil-prefix*)
    (if (and (= (type pid) 'STR) (not (member pid out))) (setq out (cons pid out)))
  )
  (setq minor 9)
  (while (>= minor 0)
    (setq curver (strcat *cutonce:civil-prefix* ".13." (itoa minor)))
    (if (not (member curver out)) (setq out (cons curver out)))
    (setq minor (1- minor))
  )
  (reverse out)
)

(defun cutonce:remember-civil-progid (pid)
  (vl-bb-set '*cutonce:bb-civil-progid* pid)
  (vl-bb-set '*cutonce:bb-civil-failed* nil)
  (if (/= pid (cutonce:pref-get "CivilProgID")) (cutonce:pref-set "CivilProgID" pid))
)

(defun cutonce:civil-app ( / app)
  (cond
    ((and (= (type *cutonce:civil-app*) 'VLA-OBJECT)
          (not (vlax-object-released-p *cutonce:civil-app*)))
     *cutonce:civil-app*)
    ;; already failed once this session (plain AutoCAD, or unknown release):
    ;; do not pay for the probe again on every save
    ((vl-bb-ref '*cutonce:bb-civil-failed*) nil)
    (T
     (foreach pid (cutonce:civil-candidates)
       (if (and (not app) (setq app (cutonce:try-civil-progid pid)))
         (cutonce:remember-civil-progid pid)
       )
     )
     (if app
       (setq *cutonce:civil-app* app)
       (vl-bb-set '*cutonce:bb-civil-failed* T)
     )
     app
    )
  )
)

(defun cutonce:civil-doc ( / app d)
  (if (setq app (cutonce:civil-app))
    (progn
      (setq d (vl-catch-all-apply 'vlax-get-property (list app 'ActiveDocument)))
      (if (vl-catch-all-error-p d) nil d)
    )
  )
)

;; "AeccXUiLand.AeccApplication.13.9" -> 13009, version-less -> -1
(defun cutonce:progid-rank (pid / rest dot)
  (setq rest (substr pid (1+ (strlen *cutonce:civil-prefix*))))
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
  (cutonce:msg "CutOnce" "Scanning the registry for Civil 3D ProgIDs (this can take a while)...")
  (setq all (vl-catch-all-apply 'vl-registry-descendents (list "HKEY_CLASSES_ROOT")))
  (if (vl-catch-all-error-p all) (setq all nil))
  (setq matches nil)
  (foreach k all
    (if (wcmatch (strcase k) (strcat (strcase *cutonce:civil-prefix*) "*"))
      (setq matches (cons k matches))
    )
  )
  (setq matches (vl-sort matches (function (lambda (a b) (> (cutonce:progid-rank a) (cutonce:progid-rank b))))))
  (if (not matches)
    (cutonce:msg "CutOnce" "No Civil 3D ProgID is registered. This is plain AutoCAD, or Civil 3D needs a repair install.")
    (foreach pid matches
      (if (cutonce:try-civil-progid pid)
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
      (cutonce:remember-civil-progid found)
      (setq *cutonce:civil-app* nil)
      (cutonce:msg "CutOnce" (strcat "Saved " found " for future sessions."))
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
;; ---------------------------------------------------------------------------

(setq *cutonce:kb-default-url*
  "https://designtovisualization.com/kb-c3d-and-cutonce-assistant/")

(setq *cutonce:kb-default-anchors*
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

(defun cutonce:kb-url (topic / base i anchors pair anchor)
  (setq base (cond ((cutonce:nonblank (cutonce:cfg "LearnMoreUrl" nil)))
                   (*cutonce:kb-default-url*)))
  (setq anchors (cutonce:cfg "LearnMoreAnchors" nil))
  (if (setq i (vl-string-search "#" base)) (setq base (substr base 1 i)))
  (setq pair (if (and anchors (listp anchors)) (assoc topic anchors)))
  (setq anchor (if pair (cdr pair) (cdr (assoc topic *cutonce:kb-default-anchors*))))
  (if (cutonce:nonblank anchor)
    (strcat base "#" (vl-string-left-trim "#" anchor))
    base
  )
)

;; Opens a URL in the default browser: Windows shell first, then the URL
;; protocol handler. The URL is always printed so it can be copied.
(defun cutonce:open-url (url / sh r)
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

(defun cutonce:open-kb (topic) (cutonce:open-url (cutonce:kb-url topic)))

;; ---------------------------------------------------------------------------
;; Notice dialog: a message with OK and one or more Learn More buttons, each
;; opening its own section of the knowledge-base page. Used for every warning
;; that has a section. Falls back to a plain alert (with the links written
;; out) if the dialog cannot be shown.
;;
;;   (cutonce:notice text "GUARD_XREF_BIND")                one Learn More button
;;   (cutonce:notice-links text '(("About ByLayer..." . "STD_BYLAYER") ...))
;; ---------------------------------------------------------------------------

;; DCL with the buttons baked in; written fresh for each notice because the
;; number and labels of the buttons vary. Returns the temp file path.
(defun cutonce:write-notice-dcl (links / path f i)
  (setq path (vl-filename-mktemp "cutonce" nil ".dcl"))
  (if (setq f (open path "w"))
    (progn
      (foreach ln
        (append
          (list "co_notice : dialog {"
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

(defun cutonce:split-lines (s / i out)
  (setq out nil)
  (while (setq i (vl-string-search "\n" s))
    (setq out (cons (substr s 1 i) out) s (substr s (+ i 2)))
  )
  (reverse (cons s out))
)

(defun cutonce:notice-links (text links / path dcl_id shown i)
  (setq links (vl-remove-if-not (function (lambda (lk) (cdr lk))) links))
  (setq path (cutonce:write-notice-dcl links) shown nil)
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog "co_notice" dcl_id)
        (progn
          (start_list "notice_text")
          (foreach ln (cutonce:split-lines text) (add_list ln))
          (end_list)
          (action_tile "accept" "(done_dialog 1)")
          (setq i 0)
          (foreach lk links
            (setq i (1+ i))
            (action_tile (strcat "learn_" (itoa i))
                         (strcat "(cutonce:open-kb " (vl-prin1-to-string (cdr lk)) ")"))
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
                     (mapcar (function (lambda (lk) (strcat "\n" (car lk) " " (cutonce:kb-url (cdr lk)))))
                             links))))
  )
  (princ)
)

(defun cutonce:notice (text topic)
  (cutonce:notice-links text (list (cons "Learn More..." topic)))
)

;; A command or save-check warning: shown only when due under the designer's
;; frequency choice (see cutonce:warn-due-p), then remembered.
(defun cutonce:notice-once (key text topic)
  (if (cutonce:warn-due-p key)
    (progn
      (cutonce:notice (strcat text "\n\n" (cutonce:freq-note)) topic)
      (cutonce:mark-warned key)
    )
  )
  (princ)
)

(defun c:CUTONCE-STATUS ( / app)
  (setq app (cutonce:civil-app))
  (cutonce:msg "CutOnce" (strcat "Version " *cutonce:version* " - published by " *cutonce:publisher*))
  (princ (strcat "\n  Install folder:  " (cutonce:home)))
  (princ (strcat "\n  Log folder:      " (cutonce:log-dir)))
  (princ (strcat "\n  Civil 3D COM:    "
                 (if app
                   (strcat "connected (" (cond ((vl-bb-ref '*cutonce:bb-civil-progid*)) ("?")) ")")
                   "not connected - run CUTONCE-FINDCIVIL")))
  (princ (strcat "\n  Logging:         " (if (cutonce:on-p "LogEnabled") "on" "OFF")))
  (princ "\n  Settings:        CUTONCE (dialog), -CUTONCE List (command line)")
  (princ "\n  Tool status:     CUTONCE-GUARD-STATUS, CUTONCE-IMPACT-STATUS, CUTONCE-CHECK-STATUS")
  (princ)
)

(princ)
