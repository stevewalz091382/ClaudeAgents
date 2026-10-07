;;; ============================================================================
;;; CutOnce-Loader.lsp
;;;
;;; Loads CutOnce into the current drawing:
;;;   1. finds the install folder
;;;   2. loads CutOnce-Config.lsp from it
;;;   3. loads CutOnce.vlx (or, for development builds only, the .lsp sources)
;;;
;;; Install folder resolution, first match wins:
;;;   - *c3dt:home* if already set before this file is loaded
;;;   - the CUTONCE_HOME environment variable (set by Install.ps1 -InstallDir)
;;;   - the folder this file is found in on the support path
;;;   - %APPDATA% or %ProgramData% \Autodesk\ApplicationPlugins\CutOnce.bundle\Contents
;;; ============================================================================

(vl-load-com)

(defun c3dt:loader-dir-ok (d)
  (and (= (type d) 'STR)
       (/= d "")
       (or (findfile (strcat (vl-string-right-trim "\\/" d) "\\CutOnce.vlx"))
           (findfile (strcat (vl-string-right-trim "\\/" d) "\\CutOnce-Config.lsp"))))
)

(defun c3dt:loader-find-home ( / f base)
  (cond
    ((and (boundp '*c3dt:home*) (c3dt:loader-dir-ok *c3dt:home*)) *c3dt:home*)
    ((c3dt:loader-dir-ok (getenv "CUTONCE_HOME")) (getenv "CUTONCE_HOME"))
    ((c3dt:loader-dir-ok (getenv "C3DTOOLS_HOME")) (getenv "C3DTOOLS_HOME"))
    ((and (setq f (findfile "CutOnce-Loader.lsp"))
          (c3dt:loader-dir-ok (vl-filename-directory f)))
     (vl-filename-directory f))
    ((and (setq base (getenv "APPDATA"))
          (c3dt:loader-dir-ok (strcat base "\\Autodesk\\ApplicationPlugins\\CutOnce.bundle\\Contents")))
     (strcat base "\\Autodesk\\ApplicationPlugins\\CutOnce.bundle\\Contents"))
    ((and (setq base (getenv "ProgramData"))
          (c3dt:loader-dir-ok (strcat base "\\Autodesk\\ApplicationPlugins\\CutOnce.bundle\\Contents")))
     (strcat base "\\Autodesk\\ApplicationPlugins\\CutOnce.bundle\\Contents"))
  )
)

(defun c3dt:loader-load (path / r)
  (setq r (vl-catch-all-apply 'load (list path)))
  (if (vl-catch-all-error-p r)
    (progn
      (princ (strcat "\n[CutOnce] Failed to load " path ": " (vl-catch-all-error-message r)))
      nil
    )
    T
  )
)

(defun c3dt:loader-main ( / home vlx src)
  ;; The trial scripts used unprefixed names; running both would double every
  ;; warning and redefine shared helpers.
  (if (or (= (type (eval 'c3dg-init)) 'USUBR) (= (type (eval 'c3d:autoinit)) 'USUBR))
    (princ "\n[CutOnce] WARNING: an older C3DGUARD / C3DAUDIT / Civil3D-ImpactAgent .lsp is also loaded. Remove its (load ...) lines from acaddoc.lsp or the Startup Suite.")
  )
  (setq home (c3dt:loader-find-home))
  (if (not home)
    (princ "\n[CutOnce] Install folder not found. Re-run Install.cmd, or set CUTONCE_HOME.")
    (progn
      (setq home (strcat (vl-string-right-trim "\\/" (vl-string-translate "/" "\\" home)) "\\"))
      (setq *c3dt:home* home)
      (if (findfile (strcat home "CutOnce-Config.lsp"))
        (c3dt:loader-load (strcat home "CutOnce-Config.lsp"))
      )
      (cond
        ((findfile (setq vlx (strcat home "CutOnce.vlx")))
         (c3dt:loader-load vlx))
        ;; Development fallback: sources next to the loader (installed with
        ;; -AllowSource) or in the repository layout.
        ((or (findfile (strcat (setq src (strcat home "src\\")) "CutOnce-Core.lsp"))
             (findfile (strcat (setq src (strcat home "..\\..\\src\\")) "CutOnce-Core.lsp")))
         (princ "\n[CutOnce] CutOnce.vlx not found - loading development sources.")
         (and (c3dt:loader-load (strcat src "CutOnce-Core.lsp"))
              (c3dt:loader-load (strcat src "C3DGuard.lsp"))
              (c3dt:loader-load (strcat src "C3DAudit.lsp"))
              (c3dt:loader-load (strcat src "C3DImpact.lsp"))))
        (T (princ (strcat "\n[CutOnce] CutOnce.vlx is missing from " home)))
      )
      (if (boundp '*c3dt:version*)
        (princ (strcat "\nCutOnce " *c3dt:version* " loaded. Type CUTONCE-STATUS for details."))
      )
    )
  )
  (princ)
)

;; once per drawing, even if both the bundle and an acaddoc.lsp line load it
(if (not (boundp '*c3dt:loaded*))
  (progn
    (setq *c3dt:loaded* T)
    (c3dt:loader-main)
  )
)
(princ)
