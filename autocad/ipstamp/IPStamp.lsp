;;; ==========================================================================
;;; IPStamp.lsp  -  reactor-based "last touched" stamps + IP marking
;;; --------------------------------------------------------------------------
;;; Target : AutoCAD 2027 / Civil 3D 2027. Pure AutoLISP / Visual LISP.
;;; Needs  : IPStamp-Core.lsp in the same support folder.
;;;
;;; What it does
;;;   * A vlr-object-reactor watches every tracked object in the drawing
;;;     (alignments, profiles, corridors, polylines, blocks ... see *IPS:Types*).
;;;   * When one is modified, the reactor queues it. AutoCAD forbids changing
;;;     an object inside its own :vlr-modified callback, so the stamp is
;;;     written when the command ends (:vlr-commandEnded), when a LISP routine
;;;     ends, or just before save (:vlr-beginSave).
;;;   * Each object carries "IPSTAMP" xdata: who created it, where and when
;;;     (signed once, never rewritten), who last touched it, with what
;;;     command, in which drawing, a short history, a geometry fingerprint,
;;;     and a keyed signature over the whole record.
;;;   * New objects (drawn, pasted, inserted, exploded) are picked up by a
;;;     database reactor, stamped with how they arrived, and joined to the
;;;     object reactor.
;;;
;;; Commands
;;;   IPWHO        look up the stamp on an object (also on the right-click menu)
;;;   IPWHON       same, for an object nested in a block or xref
;;;   IPMARK       baseline-claim every unstamped object in this drawing
;;;   IPSEAL       IPMARK + coordinate watermark + hidden sentinels (anti-strip)
;;;   IPXMIT       record an outgoing transmittal (recipient, purpose) in the DWG
;;;   IPSTATUS     show tracking state, key id and log path
;;;   IPSTAMPON / IPSTAMPOFF    resume / suspend tracking in this drawing
;;;   IPMENU / IPMENUREMOVE     add / remove the right-click menu entry
;;; ==========================================================================
(vl-load-com)

(if (null *IPS:CoreVersion*)
  (if (findfile "IPStamp-Core.lsp")
    (load "IPStamp-Core.lsp")
    (princ "\nIPStamp: IPStamp-Core.lsp was not found on the support path.")))

;;; ------------------------------------------------------------- config ---
;; Commands whose side effects are never stamped.
(if (null *IPS:IgnoreCmds*)
  (setq *IPS:IgnoreCmds* "U,UNDO,MREDO,QSAVE,SAVE,SAVEAS,CLOSE,CLOSEALL,QUIT,EXIT"))
;; "YES" = add "IP Stamp - who touched this?" to the edit-mode right-click menu.
(if (null *IPS:AutoMenu*) (setq *IPS:AutoMenu* "YES"))
;; "YES" = when U removes only our stamp group, issue a second U for you.
;; Leave "NO" unless the README undo test shows you need it.
(if (null *IPS:ChainUndo*) (setq *IPS:ChainUndo* "NO"))

;;; ------------------------------------------------------ runtime state ---
(setq *IPS:Pending* nil   ; ((vla-object time cmd) ...)  modified owners
      *IPS:New*     nil   ; ((ename time cmd) ...)       appended objects
      *IPS:Erased*  nil   ; ((vla-object time cmd handle objname rec) ...)
      *IPS:Rows*    nil   ; CSV log rows waiting to be written
      *IPS:Busy*    nil   ; T while we write, so our own changes are ignored
      *IPS:CurCmd*  nil
      *IPS:Depth*   0
      *IPS:InLisp*  nil
      *IPS:LispName* nil
      *IPS:StampLast* nil
      *IPS:Off*     nil)

;;; ------------------------------------------------------------ helpers ---
(defun ips:cmd-in (cmd pat) (and cmd (wcmatch (strcase cmd) pat)))

(defun ips:ignored-p () (ips:cmd-in *IPS:CurCmd* *IPS:IgnoreCmds*))

;; Name of what is changing the drawing right now, nil if no command
;; (Properties palette, Civil 3D rebuilds, data-shortcut sync, other reactors).
(defun ips:cmd ()
  (cond (*IPS:CurCmd*)
        (*IPS:InLisp* (strcat "LISP" (if *IPS:LispName* (strcat ":" *IPS:LispName*) "")))
        (T nil)))

(defun ips:context ()
  (list (cons "USER"  (ips:user))
        (cons "HOST"  (ips:host))
        (cons "DWG"   (getvar "DWGNAME"))
        (cons "DWGID" (getvar "FINGERPRINTGUID"))
        (cons "TZ"    (ips:tz))))

;; Owner of an entity, skipping the {ACAD_REACTORS} 330 groups.
(defun ips:owner (ed / in own)
  (foreach p ed
    (cond ((and (= (car p) 102) (wcmatch (cdr p) "{*")) (setq in T))
          ((and (= (car p) 102) (= (cdr p) "}")) (setq in nil))
          ((and (= (car p) 330) (not in) (not own)) (setq own (cdr p)))))
  own)

;; A tracked type sitting directly in model space or a paper space layout.
(defun ips:trackable-p (ed / own oed)
  (and ed
       (wcmatch (cdr (assoc 0 ed)) *IPS:Types*)
       (setq own (ips:owner ed))
       (setq oed (entget own))
       (= (cdr (assoc 0 oed)) "BLOCK_RECORD")
       (wcmatch (strcase (cdr (assoc 2 oed))) "`*MODEL_SPACE,`*PAPER_SPACE*")))

(defun ips:collect ( / ss i lst)
  (if (setq ss (ssget "_X" (list (cons 0 *IPS:Types*))))
    (repeat (setq i (sslength ss))
      (setq lst (cons (vlax-ename->vla-object (ssname ss (setq i (1- i)))) lst))))
  lst)

