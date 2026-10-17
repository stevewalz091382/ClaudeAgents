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
;;;   - the shared backup folder for "save a copy" before risky changes
;;;   - a cached connection to the Civil 3D COM application object
;;;
;;; Naming: every function and global in this file starts with cutonce: or
;;; *cutonce:, so nothing here can collide with other LISP loaded in the session.
;;; ============================================================================

(vl-load-com)

(setq *cutonce:version* "2.1.0")
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
    ("GuardCleanup"     "Save"     "Offer one-click cleanup when growth is flagged"       T)
    ("BackupBeforeCleanup" "Save"  "Save a backup copy to the shared folder before cleanup" T)
    ;; Standards check when a drawing opens
    ("StdCheckOnOpen"   "Open"     "Run the standards check when a drawing opens"         T)
    ("StdByLayer"       "Open"     "Objects whose color or linetype is not ByLayer"       T)
    ("StdXrefStatus"    "Open"     "Xrefs that are broken (not found) or unloaded"        T)
    ("StdXrefOrigin"    "Open"     "Xrefs not inserted at 0,0,0"                          T)
    ("StdCoordUnits"    "Open"     "Coordinate system and insertion units"                T)
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
;; then, for a shared team folder, a per-person subfolder (see
;; cutonce:log-subfolder). Resolved once per drawing session and cached.
(setq *cutonce:log-dir* nil)

