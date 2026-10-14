;;; ============================================================================
;;; CutOnce-Core.lsp  (TRIAL)
;;;
;;; Copyright (c) 2026 Stephen Walz. All rights reserved.
;;;
;;; CutOnce Trial. This build includes only the EXPLODE / BURST warning and
;;; its switch in the CutOnce Control Center. Standards checks, health logs,
;;; impact warnings, xref guards and every other CutOnce feature are left out.
;;;
;;; To unlock the full version, reach out to stevewalz@hotmail.com
;;;
;;; Shared services for CutOnce-Guard.lsp and the CutOnce Control Center:
;;;   - configuration lookup (CutOnce-Config.lsp)
;;;   - per-user settings (what the Control Center switches on/off)
;;;   - warning frequency (every time, or once per command per session)
;;;   - fail-safe COM property helpers
;;;   - Learn More links and the notice dialog
;;;
;;; Naming: every function and global in this file starts with cutonce: or
;;; *cutonce:, so nothing here can collide with other LISP loaded in the session.
;;; ============================================================================

(vl-load-com)

(setq *cutonce:version* "2.0.0 Trial")
(setq *cutonce:publisher* "Stephen Walz")
(setq *cutonce:contact* "stevewalz@hotmail.com")
(setq *cutonce:unlock-note*
  (strcat "This is the CutOnce Trial (EXPLODE warning only). "
          "To unlock the full version, reach out to " *cutonce:contact*))

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
;; The trial has one switch. Its effective value is:
;;   1. the user's own choice (AutoCAD profile, CutOnce.<key>)
;;   2. otherwise the administrator's default: ("<key>" . T/nil) in the config
;;   3. otherwise the built-in default below
;;
;; Fields: key, Control Center group, label, built-in default.
;; ---------------------------------------------------------------------------

