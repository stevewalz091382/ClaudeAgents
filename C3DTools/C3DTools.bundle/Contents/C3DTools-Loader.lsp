;;; ============================================================================
;;; C3DTools-Loader.lsp
;;;
;;; Loads C3DTools into the current drawing:
;;;   1. finds the install folder
;;;   2. loads C3DTools-Config.lsp from it
;;;   3. loads C3DTools.vlx (or, for development builds only, the .lsp sources)
;;;
;;; Install folder resolution, first match wins:
;;;   - *c3dt:home* if already set before this file is loaded
;;;   - the C3DTOOLS_HOME environment variable (set by Install.ps1 -InstallDir)
;;;   - the folder this file is found in on the support path
;;;   - %APPDATA% or %ProgramData% \Autodesk\ApplicationPlugins\C3DTools.bundle\Contents
;;; ============================================================================

(vl-load-com)

(defun c3dt:loader-dir-ok (d)
  (and (= (type d) 'STR)
       (/= d "")
       (or (findfile (strcat (vl-string-right-trim "\\/" d) "\\C3DTools.vlx"))
           (findfile (strcat (vl-string-right-trim "\\/" d) "\\C3DTools-Config.lsp"))))
)

(defun c3dt:loader-find-home ( / f base)
  (cond
    ((and (boundp '*c3dt:home*) (c3dt:loader-dir-ok *c3dt:home*)) *c3dt:home*)
    ((c3dt:loader-dir-ok (getenv "C3DTOOLS_HOME")) (getenv "C3DTOOLS_HOME"))
    ((and (setq f (findfile "C3DTools-Loader.lsp"))
          (c3dt:loader-dir-ok (vl-filename-directory f)))
     (vl-filename-directory f))
    ((and (setq base (getenv "APPDATA"))
          (c3dt:loader-dir-ok (strcat base "\\Autodesk\\ApplicationPlugins\\C3DTools.bundle\\Contents")))
     (strcat base "\\Autodesk\\ApplicationPlugins\\C3DTools.bundle\\Contents"))
    ((and (setq base (getenv "ProgramData"))
          (c3dt:loader-dir-ok (strcat base "\\Autodesk\\ApplicationPlugins\\C3DTools.bundle\\Contents")))
     (strcat base "\\Autodesk\\ApplicationPlugins\\C3DTools.bundle\\Contents"))
  )
)

(defun c3dt:loader-load (path / r)
  (setq r (vl-catch-all-apply 'load (list path)))
  (if (vl-catch-all-error-p r)
    (progn
      (princ (strcat "\n[C3DTools] Failed to load " path ": " (vl-catch-all-error-message r)))
      nil
    )
    T
  )
)

(defun c3dt:loader-main ( / home vlx src)
  ;; The trial scripts used unprefixed names; running both would double every
  ;; warning and redefine shared helpers.
  (if (or (= (type (eval 'c3dg-init)) 'USUBR) (= (type (eval 'c3d:autoinit)) 'USUBR))
    (princ "\n[C3DTools] WARNING: an older C3DGUARD / C3DAUDIT / Civil3D-ImpactAgent .lsp is also loaded. Remove its (load ...) lines from acaddoc.lsp or the Startup Suite.")
  )
  (setq home (c3dt:loader-find-home))
  (if (not home)
    (princ "\n[C3DTools] Install folder not found. Re-run Install.cmd, or set C3DTOOLS_HOME.")
    (progn
      (setq home (strcat (vl-string-right-trim "\\/" (vl-string-translate "/" "\\" home)) "\\"))
      (setq *c3dt:home* home)
      (if (findfile (strcat home "C3DTools-Config.lsp"))
        (c3dt:loader-load (strcat home "C3DTools-Config.lsp"))
      )
      (cond
        ((findfile (setq vlx (strcat home "C3DTools.vlx")))
         (c3dt:loader-load vlx))
        ;; Development fallback: sources next to the loader (installed with
        ;; -AllowSource) or in the repository layout.
        ((or (findfile (strcat (setq src (strcat home "src\\")) "C3DTools-Core.lsp"))
             (findfile (strcat (setq src (strcat home "..\\..\\src\\")) "C3DTools-Core.lsp")))
         (princ "\n[C3DTools] C3DTools.vlx not found - loading development sources.")
         (and (c3dt:loader-load (strcat src "C3DTools-Core.lsp"))
              (c3dt:loader-load (strcat src "C3DGuard.lsp"))
              (c3dt:loader-load (strcat src "C3DAudit.lsp"))
              (c3dt:loader-load (strcat src "C3DImpact.lsp"))))
        (T (princ (strcat "\n[C3DTools] C3DTools.vlx is missing from " home)))
      )
      (if (boundp '*c3dt:version*)
        (princ (strcat "\nC3DTools " *c3dt:version* " loaded. Type C3DTOOLS-STATUS for details."))
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
