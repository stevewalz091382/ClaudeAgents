;;; ============================================================================
;;; CutOnce-Config.lsp  -  settings for the CutOnce Trial
;;;
;;; Copyright (c) 2026 Stephen Walz. All rights reserved.
;;;
;;; CutOnce Trial: the EXPLODE / BURST warning only.
;;; To unlock the full version, reach out to stevewalz@hotmail.com
;;;
;;; Edit the values below, save, and restart Civil 3D (or open a new drawing).
;;; Keep the ("Key" . value) shape.
;;;
;;;   T    means yes / on
;;;   nil  means no / off
;;;
;;; Each designer can switch the EXPLODE warning on or off for themselves in
;;; the CutOnce Control Center (CUTONCE). The values below are what a designer
;;; gets until they make their own choice.
;;; ============================================================================

(setq *cutonce:config*
  '(
    ("WarnEXPLODE"      . T)    ; EXPLODE / BURST of Civil 3D objects, blocks, hatches, attributes

    ;; How often the warning appears:
    ;;   "every"  every time
    ;;   "once"   the first time each warning shows in a Civil 3D session
    ("WarnFrequency" . "every")
  )
)

(princ)
