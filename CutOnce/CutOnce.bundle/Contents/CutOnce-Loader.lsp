;;; ============================================================================
;;; CutOnce-Loader.lsp
;;;
;;; Loads CutOnce into the current drawing:
;;;   1. finds the install folder
;;;   2. loads CutOnce-Config.lsp from it
;;;   3. loads CutOnce.vlx (or, for development builds only, the .lsp sources)
;;;
;;; Install folder resolution, first match wins:
;;;   - *mwise:home* if already set before this file is loaded
;;;   - the CUTONCE_HOME environment variable (set by Install.ps1 -InstallDir)
;;;   - the folder this file is found in on the support path
;;;   - %APPDATA% or %ProgramData% \Autodesk\ApplicationPlugins\CutOnce.bundle\Contents
;;; ============================================================================

(vl-load-com)

(defun mwise:loader-dir-ok (d)
  (and (= (type d) 'STR)
       (/= d "")
       (or (findfile (strcat (vl-string-right-trim "\\/" d) "\\CutOnce.vlx"))
           (findfile (strcat (vl-string-right-trim "\\/" d) "\\CutOnce-Config.lsp"))))
)

(defun mwise:loader-find-home ( / f base)
  (cond
    ((and (boundp '*mwise:home*) (mwise:loader-dir-ok *mwise:home*)) *mwise:home*)
    ((mwise:loader-dir-ok (getenv "CUTONCE_HOME")) (getenv "CUTONCE_HOME"))
    ;; a custom-folder install from before the CutOnce rename
    ((mwise:loader-dir-ok (getenv "MODELWISE_HOME")) (getenv "MODELWISE_HOME"))
    ((and (setq f (findfile "CutOnce-Loader.lsp"))
          (mwise:loader-dir-ok (vl-filename-directory f)))
     (vl-filename-directory f))
    ((and (setq base (getenv "APPDATA"))
          (mwise:loader-dir-ok (strcat base "\\Autodesk\\ApplicationPlugins\\CutOnce.bundle\\Contents")))
     (strcat base "\\Autodesk\\ApplicationPlugins\\CutOnce.bundle\\Contents"))
    ((and (setq base (getenv "ProgramData"))
          (mwise:loader-dir-ok (strcat base "\\Autodesk\\ApplicationPlugins\\CutOnce.bundle\\Contents")))
     (strcat base "\\Autodesk\\ApplicationPlugins\\CutOnce.bundle\\Contents"))
  )
)

(defun mwise:loader-load (path / r)
  (setq r (vl-catch-all-apply 'load (list path)))
  (if (vl-catch-all-error-p r)
    (progn
      (princ (strcat "\n[CutOnce] Failed to load " path ": " (vl-catch-all-error-message r)))
      nil
    )
    T
  )
)

(defun mwise:loader-main ( / home vlx src)
  ;; The trial scripts used unprefixed names; running both would double every
  ;; warning and redefine shared helpers.
  (if (or (= (type (eval 'c3dg-init)) 'USUBR) (= (type (eval 'c3d:autoinit)) 'USUBR))
    (princ "\n[CutOnce] WARNING: an older C3DGUARD / C3DAUDIT / Civil3D-ImpactAgent .lsp is also loaded. Remove its (load ...) lines from acaddoc.lsp or the Startup Suite.")
  )
  ;; CutOnce replaces C3DTools; running both doubles every warning and log row.
  (if (boundp '*c3dt:version*)
    (princ "\n[CutOnce] WARNING: C3DTools is also loaded. CutOnce replaces it - re-run Install.cmd, or delete %APPDATA%\\Autodesk\\ApplicationPlugins\\C3DTools.bundle.")
  )
  ;; ByLayerCheck is now part of CutOnce; running both checks every drawing twice.
  (if (or (boundp '*blc:version*) (boundp '*blc:loaded*))
    (princ "\n[CutOnce] WARNING: the separate ByLayerCheck add-on is also loaded. It is now part of CutOnce - re-run Install.cmd, or delete %APPDATA%\\Autodesk\\ApplicationPlugins\\ByLayerCheck.bundle.")
  )
  (setq home (mwise:loader-find-home))
  (if (not home)
    (princ "\n[CutOnce] Install folder not found. Re-run Install.cmd, or set CUTONCE_HOME.")
    (progn
      (setq home (strcat (vl-string-right-trim "\\/" (vl-string-translate "/" "\\" home)) "\\"))
      (setq *mwise:home* home)
      (if (findfile (strcat home "CutOnce-Config.lsp"))
        (mwise:loader-load (strcat home "CutOnce-Config.lsp"))
      )
      (cond
        ((findfile (setq vlx (strcat home "CutOnce.vlx")))
         (mwise:loader-load vlx))
        ;; Development fallback: sources next to the loader (installed with
        ;; -AllowSource) or in the repository layout.
        ((or (findfile (strcat (setq src (strcat home "src\\")) "CutOnce-Core.lsp"))
             (findfile (strcat (setq src (strcat home "..\\..\\src\\")) "CutOnce-Core.lsp")))
         (princ "\n[CutOnce] CutOnce.vlx not found - loading development sources.")
         ;; order matters: the Control Center loads last and runs the
         ;; open-time check once everything else is in place
         (and (mwise:loader-load (strcat src "CutOnce-Core.lsp"))
              (mwise:loader-load (strcat src "CutOnce-Standards.lsp"))
              (mwise:loader-load (strcat src "CutOnce-Health.lsp"))
              (mwise:loader-load (strcat src "CutOnce-Guard.lsp"))
              (mwise:loader-load (strcat src "CutOnce-Impact.lsp"))
              (mwise:loader-load (strcat src "CutOnce-ControlCenter.lsp"))))
        (T (princ (strcat "\n[CutOnce] CutOnce.vlx is missing from " home)))
      )
      (if (boundp '*mwise:version*)
        (princ (strcat "\nCutOnce " *mwise:version* " loaded. Type CUTONCE for settings, CUTONCE-STATUS for details."))
      )
    )
  )
  (princ)
)

;; once per drawing, even if both the bundle and an acaddoc.lsp line load it
(if (not (boundp '*mwise:loaded*))
  (progn
    (setq *mwise:loaded* T)
    (mwise:loader-main)
  )
)
(princ)