(setq *cutonce:settings*
  '(
    ("WarnEXPLODE"      "Cmd"      "EXPLODE / BURST - Civil 3D objects, blocks, hatches"   T)
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

(defun cutonce:on-p (key / p)
  (setq p (cutonce:pref-get key))
  (cond ((= p "1") T)
        ((= p "0") nil)
        (T (cutonce:setting-default key)))
)

;; Stores the user's choice. A choice equal to the administrator default is
;; stored as "no choice", so a later change to the default still reaches
;; this user.
(defun cutonce:set-on (key on)
  (if (eq (if on T nil) (cutonce:setting-default key))
    (if (cutonce:pref-get key) (cutonce:pref-set key ""))
    (cutonce:pref-set key (if on "1" "0"))
  )
)

(defun cutonce:cmd-warn-p (key) (cutonce:on-p key))

;; ---------------------------------------------------------------------------
;; Warning frequency: "every" time, or "once" per command per Civil 3D session.
;; What has been shown is kept on the Visual LISP blackboard, so it is shared
;; by every open drawing and forgotten when Civil 3D closes.
;; ---------------------------------------------------------------------------

(defun cutonce:default-warn-mode ( )
  (if (= (cutonce:cfg "WarnFrequency" "every") "once") "once" "every")
)

(defun cutonce:warn-mode ( / p)
  (setq p (cutonce:pref-get "WarnFrequency"))
  (if (member p '("every" "once")) p (cutonce:default-warn-mode))
)

(defun cutonce:reset-warned ( ) (vl-bb-set '*cutonce:bb-warned* nil))

(defun cutonce:set-warn-mode (mode)
  (if (/= mode (cutonce:warn-mode)) (cutonce:reset-warned))
  (if (= mode (cutonce:default-warn-mode))
    (if (cutonce:pref-get "WarnFrequency") (cutonce:pref-set "WarnFrequency" ""))
    (cutonce:pref-set "WarnFrequency" mode))
)

;; key identifies one warning, e.g. "GUARD_EXPLODE".
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

;; Install folder, as resolved by CutOnce-Loader.lsp.
(defun cutonce:home ( )
  (if (and (boundp '*cutonce:home*) *cutonce:home*) *cutonce:home* "")
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
;; property returns nil.
;; ---------------------------------------------------------------------------

(defun cutonce:prop (obj propname / r)
  (if (= (type obj) 'VLA-OBJECT)
    (progn
      (setq r (vl-catch-all-apply 'vlax-get-property (list obj propname)))
      (if (vl-catch-all-error-p r) nil r)
    )
  )
)

(defun cutonce:str-prop (obj propname / v)
  (setq v (cutonce:prop obj propname))
  (if (= (type v) 'STR) v nil)
)

(defun cutonce:object-name (obj)
  (cond ((cutonce:str-prop obj 'ObjectName)) (""))
)

(defun cutonce:active-doc ( )
  (vla-get-ActiveDocument (vlax-get-acad-object))
)

(defun cutonce:join (strs sep / s)
  (setq s nil)
  (foreach x strs (setq s (if s (strcat s sep x) x)))
  (if s s "")
)

;; ---------------------------------------------------------------------------
;; Knowledge-base links ("Learn More")
;;
;; Each warning has a topic; the topic maps to a section anchor on the
;; "Civil 3D Warnings Explained" page.
;; ---------------------------------------------------------------------------

(setq *cutonce:kb-default-url*
  "https://designtovisualization.com/kb-c3d-and-cutonce-assistant/")

(setq *cutonce:kb-default-anchors*
  '(("GUARD_EXPLODE"     . "explode-civil-objects")
    ("GUARD_ATTRIB"      . "explode-attributed-blocks")
    ("CONTROL_CENTER"    . "control-center")))

(defun cutonce:kb-url (topic / anchor)
  (setq anchor (cdr (assoc topic *cutonce:kb-default-anchors*)))
  (if (cutonce:nonblank anchor)
    (strcat *cutonce:kb-default-url* "#" anchor)
    *cutonce:kb-default-url*
  )
)

;; Opens a URL (or mailto: link) with the Windows shell, then the URL
;; protocol handler. The URL is always printed so it can be copied.
(defun cutonce:open-url (url / sh r)
  (princ (strcat "\n" url))
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

;; Opens a new email to the publisher about the full version.
(defun cutonce:email-unlock ( )
  (cutonce:open-url (strcat "mailto:" *cutonce:contact* "?subject=CutOnce%20full%20version"))
)

;; ---------------------------------------------------------------------------
;; Notice dialog: a message with OK and one or more Learn More buttons, each
;; opening its own section of the knowledge-base page. Falls back to a plain
;; alert (with the links written out) if the dialog cannot be shown.
;;
;;   (cutonce:notice text "GUARD_EXPLODE")                 one Learn More button
;;   (cutonce:notice-links text '(("Learn More..." . "GUARD_EXPLODE") ...))
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
                "  label = \"CutOnce Trial\";"
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

;; A command warning: shown only when due under the designer's frequency
;; choice (see cutonce:warn-due-p), then remembered. Every trial warning
;; ends with the note on unlocking the full version.
(defun cutonce:notice-once (key text topic)
  (if (cutonce:warn-due-p key)
    (progn
      (cutonce:notice (strcat text "\n\n" (cutonce:freq-note)
                              "\n\n" *cutonce:unlock-note*)
                      topic)
      (cutonce:mark-warned key)
    )
  )
  (princ)
)

(defun c:CUTONCE-STATUS ( )
  (cutonce:msg "CutOnce" (strcat "Version " *cutonce:version* " - published by " *cutonce:publisher*))
  (princ (strcat "\n  Install folder:  " (cutonce:home)))
  (princ (strcat "\n  EXPLODE warning: " (if (cutonce:on-p "WarnEXPLODE") "on" "OFF")))
  (princ (strcat "\n  Frequency:       " (if (= (cutonce:warn-mode) "once") "once per command per session" "every time")))
  (princ "\n  Settings:        CUTONCE (dialog), -CUTONCE (command line)")
  (princ (strcat "\n  " *cutonce:unlock-note*))
  (princ)
)

(princ)