(defun ips:ensure-app ()
  (if (not (tblsearch "APPID" *IPS:App*)) (regapp *IPS:App*)))

;; Create or replace an xrecord under NOD\IPSTAMP (current drawing only).
(defun ips:xrec-put (name pairs / nod dict old)
  (setq nod (namedobjdict))
  (if (not (setq dict (cdr (assoc -1 (dictsearch nod *IPS:App*)))))
    (progn
      (setq dict (entmakex '((0 . "DICTIONARY") (100 . "AcDbDictionary"))))
      (dictadd nod *IPS:App* dict)))
  (if (setq old (dictremove dict name))
    (vl-catch-all-apply 'entdel (list old)))
  (dictadd dict name
    (entmakex
      (append '((0 . "XRECORD") (100 . "AcDbXrecord"))
              (mapcar (function (lambda (p) (cons 1 (ips:clip (strcat (car p) "=" (ips:str (cdr p))) 1000))))
                      pairs))))
  ;; Keep an encrypted hidden copy of the drawing record as well.
  (if (= name "DWGINFO")
    (vl-catch-all-apply 'ips:dshadow-write (list (ips:doc) pairs))))

;; Drawing identity record. Created the first time anything is stamped.
;; Records who first tracked the file; it does NOT claim ownership (IPMARK does).
(defun ips:ensure-dwginfo ( / info id sh)
  (setq info (ips:xrec-read (ips:doc) "DWGINFO")
        id   (getvar "FINGERPRINTGUID"))
  ;; Visible record stripped but the hidden copy survives: put it back.
  (if (and (null info)
           (= (car (setq sh (ips:dshadow-read (ips:doc)))) "VALID"))
    (progn
      (setq info (ips:put* (cdr sh) (list (cons "RESTORED" (ips:now)))))
      (ips:xrec-put "DWGINFO" info)
      (princ "\nIPStamp: the drawing record had been removed - restored from the hidden copy.")))
  (cond
    ((null info)
     (ips:xrec-put "DWGINFO"
       (list (cons "DWGID" id)
             (cons "FIRST_TRACKED_BY" (ips:user))
             (cons "FIRST_TRACKED_ORG" *IPS:Org*)
             (cons "FIRST_TRACKED_TIME" (ips:now))
             (cons "FIRST_TRACKED_NAME" (getvar "DWGNAME")))))
    ((/= (ips:kv "DWGID" info) id)
     ;; New drawing started from a marked file or template: keep the lineage.
     (ips:xrec-put "DWGINFO"
       (ips:put* info
         (list (cons "DWGID" id)
               (cons "PARENT_DWGID" (ips:kv "DWGID" info))
               (cons "PARENT_NOTED" (ips:now))))))))

;;; ----------------------------------------------------------- stamping ---
(defun ips:classify (cmd)
  (cond ((null cmd) "AUTO")
        ((ips:cmd-in cmd *IPS:ImportCmds*) (strcat "IMPORTED:" cmd))
        ((ips:cmd-in cmd *IPS:DeriveCmds*) (strcat "DERIVED:" cmd))
        ((ips:cmd-in cmd *IPS:InsertCmds*) (strcat "INSERTED:" cmd))
        (T "NATIVE")))

;; Set the origin block and sign it. Called once per object, ever
;; (or when IPMARK upgrades an unclaimed pre-existing object).
(defun ips:origin (rec org user host when dwg dwgid ctype)
  (setq rec (ips:put* rec
              (list (cons "ORG" org)
                    (cons "IP" (if (= org *IPS:Org*) *IPS:IPNotice* ""))
                    (cons "C_USER" user)
                    (cons "C_HOST" host)
                    (cons "C_TIME" when)
                    (cons "C_DWG" dwg)
                    (cons "C_DWGID" dwgid)
                    (cons "C_TYPE" ctype)
                    (cons "C_KEYID" (ips:keyid)))))
  (ips:put rec "C_SIG" (ips:mac (ips:canon-c rec))))

;; Object produced by EXPLODE etc. from an erased stamped object: inherit the
;; parent's origin. Re-signed with our key only if the parent verified.
(defun ips:derive (src cmd / ok org)
  (setq ok  (= (car (ips:verify src)) "VALID")
        org (ips:str (ips:kv "ORG" src)))
  (ips:origin nil
              (if ok org (strcat "(unverified) " org))
              (ips:str (ips:kv "C_USER" src))
              (ips:str (ips:kv "C_HOST" src))
              (ips:str (ips:kv "C_TIME" src))
              (ips:str (ips:kv "C_DWG" src))
              (ips:str (ips:kv "C_DWGID" src))
              (strcat "DERIVED:" cmd)))

;; Ordered record + history + record signature, ready to write.
(defun ips:finalize (rec hist / out)
  (foreach k *IPS:Order*
    (if (assoc k rec) (setq out (cons (assoc k rec) out))))
  (foreach h hist (setq out (cons (cons "H" h) out)))
  (setq out (reverse out))
  (append out (list (cons "SIG" (ips:mac (ips:canon-all out))))))

;; Run (fn args) on obj; if it fails because the object sits on a locked
;; layer (Civil 3D rebuilds do that), unlock the layer, retry, relock.
;; -> (T . result) or (nil . error)
(defun ips:unlocked (obj fn args / r lay lyr)
  (setq r (vl-catch-all-apply fn args))
  (if (and (vl-catch-all-error-p r)
           (setq lay (ips:prop obj 'Layer))
           (setq lyr (ips:item (vla-get-layers (ips:doc)) lay))
           (= (vla-get-lock lyr) :vlax-true))
    (progn
      (vla-put-lock lyr :vlax-false)
      (setq r (vl-catch-all-apply fn args))
      (vla-put-lock lyr :vlax-true)))
  (if (vl-catch-all-error-p r) (cons nil r) (cons T r)))

;; Visible stamp, then the hidden encrypted copy.
(defun ips:write-safe (obj rec)
  (if (car (ips:unlocked obj 'ips:xd-write (list obj rec)))
    (progn (ips:unlocked obj 'ips:shadow-write (list obj rec)) T)))

(defun ips:logrow (when user cmd action obj ctx)
  (setq *IPS:Rows*
    (cons (ips:csv-line
            (list when user (ips:kv "HOST" ctx) (ips:kv "DWG" ctx) action (ips:str cmd)
                  (ips:prop obj 'Handle) (ips:prop obj 'ObjectName) (ips:prop obj 'Name)))
          *IPS:Rows*)))

;; mode: "NEW" appended object, "MOD" modified object, "BASE" IPMARK baseline,
;;       "SEAL" IPSEAL (watermark applied; also creates sentinels).
(defun ips:stamp (obj when cmd mode ctx src / old rec hist ctype org me n sh)
  (setq old (ips:xd-read obj)
        me  (ips:kv "USER" ctx))
  ;; Visible stamp stripped but the hidden copy survives: rebuild from it.
  (if (and (null old) (= (car (setq sh (ips:shadow-read obj))) "VALID"))
    (setq old (append (cdr sh)
                      (list (cons "H" (strcat when " " me " RESTORED from hidden copy @" (ips:kv "DWG" ctx)))))))
  (cond
    ;; Already stamped (ours, a copy of ours, or someone else's): keep origin.
    (old
     (setq rec  (vl-remove-if (function (lambda (p) (member (car p) '("H" "SIG")))) old)
           hist (mapcar 'cdr (vl-remove-if-not (function (lambda (p) (= (car p) "H"))) old)))
     (if (and (= mode "BASE") (= (ips:kv "ORG" rec) "(unclaimed)"))
       (setq rec (ips:origin rec *IPS:Org* me (ips:kv "HOST" ctx) when
                             (ips:kv "DWG" ctx) (ips:kv "DWGID" ctx) "BASELINE"))))
    ;; Exploded / burst from a stamped parent erased in the same command.
    ((and (= mode "NEW") src (ips:cmd-in cmd *IPS:DeriveCmds*))
     (setq rec (ips:derive src cmd)))
    ;; First time we see this object.
    (T
     (setq ctype (cond ((= mode "BASE") "BASELINE")
                       ((= mode "SEAL") "SENTINEL")
                       ((= mode "MOD") "PRE-EXISTING")
                       (T (ips:classify cmd)))
           org   (if (wcmatch ctype "NATIVE,AUTO,BASELINE,SENTINEL,INSERTED:*") *IPS:Org* "(unclaimed)"))
     (setq rec
       (if (= mode "MOD")
         ;; Existed before tracking: we know where it is, not who made it.
         (ips:origin nil org "(unknown)" "" (strcat "before " when)
                     (ips:kv "DWG" ctx) (ips:kv "DWGID" ctx) ctype)
         (ips:origin nil org me (ips:kv "HOST" ctx) when
                     (ips:kv "DWG" ctx) (ips:kv "DWGID" ctx) ctype)))))
  ;; Touch fields.
  (if (member mode '("BASE" "SEAL"))
    (setq hist (cons (strcat when " " me (if (= mode "SEAL") " IPSEAL @" " IPMARK @") (ips:kv "DWG" ctx)) hist))
    (progn
      (if cmd
        (setq rec (ips:put* rec (list (cons "M_USER" me)
                                      (cons "M_HOST" (ips:kv "HOST" ctx))
                                      (cons "M_TIME" when)
                                      (cons "M_CMD" cmd)
                                      (cons "M_DWG" (ips:kv "DWG" ctx))
                                      (cons "M_DWGID" (ips:kv "DWGID" ctx)))))
        (setq rec (ips:put* rec (list (cons "A_USER" me)
                                      (cons "A_TIME" when)
                                      (cons "A_DWG" (ips:kv "DWG" ctx))))))
      (setq n (atoi (ips:str (ips:kv "N" rec))))
      (setq rec  (ips:put rec "N" (itoa (1+ n)))
            hist (cons (strcat when " " me " " (if cmd cmd "(no command)") " @" (ips:kv "DWG" ctx)) hist))))
  (setq hist (ips:take (mapcar (function (lambda (h) (ips:clip h 200))) hist) *IPS:HistoryDepth*))
  ;; The geometry fingerprint is refreshed only when we observe an edit.
  ;; IPMARK never overwrites one, so edits made outside tracking stay visible;
  ;; IPSEAL refreshes it only if the geometry matched before the watermark.
  (if (or (null (ips:kv "GEO" rec))
          (member mode '("NEW" "MOD"))
          (and (= mode "SEAL") *IPS:SealGeoOK*))
    (setq rec (ips:put rec "GEO" (ips:geo obj))))
  (setq rec (ips:put* rec (list (cons "V" "1")
                                (cons "TZ" (ips:kv "TZ" ctx))
                                (cons "KEYID" (ips:keyid)))))
  (if (ips:write-safe obj (ips:finalize rec hist))
    (progn
      (ips:logrow when me cmd
                  (cond ((= mode "NEW") "CREATE") ((= mode "BASE") "MARK") ((= mode "SEAL") "SEAL")
                        (cmd "MODIFY") (T "AUTO-MODIFY"))
                  obj ctx)
      T)))

(defun ips:stamp* (obj when cmd mode ctx src / r)
  (setq r (vl-catch-all-apply 'ips:stamp (list obj when cmd mode ctx src)))
  (if (vl-catch-all-error-p r)
    (progn (princ (strcat "\nIPStamp: could not stamp an object - " (vl-catch-all-error-message r))) nil)
    r))

(defun ips:objrx-add (obj)
  (if *IPS:ObjRx*
    (vl-catch-all-apply 'vlr-owner-add (list *IPS:ObjRx* obj))
    (setq *IPS:ObjRx* (ips:make-objrx (list obj)))))

;;; -------------------------------------------------------------- flush ---
(defun ips:logfile ( / m)
  (setq m (strcase *IPS:LogMode*))
  (cond ((= m "OFF") nil)
        ((= m "DWG")
         (if (= (getvar "DWGTITLED") 1)
           (strcat (getvar "DWGPREFIX") (vl-filename-base (getvar "DWGNAME")) "_ipstamp.csv")))
        (T (vl-mkdir *IPS:LogMode*)
           (strcat (vl-string-right-trim "\\/" *IPS:LogMode*) "\\"
                   (vl-filename-base (getvar "DWGNAME")) "_ipstamp.csv"))))

(defun ips:log-flush ( / path)
  (if (and *IPS:Rows* (setq path (ips:logfile)))
    (ips:append-lines path
      (ips:csv-line '("time" "user" "host" "drawing" "action" "command" "handle" "object" "name"))
      (reverse *IPS:Rows*)))
  (setq *IPS:Rows* nil))

(defun ips:flush-core ( / doc ctx done obj ed src)
  (setq doc (ips:doc) *IPS:Rows* nil)
  (ips:ensure-app)
  (ips:ensure-dwginfo)
  (setq ctx (ips:context)
        src (vl-some (function (lambda (x) (nth 5 x))) *IPS:Erased*))
  (vla-startundomark doc)
  ;; 1. objects created during the command
  (foreach it (reverse *IPS:New*)
    (if (ips:trackable-p (setq ed (entget (car it))))
      (progn
        (setq obj (vlax-ename->vla-object (car it)))
        (ips:stamp* obj (cadr it) (caddr it) "NEW" ctx src)
        (setq done (cons obj done))
        (ips:objrx-add obj))))
  ;; 2. existing objects that were modified
  (foreach it (reverse *IPS:Pending*)
    (setq obj (car it))
    (if (and (not (vlax-erased-p obj)) (not (member obj done)))
      (progn
        (ips:stamp* obj (cadr it) (caddr it) "MOD" ctx nil)
        (setq done (cons obj done)))))
  ;; 3. erased objects: they cannot hold a stamp, so they go to the log
  (foreach it (reverse *IPS:Erased*)
    (if (vlax-erased-p (car it))
      (setq *IPS:Rows*
        (cons (ips:csv-line (list (cadr it) (ips:kv "USER" ctx) (ips:kv "HOST" ctx) (ips:kv "DWG" ctx)
                                  "ERASE" (ips:str (caddr it)) (nth 3 it) (nth 4 it) ""))
              *IPS:Rows*))))
  (vla-endundomark doc)
  (if done (setq *IPS:StampLast* T))
  (ips:log-flush))

(defun ips:flush ( / r)
  (if (and (not *IPS:Off*) (not *IPS:Busy*) (or *IPS:Pending* *IPS:New* *IPS:Erased*))
    (progn
      (setq *IPS:Busy* T)
      (setq r (vl-catch-all-apply 'ips:flush-core nil))
      (setq *IPS:Pending* nil *IPS:New* nil *IPS:Erased* nil *IPS:Busy* nil)
      (if (vl-catch-all-error-p r)
        (princ (strcat "\nIPStamp: " (vl-catch-all-error-message r))))))
  (princ))

;;; ---------------------------------------------------------- callbacks ---
;; Object reactor: queue only. Never touch the notifying object here.
(defun ips:cb-modified (owner rx args)
  (if (and (not *IPS:Off*) (not *IPS:Busy*) (not (ips:ignored-p))
           (not (assoc owner *IPS:Pending*)))
    (setq *IPS:Pending* (cons (list owner (ips:now) (ips:cmd)) *IPS:Pending*))))

(defun ips:cb-erased (owner rx args / rec h n)
  (if (and (not *IPS:Off*) (not *IPS:Busy*) (not (ips:ignored-p)))
    (progn
      (setq rec (vl-catch-all-apply 'ips:xd-read (list owner))
            h   (vl-catch-all-apply 'vla-get-handle (list owner))
            n   (vl-catch-all-apply 'vla-get-objectname (list owner)))
      (setq *IPS:Erased*
        (cons (list owner (ips:now) (ips:cmd)
                    (if (vl-catch-all-error-p h) "?" h)
                    (if (vl-catch-all-error-p n) "?" n)
                    (if (vl-catch-all-error-p rec) nil rec))
              *IPS:Erased*)))))

;; Database reactor: catches every new object so it can be stamped and watched.
(defun ips:cb-appended (rx args / e)
  (if (and (not *IPS:Off*) (not *IPS:Busy*) (not (ips:ignored-p))
           (setq e (vl-some (function (lambda (x) (if (= (type x) 'ENAME) x))) (reverse args))))
    (setq *IPS:New* (cons (list e (ips:now) (ips:cmd)) *IPS:New*))))

(defun ips:cb-cmdstart (rx args / c)
  (if (not *IPS:Busy*)
    (progn
      (setq c (strcase (car args))
            *IPS:Depth* (1+ *IPS:Depth*))
      (if (= *IPS:Depth* 1) (setq *IPS:CurCmd* c))
      (if (/= c "U") (setq *IPS:StampLast* nil)))))

(defun ips:cb-cmdend (rx args / c)
  (if (not *IPS:Busy*)
    (progn
      (setq c (strcase (car args))
            *IPS:Depth* (max 0 (1- *IPS:Depth*)))
      (if (= *IPS:Depth* 0)
        (progn
          (setq *IPS:CurCmd* nil)
          (if (not *IPS:InLisp*) (ips:flush))
          (if (and (= c "U") *IPS:StampLast* (= (strcase *IPS:ChainUndo*) "YES"))
            (progn
              (setq *IPS:StampLast* nil)
              (vla-sendcommand (ips:doc) "_.U "))))))))

(defun ips:cb-lispstart (rx args)
  (if (not *IPS:Busy*)
    (setq *IPS:InLisp* T
          *IPS:LispName* (ips:clip (strcase (ips:str (car args))) 40))))

(defun ips:cb-lispend (rx args)
  (if (not *IPS:Busy*)
    (progn
      (setq *IPS:InLisp* nil *IPS:LispName* nil)
      (if (= *IPS:Depth* 0) (ips:flush)))))

(defun ips:cb-save (rx args) (ips:flush))

;;; ------------------------------------------------------ attach/detach ---
(defun ips:make-objrx (owners)
  (vlr-object-reactor owners "IPSTAMP"
    '((:vlr-modified . ips:cb-modified)
      (:vlr-erased   . ips:cb-erased))))

(defun ips:detach ()
  (foreach grp (vlr-reactors)
    (foreach r (cdr grp)
      (if (= (vlr-data r) "IPSTAMP") (vlr-remove r))))
  (setq *IPS:ObjRx* nil *IPS:CmdRx* nil *IPS:LispRx* nil *IPS:DbRx* nil *IPS:DwgRx* nil
        *IPS:Pending* nil *IPS:New* nil *IPS:Erased* nil
        *IPS:Depth* 0 *IPS:CurCmd* nil *IPS:InLisp* nil))

(defun ips:attach ( / objs)
  (ips:detach)
  (setq objs (ips:collect))
  (if objs (setq *IPS:ObjRx* (ips:make-objrx objs)))
  ;; Keep every reactor in a global so none is ever garbage collected.
  (setq *IPS:CmdRx*
    (vlr-command-reactor "IPSTAMP"
      '((:vlr-commandWillStart . ips:cb-cmdstart)
        (:vlr-commandEnded     . ips:cb-cmdend)
        (:vlr-commandCancelled . ips:cb-cmdend)
        (:vlr-commandFailed    . ips:cb-cmdend))))
  (setq *IPS:LispRx*
    (vlr-lisp-reactor "IPSTAMP"
      '((:vlr-lispWillStart . ips:cb-lispstart)
        (:vlr-lispEnded     . ips:cb-lispend)
        (:vlr-lispCancelled . ips:cb-lispend))))
  (setq *IPS:DbRx*  (vlr-acdb-reactor "IPSTAMP" '((:vlr-objectAppended . ips:cb-appended))))
  (setq *IPS:DwgRx* (vlr-dwg-reactor "IPSTAMP" '((:vlr-beginSave . ips:cb-save))))
  (length objs))

;;; -------------------------------------------------------------- IPWHO ---
(defun ips:+ (s) (setq *IPS:L* (cons s *IPS:L*)))

(defun ips:describe (obj / rec v g nm sh wm stripped)
  (setq *IPS:L* nil
        rec (ips:xd-read obj)
        sh  (ips:shadow-read obj)
        wm  (ips:wm-count obj))
  (if (and (null rec) (= (car sh) "VALID"))
    (setq rec (cdr sh) stripped T))
  (ips:+ (strcat (ips:str (ips:prop obj 'ObjectName))
                 "   handle " (ips:str (ips:prop obj 'Handle))
                 "   layer " (ips:str (ips:prop obj 'Layer))))
  (if (setq nm (ips:prop obj 'Name)) (ips:+ (strcat "Name: " (ips:str nm))))
  (ips:+ "")
  (if stripped
    (progn
      (ips:+ "*** THE VISIBLE STAMP WAS REMOVED FROM THIS OBJECT. ***")
      (ips:+ "*** Origin below is recovered from the hidden encrypted copy. ***")
      (ips:+ "")))
  (if (null rec)
    (progn
      (ips:+ "NO IP STAMP ON THIS OBJECT.")
      (ips:+ "It predates tracking, was only edited where IPStamp was not")
      (ips:+ "running, or arrived from outside without our marks.")
      (ips:+ "In our own drawings, run IPMARK to baseline-claim it."))
    (progn
      (setq v (ips:verify rec)
            g (ips:geo-status obj rec))
      (ips:+ "LAST TOUCHED")
      (if (ips:kv "M_USER" rec)
        (progn
          (ips:+ (strcat "  " (ips:kv "M_USER" rec) "  on " (ips:str (ips:kv "M_HOST" rec))))
          (ips:+ (strcat "  " (ips:str (ips:kv "M_TIME" rec)) "  (" (ips:str (ips:kv "TZ" rec)) ")"))
          (ips:+ (strcat "  command " (ips:str (ips:kv "M_CMD" rec)) "  in " (ips:str (ips:kv "M_DWG" rec)))))
        (ips:+ "  no command edits recorded"))
      (if (ips:kv "A_USER" rec)
        (progn
          (ips:+ "LAST CHANGE WITHOUT A COMMAND (Properties palette, rebuild, sync)")
          (ips:+ (strcat "  " (ips:kv "A_USER" rec) "  " (ips:str (ips:kv "A_TIME" rec))
                         "  in " (ips:str (ips:kv "A_DWG" rec))))))
      (ips:+ "")
      (ips:+ "ORIGIN")
      (ips:+ (strcat "  Owner:   " (ips:str (ips:kv "ORG" rec))))
      (ips:+ (strcat "  Created: " (ips:str (ips:kv "C_TIME" rec)) "  by " (ips:str (ips:kv "C_USER" rec))
                     (if (/= (ips:str (ips:kv "C_HOST" rec)) "") (strcat " on " (ips:kv "C_HOST" rec)) "")))
      (ips:+ (strcat "  Drawing: " (ips:str (ips:kv "C_DWG" rec))))
      (ips:+ (strcat "  DWG id:  " (ips:str (ips:kv "C_DWGID" rec))))
      (ips:+ (strcat "  How:     " (ips:str (ips:kv "C_TYPE" rec))))
      (ips:+ "")
      (ips:+ (strcat "EDITS RECORDED: " (ips:str (ips:kv "N" rec))))
      (ips:+ "HISTORY (newest first)")
      (foreach p rec (if (= (car p) "H") (ips:+ (strcat "  " (cdr p)))))
      (ips:+ "")
      (ips:+ "INTEGRITY")
      (ips:+ (strcat "  Origin signature: " (ips:sigtext (car v))))
      (ips:+ (strcat "  Record signature: " (ips:sigtext (cadr v))))
      (ips:+ (strcat "  Geometry: "
                     (cond ((= g "UNCHANGED") "matches the last stamp")
                           ((= g "CHANGED")
                            "CHANGED since the last stamp (edited where tracking was not running)")
                           (T "no fingerprint"))))
      (if (/= (ips:str (ips:kv "IP" rec)) "")
        (progn (ips:+ "") (ips:+ (strcat "IP: " (ips:kv "IP" rec)))))))
  (ips:+ "")
  (ips:+ "HIDDEN LAYERS")
  (ips:+ (strcat "  Hidden copy: "
                 (cond ((= (car sh) "VALID") "present, readable with our key")
                       ((= (car sh) "UNREADABLE") "present, NOT readable with our key (another firm or old key)")
                       (T "none"))))
  (ips:+ (strcat "  Watermark:   "
                 (if (> (cdr wm) 0)
                   (strcat (itoa (car wm)) " of " (itoa (cdr wm)) " coordinates carry our mark"
                           (if (= (car wm) (cdr wm)) " (sealed)" ""))
                   "not applicable to this object type")))
  (reverse *IPS:L*))

(defun ips:show (obj / lines)
  (setq lines (ips:describe obj))
  (foreach l lines (princ (strcat "\n" l)))
  (alert (ips:join lines "\n")))

(defun c:IPWHO ( / ss e)
  (setq e (cond ((setq ss (ssget "_I")) (ssname ss 0))
                ((car (entsel "\nSelect object to look up: ")))))
  (if e (ips:show (vlax-ename->vla-object e)))
  (princ))

(defun c:IPWHON ( / s)
  (if (setq s (nentsel "\nSelect object inside a block or xref: "))
    (ips:show (vlax-ename->vla-object (car s))))
  (princ))

;;; ------------------------------------------------------------- IPMARK ---
(defun ips:setprop (key val / si tmp)
  (setq si (vla-get-summaryinfo (ips:doc)))
  (if (vl-catch-all-error-p (vl-catch-all-apply 'vla-getcustombykey (list si key 'tmp)))
    (vl-catch-all-apply 'vla-addcustominfo (list si key val))
    (vl-catch-all-apply 'vla-setcustombykey (list si key val))))

(defun ips:claim-drawing (ctx when / info)
  (setq info (ips:xrec-read (ips:doc) "DWGINFO"))
  (if (or (null (ips:kv "OWNER" info)) (= (ips:kv "OWNER" info) *IPS:Org*))
    (progn
      (setq info (ips:put* info
                   (list (cons "OWNER" *IPS:Org*)
                         (cons "OWNER_NOTICE" *IPS:IPNotice*)
                         (cons "OWNER_DWGID" (ips:kv "DWGID" ctx))
                         (cons "MARKED_BY" (ips:kv "USER" ctx))
                         (cons "MARKED_TIME" when)
                         (cons "OWNER_KEYID" (ips:keyid)))))
      (setq info (ips:put info "OWNER_SIG" (ips:mac (ips:canon-owner info))))
      (ips:xrec-put "DWGINFO" info)
      (ips:setprop "IP_OWNER" *IPS:Org*)
      (ips:setprop "IP_NOTICE" *IPS:IPNotice*)
      (ips:setprop "IP_DWGID" (ips:kv "DWGID" ctx))
      (ips:setprop "IP_MARKED" (strcat when " " (ips:kv "USER" ctx)))
      T)
    (progn
      (princ (strcat "\nIPMARK: this drawing is already claimed by \"" (ips:kv "OWNER" info)
                     "\". Drawing-level claim left unchanged."))
      nil)))

(defun ips:mark-core ( / ctx when rec)
  (ips:ensure-app)
  (ips:ensure-dwginfo)
  (setq ctx (ips:context) when (ips:now))
  (foreach obj (ips:collect)
    (setq rec (ips:rec-any obj))
    (cond
      ((null rec)
       (if (ips:stamp* obj when nil "BASE" ctx nil) (setq new (1+ new))))
      ((and (= (ips:kv "ORG" rec) "(unclaimed)")
            (= (ips:kv "C_TYPE" rec) "PRE-EXISTING"))
       (if (ips:stamp* obj when nil "BASE" ctx nil) (setq up (1+ up))))
      ((= (ips:kv "ORG" rec) *IPS:Org*) (setq ours (1+ ours)))
      (T (setq other (1+ other)))))
  (ips:claim-drawing ctx when)
  (ips:log-flush))

;; -> (newly-marked upgraded already-ours imported-or-third-party)
(defun ips:mark ( / doc new up ours other r)
  (setq new 0 up 0 ours 0 other 0 doc (ips:doc)
        *IPS:Busy* T *IPS:Rows* nil)
  (vla-startundomark doc)
  (setq r (vl-catch-all-apply 'ips:mark-core nil))
  (vla-endundomark doc)
  (setq *IPS:Busy* nil)
  (if (vl-catch-all-error-p r) (princ (strcat "\nIPMARK: " (vl-catch-all-error-message r))))
  (list new up ours other))

(defun ips:mark-report (res)
  (princ (strcat "\nIPMARK: " (itoa (car res)) " newly marked, "
                 (itoa (cadr res)) " pre-existing claimed, "
                 (itoa (caddr res)) " already ours, "
                 (itoa (cadddr res)) " imported / third-party left unclaimed (review with IPWHO or IPSCAN)."))
  (if (ips:default-key-p)
    (princ "\nIPMARK: WARNING - signing with the DEFAULT key. Set *IPS:KeyFile* before relying on these marks.")))

(defun c:IPMARK ( / ans)
  (initget "Yes No")
  (setq ans (getkword (strcat "\nClaim all unstamped objects in this drawing for \"" *IPS:Org*
                              "\"? Imported content is left alone. [Yes/No] <Yes>: ")))
  (if (/= ans "No") (ips:mark-report (ips:mark)))
  (princ))

;;; ------------------------------------------------------------- IPSEAL ---
;; Watermarks the coordinates of every object we own, refreshes its visible
;; stamp and hidden copy, and plants invisible sentinel points.
(defun ips:sentinels (ctx when / have mn mx h k pt e obj made)
  (setq have 0 made 0)
  (foreach obj (ips:collect)
    (if (and (ips:sentinel-p obj) (= (car (ips:shadow-read obj)) "VALID")) (setq have (1+ have))))
  (setq mn (getvar "EXTMIN") mx (getvar "EXTMAX") k 0)
  (if (and (< (car mn) (car mx)) (< (cadr mn) (cadr mx)))
    (while (< (+ have made) 3)
      (setq h  (ips:hash (strcat (ips:key) "|SENTINEL|" (itoa k) "|" (ips:now)))
            pt (list (+ (car mn) (* (- (car mx) (car mn)) (/ (ips:hexval (substr h 1 4)) 65535.0)))
                     (+ (cadr mn) (* (- (cadr mx) (cadr mn)) (/ (ips:hexval (substr h 5 4)) 65535.0)))
                     0.0)
            k  (1+ k))
      (if (setq e (entmakex (list '(0 . "POINT") '(8 . "0") '(60 . 1) (cons 10 pt))))
        (progn
          (setq obj (vlax-ename->vla-object e))
          (ips:wm-apply obj)
          (setq *IPS:SealGeoOK* T)
          (ips:stamp* obj when "IPSEAL" "SEAL" ctx nil)
          (setq made (1+ made)))
        (setq made 99))))
  (+ have (if (= made 99) 0 made)))

(defun ips:seal-core ( / ctx when rec r)
  (ips:ensure-app)
  (ips:ensure-dwginfo)
  (setq ctx (ips:context) when (ips:now))
  (foreach obj (ips:collect)
    (setq rec (ips:rec-any obj))
    (cond
      ((ips:sentinel-p obj) nil)                ; counted by ips:sentinels
      ((and rec (= (ips:kv "ORG" rec) *IPS:Org*))
        ;; Keep evidence of outside edits: only refresh the fingerprint if
        ;; the geometry matched it before we watermark.
        (setq *IPS:SealGeoOK* (/= (ips:geo-status obj rec) "CHANGED"))
        (if (ips:wm-rows obj)
          (progn
            (setq r (ips:unlocked obj 'ips:wm-apply (list obj)))
            (if (and (car r) (cdr r)) (setq moved (1+ moved)))))
        (if (ips:stamp* obj when "IPSEAL" "SEAL" ctx nil) (setq sealed (1+ sealed))))
      (T (setq skipped (1+ skipped)))))
  (setq *IPS:SealGeoOK* nil
        sents (ips:sentinels ctx when))
  (ips:log-flush))

;; -> (sealed watermarked-objects skipped sentinels)
(defun ips:seal ( / doc sealed moved skipped sents r)
  (setq sealed 0 moved 0 skipped 0 sents 0 doc (ips:doc)
        *IPS:Busy* T *IPS:Rows* nil)
  (vla-startundomark doc)
  (setq r (vl-catch-all-apply 'ips:seal-core nil))
  (vla-endundomark doc)
  (setq *IPS:Busy* nil)
  (if (vl-catch-all-error-p r) (princ (strcat "\nIPSEAL: " (vl-catch-all-error-message r))))
  (list sealed moved skipped sents))

(defun ips:seal-report (res)
  (princ (strcat "\nIPSEAL: " (itoa (car res)) " of our objects sealed (visible stamp + hidden copy), "
                 (itoa (cadr res)) " coordinate-watermarked, "
                 (itoa (caddr res)) " not ours and left untouched, "
                 (itoa (cadddr res)) " hidden sentinels in place.")))

(defun c:IPSEAL ( / ans)
  (princ (strcat "\nIPSEAL moves coordinates of our objects by at most "
                 (rtos (* *IPS:WMStep* *IPS:WMBins*) 2 6) " drawing units to embed the watermark."))
  (initget "Yes No")
  (setq ans (getkword "\nMark (IPMARK) and seal this drawing now? [Yes/No] <Yes>: "))
  (if (/= ans "No")
    (progn
      (ips:mark-report (ips:mark))
      (ips:seal-report (ips:seal))
      (princ "\nSAVE the drawing to keep the seal.")))
  (princ))

;; Geometry manifest of everything we own, kept at the office (never sent).
(defun ips:manifest-write (to why / path f rec n)
  (if (/= *IPS:ManifestDir* "")
    (progn
      (vl-mkdir *IPS:ManifestDir*)
      (setq path (strcat (vl-string-right-trim "\\/" *IPS:ManifestDir*) "\\"
                         (ips:fname-stamp) "_" (vl-filename-base (getvar "DWGNAME")) ".ipm")
            n 0)
      (if (setq f (open path "w"))
        (progn
          (write-line (ips:join (list "#IPM" (ips:now) (ips:user) to why (getvar "DWGNAME")
                                      (getvar "FINGERPRINTGUID"))
                                "|")
                      f)
          (foreach obj (ips:collect)
            (if (and (setq rec (ips:rec-any obj)) (= (ips:kv "ORG" rec) *IPS:Org*))
              (progn (write-line (ips:geo obj) f) (setq n (1+ n)))))
          (close f)
          (princ (strcat "\nIPXMIT: manifest of " (itoa n) " objects written to " path)))))))

;;; ------------------------------------------------------------- IPXMIT ---
(defun c:IPXMIT ( / to why entry lst)
  (cond
    ((= (getvar "DWGTITLED") 0) (princ "\nIPXMIT: save the drawing first."))
    (T
     (setq to  (getstring T "\nRecipient (company / person): ")
           why (getstring T "\nPurpose / package reference: "))
     (initget "Yes No")
     (if (/= (getkword "\nMark and seal before sending (IPMARK + IPSEAL)? [Yes/No] <Yes>: ") "No")
       (progn (ips:mark-report (ips:mark)) (ips:seal-report (ips:seal))))
     (ips:manifest-write to why)
     (setq entry (ips:join (list (ips:now) (ips:user) to why (getvar "DWGNAME")) " | ")
           lst   (mapcar 'cdr (vl-remove-if-not (function (lambda (p) (= (car p) "XMIT")))
                                                (ips:xrec-read (ips:doc) "XMIT")))
           lst   (ips:take (cons entry lst) 50))
     (setq *IPS:Busy* T)
     (vl-catch-all-apply 'ips:xrec-put
       (list "XMIT" (mapcar (function (lambda (s) (cons "XMIT" s))) lst)))
     (setq *IPS:Busy* nil)
     (if (/= *IPS:RegisterFile* "")
       (ips:append-lines *IPS:RegisterFile*
         (ips:csv-line '("time" "user" "host" "file" "dwgid" "recipient" "purpose"))
         (list (ips:csv-line (list (ips:now) (ips:user) (ips:host)
                                   (strcat (getvar "DWGPREFIX") (getvar "DWGNAME"))
                                   (getvar "FINGERPRINTGUID") to why)))))
     (princ "\nIPXMIT: transmittal recorded inside the drawing. SAVE now so the record travels with the file.")))
  (princ))

;;; ------------------------------------------------------- status / on/off ---
(defun c:IPSTATUS ()
  (princ (strcat "\nIPStamp " (if *IPS:Off* "OFF" "ON")
                 " | objects watched: " (itoa (if *IPS:ObjRx* (length (vlr-owners *IPS:ObjRx*)) 0))
                 " | org: " *IPS:Org*
                 " | key id: " (ips:keyid)
                 (if (ips:default-key-p) " (DEFAULT KEY - set *IPS:KeyFile*)" "")
                 " | log: " (cond ((ips:logfile)) ("off"))))
  (princ))

(defun c:IPSTAMPOFF ()
  (setq *IPS:Off* T)
  (ips:detach)
  (princ "\nIPStamp: tracking suspended in this drawing.")
  (princ))

(defun c:IPSTAMPON ( / n)
  (setq *IPS:Off* nil n (ips:attach))
  (princ (strcat "\nIPStamp: tracking " (itoa n) " objects."))
  (princ))

;;; ------------------------------------------------- right-click menu ---
(setq *IPS:MenuLabel* "IP Stamp - who touched this?")

(defun ips:menu-has (pm lbl / f)
  (vlax-for it pm (if (= (ips:prop it 'Label) lbl) (setq f T)))
  f)

;; Adds the entry to the edit-mode shortcut menu ("Edit Menu"), which AutoCAD
;; merges with every object-specific menu (alignments, profiles, ...).
(defun ips:menu-add ( / n)
  (setq n 0)
  (vlax-for mg (vla-get-menugroups (vlax-get-acad-object))
    (vlax-for pm (vla-get-menus mg)
      (if (and (= (vla-get-shortcutmenu pm) :vlax-true)
               (wcmatch (strcase (vla-get-namenomnemonic pm)) "*EDIT MENU*,*EDIT MODE*")
               (not (ips:menu-has pm *IPS:MenuLabel*)))
        (progn
          (vla-addseparator pm (vla-get-count pm))
          (vla-addmenuitem pm (vla-get-count pm) *IPS:MenuLabel* "_IPWHO ")
          (setq n (1+ n))))))
  n)

(defun c:IPMENU ( / r)
  (setq r (vl-catch-all-apply 'ips:menu-add nil))
  (princ (cond ((vl-catch-all-error-p r) (strcat "\nIPMENU: " (vl-catch-all-error-message r)))
               ((> r 0) "\nIPMENU: added to the right-click edit menu.")
               (T "\nIPMENU: entry already present (or no edit menu found - see README to add it in CUI).")))
  (princ))

(defun c:IPMENUREMOVE ( / dead)
  (vlax-for mg (vla-get-menugroups (vlax-get-acad-object))
    (vlax-for pm (vla-get-menus mg)
      (if (= (vla-get-shortcutmenu pm) :vlax-true)
        (vlax-for it pm
          (if (= (ips:prop it 'Label) *IPS:MenuLabel*) (setq dead (cons it dead)))))))
  (foreach it dead (vl-catch-all-apply 'vla-delete (list it)))
  (princ (strcat "\nIPMENUREMOVE: removed " (itoa (length dead)) " entr" (if (= (length dead) 1) "y." "ies.")))
  (princ))

;;; --------------------------------------------------------------- start ---
(setq *IPS:KeyCache* nil)
(princ (strcat "\nIPStamp " *IPS:CoreVersion* ": watching " (itoa (ips:attach)) " objects for \"" *IPS:Org* "\"."))
(if (= (strcase *IPS:AutoMenu*) "YES") (vl-catch-all-apply 'ips:menu-add nil))
(if (ips:default-key-p)
  (princ "\nIPStamp: using the DEFAULT signing key. Set *IPS:KeyFile* (see README)."))
(princ "\nCommands: IPWHO  IPWHON  IPMARK  IPSEAL  IPXMIT  IPSTATUS  IPSTAMPON  IPSTAMPOFF  IPMENU")
(princ)
