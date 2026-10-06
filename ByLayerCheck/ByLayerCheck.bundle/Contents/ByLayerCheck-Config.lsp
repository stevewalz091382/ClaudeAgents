;;; ============================================================================
;;; ByLayerCheck-Config.lsp  -  settings for ByLayerCheck
;;;
;;; Edit the values below, save, and open a new drawing (or restart Civil 3D).
;;; This file is plain text on purpose so CAD administrators can change it
;;; without rebuilding the application. Keep the ("Key" . value) shape.
;;;
;;;   T    means yes / on
;;;   nil  means no / off
;;; ============================================================================

(setq *blc:config*
  '(
    ;; Run the check automatically each time a saved drawing opens.
    ;; With nil, the check only runs when a user types BLCHECK.
    ("CheckOnOpen" . T)

    ;; Show the dialog on open even when nothing is wrong.
    ;; With nil, the dialog appears only when a problem is found. The results
    ;; are always printed on the command line.
    ("AlwaysShow" . nil)

    ;; Also check objects inside named block definitions.
    ("ScanBlocks" . T)

    ;; Count Civil 3D data shortcut references (DREFs).
    ("ScanDrefs" . T)
  )
)

(princ)
