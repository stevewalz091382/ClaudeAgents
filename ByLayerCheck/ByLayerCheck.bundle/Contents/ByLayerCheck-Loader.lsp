;;; ============================================================================
;;; ByLayerCheck-Loader.lsp
;;;
;;; Loads ByLayerCheck into the current drawing:
;;;   1. finds the install folder
;;;   2. loads ByLayerCheck-Config.lsp from it
;;;   3. loads ByLayerCheck.vlx (or, for source builds, ByLayerCheck.lsp)
;;;
;;; Install folder resolution, first match wins:
;;;   - *blc:home* if already set before this file is loaded
;;;   - the BYLAYERCHECK_HOME environment variable (set by Install.ps1 -InstallDir)
;;;   - the folder this file is found in on the support path
;;;   - %APPDATA% or %ProgramData% \Autodesk\ApplicationPlugins\ByLayerCheck.bundle\Contents
;;; ============================================================================

(vl-load-com)

(defun blc:loader-dir-ok (d)
  (and (= (type d) 'STR)
       (/= d "")
       (or (findfile (strcat (vl-string-right-trim "\\/" d) "\\ByLayerCheck.vlx"))
           (findfile (strcat (vl-string-right-trim "\\/" d) "\\ByLayerCheck-Config.lsp"))))
)

(defun blc:loader-find-home ( / f base)
  (cond
    ((and (boundp '*blc:home*) (blc:loader-dir-ok *blc:home*)) *blc:home*)
    ((blc:loader-dir-ok (getenv "BYLAYERCHECK_HOME")) (getenv "BYLAYERCHECK_HOME"))
    ((and (setq f (findfile "ByLayerCheck-Loader.lsp"))
          (blc:loader-dir-ok (vl-filename-directory f)))
     (vl-filename-directory f))
    ((and (setq base (getenv "APPDATA"))
          (blc:loader-dir-ok (strcat base "\\Autodesk\\ApplicationPlugins\\ByLayerCheck.bundle\\Contents")))
     (strcat base "\\Autodesk\\ApplicationPlugins\\ByLayerCheck.bundle\\Contents"))
    ((and (setq base (getenv "ProgramData"))
          (blc:loader-dir-ok (strcat base "\\Autodesk\\ApplicationPlugins\\ByLayerCheck.bundle\\Contents")))
     (strcat base "\\Autodesk\\ApplicationPlugins\\ByLayerCheck.bundle\\Contents"))
  )
)

(defun blc:loader-load (path / r)
  (setq r (vl-catch-all-apply 'load (list path)))
  (if (vl-catch-all-error-p r)
    (progn
      (princ (strcat "\n[ByLayerCheck] Failed to load " path ": " (vl-catch-all-error-message r)))
      nil
    )
    T
  )
)

(defun blc:loader-main ( / home vlx src)
  (setq home (blc:loader-find-home))
  (if (not home)
    (princ "\n[ByLayerCheck] Install folder not found. Re-run Install.cmd, or set BYLAYERCHECK_HOME.")
    (progn
      (setq home (strcat (vl-string-right-trim "\\/" (vl-string-translate "/" "\\" home)) "\\"))
      (setq *blc:home* home)
      (if (findfile (strcat home "ByLayerCheck-Config.lsp"))
        (blc:loader-load (strcat home "ByLayerCheck-Config.lsp"))
      )
      (cond
        ((findfile (setq vlx (strcat home "ByLayerCheck.vlx")))
         (blc:loader-load vlx))
        ;; Source build: the .lsp next to the loader (installed with
        ;; -AllowSource) or in the repository layout.
        ((or (findfile (setq src (strcat home "src\\ByLayerCheck.lsp")))
             (findfile (setq src (strcat home "..\\..\\src\\ByLayerCheck.lsp"))))
         (princ "\n[ByLayerCheck] ByLayerCheck.vlx not found - loading source.")
         (blc:loader-load src))
        (T (princ (strcat "\n[ByLayerCheck] ByLayerCheck.vlx is missing from " home)))
      )
      (if (boundp '*blc:version*)
        (princ (strcat "\nByLayerCheck " *blc:version* " loaded. Type BLCHECK to run it, BLCHECK-STATUS for details."))
      )
    )
  )
  (princ)
)

;; once per drawing, even if both the bundle and an acaddoc.lsp line load it
(if (not (boundp '*blc:loaded*))
  (progn
    (setq *blc:loaded* T)
    (blc:loader-main)
  )
)
(princ)