;; Folder name with the characters Windows does not allow removed; nil if
;; nothing is left.
(defun cutonce:safe-folder (s)
  (if (= (type s) 'STR)
    (cutonce:nonblank
      (vl-string-trim " ."
        (vl-list->string
          (vl-remove-if (function (lambda (c) (member c '(92 47 58 42 63 34 60 62 124))))
                        (vl-string->list s))))))
)

;; "LogSubfolder" (or the CUTONCE_LOGSUBFOLDER variable): each person, or
;; each computer, writes to its own subfolder of a shared log folder, so two
;; people never append to the same file at once and synced folders
;; (cloud-synced across offices) never make conflict copies.
;;   nil / ""         no subfolder (everyone writes the same files)
;;   "user"           <LogDir>\<Windows user name>\
;;   "computer"       <LogDir>\<computer name>\
;;   "user-computer"  <LogDir>\<user>-<computer>\
(defun cutonce:log-subfolder ( / mode user pc)
  (setq mode (strcase (cond ((cutonce:nonblank (getenv "CUTONCE_LOGSUBFOLDER")))
                            ((cutonce:nonblank (cutonce:cfg "LogSubfolder" nil)))
                            (""))))
  (setq user (cutonce:safe-folder (cutonce:user))
        pc   (cutonce:safe-folder (getenv "COMPUTERNAME")))
  (cond
    ((= mode "USER") user)
    ((= mode "COMPUTER") pc)
    ((= mode "USER-COMPUTER") (if (and user pc) (strcat user "-" pc) (cond (user) (pc))))
  )
)

(defun cutonce:log-dir ( / d la sub)
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
      (if (setq sub (cutonce:log-subfolder))
        (setq d (strcat (cutonce:dir-slash d) sub)))
      (setq d (cutonce:dir-slash d))
      (vl-catch-all-apply 'cutonce:mkdir-p (list d))
      (setq *cutonce:log-dir* d)
    )
  )
  *cutonce:log-dir*
)

(defun cutonce:log-file (name) (strcat (cutonce:log-dir) name))

;; Backup folder: the one shared "master" folder that CUTONCE-BACKUP and the
;; cleanup write a copy of the drawing to before changing it. Resolution:
;;   1. CUTONCE_BACKUPDIR (Windows environment variable, or setenv in AutoCAD)
;;   2. "BackupDir" in CutOnce-Config.lsp
;;   3. Documents\CutOnce Backups (per user; set BackupDir for a team folder)
;; No per-person subfolder: every copy gets a unique name instead (see
;; cutonce:backup-name), so nobody overwrites anyone else's copy.
(defun cutonce:backup-dir-configured ( )
  (cond ((cutonce:nonblank (getenv "CUTONCE_BACKUPDIR")))
        ((cutonce:nonblank (cutonce:cfg "BackupDir" nil))))
)

(defun cutonce:backup-dir ( / d up)
  (setq d (cond ((cutonce:backup-dir-configured))
                ((setq up (cutonce:nonblank (getenv "USERPROFILE")))
                 (strcat up "\\Documents\\CutOnce Backups"))
                (T (strcat (getvar "TEMPPREFIX") "CutOnce Backups"))))
  (cutonce:dir-slash d)
)

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
;; Extra Health.csv columns set by the CAD administrator:
;;   ("HealthExtraCounts" . (("Column" . "ObjectName wildcard") ...))
;; e.g. ("FeatureLines" . "AeccDbFeatureLine") or
;;      ("Dimensions" . "AcDb*Dimension"). Column names keep only letters,
;; digits and _. Returns the usable entries, in order.
;; ---------------------------------------------------------------------------

(defun cutonce:column-name (s)
  (vl-list->string
    (vl-remove-if-not
      (function (lambda (c) (or (<= 48 c 57) (<= 65 c 90) (<= 97 c 122) (= c 95))))
      (vl-string->list s)))
)

(defun cutonce:health-extra-counts ( / v out name)
  (setq v (cutonce:cfg "HealthExtraCounts" nil) out nil)
  (if (and v (listp v))
    (foreach e v
      (if (and (listp e) (cutonce:nonblank (car e)) (cutonce:nonblank (cdr e)))
        (progn
          (setq name (cutonce:column-name (car e)))
          (if (and (/= name "") (not (assoc name out)))
            (setq out (cons (cons name (strcase (cdr e))) out)))
        )
      )
    )
  )
  (reverse out)
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
;; Backup copies
;; ---------------------------------------------------------------------------

(defun cutonce:backups-log ( ) (cutonce:log-file "Backups.csv"))

;; A file name nobody else will produce: drawing, time to the millisecond,
;; user and computer, and a counter if that still exists.
(defun cutonce:backup-name (dir drawpath / base ext who stamp name n)
  (setq base  (vl-filename-base drawpath)
        ext   (cond ((vl-filename-extension drawpath)) (".dwg"))
        who   (cond ((cutonce:safe-folder (strcat (cutonce:user) "-" (cond ((getenv "COMPUTERNAME")) ("")))))
                    ("unknown"))
        stamp (strcat (menucmd "M=$(edtime,$(getvar,date),YYYYMODD-HHMMSS)")
                      "-" (substr (itoa (+ 1000 (rem (getvar "MILLISECS") 1000))) 2)))
  (setq name (strcat dir base "__" stamp "_" who ext) n 1)
  (while (findfile name)
    (setq n (1+ n)
          name (strcat dir base "__" stamp "_" who "-" (itoa n) ext)))
  name
)

;; Copies the drawing as last saved to the backup folder. Returns the copy's
;; path, or nil (with the reason on the command line).
(defun cutonce:backup (doc reason / src dir dest)
  (setq src (cutonce:nonblank (cutonce:str-prop doc 'FullName))
        dir (cutonce:backup-dir))
  (vl-catch-all-apply 'cutonce:mkdir-p (list dir))
  (cond
    ((or (not src) (not (findfile src)))
     (cutonce:msg "CutOnce" "This drawing has not been saved yet, so there is no file to copy.") nil)
    ((not (vl-file-directory-p (vl-string-right-trim "\\" dir)))
     (cutonce:msg "CutOnce" (strcat "Backup folder not reachable: " dir)) nil)
    ((not (setq dest (cutonce:backup-name dir src))) nil)
    ((or (not (vl-file-copy src dest))
         (/= (vl-file-size dest) (vl-file-size src)))
     (vl-file-delete dest)
     (cutonce:msg "CutOnce" (strcat "Could not copy " src " to " dest)) nil)
    (T
     (vl-catch-all-apply 'cutonce:append-line
       (list (cutonce:backups-log)
             "Timestamp,User,Computer,DrawingPath,BackupPath,Reason,UnsavedChangesNotInCopy"
             (cutonce:csv-row (list (cutonce:timestamp) (cutonce:user) (cond ((getenv "COMPUTERNAME")) (""))
                                    src dest reason
                                    (if (and (cutonce:context-doc-p doc) (/= 0 (getvar "DBMOD"))) "Yes" "No")))))
     (cutonce:log-event "BACKUP-COPY" (strcat reason ": " dest))
     (cutonce:msg "CutOnce" (strcat "Backup copy saved: " dest))
     dest)
  )
)

;; ---------------------------------------------------------------------------
;; "Save a copy" button on every warning. The button copies the drawing as
;; last saved (cutonce:backup) at once, while the warning is still open, so
;; the designer can keep a way back before going ahead. It is a plain file
;; copy, so it also works inside the save and command reactors.
;; ---------------------------------------------------------------------------

(setq *cutonce:copy-reason* nil)

(defun cutonce:copy-available-p ( / src)
  (and (= 1 (getvar "DWGTITLED"))
       (setq src (cutonce:nonblank (cutonce:str-prop (cutonce:active-doc) 'FullName)))
       (findfile src))
)

(defun cutonce:copy-intro ( )
  (cond
    ((not (cutonce:copy-available-p))
     "Save a copy: not available until this drawing has been saved once.")
    ((/= 0 (getvar "DBMOD"))
     "Save a copy puts the drawing as last saved (unsaved changes not included) in:")
    (T "Save a copy puts the drawing, as it is now, in:")
  )
)

;; Called with the dialog open: button "savecopy", status lines "copy_status"
;; and "copy_where" (the folder on a line of its own, so it is never cut off).
(defun cutonce:fill-copy-tiles ( )
  (set_tile "copy_status" (cutonce:copy-intro))
  (set_tile "copy_where" (if (cutonce:copy-available-p) (cutonce:backup-dir) ""))
  (if (not (cutonce:copy-available-p)) (mode_tile "savecopy" 1))
  (action_tile "savecopy" "(cutonce:copy-now)")
)

(defun cutonce:copy-now ( / bk)
  (setq bk (vl-catch-all-apply 'cutonce:backup
             (list (cutonce:active-doc) (cond (*cutonce:copy-reason*) ("Before going ahead with a warning")))))
  (if (vl-catch-all-error-p bk) (setq bk nil))
  (if bk
    (progn (set_tile "copy_status" "Copy saved:") (set_tile "copy_where" bk) (mode_tile "savecopy" 1))
    (progn (set_tile "copy_status" "Copy failed - is this folder reachable? Details are on the command line.")
           (set_tile "copy_where" (cutonce:backup-dir)))
  )
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
    ("GUARD_CLEANUP"     . "drawing-cleanup")
    ("STD_COORD_UNITS"   . "coordinate-system-units")
    ("BACKUP"            . "backup-copies")
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
;; Branding: every CutOnce dialog opens with the same header band
;;
;;   [logo]  CutOnce  |  Healthy Civil 3D models, one save at a time
;;           <headline: what this dialog is about>
;;   ============ colour strip: amber warning, red error, green ok, brand info
;;   ... dialog body ...
;;   CutOnce 2.1.0  |  Stephen Walz                     (footer)
;;
;; DCL has no fonts or text colours, so the look comes from image tiles: the
;; logo tile is filled with the brand colour and carries a vector mark (a
;; check above a dashed cut line), or the firm's own logo as an AutoCAD slide
;; (BrandLogoSlide: draw the logo, MSLIDE it, point the setting at the .sld).
;; BrandName, BrandTagline and BrandColor (an AutoCAD colour index) come from
;; CutOnce-Config.lsp.
;; ---------------------------------------------------------------------------

(defun cutonce:brand-name ( ) (cond ((cutonce:nonblank (cutonce:cfg "BrandName" nil))) ("CutOnce")))

(defun cutonce:brand-tagline ( )
  (cond ((cutonce:nonblank (cutonce:cfg "BrandTagline" nil))) ("Healthy Civil 3D models, one save at a time"))
)

(defun cutonce:brand-color ( / c)
  (setq c (cutonce:cfg "BrandColor" 150))
  (if (and (numberp c) (<= 1 c 255)) (fix c) 150)
)

;; Severity colours for the strip under the header (AutoCAD colour index).
(defun cutonce:kind-color (kind)
  (cond ((eq kind 'warning) 30)
        ((eq kind 'error) 1)
        ((eq kind 'ok) 94)
        (T (cutonce:brand-color)))
)

;; DCL for the header band and the footer; width in characters.
(defun cutonce:brand-header-dcl (width)
  (list
    "  : row {"
    "    : image { key = \"co_logo\"; width = 7; height = 3.2; fixed_width = true; fixed_height = true; }"
    "    : column {"
    (strcat "      : text { key = \"co_title\"; width = " (itoa (- width 9)) "; }")
    (strcat "      : text { key = \"co_head\"; width = " (itoa (- width 9)) "; }")
    "    }"
    "  }"
    (strcat "  : image { key = \"co_bar\"; width = " (itoa width) "; height = 0.45; fixed_height = true; }"))
)

(defun cutonce:brand-footer-dcl ( )
  (list "  : text { key = \"co_foot\"; alignment = right; }")
)

;; The built-in mark: a check above a dashed "cut once" line, in white.
(defun cutonce:draw-mark (w h / i x)
  (foreach d '(-1 0 1)
    (vector_image (fix (* 0.20 w)) (+ d (fix (* 0.42 h))) (fix (* 0.42 w)) (+ d (fix (* 0.64 h))) 7)
    (vector_image (fix (* 0.42 w)) (+ d (fix (* 0.64 h))) (fix (* 0.80 w)) (+ d (fix (* 0.16 h))) 7))
  (setq x (fix (* 0.14 w)))
  (while (< x (* 0.86 w))
    (vector_image x (fix (* 0.84 h)) (min (+ x 3) (fix (* 0.86 w))) (fix (* 0.84 h)) 7)
    (setq x (+ x 6)))
)

(defun cutonce:paint-brand-body (headline kind / w h sld)
  (set_tile "co_title" (strcat (cutonce:brand-name) "  |  " (cutonce:brand-tagline)))
  (set_tile "co_head" (cond ((cutonce:nonblank headline)) ("")))
  (set_tile "co_foot" (strcat (cutonce:brand-name) " " *cutonce:version* "  |  " *cutonce:publisher*))
  (setq w (dimx_tile "co_logo") h (dimy_tile "co_logo"))
  (start_image "co_logo")
  (fill_image 0 0 w h (cutonce:brand-color))
  (if (setq sld (cutonce:brand-logo-slide))
    (slide_image 0 0 w h sld)
    (cutonce:draw-mark w h))
  (end_image)
  (start_image "co_bar")
  (fill_image 0 0 (dimx_tile "co_bar") (dimy_tile "co_bar") (cutonce:kind-color kind))
  (end_image)
)

;; The firm's logo slide: BrandLogoSlide, else CutOnce-Logo.sld in the
;; install folder; nil for the built-in mark.
(defun cutonce:brand-logo-slide ( / cfg)
  (cond ((and (setq cfg (cutonce:nonblank (cutonce:cfg "BrandLogoSlide" nil))) (findfile cfg)))
        ((findfile (strcat (cutonce:home) "CutOnce-Logo.sld"))))
)

;; Call with the dialog open, after new_dialog. Never stops the dialog.
(defun cutonce:paint-brand (headline kind)
  (vl-catch-all-apply 'cutonce:paint-brand-body (list headline kind))
)

;; The first line of a message becomes the header's headline (without the
;; "CutOnce Guard:" prefix the header already says); the rest is the body.
;; Returns (headline . body-lines).
(defun cutonce:split-headline (text / lines head)
  (setq lines (cutonce:split-lines text))
  (while (and lines (not (cutonce:nonblank (car lines)))) (setq lines (cdr lines)))
  (setq head (vl-string-trim " " (cond ((car lines)) (""))) lines (cdr lines))
  (foreach pre '("CutOnce Guard tip:" "CutOnce Guard:" "CutOnce:")
    (if (wcmatch (strcase head) (strcat (strcase pre) "*"))
      (setq head (vl-string-trim " " (substr head (1+ (strlen pre)))))))
  (while (and lines (not (cutonce:nonblank (car lines)))) (setq lines (cdr lines)))
  ;; "CutOnce Guard tip:" alone on its line: the next line is the headline
  (if (and (= head "") lines)
    (progn
      (setq head (vl-string-trim " " (car lines)) lines (cdr lines))
      (while (and lines (not (cutonce:nonblank (car lines)))) (setq lines (cdr lines)))))
  (cons (if (= head "") (cutonce:brand-name) head) lines)
)

;; Severity of the next notice: 'warning 'error 'ok or 'info. Callers set it
;; just before showing a notice; it is cleared after every notice.
(setq *cutonce:notice-kind* nil)

;; ---------------------------------------------------------------------------
;; Notice dialog: a message with OK, optional action buttons, and one or more
;; Learn More buttons, each opening its own section of the knowledge-base
;; page. Used for every warning that has a section. Falls back to a plain
;; alert (with the links written out) if the dialog cannot be shown.
;;
;;   (cutonce:notice text "GUARD_XREF_BIND")                one Learn More button
;;   (cutonce:notice-links text '(("About ByLayer..." . "STD_BYLAYER") ...))
;;   (cutonce:notice-dialog text links '("Clean up now...") "Close")
;;       returns 1 for OK / Close, 2 for the first action button, 3 for the
;;       second, and so on (1 when only the fallback alert could be shown)
;;   (cutonce:warning-dialog text links actions reason)
;;       the same with the "Save a copy" button every warning carries;
;;       reason is recorded with the copy in Backups.csv
;; ---------------------------------------------------------------------------

;; Text for a DCL string literal: backslashes doubled, double quotes made single.
(defun cutonce:dcl-str (s)
  (vl-string-translate "\"" "'"
    (apply 'strcat (mapcar (function (lambda (c) (if (= c 92) "\\\\" (chr c)))) (vl-string->list s))))
)

;; DCL with the buttons baked in; written fresh for each notice because the
;; number and labels of the buttons vary. Returns the temp file path.
(defun cutonce:write-notice-dcl (links actions oklabel copy / path f i)
  (setq path (vl-filename-mktemp "cutonce" nil ".dcl"))
  (if (setq f (open path "w"))
    (progn
      (foreach ln
        (append
          (list "co_notice : dialog {"
                (strcat "  label = \"" (cutonce:dcl-str (cutonce:brand-name)) "\";"))
          (cutonce:brand-header-dcl 82)
          (list "  : spacer { height = 0.3; }"
                "  : list_box { key = \"notice_text\"; height = 15; width = 82; }")
          (if copy (list "  : text { key = \"copy_status\"; width = 80; }"
                         "  : text { key = \"copy_where\"; width = 80; }"))
          (list "  : row {"
                "    alignment = centered; fixed_width = true;")
          (if copy (list "    : button { key = \"savecopy\"; label = \"Save a copy\"; }"))
          (progn
            (setq i 0)
            (mapcar (function (lambda (lbl)
                      (setq i (1+ i))
                      (strcat "    : button { key = \"act_" (itoa i) "\"; label = \""
                              (cutonce:dcl-str lbl) "\"; }")))
                    actions))
          (list (strcat "    : button { key = \"accept\"; label = \""
                        (cutonce:dcl-str (cond ((cutonce:nonblank oklabel)) ("OK")))
                        "\"; is_default = true; is_cancel = true; width = 12; }"))
          (progn
            (setq i 0)
            (mapcar (function (lambda (lk)
                      (setq i (1+ i))
                      (strcat "    : button { key = \"learn_" (itoa i) "\"; label = \""
                              (cutonce:dcl-str (car lk)) "\"; }")))
                    links))
          (list "  }")
          (cutonce:brand-footer-dcl)
          (list "}"))
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

(defun cutonce:notice-dialog (text links actions oklabel)
  (cutonce:notice-dialog-full text links actions oklabel nil)
)

(defun cutonce:warning-dialog (text links actions reason)
  (cutonce:notice-dialog-full text links actions nil (cond (reason) ("Before going ahead with a warning")))
)

;; copyreason non-nil adds the "Save a copy" button (see cutonce:copy-now).
(defun cutonce:notice-dialog-full (text links actions oklabel copyreason / path dcl_id result i kind parts)
  (setq kind (cond (*cutonce:notice-kind*) (copyreason 'warning) (T 'info))
        *cutonce:notice-kind* nil
        parts (cutonce:split-headline text))
  (setq links (vl-remove-if-not (function (lambda (lk) (cdr lk))) links))
  (setq path (cutonce:write-notice-dcl links actions oklabel copyreason) result nil)
  (if (and path (> (setq dcl_id (load_dialog path)) 0))
    (progn
      (if (new_dialog "co_notice" dcl_id)
        (progn
          (cutonce:paint-brand (car parts) kind)
          (start_list "notice_text")
          (foreach ln (cdr parts) (add_list ln))
          (end_list)
          (if copyreason
            (progn (setq *cutonce:copy-reason* copyreason) (cutonce:fill-copy-tiles)))
          (action_tile "accept" "(done_dialog 1)")
          (setq i 0)
          (foreach a actions
            (setq i (1+ i))
            (action_tile (strcat "act_" (itoa i)) (strcat "(done_dialog " (itoa (1+ i)) ")"))
          )
          (setq i 0)
          (foreach lk links
            (setq i (1+ i))
            (action_tile (strcat "learn_" (itoa i))
                         (strcat "(cutonce:open-kb " (vl-prin1-to-string (cdr lk)) ")"))
          )
          (setq result (start_dialog))
        )
      )
      (unload_dialog dcl_id)
    )
  )
  (if path (vl-file-delete path))
  (if (not result)
    (progn
      (alert (strcat text "\n"
                     (apply 'strcat
                       (mapcar (function (lambda (lk) (strcat "\n" (car lk) " " (cutonce:kb-url (cdr lk)))))
                               links))))
      (setq result 1)
    )
  )
  result
)

(defun cutonce:notice-links (text links)
  (cutonce:notice-dialog text links nil nil)
  (princ)
)

(defun cutonce:notice (text topic)
  (cutonce:notice-links text (list (cons "Learn More..." topic)))
)

;; Yes / no question. The safe answer (nolabel) is the default button.
(defun cutonce:confirm (text yeslabel nolabel)
  (setq *cutonce:notice-kind* 'error)
  (= 2 (cutonce:notice-dialog text nil (list yeslabel) nolabel))
)

;; A command or save-check warning: shown only when due under the designer's
;; frequency choice (see cutonce:warn-due-p), then remembered.
(defun cutonce:notice-once (key text topic)
  (cutonce:notice-once-actions key text (list (cons "Learn More..." topic)) nil)
  (princ)
)

;; "GUARD_GROWTH|C-101.dwg" -> "GUARD_GROWTH"
(defun cutonce:warning-name (key / i)
  (if (setq i (vl-string-search "|" key)) (substr key 1 i) key)
)

;; The same with action buttons. Returns the button pressed (see
;; cutonce:notice-dialog), or nil when the frequency choice hid the warning.
;; Warnings that do not offer "Save a copy": advisories and edits that are
;; quick to undo, where a backup copy is not worth the extra button.
;; Every other warning offers it.
(setq *cutonce:no-copy-warnings*
  '("GUARD_TEXT"            ; TEXT / DTEXT / MTEXT tip
    "GUARD_XREF_MOVED"      ; MOVE / COPY of an xref
    "GUARD_EXPLODE_BLOCKS"  ; EXPLODE of blocks and hatches only (no Civil 3D objects)
    "GUARD_ATTRIB"          ; EXPLODE / BURST of attributed blocks
    "GUARD_REFEDIT"         ; REFEDIT advisory
    "GUARD_REFCLOSE"))      ; REFCLOSE advisory

;; "GUARD_TEXT:MTEXT" / "GUARD_GROWTH|A.dwg" -> "GUARD_TEXT" / "GUARD_GROWTH"
(defun cutonce:warning-base (key / i)
  (setq key (cutonce:warning-name key))
  (if (setq i (vl-string-search ":" key)) (substr key 1 i) key)
)

(defun cutonce:copy-offered-p (key)
  (not (member (cutonce:warning-base key) *cutonce:no-copy-warnings*))
)

(defun cutonce:notice-once-actions (key text links actions / r)
  (if (not (cutonce:warn-due-p key)) (setq *cutonce:notice-kind* nil))
  (if (cutonce:warn-due-p key)
    (progn
      (setq text (strcat text "\n\n" (cutonce:freq-note)))
      (setq r (if (cutonce:copy-offered-p key)
                (cutonce:warning-dialog text links actions
                                        (strcat "Before going ahead: " (cutonce:warning-name key)))
                (progn
                  (if (not *cutonce:notice-kind*) (setq *cutonce:notice-kind* 'warning))
                  (cutonce:notice-dialog text links actions nil))))
      (cutonce:mark-warned key)
      r
    )
  )
)

;; Opens a folder in Windows Explorer.
(defun cutonce:open-folder (dir / sh)
  (setq sh (vl-catch-all-apply 'vlax-get-or-create-object (list "Shell.Application")))
  (if (and sh (not (vl-catch-all-error-p sh)))
    (progn
      (vl-catch-all-apply 'vlax-invoke-method (list sh 'Open dir))
      (vl-catch-all-apply 'vlax-release-object (list sh))
    )
    (vl-catch-all-apply 'startapp (list "explorer.exe" dir))
  )
  (princ)
)

(defun c:CUTONCE-STATUS ( / app)
  (setq app (cutonce:civil-app))
  (cutonce:msg "CutOnce" (strcat "Version " *cutonce:version* " - published by " *cutonce:publisher*))
  (princ (strcat "\n  Install folder:  " (cutonce:home)))
  (princ (strcat "\n  Log folder:      " (cutonce:log-dir)))
  (princ (strcat "\n  Backup folder:   " (cutonce:backup-dir)
                 (if (cutonce:backup-dir-configured) "" "  (personal default - set BackupDir for a shared folder)")))
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
